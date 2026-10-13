#!/usr/bin/env bash
# test-ticket-create-guard.sh — unit tests for hooks/ticket-create-guard.sh
# (ticket-create-skill). Feeds PreToolUse payloads on stdin.
# Usage: bash test-ticket-create-guard.sh [filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$(cd "$SCRIPT_DIR/../.." && pwd)/hooks/ticket-create-guard.sh"

PASS=0
FAIL=0

# _guard <payload> — prints the hook's stdout; the hook must always exit 0.
_guard() {
  printf '%s' "$1" | TICKET_CREATE_GUARD="${GUARD_ENV:-on}" bash "$GUARD"
}

_bash_payload() { jq -cn --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }

_denied() {
  local out
  out=$(_guard "$1") || return 1
  echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | contains("/ticket-create"))' >/dev/null 2>&1
}

_allowed() {
  local out
  out=$(_guard "$1") || return 1
  [ -z "$out" ]
}

test_mcp_create_denied() {
  _denied '{"tool_name":"mcp__linear-server__save_issue","tool_input":{"title":"x","team":"WIL"}}'
}

test_mcp_create_issue_tool_denied() {
  _denied '{"tool_name":"mcp__claude_ai_Linear__create_issue","tool_input":{"title":"x"}}'
}

test_mcp_update_allowed() {
  _allowed '{"tool_name":"mcp__linear-server__save_issue","tool_input":{"id":"WIL-5","description":"y"}}'
}

test_mcp_empty_id_denied() {
  _denied '{"tool_name":"mcp__linear-server__save_issue","tool_input":{"id":"","title":"x"}}'
}

test_curl_issue_create_denied() {
  _denied "$(_bash_payload 'curl -s https://api.linear.app/graphql -d '"'"'{"query":"mutation { issueCreate(input: {title: \"x\"}) { success } }"}'"'")"
}

test_lib_create_issue_denied() {
  _denied "$(_bash_payload 'source ~/.claude/skills/lib/linear-api.sh; create_issue "$TEAM" "Title" "Body"')"
}

test_lib_create_issue_newline_denied() {
  _denied "$(_bash_payload $'source lib/linear-api.sh\ncreate_issue t x y')"
}

test_planner_path_allowed() {
  _allowed "$(_bash_payload 'source ticket-planner/lib/planner-linear.sh && planner_linear_create_issue "$TEAM" "$TITLE" "$BODY"')"
}

# TicketGen's real block shape: issueCreate appears in a jq path and a
# message alongside the planner's own create call.
test_planner_block_with_issue_create_text_allowed() {
  _allowed "$(_bash_payload $'source ~/.claude/skills/lib/linear-api.sh\nR=$(planner_linear_create_issue "$T" "$X" "$D") || echo "issueCreate failed"\necho "$R" | jq -r .data.issueCreate.issue.identifier')"
}

test_create_sh_allowed() {
  _allowed "$(_bash_payload 'bash ~/.claude/skills/ticket-create/create.sh --type bug --kind business --title x --body-file /tmp/b.md')"
}

test_unrelated_bash_allowed() {
  _allowed "$(_bash_payload 'ls -la && git status')"
}

# Reading or grepping code that mentions the function must never be denied.
test_grep_create_issue_allowed() {
  _allowed "$(_bash_payload 'grep -n create_issue lib/linear-api.sh')"
}

test_grep_issue_create_allowed() {
  _allowed "$(_bash_payload 'grep -rn issueCreate lib/')"
}

test_other_tool_allowed() {
  _allowed '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
}

test_non_json_allowed() {
  _allowed 'this is not json {'
}

test_guard_off_allowed() {
  GUARD_ENV=off _allowed '{"tool_name":"mcp__linear-server__save_issue","tool_input":{"title":"x"}}'
}

# --- #501: prose about the Linear API must not be read as a network call ---

# The reported case: heredoc bodies mention issueCreate and a GraphQL helper,
# then gh files a GitHub issue. Nothing here sends a Linear mutation.
test_heredoc_then_gh_issue_create_allowed() {
  _allowed "$(_bash_payload $'cat > /tmp/body.md <<\'EOF\'\nUnsure whether issueCreate accepts an identifier; see planner_linear_graphql.\ncurl -s https://api.linear.app/graphql\nEOF\ngh issue create --repo o/r --title x --body-file /tmp/body.md')"
}

test_gh_title_mentions_mutation_allowed() {
  _allowed "$(_bash_payload 'gh issue create --repo o/r --title "guard denies issueCreate + linear_graphql at api.linear.app" --body-file /tmp/b.md')"
}

test_gh_pr_body_mentions_mutation_allowed() {
  _allowed "$(_bash_payload 'gh pr create --title fix --body "curl -d issueCreate https://api.linear.app/graphql"')"
}

# Accepted false positive: any git stage plus the mutation and a sender in the
# call denies. Use `git commit -F <file>` with the file written by a separate call.
test_git_commit_mentions_mutation_denied() {
  _denied "$(_bash_payload 'git commit -m "fix: issueCreate via linear_graphql at api.linear.app"')"
}

# A git commit mentioning only the mutation (no sender) stays allowed.
test_git_commit_mutation_only_allowed() {
  _allowed "$(_bash_payload 'git commit -m "fix: guard no longer denies issueCreate prose"')"
}

test_echo_to_file_mentions_mutation_allowed() {
  _allowed "$(_bash_payload 'echo "issueCreate is sent by linear_graphql to api.linear.app" > notes.md')"
}

test_comment_mentions_mutation_allowed() {
  _allowed "$(_bash_payload $'ls docs # curl issueCreate here\nwc -l docs/*.md')"
}

test_heredoc_create_issue_line_allowed() {
  _allowed "$(_bash_payload $'cat > /tmp/notes.md <<EOF\ncreate_issue t x y\nEOF')"
}

test_linear_read_without_mutation_allowed() {
  _allowed "$(_bash_payload 'source lib/linear-api.sh; linear_graphql "query { viewer { id } }" # create_issue later')"
}

# --- #501: the guard's real purpose is unchanged ---

test_planner_graphql_issue_create_denied() {
  _denied "$(_bash_payload 'planner_linear_graphql '"'"'mutation { issueCreate(input: {title: "x"}) { success } }'"'")"
}

test_linear_graphql_heredoc_issue_create_denied() {
  _denied "$(_bash_payload $'linear_graphql "$(cat <<\'EOF\'\nmutation { issueCreate(input: {title: "x"}) { success } }\nEOF\n)"')"
}

test_curl_stdin_heredoc_issue_create_denied() {
  _denied "$(_bash_payload $'curl -s -H "Authorization: $LINEAR_API_KEY" --data-binary @- https://api.linear.app/graphql <<EOF\n{"query":"mutation { issueCreate(input: {title: \\"x\\"}) { success } }"}\nEOF')"
}

test_mutation_in_variable_then_curl_denied() {
  _denied "$(_bash_payload $'Q=\'mutation { issueCreate(input: {title: "x"}) { success } }\'\ncurl -s -d "{\\"query\\": \\"$Q\\"}" "$LINEAR_URL"')"
}

test_assignment_prefix_curl_denied() {
  _denied "$(_bash_payload 'TOKEN=$(cat ~/.linear) curl -s -H "Authorization: $TOKEN" -d @/tmp/issueCreate.json https://api.linear.app/graphql')"
}

test_wget_issue_create_denied() {
  _denied "$(_bash_payload '/usr/bin/wget -qO- --post-data='"'"'{"query":"mutation { issueCreate(input: {}) { success } }"}'"'"' https://api.linear.app/graphql')"
}

test_python_api_linear_app_issue_create_denied() {
  _denied "$(_bash_payload 'python3 -c "import requests; requests.post(\"https://api.linear.app/graphql\", json={\"query\": \"mutation { issueCreate(input: {}) { success } }\"})"')"
}

test_create_issue_in_substitution_denied() {
  _denied "$(_bash_payload 'source lib/linear-api.sh && R=$(create_issue "$TEAM" "Title" "Body") && echo "$R"')"
}

test_deny_reason_names_pattern() {
  local out
  out=$(_guard "$(_bash_payload 'planner_linear_graphql "mutation { issueCreate(input: {}) { success } }"')")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("matched: issueCreate with network sender planner_linear_graphql")' >/dev/null
}

# --- PR review of #501: bypasses the first scanner allowed ---

_U='https://api.linear.app/graphql'
_Q='-d '"'"'{"query":"mutation { issueCreate(input: {title: \"x\"}) { success } }"}'"'"

# B1: a heredoc fed to an interpreter is code, not prose.
test_sh_heredoc_denied() {
  _denied "$(_bash_payload "$(printf 'sh <<EOF\ncurl -s %s %s\nEOF' "$_U" "$_Q")")"
}

test_bash_quoted_heredoc_denied() {
  _denied "$(_bash_payload "$(printf "bash <<'EOF'\ncurl -s %s %s\nEOF" "$_U" "$_Q")")"
}

test_bash_s_dquoted_heredoc_denied() {
  _denied "$(_bash_payload "$(printf 'bash -s <<"EOF"\ncurl -s %s %s\nEOF' "$_U" "$_Q")")"
}

test_cat_heredoc_pipe_sh_denied() {
  _denied "$(_bash_payload "$(printf 'cat <<EOF | sh\ncurl -s %s %s\nEOF' "$_U" "$_Q")")"
}

test_python_heredoc_denied() {
  _denied "$(_bash_payload "$(printf 'python3 - <<EOF\nimport urllib.request\nurllib.request.urlopen("%s", data=b"mutation { issueCreate(input: {}) { success } }")\nEOF' "$_U")")"
}

test_perl_heredoc_denied() {
  _denied "$(_bash_payload "$(printf 'perl - <<EOF\nsystem("curl -s %s -d mutation_issueCreate");\nEOF' "$_U")")"
}

test_node_heredoc_denied() {
  _denied "$(_bash_payload "$(printf 'node <<EOF\nfetch("%s", {method: "POST", body: "mutation { issueCreate(input: {}) { success } }"})\nEOF' "$_U")")"
}

# B1 counterpart: writing a file from a heredoc stays allowed.
test_cat_to_file_heredoc_with_url_allowed() {
  _allowed "$(_bash_payload "$(printf 'cat > /tmp/notes.md <<EOF\ncurl -s %s %s\nEOF\nwc -l /tmp/notes.md' "$_U" "$_Q")")"
}

# B2: a gh/git stage does not exempt the rest of its pipeline.
test_gh_pipe_curl_denied() {
  _denied "$(_bash_payload "gh issue list | curl -s $_U $_Q")"
}

test_git_pipe_curl_denied() {
  _denied "$(_bash_payload "git log | curl -s $_U $_Q")"
}

test_gh_jq_pipe_curl_denied() {
  _denied "$(_bash_payload "gh api x | jq . | curl -s $_U $_Q")"
}

test_gh_pipe_sh_c_curl_denied() {
  _denied "$(_bash_payload "gh api x | sh -c 'curl -s $_U $_Q'")"
}

test_git_xargs_curl_denied() {
  _denied "$(_bash_payload "git rev-parse HEAD | xargs -I{} curl -s $_U $_Q")"
}

# M1: wrappers with flags (or unknown wrappers) and the URL in a variable.
test_timeout_curl_url_var_denied() {
  _denied "$(_bash_payload "U=$_U; timeout 10 curl -s \$U $_Q")"
}

test_xargs_flag_curl_url_var_denied() {
  _denied "$(_bash_payload "U=$_U; echo x | xargs -0 curl -s \$U $_Q")"
}

test_sudo_e_curl_url_var_denied() {
  _denied "$(_bash_payload "U=$_U; sudo -E curl -s \$U $_Q")"
}

test_nice_curl_url_var_denied() {
  _denied "$(_bash_payload "U=$_U; nice -n5 curl -s \$U $_Q")"
}

# M2: $((a<<b)) is arithmetic, not a heredoc that swallows later lines.
test_arith_shift_then_curl_denied() {
  _denied "$(_bash_payload "$(printf 'echo $((1<<2))\ncurl -s %s %s' "$_U" "$_Q")")"
}

test_arith_shift_var_then_curl_denied() {
  _denied "$(_bash_payload "$(printf 'x=1; echo $((x<<y))\ncurl -s %s %s' "$_U" "$_Q")")"
}

# m1: an escaped backslash at end of line is not a line continuation.
test_escaped_backslash_eol_then_curl_denied() {
  _denied "$(_bash_payload "$(printf 'echo \\\\\\\\\ncurl -s %s %s' "$_U" "$_Q")")"
}

# --- Script written by a heredoc, then run in the same call ---

_script_heredoc() { printf 'cat > /tmp/x.sh <<EOF\ncurl -s %s %s\nEOF\n%s' "$_U" "$_Q" "$1"; }

test_heredoc_script_then_source_denied() {
  _denied "$(_bash_payload "$(_script_heredoc 'source /tmp/x.sh')")"
}

test_heredoc_script_then_bash_denied() {
  _denied "$(_bash_payload "$(_script_heredoc 'bash /tmp/x.sh')")"
}

test_heredoc_script_then_dot_denied() {
  _denied "$(_bash_payload "$(_script_heredoc '. /tmp/x.sh')")"
}

test_heredoc_script_and_sh_denied() {
  _denied "$(_bash_payload "$(printf 'cat > /tmp/x.sh <<EOF && sh /tmp/x.sh\ncurl -s %s %s\nEOF' "$_U" "$_Q")")"
}

# #501 acceptance shape: every pipeline is text-only (cat, gh).
test_heredoc_with_sender_then_gh_only_allowed() {
  _allowed "$(_bash_payload "$(printf 'cat > notes.md <<EOF\nUse curl -s %s %s\nEOF\ngh issue create --repo o/r --title x --body-file notes.md' "$_U" "$_Q")")"
}

# A heredoc that names the mutation but no sender is prose, even beside a
# non-text command.
test_heredoc_mutation_only_then_script_allowed() {
  _allowed "$(_bash_payload $'cat > notes.md <<EOF\nThe issueCreate mutation returns an identifier.\nEOF\nbash scripts/lint.sh notes.md')"
}

# --- gh/git are text-only only for a safe subcommand set ---

test_git_c_alias_denied() {
  _denied "$(_bash_payload "git -c alias.x='!curl -s $_U $_Q' x")"
}

test_git_c_core_pager_denied() {
  _denied "$(_bash_payload "git -c core.pager='sh -c \"curl -s $_U $_Q\"' log")"
}

test_git_pager_env_prefix_denied() {
  _denied "$(_bash_payload "GIT_PAGER='sh -c \"curl -s $_U $_Q\"' git log")"
}

test_git_rebase_exec_denied() {
  _denied "$(_bash_payload "git rebase --exec 'curl -s $_U $_Q' HEAD~1")"
}

test_gh_alias_set_shell_denied() {
  _denied "$(_bash_payload "gh alias set --shell x 'curl -s $_U $_Q'")"
}

test_gh_extension_exec_denied() {
  _denied "$(_bash_payload "gh extension exec x $_U $_Q")"
}

test_gh_api_heredoc_input_denied() {
  _denied "$(_bash_payload "$(printf 'gh api graphql --input - <<EOF\ncurl -s %s %s\nEOF' "$_U" "$_Q")")"
}

# #501 acceptance shapes stay allowed under the narrowed gh/git rule.
test_gh_issue_create_heredoc_body_allowed() {
  _allowed "$(_bash_payload "$(printf 'gh issue create --repo o/r --title "issueCreate via linear_graphql" --body-file - <<EOF\ncurl -s %s %s\nEOF' "$_U" "$_Q")")"
}

# Accepted false positive (git rule): see test_git_commit_mentions_mutation_denied.
test_git_commit_m_mutation_denied() {
  _denied "$(_bash_payload "git commit -m 'fix: issueCreate sent by curl to $_U'")"
}

# --- git config written without a heredoc, then used by git ---

test_printf_git_config_pager_then_log_denied() {
  _denied "$(_bash_payload "printf '[core]\\n\\tpager = curl -s $_U $_Q\\n' >> .git/config; git log")"
}

test_echo_git_config_then_checkout_denied() {
  _denied "$(_bash_payload "echo '[filter \"x\"] smudge = curl -s $_U $_Q' >> .git/config; echo '* filter=x' > .gitattributes; git checkout .")"
}

test_echo_gitattributes_then_checkout_denied() {
  _denied "$(_bash_payload "echo '* filter=x  # curl -s $_U $_Q' >> .gitattributes; git checkout .")"
}

# --- Final review: receive-pack flag, git config written by a heredoc ---

test_git_push_receive_pack_denied() {
  _denied "$(_bash_payload "git push --receive-pack='curl -s $_U $_Q' /tmp/r main")"
}

test_git_config_filter_smudge_then_checkout_denied() {
  _denied "$(_bash_payload "$(printf 'cat >> .git/config <<EOF\n[filter "x"]\n  smudge = sh -c '"'"'curl -s %s %s'"'"'\nEOF\necho "* filter=x" > .gitattributes; git checkout .' "$_U" "$_Q")")"
}

test_git_config_diff_textconv_then_diff_denied() {
  _denied "$(_bash_payload "$(printf 'cat >> .git/config <<EOF\n[diff "x"]\n  textconv = sh -c '"'"'curl -s %s %s'"'"'\nEOF\necho "* diff=x" > .gitattributes; git diff' "$_U" "$_Q")")"
}

test_git_config_pager_tee_then_log_denied() {
  _denied "$(_bash_payload "$(printf 'tee -a .git/config <<EOF\n[core]\n  pager = curl -s %s %s\nEOF\ngit log' "$_U" "$_Q")")"
}

FILTER="${1:-}"
# Security review of #508: commands that can run other commands are not text.
test_awk_system_curl_denied() {
  _denied "$(_bash_payload "awk 'BEGIN{system(\"curl -s $_U -d issueCreate\")}'")"
}
test_sed_e_curl_denied() {
  _denied "$(_bash_payload "echo x | sed 's/x/curl -s $_U -d issueCreate/e'")"
}
test_rg_pre_curl_denied() {
  _denied "$(_bash_payload "rg --pre 'curl -s $_U -d issueCreate' x .")"
}
test_sort_compress_program_denied() {
  _denied "$(_bash_payload "sort --compress-program=curl -o /tmp/x $_U issueCreate")"
}
# Control regression: a script written with printf/echo, then run, in one call.
test_printf_script_then_bash_denied() {
  _denied "$(_bash_payload "printf '%s\\n' 'curl -s $_U -d issueCreate' > /tmp/x.sh; bash /tmp/x.sh")"
}
test_echo_script_then_source_denied() {
  _denied "$(_bash_payload "echo \"curl -s $_U -d issueCreate\" > /tmp/x.sh && source /tmp/x.sh")"
}
# The #501 shape stays allowed: prose written by text commands, then gh.
test_printf_prose_then_gh_issue_create_allowed() {
  _allowed "$(_bash_payload "printf 'calls curl on api.linear.app with issueCreate' > /tmp/b.md && gh issue create --title x --body-file /tmp/b.md")"
}

# --- #516: parser differentials against bash, and the failure paths ---
#
# Each shape below has an explicit verdict. Where the shape is safe to run,
# the test also runs it through bash with curl stubbed (in a temp dir), so the
# verdict is checked against what bash really does, not only against the
# scanner. "Accepted false positive" marks a shape the guard denies although
# bash would not send: the scanner errs toward denying there on purpose.

_S="curl -s $_U -d issueCreate"

# _bash_runs_curl <cmd> — 0 when bash, with curl stubbed, really runs curl.
_bash_runs_curl() {
  local stub rc=1
  stub=$(mktemp -d)
  printf '#!/bin/sh\ntouch "%s/ran"\n' "$stub" >"$stub/curl"
  chmod +x "$stub/curl"
  (cd "$stub" && PATH="$stub:$PATH" timeout 5 bash -c "$1" >/dev/null 2>&1 </dev/null) || true
  [ -e "$stub/ran" ] && rc=0
  rm -rf "$stub"
  return "$rc"
}
_denied_sends() { _denied "$(_bash_payload "$1")" && _bash_runs_curl "$1"; }
_allowed_silent() { _allowed "$(_bash_payload "$1")" && ! _bash_runs_curl "$1"; }
_denied_silent() { _denied "$(_bash_payload "$1")" && ! _bash_runs_curl "$1"; }

# ANSI-C quoting: \' does not end $'...' (was allowed before #516).
test_ansi_c_escaped_quote_then_curl_denied() {
  _denied_sends "echo \$'it\\'s'; $_S"
}
test_ansi_c_escape_then_curl_denied() {
  _denied_sends "echo \$'a\\tb'; $_S"
}
test_ansi_c_prose_to_file_allowed() {
  _allowed_silent "echo \$'issueCreate goes out via curl to api.linear.app\\n' > notes.md"
}
test_ansi_c_escaped_quote_prose_allowed() {
  _allowed_silent "echo \$'curl \\' issueCreate'"
}
# $"..." (locale quoting) reads like double quotes.
test_locale_dq_then_curl_denied() {
  _denied_sends "echo \$\"x\"; $_S"
}
# ${...}: a ")" inside it does not end $( ) (was allowed before #516).
test_param_paren_in_substitution_denied() {
  _denied_sends "echo \"\$(echo \${x:-)} ; $_S)\""
}
# ${...}: a "#" inside it is not a comment (was allowed before #516).
test_param_hash_then_curl_denied() {
  _denied_sends "echo \${x:- #}; $_S"
}
test_param_nested_dq_substitution_denied() {
  _denied_sends "echo \"\${x:-\"\$($_S)\"}\""
}
test_param_default_prose_allowed() {
  _allowed_silent "echo \"\${x:-issueCreate via curl}\" > notes.md"
}
# Accepted false positive: bash reads the quotes inside ${...} and fails to
# parse; the scanner does not, and denies.
test_param_sq_in_dq_denied() {
  _denied_silent "echo \"\${x:-'}'\"; $_S"
}
# A "#" inside a word is not a comment; one starting a word is.
test_midword_hash_then_curl_denied() {
  _denied_sends "echo a#b; $_S"
}
test_word_start_hash_comment_allowed() {
  _allowed_silent "echo a #; $_S"
}
# CR is an ordinary word character for bash and for the scanner.
test_crlf_lines_curl_denied() {
  _denied_sends "$(printf 'echo x\r\n%s\r\n' "$_S")"
}
test_cr_in_word_then_curl_denied() {
  _denied_sends "$(printf 'echo x\r; %s' "$_S")"
}
# case/esac: the pattern ")" and ";;" split commands; case itself is non-text.
test_case_arm_curl_denied() {
  _denied_sends "case a in a) $_S;; esac"
}
test_case_in_substitution_curl_denied() {
  _denied_sends "echo \"\$(case a in a) $_S;; esac)\""
}
# Accepted false positive: case/esac count as non-text commands.
test_case_prose_denied() {
  _denied_silent "case \$x in a) echo 'issueCreate via curl';; esac"
}

# Fail open: no jq, so the guard cannot read the payload at all.
test_missing_jq_fails_open() {
  local d out p rc=0
  d=$(mktemp -d)
  p=$(_bash_payload "$_S")
  # Here-string, not a pipe: the hook exits before reading stdin.
  out=$(TICKET_CREATE_GUARD=on PATH="$d" "$BASH" "$GUARD" <<<"$p") || rc=1
  rm -rf "$d"
  [ "$rc" -eq 0 ] && [ -z "$out" ]
}
# Fail open: a payload jq cannot parse, even one naming the mutation and curl.
test_malformed_json_with_mutation_fails_open() {
  _allowed '{"tool_name":"Bash","tool_input":{"command":"curl https://api.linear.app/graphql -d issueCreate"'
}
# NUL: bash drops it when reading jq output, so the scanner sees "curl".
test_json_nul_escape_denied() {
  _denied '{"tool_name":"Bash","tool_input":{"command":"cu\u0000rl -s https://api.linear.app/graphql -d issueCreate"}}' 2>/dev/null
}

# _guard_broken_awk <payload> — the hook with an awk that always fails.
_guard_broken_awk() {
  local d out
  d=$(mktemp -d)
  printf '#!/bin/sh\nexit 2\n' >"$d/awk"
  chmod +x "$d/awk"
  out=$(printf '%s' "$1" | TICKET_CREATE_GUARD=on PATH="$d:$PATH" bash "$GUARD")
  rm -rf "$d"
  printf '%s' "$out"
}
_broken_awk_denied() {
  _guard_broken_awk "$(_bash_payload "$1")" | jq -e '.hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | contains("could not judge (scanner error)"))' >/dev/null 2>&1
}
_broken_awk_allowed() { [ -z "$(_guard_broken_awk "$(_bash_payload "$1")")" ]; }

# Fail closed on raw text when the scanner fails.
test_awk_failure_mutation_and_sender_denied() {
  _broken_awk_denied "$_S"
}
test_awk_failure_mutation_only_allowed() {
  _broken_awk_allowed 'echo "issueCreate returns an identifier" > notes.md'
}
test_awk_failure_create_issue_command_denied() {
  _broken_awk_denied 'source lib/linear-api.sh; create_issue t x y'
}
test_awk_failure_grep_create_issue_allowed() {
  _broken_awk_allowed 'grep -n create_issue lib/linear-api.sh'
}
# Accepted false positive, in the failure mode only: the raw-text rule cannot
# tell a gh body from a send.
test_awk_failure_gh_prose_denied() {
  _broken_awk_denied 'gh issue create --title "issueCreate via curl" --body-file b.md'
}

# Over the scan cap (65536): judged on raw text.
_pad() { printf '%0*d' "$1" 0; }
test_oversized_mutation_and_sender_denied() {
  local out
  out=$(_guard "$(_bash_payload "echo $(_pad 70000) > /tmp/x; $_S")")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("could not judge (over 65536 characters)")' >/dev/null
}
test_oversized_mutation_only_allowed() {
  _allowed "$(_bash_payload "echo $(_pad 70000) issueCreate > notes.md")"
}
# Under the cap, a long command is scanned, and well inside the 2s hook
# timeout. The long word once made a regex backtrack for 35s at 100KB.
test_long_word_scanned_within_timeout() {
  local t0 t1
  t0=$(date +%s%N)
  _denied "$(_bash_payload "echo $(_pad 60000); $_S")" || return 1
  t1=$(date +%s%N)
  [ $(((t1 - t0) / 1000000)) -lt 2000 ]
}
test_long_gh_body_under_cap_allowed() {
  _allowed "$(_bash_payload "gh issue create --title x --body \"$(_pad 60000) issueCreate via curl\"")"
}

for fn in \
  test_ansi_c_escaped_quote_then_curl_denied \
  test_ansi_c_escape_then_curl_denied \
  test_ansi_c_prose_to_file_allowed \
  test_ansi_c_escaped_quote_prose_allowed \
  test_locale_dq_then_curl_denied \
  test_param_paren_in_substitution_denied \
  test_param_hash_then_curl_denied \
  test_param_nested_dq_substitution_denied \
  test_param_default_prose_allowed \
  test_param_sq_in_dq_denied \
  test_midword_hash_then_curl_denied \
  test_word_start_hash_comment_allowed \
  test_crlf_lines_curl_denied \
  test_cr_in_word_then_curl_denied \
  test_case_arm_curl_denied \
  test_case_in_substitution_curl_denied \
  test_case_prose_denied \
  test_missing_jq_fails_open \
  test_malformed_json_with_mutation_fails_open \
  test_json_nul_escape_denied \
  test_awk_failure_mutation_and_sender_denied \
  test_awk_failure_mutation_only_allowed \
  test_awk_failure_create_issue_command_denied \
  test_awk_failure_grep_create_issue_allowed \
  test_awk_failure_gh_prose_denied \
  test_oversized_mutation_and_sender_denied \
  test_oversized_mutation_only_allowed \
  test_long_word_scanned_within_timeout \
  test_long_gh_body_under_cap_allowed \
  test_awk_system_curl_denied \
  test_sed_e_curl_denied \
  test_rg_pre_curl_denied \
  test_sort_compress_program_denied \
  test_printf_script_then_bash_denied \
  test_echo_script_then_source_denied \
  test_printf_prose_then_gh_issue_create_allowed \
  test_mcp_create_denied \
  test_mcp_create_issue_tool_denied \
  test_mcp_update_allowed \
  test_mcp_empty_id_denied \
  test_curl_issue_create_denied \
  test_lib_create_issue_denied \
  test_lib_create_issue_newline_denied \
  test_planner_path_allowed \
  test_planner_block_with_issue_create_text_allowed \
  test_create_sh_allowed \
  test_unrelated_bash_allowed \
  test_grep_create_issue_allowed \
  test_grep_issue_create_allowed \
  test_other_tool_allowed \
  test_non_json_allowed \
  test_guard_off_allowed \
  test_heredoc_then_gh_issue_create_allowed \
  test_gh_title_mentions_mutation_allowed \
  test_gh_pr_body_mentions_mutation_allowed \
  test_git_commit_mentions_mutation_denied \
  test_git_commit_mutation_only_allowed \
  test_echo_to_file_mentions_mutation_allowed \
  test_comment_mentions_mutation_allowed \
  test_heredoc_create_issue_line_allowed \
  test_linear_read_without_mutation_allowed \
  test_planner_graphql_issue_create_denied \
  test_linear_graphql_heredoc_issue_create_denied \
  test_curl_stdin_heredoc_issue_create_denied \
  test_mutation_in_variable_then_curl_denied \
  test_assignment_prefix_curl_denied \
  test_wget_issue_create_denied \
  test_python_api_linear_app_issue_create_denied \
  test_create_issue_in_substitution_denied \
  test_deny_reason_names_pattern \
  test_sh_heredoc_denied \
  test_bash_quoted_heredoc_denied \
  test_bash_s_dquoted_heredoc_denied \
  test_cat_heredoc_pipe_sh_denied \
  test_python_heredoc_denied \
  test_perl_heredoc_denied \
  test_node_heredoc_denied \
  test_cat_to_file_heredoc_with_url_allowed \
  test_gh_pipe_curl_denied \
  test_git_pipe_curl_denied \
  test_gh_jq_pipe_curl_denied \
  test_gh_pipe_sh_c_curl_denied \
  test_git_xargs_curl_denied \
  test_timeout_curl_url_var_denied \
  test_xargs_flag_curl_url_var_denied \
  test_sudo_e_curl_url_var_denied \
  test_nice_curl_url_var_denied \
  test_arith_shift_then_curl_denied \
  test_arith_shift_var_then_curl_denied \
  test_escaped_backslash_eol_then_curl_denied \
  test_heredoc_script_then_source_denied \
  test_heredoc_script_then_bash_denied \
  test_heredoc_script_then_dot_denied \
  test_heredoc_script_and_sh_denied \
  test_heredoc_with_sender_then_gh_only_allowed \
  test_heredoc_mutation_only_then_script_allowed \
  test_git_c_alias_denied \
  test_git_c_core_pager_denied \
  test_git_pager_env_prefix_denied \
  test_git_rebase_exec_denied \
  test_gh_alias_set_shell_denied \
  test_gh_extension_exec_denied \
  test_gh_api_heredoc_input_denied \
  test_gh_issue_create_heredoc_body_allowed \
  test_git_commit_m_mutation_denied \
  test_printf_git_config_pager_then_log_denied \
  test_echo_git_config_then_checkout_denied \
  test_echo_gitattributes_then_checkout_denied \
  test_git_push_receive_pack_denied \
  test_git_config_filter_smudge_then_checkout_denied \
  test_git_config_diff_textconv_then_diff_denied \
  test_git_config_pager_tee_then_log_denied; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  if "$fn"; then
    echo "PASS: $fn"
    ((PASS++)) || true
  else
    echo "FAIL: $fn"
    ((FAIL++)) || true
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
