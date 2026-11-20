#!/usr/bin/env node
// board-shot.mjs — the recorder board driver's browser half (openspec change
// ticket-auto-record, design D6). Run by lib/board-drivers/recorder.sh, never
// by an agent.
//
//   board-shot.mjs shoot --repos-root DIR --url URL --tid ID --column NAME
//                        --columns JSON_ARRAY --out FILE
//       Open the board with the saved session, wait until the card with the
//       ticket id is under the named column's header, save a screenshot
//       cropped to that column (temp file + rename). 20 s overall deadline.
//   board-shot.mjs --check  --repos-root DIR [--url URL]
//       Print one word: ok | browser-missing | no-session | expired | timeout
//       | error. Exit code as below.
//   board-shot.mjs --login  --repos-root DIR [--url URL]
//       Headed browser. Log in by hand; the session is saved when Enter is
//       pressed in the terminal (no terminal: once the page has stayed off
//       the login pages for 8 s).
//   board-shot.mjs --import --repos-root DIR
//       Save a Playwright storage state read from stdin (for a host with no
//       display: log in elsewhere, pipe the state over).
//
// Exit codes: 0 ok, 1 error, 2 usage, 3 card not in the column,
// 4 session expired (landed on a login page), 5 Playwright or Chromium
// missing, 6 deadline passed, 7 no saved session.
//
// The session ($REPOS_ROOT/.ticket-auto/record/linear-session.json) is a full
// login for its user. It is written with umask 077, dir 0700, file 0600, next
// to a `.gitignore` holding `*`. Nothing here prints its contents, and error
// text from the browser is printed only with RECORD_SHOT_DEBUG=1.
//
// Playwright is not a dependency of the plugin: the operator installs it
// under $REPOS_ROOT/.ticket-auto/record/ (`npm i playwright`, then
// `npx playwright install chromium`) and it is resolved from there.

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const EXIT = {
  ok: 0,
  error: 1,
  usage: 2,
  mismatch: 3,
  expired: 4,
  browserMissing: 5,
  timeout: 6,
  noSession: 7,
};
const DEADLINE_MS = 20000;
const LOGIN_WAIT_MS = 10 * 60 * 1000;
const VIEWPORT = { width: 1600, height: 900 };
const MARGIN = 16;
const DEFAULT_URL = 'https://linear.app/';

function debug(err) {
  if (process.env.RECORD_SHOT_DEBUG === '1' && err) {
    process.stderr.write(`board-shot: ${err.message || err}\n`);
  }
}

function usage(msg) {
  process.stderr.write(
    `board-shot.mjs: ${msg}\n` +
      'Usage: board-shot.mjs shoot --repos-root DIR --url URL --tid ID --column NAME --columns JSON --out FILE\n' +
      '       board-shot.mjs --check|--login|--import --repos-root DIR [--url URL]\n',
  );
  process.exit(EXIT.usage);
}

function parseArgs(argv) {
  const mode = argv[0];
  const opts = {};
  for (let i = 1; i < argv.length; i += 2) {
    const key = argv[i];
    const val = argv[i + 1];
    if (!key.startsWith('--') || val === undefined) usage(`bad argument '${key}'`);
    opts[key.slice(2)] = val;
  }
  return { mode, opts };
}

function recordDir(root) {
  return path.join(root, '.ticket-auto', 'record');
}

function sessionFile(root) {
  return path.join(recordDir(root), 'linear-session.json');
}

function loadPlaywright(root) {
  try {
    const req = createRequire(path.join(recordDir(root), 'package.json'));
    const pw = req('playwright');
    return pw && pw.chromium ? pw : null;
  } catch (err) {
    debug(err);
    return null;
  }
}

async function launch(pw, headless) {
  try {
    return await pw.chromium.launch({ headless });
  } catch (err) {
    debug(err);
    return null;
  }
}

// A page that is not on linear.app, or is on one of its sign-in paths, is a
// login page: the saved session did not get us in.
function isLoginUrl(raw) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    return false;
  }
  if (u.protocol === 'about:') return false;
  if (!/(^|\.)linear\.app$/.test(u.hostname)) return true;
  return /^\/(login|signup|auth|sso)(\/|$)/.test(u.pathname);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Save a storage state as the session: private from the first byte.
function saveSession(root, state) {
  process.umask(0o077);
  const dir = recordDir(root);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  if (fs.lstatSync(dir).isSymbolicLink()) throw new Error('record dir is a symlink');
  fs.chmodSync(dir, 0o700);
  const ignore = path.join(dir, '.gitignore');
  if (!fs.existsSync(ignore)) fs.writeFileSync(ignore, '*\n', { mode: 0o600 });
  const file = sessionFile(root);
  const tmp = `${file}.tmp-${process.pid}`;
  fs.rmSync(tmp, { force: true });
  fs.writeFileSync(tmp, JSON.stringify(state), { mode: 0o600, flag: 'wx' });
  fs.chmodSync(tmp, 0o600);
  fs.renameSync(tmp, file);
}

// Runs in the page. Finds the header row (the row of the page holding the
// most known column names), then the column whose header starts left of the
// card's centre. Returns {state: 'in-column', clip} | {state: 'elsewhere'} |
// {state: 'absent'}.
function locateCard({ tid, column, columns, margin }) {
  const rectsOf = (text) => {
    const out = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (node.nodeValue.trim() !== text || !node.parentElement) continue;
      const r = node.parentElement.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) out.push(r);
    }
    return out;
  };
  const heads = [];
  for (const name of columns) {
    for (const r of rectsOf(name)) heads.push({ name, left: r.left, top: r.top });
  }
  if (!heads.length) return { state: 'absent' };
  const rows = new Map();
  for (const h of heads) {
    const key = Math.round(h.top / 12);
    if (!rows.has(key)) rows.set(key, []);
    rows.get(key).push(h);
  }
  let row = null;
  for (const list of rows.values()) {
    const distinct = new Set(list.map((h) => h.name)).size;
    const best = row ? new Set(row.map((h) => h.name)).size : 0;
    if (distinct > best || (distinct === best && list[0].top < row[0].top)) row = list;
  }
  row.sort((a, b) => a.left - b.left);
  const rowTop = Math.min(...row.map((h) => h.top));
  const cards = rectsOf(tid).filter((r) => r.top > rowTop);
  if (!cards.length) return { state: 'absent' };
  const centre = cards[0].left + cards[0].width / 2;
  let idx = -1;
  for (let i = 0; i < row.length; i += 1) if (row[i].left <= centre) idx = i;
  if (idx < 0 || row[idx].name !== column) return { state: 'elsewhere' };
  const width =
    idx + 1 < row.length
      ? row[idx + 1].left - row[idx].left
      : idx > 0
        ? row[idx].left - row[idx - 1].left
        : 400;
  const x = Math.max(0, row[idx].left - margin);
  const y = Math.max(0, rowTop - margin);
  const right = Math.min(window.innerWidth, row[idx].left + width);
  return {
    state: 'in-column',
    clip: { x, y, width: Math.max(1, right - x), height: Math.max(1, window.innerHeight - y) },
  };
}

async function shoot(opts) {
  for (const k of ['repos-root', 'url', 'tid', 'column', 'columns', 'out']) {
    if (!opts[k]) usage(`shoot needs --${k}`);
  }
  let columns;
  try {
    columns = JSON.parse(opts.columns);
  } catch {
    usage('--columns is not JSON');
  }
  if (!Array.isArray(columns)) usage('--columns is not a JSON array');
  const root = opts['repos-root'];
  const out = opts.out;
  if (!fs.existsSync(path.dirname(out))) return EXIT.error;
  const pw = loadPlaywright(root);
  if (!pw) return EXIT.browserMissing;
  const session = sessionFile(root);
  if (!fs.existsSync(session)) return EXIT.noSession;

  const started = Date.now();
  const left = () => DEADLINE_MS - (Date.now() - started);
  const browser = await launch(pw, true);
  if (!browser) return EXIT.browserMissing;
  const hard = setTimeout(() => {
    browser.close().catch(() => {});
    setTimeout(() => process.exit(EXIT.timeout), 500);
  }, DEADLINE_MS);
  try {
    const context = await browser.newContext({ storageState: session, viewport: VIEWPORT });
    const page = await context.newPage();
    await page.goto(opts.url, { waitUntil: 'domcontentloaded', timeout: Math.max(1000, left()) });
    let seen = 0;
    let login = 0;
    while (left() > 2500) {
      if (isLoginUrl(page.url())) {
        login += 1;
        if (login >= 2) return EXIT.expired;
      } else {
        login = 0;
        const found = await page.evaluate(locateCard, {
          tid: opts.tid,
          column: opts.column,
          columns,
          margin: MARGIN,
        });
        // Two looks in a row, so a card mid-animation is not shot.
        seen = found.state === 'in-column' ? seen + 1 : 0;
        if (seen >= 2) {
          const tmp = path.join(path.dirname(out), `.${path.basename(out)}.tmp-${process.pid}`);
          await page.screenshot({ path: tmp, type: 'png', clip: found.clip });
          fs.renameSync(tmp, out);
          return EXIT.ok;
        }
      }
      await sleep(500);
    }
    return EXIT.mismatch;
  } catch (err) {
    debug(err);
    return left() <= 0 ? EXIT.timeout : EXIT.error;
  } finally {
    clearTimeout(hard);
    await browser.close().catch(() => {});
  }
}

async function check(opts) {
  if (!opts['repos-root']) usage('--check needs --repos-root');
  const root = opts['repos-root'];
  const say = (word, code) => {
    process.stdout.write(`${word}\n`);
    return code;
  };
  const pw = loadPlaywright(root);
  if (!pw) return say('browser-missing', EXIT.browserMissing);
  const browser = await launch(pw, true);
  if (!browser) return say('browser-missing', EXIT.browserMissing);
  const hard = setTimeout(() => {
    process.stdout.write('timeout\n');
    browser.close().catch(() => {});
    setTimeout(() => process.exit(EXIT.timeout), 500);
  }, DEADLINE_MS);
  try {
    const session = sessionFile(root);
    if (!fs.existsSync(session)) return say('no-session', EXIT.noSession);
    const context = await browser.newContext({ storageState: session, viewport: VIEWPORT });
    const page = await context.newPage();
    await page.goto(opts.url || DEFAULT_URL, { waitUntil: 'domcontentloaded', timeout: 15000 });
    // The app redirects to its login page from script, a moment after load.
    for (let i = 0; i < 6; i += 1) {
      if (isLoginUrl(page.url())) return say('expired', EXIT.expired);
      await sleep(500);
    }
    return say('ok', EXIT.ok);
  } catch (err) {
    debug(err);
    return say('error', EXIT.error);
  } finally {
    clearTimeout(hard);
    await browser.close().catch(() => {});
  }
}

async function login(opts) {
  if (!opts['repos-root']) usage('--login needs --repos-root');
  const root = opts['repos-root'];
  const pw = loadPlaywright(root);
  if (!pw) {
    process.stderr.write(
      `board-shot: Playwright not found under ${recordDir(root)} (npm i playwright; npx playwright install chromium)\n`,
    );
    return EXIT.browserMissing;
  }
  const browser = await launch(pw, false);
  if (!browser) {
    process.stderr.write('board-shot: could not open a browser window (Chromium installed? display available?)\n');
    return EXIT.browserMissing;
  }
  try {
    const context = await browser.newContext({ viewport: VIEWPORT });
    const page = await context.newPage();
    await page.goto(opts.url || DEFAULT_URL, { waitUntil: 'domcontentloaded' }).catch(debug);
    const tty = Boolean(process.stdin.isTTY);
    process.stderr.write(
      tty
        ? 'Log in as the dedicated read-only Linear user. When the board is open, press Enter here to save the session.\n'
        : 'Log in as the dedicated read-only Linear user. The session is saved once the board has been open for 8 s.\n',
    );
    const entered = tty
      ? new Promise((resolve) => process.stdin.once('data', () => resolve(true)))
      : new Promise(() => {});
    const started = Date.now();
    let stable = 0;
    let done = false;
    entered.then(() => {
      done = true;
    });
    while (!done) {
      if (Date.now() - started > LOGIN_WAIT_MS) return EXIT.timeout;
      if (page.isClosed()) {
        process.stderr.write('board-shot: the window was closed before the session was saved\n');
        return EXIT.error;
      }
      if (!tty) {
        stable = isLoginUrl(page.url()) ? 0 : stable + 1;
        if (stable >= 16) done = true;
      }
      await sleep(500);
    }
    if (isLoginUrl(page.url())) {
      process.stderr.write('board-shot: still on a login page; nothing saved\n');
      return EXIT.expired;
    }
    saveSession(root, await context.storageState());
    process.stderr.write(`Session saved (mode 0600): ${sessionFile(root)}\n`);
    return EXIT.ok;
  } catch (err) {
    debug(err);
    return EXIT.error;
  } finally {
    await browser.close().catch(() => {});
    process.stdin.pause();
  }
}

async function importSession(opts) {
  if (!opts['repos-root']) usage('--import needs --repos-root');
  let state;
  try {
    state = JSON.parse(fs.readFileSync(0, 'utf8'));
  } catch {
    state = null;
  }
  if (!state || typeof state !== 'object' || !Array.isArray(state.cookies)) {
    process.stderr.write('board-shot: stdin is not a Playwright storage state; nothing saved\n');
    return EXIT.error;
  }
  try {
    saveSession(opts['repos-root'], state);
  } catch (err) {
    debug(err);
    return EXIT.error;
  }
  process.stderr.write(`Session saved (mode 0600): ${sessionFile(opts['repos-root'])}\n`);
  return EXIT.ok;
}

const { mode, opts } = parseArgs(process.argv.slice(2));
const run = { shoot, '--check': check, '--login': login, '--import': importSession }[mode];
if (!run) usage(mode ? `unknown mode '${mode}'` : 'no mode given');
run(opts).then(
  (code) => process.exit(code),
  (err) => {
    debug(err);
    process.exit(EXIT.error);
  },
);
