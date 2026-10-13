#!/usr/bin/env bash
# ticket-create-guard.sh — PreToolUse hook (ticket-create-skill, design D5).
# Denies direct Linear issue creation so every new ticket goes through
# /ticket-create (skills/ticket-create/create.sh): template layout, readiness
# check, duplicate check, _adhoc manifest.
#
# Denied:
#   - Linear MCP save_issue/create_issue with no tool_input.id (a create)
#   - Bash that runs create_issue as a command (not the planner's
#     planner_linear_create_issue), or that mentions issueCreate and has a
#     pipeline that is not purely text commands whose text (heredoc bodies
#     included) names curl/wget/*linear_graphql or api.linear.app
# Allowed: create.sh itself, the planner path, MCP updates (id present),
# everything else, and every call when TICKET_CREATE_GUARD=off (set in the
# Claude Code session environment — a `VAR=off` prefix inside the command
# never reaches the hook).
#
# A small shell-aware scanner (quotes, $( ), $(( )), backticks, comments,
# heredocs) splits the command into pipelines and finds their command words.
# A pipeline made only of text commands (echo, cat, jq, gh, git, ...; never
# awk, sed, rg, sort or less, which can run commands) never
# counts as a sender, so writing prose about the API to a file, or filing a
# GitHub issue about it, is allowed (#501). Comments are dropped. A heredoc
# belongs to the pipeline that reads it, so `sh <<EOF` or `cat <<EOF | sh`
# is checked like any other code. A call whose text (heredocs and quoted
# strings included) holds the mutation and a sender also denies when any
# pipeline in it is non-text, which covers writing a script to a file and
# then running or sourcing it.
#
# Fails open: missing jq or a payload that does not parse exits 0 silently —
# a broken guard must never block unrelated work. Matching is deliberately
# narrow so reading, grepping or writing prose about create_issue/issueCreate
# is never denied. This guards against drift off the standard path; it is not
# a defence against a determined bypass.

[ "${TICKET_CREATE_GUARD:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ -n "$tool" ] || exit 0

# deny <matched pattern> — names what matched so a false positive is easy to
# diagnose.
deny() {
  jq -cn --arg m "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
    permissionDecisionReason: ("Direct ticket creation is disabled (matched: " + $m + ") — use the /ticket-create skill (bash ~/.claude/skills/ticket-create/create.sh …) so the ticket gets the standard template, readiness check and duplicate check. Set TICKET_CREATE_GUARD=off in the Claude Code session environment to bypass.")}}'
  exit 0
}

if [[ "$tool" =~ ^mcp__.*[Ll]inear.*__(save_issue|create_issue)$ ]]; then
  id=$(printf '%s' "$payload" | jq -r '.tool_input.id // empty' 2>/dev/null) || exit 0
  [ -z "$id" ] && deny "$tool without tool_input.id"
  exit 0
fi

[ "$tool" = "Bash" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0
[[ "$cmd" == *"ticket-create/create.sh"* ]] && exit 0
# EpicGen/TicketGen: the planner runs its own pre-create validation and
# Refinement DoR. Its blocks mention issueCreate in jq paths and messages.
[[ "$cmd" == *planner_linear_create_issue* ]] && exit 0
# Cheap pre-filter: nothing below can match without one of these.
[[ "$cmd" == *create_issue* || "$cmd" == *issueCreate* ]] || exit 0

# _scan — reads a shell command on stdin and prints one line per finding:
#   create_issue        create_issue run as a command
#   sender <word>       curl/wget/*linear_graphql named in a non-text pipeline
#   url <first-word>    api.linear.app named in a non-text pipeline
#   heredoc <word>      the command text (heredocs and quoted strings
#                       included) holds issueCreate and a sender, and the
#                       command has a non-text pipeline somewhere
# A non-text pipeline is one with at least one command word outside the
# text-only list (echo, cat, jq, gh, git, ...), or with no command word.
_scan() {
  awk '
    function top() { return st[sp] }
    function unquoted() { return top() == "top" || top() == "sub" || top() == "bq" }
    function endword(   w, base) {
      if (!collecting) return
      collecting = 0
      w = word; word = ""
      if (w == "") return
      # Arguments of the current gh/git stage, for the safe-subcommand check.
      if (!cs) { if (stg) sargs[stg] = sargs[stg] " " w; return }
      # Assignment prefixes and wrappers keep the next word in command position.
      if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { if (w ~ /^GIT_/) gitenv = 1; return }
      if (w ~ /^(\{|\}|!|then|do|else|elif|if|while|until|time|command|exec|sudo|env|nohup|xargs|builtin|eval)$/) return
      cs = 0
      base = w; sub(/.*\//, "", base)
      words[pl] = words[pl] " " base
      if (first[pl] == "") first[pl] = base
      stg = 0
      if (base == "gh" || base == "git") { ns++; stg = ns; scmd[ns] = base; sargs[ns] = ""; spl[ns] = pl; sgenv[ns] = gitenv }
      gitenv = 0
    }
    function newpipe() { endword(); pl++; words[pl] = ""; first[pl] = ""; ptext[pl] = ""; cs = 1; stg = 0; gitenv = 0 }
    function cmdstart() { endword(); cs = 1; stg = 0; gitenv = 0 }
    function push(s) { endword(); saved[sp] = cs; savedstg[sp] = stg; st[++sp] = s; cs = 1; stg = 0 }
    function pop() { endword(); if (sp > 0) { sp--; cs = saved[sp]; stg = savedstg[sp] } }
    # gh_git_safe <stage> — 1 when a gh/git stage is a known read/record
    # subcommand with no config, exec, upload-pack or receive-pack flag and no
    # GIT_* prefix.
    function gh_git_safe(k,   n, a, i, nf, f1, f2, rest) {
      if (sgenv[k]) return 0
      n = split(sargs[k], a, " ")
      nf = 0; f1 = ""; f2 = ""; rest = 0
      for (i = 1; i <= n; i++) {
        if (a[i] == "-c" || a[i] == "-x" || a[i] ~ /^-c./ || a[i] ~ /^--(config|exec|upload-pack|receive-pack)/) return 0
        if (a[i] ~ /^-/) continue
        nf++
        if (nf == 1) f1 = a[i]; else if (nf == 2) f2 = a[i]; else rest = 1
      }
      if (scmd[k] == "git") {
        if (f1 ~ /^(commit|log|diff|status|show|add|push|fetch|branch|checkout|switch|rev-parse)$/) return 1
        return (f1 == "remote" && f2 == "" && sargs[k] == " -v")
      }
      if (f1 == "issue") return (f2 ~ /^(create|edit|comment|view|list)$/)
      if (f1 == "pr") return (f2 ~ /^(create|edit|comment|view|list|diff|checks)$/)
      if (f1 == "repo") return (f2 == "view")
      return 0
    }
    function addch(c) {
      ptext[pl] = ptext[pl] c
      if (c ~ /^[ \t\n]$/ && unquoted()) { endword(); return }
      collecting = 1; word = word c
    }
    { lines[++nl] = $0 }
    END {
      sp = 0; st[0] = "top"; pl = 0; words[0] = ""; first[0] = ""; ptext[0] = ""
      cs = 1; collecting = 0; word = ""; nh = 0
      for (ln = 1; ln <= nl; ln++) {
        s = lines[ln]; n = length(s); cont = 0
        for (i = 1; i <= n; i++) {
          c = substr(s, i, 1); c2 = substr(s, i, 2)
          t = top()
          if (t == "sq") { if (c == "\047") sp--; else addch(c); continue }
          # $(( ... )) arithmetic: text only, never a heredoc or a command.
          if (t == "ar") {
            if (c == "(") ad[sp]++
            else if (c == ")") {
              if (ad[sp] > 0) ad[sp]--
              else if (substr(s, i + 1, 1) == ")") { sp--; i++; continue }
            }
            addch(c); continue
          }
          if (substr(s, i, 3) == "$((") { endword(); st[++sp] = "ar"; ad[sp] = 0; i += 2; continue }
          if (t == "dq") {
            if (c == "\\") { addch(substr(s, i + 1, 1)); i++; continue }
            if (c == "\"") { sp--; continue }
            if (c2 == "$(") { push("sub"); i++; continue }
            if (c == "`") { push("bq"); continue }
            addch(c); continue
          }
          # unquoted: top, sub or bq
          if (c == "\\") { if (i < n) addch(substr(s, i + 1, 1)); else cont = 1; i++; continue }
          if (c == "\047") { st[++sp] = "sq"; collecting = 1; continue }
          if (c == "\"") { st[++sp] = "dq"; collecting = 1; continue }
          if (c == "#" && !collecting) break
          if (c2 == "$(") { push("sub"); i++; continue }
          if (c == "`") { if (t == "bq") pop(); else push("bq"); continue }
          if (c == ")") { if (t == "sub") pop(); else cmdstart(); continue }
          if (c == "(") { cmdstart(); continue }
          if (c2 == ">&" || c2 == "&>") { addch(c2); i++; continue }
          if (substr(s, i, 3) == "<<<") { addch("<<<"); i += 2; continue }
          if (c2 == "<<") {
            # A shift such as ((x<<2)) is not a heredoc: skip a digit or "(".
            if (substr(s, i + 2, 1) ~ /^[0-9(]$/) { addch("<<"); i++; continue }
            endword(); i += 2
            strip = 0
            if (substr(s, i, 1) == "-") { strip = 1; i++ }
            while (substr(s, i, 1) ~ /^[ \t]$/) i++
            d = ""
            while (i <= n && substr(s, i, 1) !~ /^[ \t;&|<>()]$/) { d = d substr(s, i, 1); i++ }
            i--
            gsub(/[\047"\\]/, "", d)
            if (d != "") { nh++; hd[nh] = d; hs[nh] = strip; hp[nh] = pl }
            continue
          }
          if (c == ";" || c == "&" || c2 == "||") {
            if (c2 == "||") i++
            if (t == "top") newpipe(); else cmdstart()
            continue
          }
          if (c == "|") { cmdstart(); continue }
          addch(c)
        }
        # End of physical line.
        if (top() == "sq" || top() == "dq") { addch("\n"); continue }
        if (cont) continue
        # Consume pending heredoc bodies. They are never parsed for command
        # words, but their text belongs to the pipeline that reads them, so an
        # interpreter fed a heredoc (sh, python3 -, cat | sh) is still checked.
        for (h = 1; h <= nh; h++) {
          while (ln < nl) {
            ln++; b = lines[ln]
            if (hs[h]) sub(/^\t+/, "", b)
            if (b == hd[h]) break
            ptext[hp[h]] = ptext[hp[h]] "\n" b
          }
        }
        nh = 0
        if (top() == "top") newpipe(); else cmdstart()
      }
      endword()
      # A gh/git stage outside the safe set makes its whole pipeline non-text.
      for (k = 1; k <= ns; k++) if (!gh_git_safe(k)) unsafe[spl[k]] = 1
      for (p = 0; p <= pl; p++) {
        nw = split(words[p], ws, " ")
        textonly = (nw > 0) && !unsafe[p]
        for (k = 1; k <= nw; k++) {
          if (ws[k] == "create_issue") print "create_issue"
          if (ws[k] !~ /^(echo|printf|cat|tee|grep|jq|head|tail|wc|uniq|tr|cut|true|false|:|test|\[|gh|git)$/) textonly = 0
        }
        # A pipeline made only of text commands (gh and git included) cannot
        # send anything, whatever its arguments or heredocs say. Any other
        # pipeline is a sender if its text, heredoc bodies included, names a
        # sender word at any position (wrappers like timeout/nice/sudo -E,
        # sh -c, xargs) or the API host.
        if (textonly) continue
        if (nw > 0) nontext = 1
        tx = ptext[p]
        if (match(tx, /[A-Za-z0-9_]*linear_graphql/)) { print "sender " substr(tx, RSTART, RLENGTH); continue }
        if (match(tx, /(^|[^A-Za-z0-9_])curl([^A-Za-z0-9_]|$)/)) { print "sender curl"; continue }
        if (match(tx, /(^|[^A-Za-z0-9_])wget([^A-Za-z0-9_]|$)/)) { print "sender wget"; continue }
        if (index(tx, "api.linear.app") > 0) print "url " first[p]
      }
      # Text written to a file (heredoc or quoted string) can be run later in
      # the same call (source, bash, ., sh, python3 ...). Without tracking
      # files: any non-text pipeline in a call whose text names the mutation
      # and a sender anywhere is treated as a send.
      # Any git stage, safe or not, is reported so the caller can apply the
      # whole-command git rule (git runs configured filters, textconv and
      # pagers that any earlier stage may have written).
      for (k = 1; k <= ns; k++) if (scmd[k] == "git") { print "gitstage"; break }
      all = ""
      for (p = 0; p <= pl; p++) all = all "\n" ptext[p]
      if (nontext && index(all, "issueCreate") > 0) {
        hs_word = ""
        if (match(all, /[A-Za-z0-9_]*linear_graphql/)) hs_word = substr(all, RSTART, RLENGTH)
        else if (match(all, /(^|[^A-Za-z0-9_])curl([^A-Za-z0-9_]|$)/)) hs_word = "curl"
        else if (match(all, /(^|[^A-Za-z0-9_])wget([^A-Za-z0-9_]|$)/)) hs_word = "wget"
        else if (index(all, "api.linear.app") > 0) hs_word = "api.linear.app"
        if (hs_word != "") print "heredoc " hs_word
      }
    }
  '
}

findings=$(printf '%s\n' "$cmd" | _scan 2>/dev/null) || exit 0

if printf '%s\n' "$findings" | grep -qx 'create_issue'; then
  deny "create_issue called as a command"
fi
if [[ "$cmd" == *issueCreate* ]]; then
  # git rule: any git stage (safe or not) plus the mutation and a sender
  # anywhere in the raw command. git runs filters, textconv and pagers from
  # config an earlier stage may have written (printf/echo/heredoc into
  # .git/config or .gitattributes). gh is exempt.
  if printf '%s\n' "$findings" | grep -qx 'gitstage'; then
    gsend=$(printf '%s\n' "$cmd" | grep -oE -m1 '[A-Za-z0-9_]*linear_graphql|api\.linear\.app|(^|[^A-Za-z0-9_])(curl|wget)([^A-Za-z0-9_]|$)' | head -n1 | tr -cd 'A-Za-z0-9_.' || true)
    [ -n "$gsend" ] && deny "issueCreate and $gsend in a call with a git stage"
  fi
  hit=$(printf '%s\n' "$findings" | grep -m1 -E '^(sender|url|heredoc) ' || true)
  case "$hit" in
  heredoc\ *) deny "issueCreate and ${hit#heredoc } in the call text, with a non-text command in the same call" ;;
  sender\ *) deny "issueCreate with network sender ${hit#sender } in a non-text pipeline" ;;
  url\ *) deny "issueCreate with api.linear.app in a pipeline run by ${hit#url }" ;;
  esac
fi

exit 0
