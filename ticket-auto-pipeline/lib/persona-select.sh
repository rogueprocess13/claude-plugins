#!/usr/bin/env bash
# persona-select.sh — deterministic base+specializer persona selector.
# Given a repo path, layer classification, and pipeline phase, emits the
# correct persona file paths. Zero LLM involvement. Follows the gate-check.sh
# philosophy: if a decision can be made deterministically, bash is the answer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve personas dir relative to plugin root (available in agent spawns), with
# fallback to script-relative for local dev/testing. Follows the same pattern as
# gate-check.sh and notes-parse.sh which use ${CLAUDE_PLUGIN_ROOT:-<fallback>}.
# CLAUDE_PLUGIN_ROOT can be non-empty but wrong (e.g. a spawned worker's env
# carries a different plugin's root) — ${VAR:-fallback} only falls back on
# unset/empty, so validate the resolved dir actually has a personas/
# subdirectory before trusting it; otherwise fall back to script-relative.
PERSONAS_DIR="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/personas"
if [ ! -d "$PERSONAS_DIR" ]; then
  PERSONAS_DIR="$SCRIPT_DIR/../personas"
fi

# ── Usage ──────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: persona-select.sh --repo <path> [--layer FE|BE|infra] [--phase appraise|implement|review|audit|prescan]
                         [--type bug|feature|improvement|security|chore|refactor] [--remediation] [--with-qa]
                         [--ticket-dir <dir>]

Emits persona file paths as KEY=value lines:
  PERSONA_BASE=personas/base/<role>.md
  PERSONA_SPECIALIZER=personas/specializers/<group>/<stack>.md   (empty if none matches)
  PERSONA_AUTO_INCLUDE=personas/base/security.md                (empty if no trigger)
  PERSONA_TESTDATA=personas/base/test-data-engineer.md          (empty if no test-data signal)
  PERSONA_TESTDATA_SPECIALIZERS=<colon-separated testdata/<channel>.md paths, max 3>
  PERSONA_DEBUG=personas/base/debugger.md                      (empty unless bug type or --remediation)
  PERSONA_DEBUG_SPECIALIZER=personas/specializers/debug/<stack>.md (empty if no stack matches)
  PERSONA_SET=<newline-separated paths>                          (prescan phase only)
  PERSONA_TYPE=<type>                                            (--ticket-dir only; empty if none)

Options:
  --repo <path>      Path to the affected repository (required)
  --layer <value>    Layer classification: FE, BE, infra (optional)
  --phase <value>    Pipeline phase: appraise, implement, review, audit, prescan (optional)
  --type <value>     Ticket type (validated by template-select.sh). `bug` sets the
                     debugger overlay. Empty means absent; when absent and both
                     TICKET_ID and REPOS_ROOT are set, the local manifest `type` is used.
  --remediation      Verify-fail rework: sets the debugger overlay for any type
  --with-qa          Include qa-engineer in prescan persona set (prescan phase only),
                     with a qa/* specializer when the repo has Playwright or
                     OpenAPI/Postman files
  --ticket-dir <dir> The ticket workspace ({ID}--slug). Uses <dir>/context.md as the
                     ticket text when TICKET_TEXT_FILE is unset or empty, and, when
                     --type is absent, derives the type: the manifest `type` if it is
                     a known type (TICKET_ID from the env, else the dir name before
                     `--`; needs REPOS_ROOT), else `bug` when context.md's
                     `**Labels:**` line has a `bug` label, else none. An unknown
                     manifest type is dropped. Emits PERSONA_TYPE.

Ticket text for the keyword detectors comes from TICKET_TITLE, TICKET_DESCRIPTION
and the file named by TICKET_TEXT_FILE (skills pass the ticket's context.md).
EOF
  exit 1
}

# ── Flag parsing ───────────────────────────────────────────────────────────────

REPO=""
LAYER=""
PHASE=""
WITH_QA="false"
TYPE=""
REMEDIATION="false"
TICKET_DIR=""
TICKET_DIR_SET="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo)
    REPO="${2:-}"
    shift 2
    ;;
  --layer)
    LAYER="${2:-}"
    shift 2
    ;;
  --phase)
    PHASE="${2:-}"
    shift 2
    ;;
  --type)
    TYPE="${2:-}"
    shift 2
    ;;
  --remediation)
    REMEDIATION="true"
    shift
    ;;
  --with-qa)
    WITH_QA="true"
    shift
    ;;
  --ticket-dir)
    TICKET_DIR="${2:-}"
    TICKET_DIR_SET="true"
    shift 2
    ;;
  --help | -h)
    usage
    ;;
  *)
    echo "Unknown flag: $1" >&2
    usage
    ;;
  esac
done

# ── Validation ─────────────────────────────────────────────────────────────────

if [ -z "$REPO" ]; then
  echo "ERROR: --repo is required" >&2
  usage
fi

# Validate --layer if provided
if [ -n "$LAYER" ]; then
  case "$LAYER" in
  FE | BE | infra) ;;
  *)
    echo "ERROR: Invalid --layer value '$LAYER'. Must be FE, BE, or infra." >&2
    exit 1
    ;;
  esac
fi

# Validate --phase if provided
if [ -n "$PHASE" ]; then
  case "$PHASE" in
  appraise | implement | review | audit | prescan) ;;
  *)
    echo "ERROR: Invalid --phase value '$PHASE'. Must be appraise, implement, review, audit, or prescan." >&2
    exit 1
    ;;
  esac
fi

# Validate --type if provided. template-select.sh is sourced only here, after
# the flag loop: it runs a file-scope `--self-test` check on "$1", which is
# empty by now. resolve_template returns 3 on an unknown type — tested inside
# `if` so errexit cannot fire on it.
# shellcheck source=template-select.sh
source "$SCRIPT_DIR/template-select.sh"
if [ -n "$TYPE" ] && ! resolve_template "$TYPE" >/dev/null; then
  echo "ERROR: Invalid --type value '$TYPE'. Must be one of: ${KNOWN_TYPES[*]}." >&2
  exit 1
fi

# ── --ticket-dir: ticket text and type derivation ─────────────────────────────

# The type list the skills used to filter on before passing --type; keep it in
# step with template-select.sh's KNOWN_TYPES (refactor is an alias there).
_PS_DERIVABLE_TYPES=" bug feature improvement security chore refactor "

# Manifest `type` for the ticket, or empty. TICKET_ID from the env, else the
# workspace name before `--` ({ID}--slug, ticket-dir.sh's convention).
_ps_manifest_type() {
  local tid="${TICKET_ID:-}" t=""
  if [ -z "$tid" ]; then
    tid=$(basename "$TICKET_DIR")
    tid="${tid%%--*}"
  fi
  if [ -z "$tid" ] || [ -z "${REPOS_ROOT:-}" ] || [ ! -f "$SCRIPT_DIR/manifest-read.sh" ]; then
    return 0
  fi
  # shellcheck source=manifest-read.sh
  source "$SCRIPT_DIR/manifest-read.sh"
  # `|| true`: a missing index/manifest returns 1/3, fatal under set -e.
  t=$(TICKET_ID="$tid" get_ticket_manifest_field "$tid" type 2>/dev/null || true)
  echo "$t"
}

# `bug` when context.md's first `**Labels:**` line carries a whole `bug`
# label (comma-separated, case-insensitive), else nothing.
_ps_labels_type() {
  local ctx="$TICKET_DIR/context.md"
  [ -f "$ctx" ] || return 0
  if grep -m1 '^\*\*Labels:\*\*' "$ctx" 2>/dev/null |
    sed 's/^\*\*Labels:\*\*//' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -qix bug; then
    echo bug
  fi
  return 0
}

if [ "$TICKET_DIR_SET" = "true" ] && [ -n "$TICKET_DIR" ] && [ -d "$TICKET_DIR" ]; then
  if [ -z "${TICKET_TEXT_FILE:-}" ] && [ -f "$TICKET_DIR/context.md" ]; then
    TICKET_TEXT_FILE="$TICKET_DIR/context.md"
  fi
  if [ -z "$TYPE" ] && [ -f "$TICKET_DIR/context.md" ]; then
    _ps_t=$(_ps_manifest_type)
    # Unknown (or empty / JSON null) manifest type: dropped, not an error.
    case "$_PS_DERIVABLE_TYPES" in
    *" ${_ps_t} "*) ;;
    *) _ps_t="" ;;
    esac
    if [ -z "$_ps_t" ]; then
      _ps_t=$(_ps_labels_type)
    fi
    TYPE="$_ps_t"
  fi
fi

# ── Helper: resolve persona path relative to plugin root ───────────────────────

_persona_path() {
  # Given a relative path like "base/analyzer.md", output the full path
  # relative to the personas directory. If the file doesn't exist, output empty.
  local rel="$1"
  if [ -f "$PERSONAS_DIR/$rel" ]; then
    echo "$PERSONAS_DIR/$rel"
  else
    echo ""
  fi
}

# ── Base persona selection ─────────────────────────────────────────────────────

select_base() {
  # Phase takes priority over layer for base selection.
  # If no phase and no layer, default to analyzer (safest universal role).
  case "${PHASE:-}" in
  appraise | review)
    echo "analyzer"
    return
    ;;
  audit)
    echo "product-owner"
    return
    ;;
  implement)
    # A test-data ticket's whole deliverable is data — the layer persona is
    # the wrong lens for it, so the role swaps regardless of layer.
    if has_testdata_strong; then
      echo "test-data-engineer"
      return
    fi
    case "${LAYER:-}" in
    FE)
      echo "frontend-developer"
      return
      ;;
    BE | infra)
      echo "backend-developer"
      return
      ;;
    *)
      # implement phase without layer — default to backend-developer
      echo "backend-developer"
      return
      ;;
    esac
    ;;
  *)
    # No phase — use layer if available
    case "${LAYER:-}" in
    FE)
      echo "frontend-developer"
      return
      ;;
    BE | infra)
      echo "backend-developer"
      return
      ;;
    *)
      echo "analyzer"
      return
      ;;
    esac
    ;;
  esac
}

# ── Specializer detection ──────────────────────────────────────────────────────

probe_file() { [ -f "$REPO/$1" ] && return 0 || return 1; }
probe_dep() { [ -f "$REPO/package.json" ] && grep -q "\"$1\"" "$REPO/package.json" 2>/dev/null && return 0 || return 1; }

# Assemble the ticket text the keyword detectors scan: TICKET_TITLE,
# TICKET_DESCRIPTION and the contents of TICKET_TEXT_FILE, space-joined.
_ticket_haystack() {
  local haystack=""
  if [ -n "${TICKET_TITLE:-}" ]; then haystack="$haystack $TICKET_TITLE"; fi
  if [ -n "${TICKET_DESCRIPTION:-}" ]; then haystack="$haystack $TICKET_DESCRIPTION"; fi
  if [ -n "${TICKET_TEXT_FILE:-}" ] && [ -f "$TICKET_TEXT_FILE" ]; then
    haystack="$haystack $(cat "$TICKET_TEXT_FILE" 2>/dev/null || true)"
  fi
  printf '%s' "$haystack"
}

# Detect migration/upgrade intent from ticket text (explicit user signal).
# The user must state they are upgrading/migrating — this is NOT heuristic version detection.
has_migration_keywords() {
  local haystack
  haystack=$(_ticket_haystack)
  if [ -z "$haystack" ]; then return 1; fi
  echo "$haystack" | grep -qiE '\b(upgrade|migration|migrate|bump.*version|version.*bump|java\s*[0-9]+\s*→|java\s*[0-9]+\s*->|java\s*[0-9]+\s*to)\b' && return 0 || return 1
}

# Detect refactor/restructuring intent from ticket text (explicit user signal).
# The user must state they are refactoring with NO business logic changes.
has_refactor_keywords() {
  local haystack
  haystack=$(_ticket_haystack)
  if [ -z "$haystack" ]; then return 1; fi
  echo "$haystack" | grep -qiE '\b(refactor|refactoring|restructur\w*|clean\s*up|improve\s+structure|code\s+quality|technical\s+debt|pay\s+down\s+debt)\b' && return 0 || return 1
}

# detect_stack <layer> — the one layer-gated stack detector, shared by the
# stack specializer and the debug specializer. The layer is an argument (not
# the LAYER global) because select_prescan_set swaps LAYER per role.
#   BE|infra → python | jvm | node | ""   (python files → BE_TEST_RUNNER → java → node)
#   FE       → browser | ""               (angular.json → react → vue)
# Always echoes and returns 0: a non-zero return inside $(...) would kill the
# caller under set -e.
detect_stack() {
  local layer="${1:-}"
  case "$layer" in
  BE | infra)
    if probe_file "pyproject.toml" || probe_file "requirements.txt" || probe_file "poetry.lock"; then
      echo "python"
      return 0
    fi
    if [ -n "${BE_TEST_RUNNER:-}" ] && echo "$BE_TEST_RUNNER" | grep -qiE "pyenv|pipenv|poetry"; then
      echo "python"
      return 0
    fi
    if probe_file "pom.xml" || probe_file "build.gradle" || probe_file "build.gradle.kts" || probe_file "settings.gradle"; then
      echo "jvm"
      return 0
    fi
    if probe_file "package.json"; then
      if ! probe_dep "angular" && ! probe_dep "react" && ! probe_dep "vue" && ! probe_file "angular.json"; then
        echo "node"
        return 0
      fi
    fi
    ;;
  FE)
    if probe_file "angular.json"; then
      echo "browser"
      return 0
    fi
    if probe_file "package.json"; then
      if grep -qE '"react"|"react-dom"|"vue"' "$REPO/package.json" 2>/dev/null; then
        echo "browser"
        return 0
      fi
    fi
    ;;
  esac
  echo ""
  return 0
}

select_specializer() {
  local layer="${LAYER:-}"
  local phase="${PHASE:-}"
  local stack
  stack=$(detect_stack "$layer")

  # Backend stack: keyword refinement (migration > refactor > standard).
  case "$stack" in
  python)
    if has_refactor_keywords; then
      echo "specializers/backend/python-refactor.md"
      return
    fi
    echo "specializers/backend/python.md"
    return
    ;;
  jvm)
    if has_migration_keywords; then
      echo "specializers/backend/java-migration.md"
      return
    fi
    if has_refactor_keywords; then
      echo "specializers/backend/java-refactor.md"
      return
    fi
    echo "specializers/backend/java.md"
    return
    ;;
  node)
    if has_refactor_keywords; then
      echo "specializers/backend/node-refactor.md"
      return
    fi
    echo "specializers/backend/node.md"
    return
    ;;
  browser)
    # Frontend framework: angular.json is the strongest signal, then react, vue.
    if probe_file "angular.json"; then
      echo "specializers/frontend/angular.md"
      return
    fi
    if grep -qE '"react"|"react-dom"' "$REPO/package.json" 2>/dev/null; then
      echo "specializers/frontend/react.md"
      return
    fi
    echo "specializers/frontend/vue.md"
    return
    ;;
  esac

  # Architect specializers — only when explicit multi-service signals detected
  if [ "$layer" = "infra" ] || { [ "$layer" = "BE" ] && [ "$phase" = "implement" ]; }; then
    # Check for multi-service structure
    local svc_dirs
    svc_dirs=$(find "$REPO" -maxdepth 2 -type d -name "services" -o -name "apps" -o -name "packages" 2>/dev/null | head -1 || true)
    if [ -n "$svc_dirs" ]; then
      echo "specializers/architect/microservices.md"
      return
    fi
    # Check for docker-compose with multiple services
    if [ -f "$REPO/docker-compose.yml" ] || [ -f "$REPO/docker-compose.yaml" ]; then
      local svc_count
      svc_count=$(grep -cE '^\s{2}\w+:' "$REPO/docker-compose.yml" 2>/dev/null || true)
      svc_count=${svc_count:-0}
      if [ "${svc_count:-0}" -gt 2 ] 2>/dev/null; then
        echo "specializers/architect/microservices.md"
        return
      fi
    fi
    # Single service with architect context → monolith
    if [ -f "$REPO/Dockerfile" ] || [ -f "$REPO/Makefile" ] || [ "$layer" = "infra" ]; then
      echo "specializers/architect/monolith.md"
      return
    fi
  fi

  # No specializer matched
  echo ""
}

# QA specializer for the qa-engineer lens (issue #559). Repo-file signals
# only, so the result is the same for every ticket:
#   Playwright config or @playwright/test dependency → qa/playwright-web
#   OpenAPI/Swagger spec or Postman collection       → qa/api-testing
# Always echoes and returns 0: a non-zero return inside $(...) would kill the
# caller under set -e.
select_qa_specializer() {
  local f
  for f in playwright.config.ts playwright.config.js playwright.config.mjs playwright.config.cjs; do
    if probe_file "$f"; then
      echo "specializers/qa/playwright-web.md"
      return 0
    fi
  done
  if probe_dep "@playwright/test"; then
    echo "specializers/qa/playwright-web.md"
    return 0
  fi
  if [ -n "$(find "$REPO" -maxdepth 4 \( -name node_modules -o -name .git \) -prune -o \
    \( -iname 'openapi.json' -o -iname 'openapi.yaml' -o -iname 'openapi.yml' -o -iname 'swagger.json' \
    -o -iname 'swagger.yaml' -o -iname 'swagger.yml' -o -iname '*.postman_collection.json' \) \
    -print -quit 2>/dev/null || true)" ]; then
    echo "specializers/qa/api-testing.md"
    return 0
  fi
  echo ""
  return 0
}

# ── Auto-include detection ─────────────────────────────────────────────────────

select_auto_include() {
  # Check if security keywords appear in ticket context.
  # We probe: TICKET_TITLE, TICKET_DESCRIPTION env vars, or a temp file.
  local haystack
  haystack=$(_ticket_haystack)

  if [ -z "$haystack" ]; then
    echo ""
    return
  fi

  # Case-insensitive keyword match for security-sensitive terms
  if echo "$haystack" | grep -qiE '\b(auth|authentication|authorization|login|password|credential|token|payment|billing|PII|personal.data|encryption|vulnerability)\b'; then
    echo "base/security.md"
    return
  fi

  echo ""
}

# ── Test-data persona detection ────────────────────────────────────────────────

# Strong signal: the ticket's deliverable IS test data. Any of the markers a
# synthesized test-data ticket carries (ticket-planner planner-test-data-
# derivation): a `## Test Data Provided` heading, a `Seed command:` line, or
# the synth marker comment.
has_testdata_strong() {
  local haystack
  haystack=$(_ticket_haystack)
  if [ -z "$haystack" ]; then return 1; fi
  grep -qE '(^|[[:space:]])##[[:space:]]+Test Data Provided[[:space:]]*$|(^|[[:space:]*])Seed command:|<!-- planner:testdata-synth v1 -->' <<<"$haystack" && return 0 || return 1
}

# Weak signal: an ordinary ticket that also touches test data. Phrase-based on
# purpose — a bare "data" would fire on almost every ticket.
has_testdata_weak() {
  local haystack
  haystack=$(_ticket_haystack)
  if [ -z "$haystack" ]; then return 1; fi
  grep -qiE '\b(seed(ed)?[[:space:]]+data|test[[:space:]]+data|fixtures?|sample[[:space:]]+data|demo[[:space:]]+data|mock[[:space:]]+data|synthetic[[:space:]]+data|generate([[:space:]]+the)?[[:space:]]+data|data[[:space:]]+load|bulk[[:space:]]+import)\b' <<<"$haystack" && return 0 || return 1
}

# Channel specializers for a test-data ticket, at most 3, colon-separated.
# Precedence: an explicit `Seed channel: <list>` line → body keyword families
# → repo probes. ui-forms is only a probe fallback when UAT_URL is set and
# nothing else matched — it is the slowest, flakiest channel.
select_testdata_channels() {
  local haystack channels=()
  haystack=$(_ticket_haystack)

  local explicit
  explicit=$(printf '%s\n' "$haystack" | grep -oiE 'Seed channel:[[:space:]]*[a-z, -]+' | head -1 | sed -E 's/^[Ss]eed [Cc]hannel:[[:space:]]*//' || true)
  if [ -n "$explicit" ]; then
    local c
    for c in $(printf '%s' "$explicit" | tr 'A-Z,' 'a-z '); do
      case "$c" in sql | api | ui-forms | files | factories) channels+=("$c") ;; esac
    done
  fi

  if [ "${#channels[@]}" -eq 0 ] && [ -n "$haystack" ]; then
    local lc
    lc=$(printf '%s' "$haystack" | tr '[:upper:]' '[:lower:]')
    grep -qE '\b(sql|insert|upsert|seed script|migration)s?\b' <<<"$lc" && channels+=("sql")
    grep -qE '\b(endpoints?|(post|put) requests?|http (post|put)|curl|rest api|graphql|(via|through) the api|api calls?)\b' <<<"$lc" && channels+=("api")
    grep -qE '\b(forms?|screens?|through the (ui|app)|via the (ui|app))\b' <<<"$lc" && channels+=("ui-forms")
    grep -qE '\b(csv|xlsx|json fixtures?|upload|import files?)\b' <<<"$lc" && channels+=("files")
    grep -qE '\b(factory|factories|builders?|faker)\b' <<<"$lc" && channels+=("factories")
  fi

  if [ "${#channels[@]}" -eq 0 ]; then
    if [ -n "$(find "$REPO" -maxdepth 6 -type d -path '*db/migration*' -print -quit 2>/dev/null)" ] ||
      [ -n "$(find "$REPO" -maxdepth 6 -name '*.sql' -not -path '*/node_modules/*' -print -quit 2>/dev/null)" ] ||
      grep -qsiE 'flyway|liquibase' "$REPO/pom.xml" "$REPO/build.gradle" "$REPO/build.gradle.kts" 2>/dev/null; then
      channels+=("sql")
    fi
    if [ -n "$(find "$REPO" -maxdepth 4 \( -iname 'openapi.json' -o -iname 'openapi.yaml' -o -iname 'openapi.yml' -o -iname 'swagger.json' -o -iname 'swagger.yaml' \) -not -path '*/node_modules/*' -print -quit 2>/dev/null)" ]; then
      channels+=("api")
    fi
    if grep -qsiE 'factory[_-]boy|factory_bot|fishery|@faker-js/faker|instancio' \
      "$REPO/pyproject.toml" "$REPO/requirements.txt" "$REPO/package.json" "$REPO/Gemfile" "$REPO/pom.xml" "$REPO/build.gradle" 2>/dev/null; then
      channels+=("factories")
    fi
    if [ "${#channels[@]}" -eq 0 ] && [ -n "${UAT_URL:-}" ]; then
      channels+=("ui-forms")
    fi
  fi

  # Dedupe in order, keep files that exist, cap at 3.
  local out="" seen=" " n=0 ch path
  for ch in "${channels[@]}"; do
    case "$seen" in *" $ch "*) continue ;; esac
    seen="$seen$ch "
    path=$(_persona_path "specializers/testdata/${ch}.md")
    [ -n "$path" ] || continue
    out="${out:+$out:}$path"
    n=$((n + 1))
    [ "$n" -ge 3 ] && break
  done
  printf '%s' "$out"
}

# ── Debugger overlay ───────────────────────────────────────────────────────────

# True when the overlay applies: --remediation (any type), an explicit
# --type bug, or — only when --type is absent — the ticket's local manifest
# type is exactly `bug`. An explicit non-bug --type wins over the manifest.
debug_overlay_wanted() {
  if [ "$REMEDIATION" = "true" ]; then return 0; fi
  if [ -n "$TYPE" ]; then
    [ "$TYPE" = "bug" ] && return 0 || return 1
  fi
  if [ -z "${TICKET_ID:-}" ] || [ -z "${REPOS_ROOT:-}" ]; then return 1; fi
  if [ ! -f "$SCRIPT_DIR/manifest-read.sh" ]; then return 1; fi
  # shellcheck source=manifest-read.sh
  source "$SCRIPT_DIR/manifest-read.sh"
  local t
  # `|| true` inside the substitution: a missing index/manifest returns 1/3,
  # which would otherwise kill the selector under set -e. A JSON null prints
  # "null", so compare against `bug` only.
  t=$(get_ticket_manifest_field "${TICKET_ID:-}" type 2>/dev/null || true)
  [ "$t" = "bug" ] && return 0 || return 1
}

# Debug specializer for the detected stack. An empty layer tries BE then FE.
select_debug_specializer() {
  local stack=""
  if [ -n "${LAYER:-}" ]; then
    stack=$(detect_stack "$LAYER")
  else
    stack=$(detect_stack BE)
    if [ -z "$stack" ]; then stack=$(detect_stack FE); fi
  fi
  if [ -n "$stack" ]; then
    echo "specializers/debug/${stack}.md"
  else
    echo ""
  fi
  return 0
}

# ── Prescan persona set ────────────────────────────────────────────────────────

# For prescan, we fan out multiple agents in parallel — each with a different
# persona lens. This function emits the complete set of persona file paths.
select_prescan_set() {
  local layer="${LAYER:-}"
  local prescan_personas=()

  # Always include these four lenses
  prescan_personas+=("architect")
  prescan_personas+=("analyzer")
  prescan_personas+=("security")
  prescan_personas+=("technical-writer")

  # Layer-driven developer persona
  case "$layer" in
  FE)
    prescan_personas+=("frontend-developer")
    ;;
  BE | infra)
    prescan_personas+=("backend-developer")
    ;;
  *)
    # Unknown layer — include both frontend and backend
    prescan_personas+=("backend-developer")
    prescan_personas+=("frontend-developer")
    ;;
  esac

  # Optional QA engineer
  if [ "$WITH_QA" = "true" ]; then
    prescan_personas+=("qa-engineer")
  fi

  # Emit each persona as a base path, with specializer if available
  local first=true
  local persona_set=""
  for role in "${prescan_personas[@]}"; do
    local base_path specializer_path persona_entry
    base_path=$(_persona_path "base/${role}.md")
    if [ -z "$base_path" ]; then
      continue # skip missing persona files
    fi

    persona_entry="$base_path"

    # Attach a specializer to the developer personas (stack) and to
    # qa-engineer (test tooling); the other lenses have none.
    case "$role" in
    qa-engineer)
      specializer_path=$(_persona_path "$(select_qa_specializer)")
      if [ -n "$specializer_path" ]; then
        persona_entry="${persona_entry}|${specializer_path}"
      fi
      ;;
    backend-developer | frontend-developer)
      # Temporarily set LAYER for specializer detection
      local saved_layer="$LAYER"
      LAYER="${role%*-developer}" # "backend" or "frontend"
      # Upper-case for the LAYER variable check in select_specializer
      if [ "$LAYER" = "backend" ]; then LAYER="BE"; fi
      if [ "$LAYER" = "frontend" ]; then LAYER="FE"; fi
      specializer_path=$(_persona_path "$(select_specializer)")
      LAYER="$saved_layer"
      if [ -n "$specializer_path" ]; then
        persona_entry="${persona_entry}|${specializer_path}"
      fi
      ;;
    esac

    if [ "$first" = "true" ]; then
      persona_set="$persona_entry"
      first=false
    else
      persona_set="${persona_set}
${persona_entry}"
    fi
  done

  echo "$persona_set"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  local base_role base_path specializer specializer_path auto_include auto_path

  # ── Prescan phase: emit persona set for multi-agent fan-out ────────────────
  if [ "$PHASE" = "prescan" ]; then
    local persona_set
    persona_set=$(select_prescan_set)
    if [ -z "$persona_set" ]; then
      echo "ERROR: No persona files found for prescan phase" >&2
      exit 2
    fi
    echo "PERSONA_SET=$persona_set"
    echo "PERSONA_BASE="
    echo "PERSONA_SPECIALIZER="
    echo "PERSONA_AUTO_INCLUDE="
    echo "PERSONA_TESTDATA="
    echo "PERSONA_TESTDATA_SPECIALIZERS="
    echo "PERSONA_DEBUG="
    echo "PERSONA_DEBUG_SPECIALIZER="
    if [ "$TICKET_DIR_SET" = "true" ]; then
      echo "PERSONA_TYPE=${TYPE}"
    fi
    return
  fi

  base_role=$(select_base)
  base_path=$(_persona_path "base/${base_role}.md")

  if [ -z "$base_path" ]; then
    echo "ERROR: Base persona file not found: personas/base/${base_role}.md (resolved PERSONAS_DIR=$PERSONAS_DIR)" >&2
    exit 2
  fi

  specializer=$(select_specializer)
  specializer_path=""
  if [ -n "$specializer" ]; then
    specializer_path=$(_persona_path "$specializer")
    # If the specializer file doesn't exist, silently fall back to empty
  fi

  auto_include=$(select_auto_include)
  auto_path=""
  if [ -n "$auto_include" ]; then
    auto_path=$(_persona_path "$auto_include")
  fi

  # Test-data persona: a strong signal (the ticket IS test data) or a weak
  # keyword hit both set PERSONA_TESTDATA; only a strong signal on the
  # implement phase also swapped PERSONA_BASE (select_base above).
  local testdata_path="" testdata_specializers=""
  if has_testdata_strong || has_testdata_weak; then
    testdata_path=$(_persona_path "base/test-data-engineer.md")
    if [ -n "$testdata_path" ]; then
      testdata_specializers=$(select_testdata_channels)
    fi
  fi

  # Debugger overlay: additive, never swaps PERSONA_BASE. Only paths whose
  # file exists are emitted.
  local debug_path="" debug_spec_path="" debug_spec
  if debug_overlay_wanted; then
    debug_path=$(_persona_path "base/debugger.md")
    if [ -n "$debug_path" ]; then
      debug_spec=$(select_debug_specializer)
      if [ -n "$debug_spec" ]; then
        debug_spec_path=$(_persona_path "$debug_spec")
      fi
    fi
  fi

  # Emit results as KEY=value — the stable contract for consuming skills
  echo "PERSONA_BASE=$base_path"
  echo "PERSONA_SPECIALIZER=${specializer_path:-}"
  echo "PERSONA_AUTO_INCLUDE=${auto_path:-}"
  echo "PERSONA_TESTDATA=${testdata_path}"
  echo "PERSONA_TESTDATA_SPECIALIZERS=${testdata_specializers}"
  echo "PERSONA_DEBUG=${debug_path}"
  echo "PERSONA_DEBUG_SPECIALIZER=${debug_spec_path}"
  if [ "$TICKET_DIR_SET" = "true" ]; then
    echo "PERSONA_TYPE=${TYPE}"
  fi
}

main
