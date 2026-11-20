#!/usr/bin/env bash
# planner-body-template.sh — the ticket-body-v2 additions to a spec (GitHub #773).
#
# A review of one epic's planned tickets found the same gaps in every generated
# body: no stated verify mode (API, git and scaffold tickets ran in browser
# mode), no place for error and edge-case behaviour (agents guessed it), one
# criterion per field (71 criteria on one ticket), criteria that cannot be
# true before merge, a Scope table that did not match Technical Context, and
# security decisions recorded as unconfirmed assumptions.
#
# This file holds the wording the Specify, Consensus and Epic Gen prompts gain
# and the spec readers the Crosscheck body family
# (planner-crosscheck-body.sh) checks them with. Every section is additive:
# planner_ticket_body_compose copies a spec's `## Verify Mode` and
# `## Errors and Edge Cases` into the ticket body as they are, and no
# downstream reader requires either.
#
#   PLANNER_BODY_CONTRACT          ticket-body-v2
#   PLANNER_VERIFY_MODE_SHAPES     the five shapes ticket-auto-pipeline's
#                                  lib/verify-mode.sh accepts in an explicit
#                                  "Verify mode:" field
#   PLANNER_AC_SOFT_CAP            20 criteria per spec (a constant, not a knob)
#
#   planner_body_contract_mark <INIT>        append META|contract|start|ticket-body-v2
#                                            once (first Specify dispatch)
#   planner_body_contract_initiative <INIT>  rc 0 when that line is present
#   planner_body_spec_checked <spec>         rc 1 for INDEX.md and synth-marked specs
#   planner_body_section <spec> <heading>    one `## ` section, fence-aware,
#                                            heading lower-case
#   planner_body_verify_mode <spec>          prints the shape; rc 1 no
#                                            `## Verify Mode` section, rc 2 its
#                                            first line is not
#                                            `**Verify mode:** <shape>`
#   planner_body_spec_type <spec>            the Labels line's ticket type, or nothing
#   planner_body_ac_items <spec>             criteria, markers stripped
#   planner_body_files <spec> <heading>      "<file>\t<ro|rw>" per backticked
#                                            file name in that section
#   planner_body_file_match <a> <b>          rc 0 when both name one file
#
#   planner_security_decisions_prompt_rules  Specify Part 1 (proposal.md)
#   planner_security_decisions_epic_rule     Epic Gen
#   planner_body_template_prompt_rules       Specify Part 2 (spec sections)
#   planner_ac_shape_prompt_rules            Specify Part 2 (criteria)
#   planner_body_template_consensus_rule     Consensus
#   planner_body_template_selflint_note      Specify Part 4
#
# Sourceable library — no set -euo pipefail. awk is used without regex
# intervals (mawk).

_PLANNER_BODY_TEMPLATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_state_log >/dev/null 2>&1; then
  # shellcheck source=planner-state.sh
  source "${_PLANNER_BODY_TEMPLATE_LIB_DIR}/planner-state.sh"
fi

PLANNER_BODY_CONTRACT="ticket-body-v2"
PLANNER_VERIFY_MODE_SHAPES="browser api-only diff-only build-only live-backend"
PLANNER_AC_SOFT_CAP=20
# File extensions a backticked name must end in to count as a file when it
# has no directory part. `matters.locked_at` and `auth.session_idle_minutes`
# are columns and parameter keys, not files.
PLANNER_BODY_FILE_EXTS="js jsx mjs cjs ts tsx json css scss less html htm md yml yaml java kt kts py rb go rs sh bash sql xml toml ini properties gradle vue svelte php cs c h cpp hpp txt env lock conf cfg tf proto graphql"
# Backticked names that end like a file and are not one.
PLANNER_BODY_NOT_FILES="node.js next.js vue.js nuxt.js express.js react.js three.js d3.js"

# ── Contract marker ──────────────────────────────────────────────────────────

planner_body_contract_initiative() {
  local log
  log=$(planner_state_log "$1" 2>/dev/null) || return 1
  [ -f "$log" ] || return 1
  grep -q "^[^|]*|META|contract|start|${PLANNER_BODY_CONTRACT}\$" "$log" 2>/dev/null
}

planner_body_contract_mark() {
  local init="$1"
  planner_body_contract_initiative "$init" && return 0
  planner_state_write "$init" META contract start "$PLANNER_BODY_CONTRACT"
}

# ── Spec readers ─────────────────────────────────────────────────────────────

planner_body_spec_checked() {
  local spec="$1"
  [ -f "$spec" ] || return 1
  [ "$(basename "$spec")" = "INDEX.md" ] && return 1
  grep -qF -- "${PLANNER_TESTDATA_SYNTH_MARKER:-<!-- planner:testdata-synth v1 -->}" "$spec" 2>/dev/null && return 1
  return 0
}

# Content of one `## <heading>` section up to the next `## ` heading. A
# heading inside a fenced block is not a boundary. Fenced lines are printed.
planner_body_section() {
  local spec="$1" want="$2"
  tr -d '\r' <"$spec" 2>/dev/null | PB_WANT="$want" awk '
    /^(```|~~~)/ { fence = !fence }
    !fence && /^## / {
      h = tolower($0); sub(/^## +/, "", h); sub(/[[:space:]]+$/, "", h)
      on = (h == ENVIRON["PB_WANT"]); next
    }
    on { print }
  '
}

# The same section with fenced blocks blanked (line count kept).
_planner_body_section_prose() {
  planner_body_section "$1" "$2" | awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; print ""; next }
    fence { print ""; next }
    { print }
  '
}

planner_body_verify_mode() {
  local spec="$1" line shape s
  grep -qiE '^## +verify mode[[:space:]]*$' <(tr -d '\r' <"$spec" 2>/dev/null) || return 1
  line=$(_planner_body_section_prose "$spec" "verify mode" | awk 'NF { print; exit }')
  case "$line" in
  '**Verify mode:** '*) shape="${line#'**Verify mode:** '}" ;;
  *) return 2 ;;
  esac
  shape="${shape%%[[:space:]]*}"
  for s in $PLANNER_VERIFY_MODE_SHAPES; do
    if [ "$shape" = "$s" ]; then
      echo "$s"
      return 0
    fi
  done
  return 2
}

planner_body_spec_type() {
  local spec="$1" labels tok t
  labels=$(tr -d '\r' <"$spec" 2>/dev/null | awk '/^## Labels/{f=1;next} f && NF{print; exit}')
  for tok in $(echo "$labels" | tr ',`' '  '); do
    t=$(echo "${tok#type:}" | tr '[:upper:]' '[:lower:]')
    case "$t" in
    feature | bug | improvement | chore | security)
      echo "$t"
      return 0
      ;;
    esac
  done
  return 0
}

planner_body_ac_items() {
  _planner_body_section_prose "$1" "acceptance criteria" |
    { grep -E '^[[:space:]]*(-[[:space:]]*\[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]+[^[:space:]]' || true; } |
    sed -E 's/^[[:space:]]*(-[[:space:]]*\[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]*//; s/[[:space:]]+$//' |
    awk '!seen[$0]++'
}

# Backticked file names in one section: "<file>\t<ro|rw>", first mention
# first, each file once. A trailing `:<line>` or `:<from>-<to>` is dropped.
# `ro` when "(read-only)" follows the name. A name counts as a file when it
# has no space, `*`, `{`, `<` or `://`, and either ends in a known extension
# (or is Makefile/Dockerfile) or has a directory part and any extension.
planner_body_files() {
  _planner_body_section_prose "$1" "$2" |
    PB_EXTS="$PLANNER_BODY_FILE_EXTS" PB_NOT="$PLANNER_BODY_NOT_FILES" awk '
    BEGIN {
      n = split(ENVIRON["PB_EXTS"], e, " "); for (i = 1; i <= n; i++) ext[e[i]] = 1
      n = split(ENVIRON["PB_NOT"], d, " "); for (i = 1; i <= n; i++) notfile[d[i]] = 1
    }
    function is_file(t,   base, x, k, parts) {
      if (t == "" || t ~ /[ *{<>]/ || index(t, "://")) return 0
      k = split(t, parts, "/"); base = parts[k]
      if (base == "" ) return 0
      if (tolower(base) in notfile) return 0
      if (base == "Makefile" || base == "Dockerfile") return 1
      if (base !~ /[A-Za-z0-9_-]\.[A-Za-z0-9]+$/) return 0
      x = base; sub(/^.*\./, "", x); x = tolower(x)
      if (x in ext) return 1
      return (k > 1 && x ~ /[a-z]/)
    }
    {
      s = $0
      while ((i = index(s, "`")) > 0) {
        s = substr(s, i + 1)
        j = index(s, "`")
        if (j == 0) break
        t = substr(s, 1, j - 1)
        s = substr(s, j + 1)
        sub(/:[0-9]+-[0-9]+$/, "", t); sub(/:[0-9]+$/, "", t)
        sub(/^\.\//, "", t)
        if (!is_file(t)) continue
        ro = (tolower(s) ~ /^[[:space:]]*\(read-only\)/) ? "ro" : "rw"
        if (!(t in seen)) { seen[t] = 1; order[++m] = t; mode[t] = ro }
        else if (ro == "ro") mode[t] = "ro"
      }
    }
    END { for (i = 1; i <= m; i++) printf "%s\t%s\n", order[i], mode[order[i]] }
  '
}

# Two names are one file when they are equal or one is the other's path tail
# (`auth.js` and `frontend/src/auth.js`).
planner_body_file_match() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 0
  case "$a" in */"$b") return 0 ;; esac
  case "$b" in */"$a") return 0 ;; esac
  return 1
}

# ── Prompt wording ───────────────────────────────────────────────────────────

# Specify Part 1, directly before the Parameters rules.
planner_security_decisions_prompt_rules() {
  cat <<'RULES'

### Security and identity decisions (issue #773)

When the plan adds or changes sign-in, accounts, sessions, tokens, secrets or
stored personal data, proposal.md carries a `## Security & Identity Decisions`
section directly after `## Parameters`. Leave it out otherwise. Write one
bullet per decision, each naming by its backticked key the `## Parameters` row
that holds the decision (the value, or the open question, stays in that row):

- **Identifier normalisation** — for each identifier a person types (email,
  username): is it trimmed, is its case folded, and is the stored value the
  normalised one? Uniqueness checks and sign-in compare the same form.
- **Secret and config policy** — per environment (local, test, production):
  where each secret comes from, and whether a built-in default is allowed
  there.
- **Token handling** — lifetime, where the client keeps it, and what makes it
  invalid.

Each of these is a `policy` row: a person is asked unless a source states the
value. Never record one as an assumption, a risk or a default you chose. A
spec that depends on a decision names the row's key in its
`## Technical Context` and states the decided value in its criteria.
RULES
}

# Epic Gen, after the epic body layout.
planner_security_decisions_epic_rule() {
  cat <<'RULE'
When proposal.md has a `## Security & Identity Decisions` section, add it to
the epic as a sixth section, `## Security and identity decisions`, directly
after `## Outcomes`: one bullet per decision with its decided value from
`## Parameters`. A decision that is still open is carried as an open question.
Never write one under an assumptions heading, and never mark a decided value
as unconfirmed.
RULE
}

# Specify Part 2, before "One acceptance criterion per stated outcome".
planner_body_template_prompt_rules() {
  cat <<'RULES'
### Verify mode, errors and scope files (issue #773)

Every spec's Description also follows these rules. Crosscheck checks the first
three (`VERIFY_MODE_INVALID`, `EDGE_CASES_MISSING`, `SCOPE_TC_MISMATCH`).

- **`## Verify Mode`** — on every spec. Its first line is
  `**Verify mode:** <shape>`, then ` — ` and a short reason. `<shape>` is
  exactly one of:
  - `browser` — a person uses a page; the criteria are checked by clicking
    through the running app.
  - `api-only` — HTTP endpoints and no page; checked with requests and the
    test command against a running backend.
  - `live-backend` — behaviour of running services with no page and no single
    endpoint to call (service registration, failover).
  - `build-only` — nothing has to run; the build or test command passing is
    the check (scaffold, dependency and tooling work).
  - `diff-only` — only files to read: documentation, git or configuration
    changes.

  Choose from what the criteria need, not from the words the ticket uses.
  ticket-auto reads this field before anything else and then makes no guess
  of its own.
- **`## Errors and Edge Cases`** — on every feature and improvement spec and
  on every `api-only` or `live-backend` spec, directly before
  `## Acceptance Criteria`. Answer each prompt with the behaviour, or with
  `Not applicable — <why>`:
  - **Failure** — what the user or caller sees on a network failure or a 5xx
    response.
  - **Check order** — when more than one of 401, 403, 404 and 422 could apply
    to a request, which one is returned first.
  - **Empty or malformed input** — an empty body, a missing or wrong-typed
    field, a payload without its wrapper.
  - **Late or concurrent responses** — an action taken while an earlier
    request is still running; a response that arrives after the state it
    answers has changed.
  - **Unauthorised viewer** — what someone without the right sees on an edit
    or owner-only page, and what a request with no token or an expired token
    gets.

  Each behaviour stated here is an outcome and gets its own criterion (next
  section).
- **Scope names files** — the `## Scope` table's Area cell lists, in
  backticks, every file the ticket creates or changes: the same paths
  `## Technical Context` names. A file Technical Context names only as
  evidence is listed too, with `(read-only)` straight after it. A file in
  Scope that Technical Context never names is a mistake in one of the two.
- **Technical Context states constraints, not calls** — name the files,
  symbols, contracts and rules the change must respect ("navigation after
  sign-out replaces the history entry, as the route guard does"). Do not
  dictate the exact call or module layout unless a contract depends on it.
- **Decision is this ticket's slice** — Signals `Decision` states only the
  part of the architecture decision this ticket builds. A scaffold ticket
  does not carry the data-store or router decision of later tickets.
- **Pin what a scaffold installs** — a spec that adds a framework or runtime
  dependency states its major version in `## Technical Context`.
- **Order by state** — a ticket whose criteria need a state (signed in, an
  article exists) is `blocked-by` the ticket that lets a user create that
  state, so its tests never plant the state by hand.

RULES
}

# Specify Part 2, after the acceptance-criteria checklist.
planner_ac_shape_prompt_rules() {
  cat <<RULES

### Criteria: grouped, tagged, true on the branch (issue #773)

- **Group field checks.** Write one criterion per response, row, page or
  behaviour, not one per field. Name the fields in the criterion line when
  they fit. Otherwise end the line with "every field in the table below" and
  put a \`| Field | Expected |\` table directly under it, indented two spaces.
  One Verification Notes row covers the whole group.
- **About ${PLANNER_AC_SOFT_CAP} criteria at most.** Above that, find a seam and split the
  ticket. Crosscheck warns (\`AC_COUNT_HIGH\`).
- **Tag each criterion** \`[unit]\` or \`[live]\` straight after the checkbox:
  \`- [ ] [live] Signing in with a wrong password shows "Invalid email or password"\`.
  \`[live]\` — verify can observe it on the running system. \`[unit]\` — it
  needs control verify does not have (a frozen clock, a forced tie, an
  injected failure, a request nobody can see from outside), so an automated
  test proves it; its Verification Notes Expected cell names that test's
  result. The tag is part of the criterion text: repeat it in the
  Verification Notes \`Criterion\` cell.
- **True on the PR branch.** Word every criterion so it holds on the
  ticket's own branch before merge. Never refer to a state after merge ("on
  \`develop\`", "once merged"), or to a branch, tag or deploy that may not
  exist when verify runs.
RULES
}

# Consensus, after its acceptance-criteria checklist.
planner_body_template_consensus_rule() {
  cat <<'RULE'
A spec you edit keeps its body rules (issue #773): `## Verify Mode` and
`## Errors and Edge Cases` stay in place; a file you add to
`## Technical Context` also goes into the `## Scope` table, and one you remove
comes out of it; a new error or edge-case behaviour gets its line in
`## Errors and Edge Cases`; a criterion you add carries its `[unit]` or
`[live]` tag, holds on the PR branch before merge, and groups field checks
into one criterion.
RULE
}

# Specify Part 4, under the self-lint command block.
planner_body_template_selflint_note() {
  cat <<'NOTE'
A `planner-crosscheck-body:` line names a spec (or proposal.md) that breaks a
rule of "Verify mode, errors and scope files" or "Criteria: grouped, tagged,
true on the branch" above: fix the file it names and re-run.
NOTE
}
