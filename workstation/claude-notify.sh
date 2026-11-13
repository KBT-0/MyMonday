#!/usr/bin/env bash
# Claude Code hook: notify only when Claude is really waiting on you.
# shellcheck disable=SC1003  # the \\ in printf formats end the OSC sequences (ST), not a quote escape
# Claude Code writes the returned terminalSequence to the terminal itself (no /dev/tty needed).
input=$(cat)
# personal values (WORKSTATION_DEV, LEADS_KIT_*, LEADS_SOCKET): ~/.config/monday/workstation.env, written
# by install-user.sh from the repo's local.env; variables already in the environment win.
wenv=$HOME/.config/monday/workstation.env
while IFS='=' read -r k v; do [ -n "${!k+x}" ] || export "$k=$v"; done \
  < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$wenv" 2>/dev/null)
q() { jq -r "$1 // empty" <<<"$input"; }
# popup texts: NOTIFY_LANG in workstation.env (from local.env): en (default) | tr
case ${NOTIFY_LANG:-en} in
  tr) t_fail="Hata ile durdu" t_stop="Cevabını bekliyor" t_question="Soru soruyor" t_perm="İzin bekliyor" ;;
  *)  t_fail="Stopped with an error" t_stop="Waiting for your reply" t_question="Asking a question" t_perm="Waiting for permission" ;;
esac
# a live background worker of the agent kit in this project (cwd or its main checkout): the lead's turn
# ended but the work goes on, so the lead is not waiting on the owner
kit_busy() {
  local d k f pid main; d=$(q .cwd); [ -d "$d" ] || return 1
  main=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); main=${main%/.git}
  for k in "$d/${LEADS_KIT_DIR:-.agentkit}" ${main:+"$main/${LEADS_KIT_DIR:-.agentkit}"}; do
    for f in "$k"/workers/*.live; do
      [ -f "$f" ] || continue
      pid=$(tr -cd '0-9' < "$f"); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    done
  done
  return 1
}

# No terminal you look at (daemon-spawned bg/worker/teammate sessions have a pty but no
# terminal emulator around it): no popup could reach you, so stay silent, no sound either.
[ -n "$KITTY_WINDOW_ID$TERM_PROGRAM$WT_SESSION$TMUX" ] || exit 0

event=$(q .hook_event_name)
id=$(q .session_id | tr -cd 'a-zA-Z0-9-')
emit() { jq -nc --arg seq "$1" '{terminalSequence: $seq}'; }

# A lead: a window of session `leads` in `tmux -L leads` (see MyMonday workstation/monday-leads). Log the
# event for Monday, write ~/.local/state/monday/leads/<lead>.json {state, ts, session_id} and keep the
# lead's session_id in leads.json current, except in an agent-kit project (DIR/$LEADS_KIT_DIR: its master-writer is the truth).
# Never fails the hook.
argv0() { local a; a=$(tr '\0' '\n' < "/proc/$1/cmdline" | head -n1); echo "${a##*/}"; }
ppid_of() { local s; s=$(<"/proc/$1/stat"); s=${s##*) }; s=${s#* }; echo "${s%% *}"; }
lead_log() {
  local sock=${LEADS_SOCKET:-leads} sess lead pp p st=$HOME/.local/state/monday reg=$HOME/.config/monday/leads.json
  case "$TMUX" in */"$sock",*) ;; *) return 0 ;; esac
  # the group name: a viewer session (lead-attach, mac-leads: view-*) grouped with `leads` shares its windows
  read -r sess lead pp < <(tmux -L "$sock" display -p -t "$TMUX_PANE" '#{?session_grouped,#{session_group},#S} #W #{pane_pid}') || return 0
  [ "$sess" = leads ] && [[ "$lead" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || return 0
  # only the lead's own claude: the pane process (monday-leads execs it), or the child of a shell pane;
  # never a nested `claude -p` it runs (a Bash tool shell may exec it: then it is the lead's direct child)
  p=$PPID; while [ "$p" -gt 1 ] && [ "$(argv0 "$p")" != claude ]; do p=$(ppid_of "$p"); done
  [ "$p" = "$pp" ] || { [ "$(ppid_of "$p")" = "$pp" ] && [ "$(argv0 "$pp")" != claude ]; } || return 0
  mkdir -p "$st/leads"
  ( flock -w 2 9 || exit 0  # same lock as `monday-leads events` rotation
    jq -c --arg lead "$lead" --arg ev "$1" --arg msg "${2:0:200}" --arg bg "$quiet" \
      '{ts: (now|floor), lead: $lead, event: $ev, session_id, cwd} + (if $msg == "" then {} else {msg: $msg} end) + (if $bg == "" then {} else {bg: true} end)' \
      <<<"$input" >> "$st/events.jsonl"
  ) 9>>"$st/events.jsonl.lock"
  jq -c --arg s "$3" '{state: $s, ts: (now|floor), session_id}' <<<"$input" > "$st/leads/$lead.json.$$" \
    && mv "$st/leads/$lead.json.$$" "$st/leads/$lead.json"
  [ -n "$id" ] && [ -f "$reg" ] || return 0
  [ ! -d "$(jq -r --arg l "$lead" '.[$l].dir // "/nonexistent"' "$reg")/${LEADS_KIT_DIR:-.agentkit}" ] || return 0
  ( # same lock as monday-leads: two leads stopping at once must not lose an update
    flock -w 2 9 || exit 0
    jq -e --arg l "$lead" --arg id "$id" 'has($l) and .[$l].session_id != $id' "$reg" >/dev/null \
      && jq --arg l "$lead" --arg id "$id" '.[$l].session_id = $id | .[$l].updated = (now|floor)' "$reg" > "$reg.$$.tmp" \
      && mv "$reg.$$.tmp" "$reg"
    rm -f "$reg.$$.tmp"
  ) 9>>"$reg.lock"
}

# Set while a question or permission prompt waits; answering one fires no UserPromptSubmit, only PostToolUse.
waiting=${TMPDIR:-/tmp}/claude-waiting-$id quiet=
# PostToolUse runs after every tool call: only the first one after a wait counts (the answer, or the permitted tool).
if [ "$event" = PostToolUse ]; then rm "$waiting" 2>/dev/null || exit 0; fi

# Kitty: close this session's notification once you answer.
if [ "$event" = UserPromptSubmit ] || [ "$event" = PostToolUse ]; then
  if [ "$event" = PostToolUse ]; then lead_log answered "" working 2>/dev/null
  else rm -f "$waiting"; lead_log prompt "" working 2>/dev/null; fi  # never the prompt text
  [ -n "$KITTY_WINDOW_ID" ] && emit "$(printf '\033]99;i=%s:p=close;\033\\' "$id")"
  exit 0
fi

case "$event" in
  SessionEnd) lead_log ended "$(q .reason)" ended 2>/dev/null; exit 0 ;;
  # StopFailure: the turn ended on an API error (error: rate_limit, overloaded, ...). This Claude Code has
  # no Notification for a quota auto-resume; a rate_limit failure here is that signal.
  StopFailure) ev=failure st=failed; what=$t_fail; body="$(q .error) $(q .error_details)" ;;
  Stop) rm -f "$waiting"; ev=stop st=idle; what=$t_stop; body=$(q .last_assistant_message)
    # Any background task or scheduled wakeup will resume the turn, and so will a running kit worker: no
    # sound or popup; the stop is logged with bg:true and the lead status stays working (it is not
    # waiting on the owner).
    # shortcut: a never-ending task (dev server, /loop) also silences this for its session; questions and permission prompts still notify.
    { [ "$(jq '(.background_tasks // []) + (.session_crons // []) | length' <<<"$input")" = 0 ] && ! kit_busy; } \
      || { quiet=1; st=working; } ;;
  # A question is also a "permission prompt" to Claude Code (6 s later): remember it, skip that echo.
  PreToolUse) ev=question st=waiting_question; touch "${TMPDIR:-/tmp}/claude-question-$id" "$waiting"; what=$t_question; body=$(q '.tool_input.questions[0].question') ;;
  *) [ -n "$(find "${TMPDIR:-/tmp}/claude-question-$id" -newermt '-15 seconds' 2>/dev/null)" ] && exit 0
     touch "$waiting"; ev=permission st=waiting_permission; what=$t_perm; body=$(q .message) ;;
esac

title="Claude · $(basename "$(q .cwd)") — $what"
body=$(printf '%s' "$body" | tr '\n\t' '  ' | tr -d '\000-\037')
lead_log "$ev" "${body:0:200}" "$st" 2>/dev/null; body=${body:0:140}
[ -z "$quiet" ] || exit 0

if [ -n "$KITTY_WINDOW_ID" ]; then
  # o=unfocused: kitty drops the popup when you are looking at this window (any tab, any workspace).
  # s=: kitty plays the sound itself, only when it really shows the popup (libcanberra looks the
  # name up in ~/.local/share/sounds/freedesktop/stereo/claude-notify.wav). Same id replaces the
  # session's previous notification. f/n: shown as "Claude" with the Claude icon; n is a file path.
  # No a=focus: it yanked you to the terminal from another workspace.
  # Never inline the icon data (p=icon): Claude Code silently drops a terminalSequence that large.
  b64() { base64 | tr -d '\n'; }
  seq=$(printf '\033]99;i=%s:d=0:o=unfocused:s=%s:f=%s:n=%s;%s\033\\\033]99;i=%s:d=0:p=body;%s\033\\' \
    "$id" "$(printf claude-notify | b64)" "$(printf Claude | b64)" "$(printf %s "$HOME/.claude/notify-icon.png" | b64)" "$title" "$id" "$body")
  seq+=$(printf '\033]99;i=%s:d=1;\033\\' "$id")
  emit "$seq$(printf '\a')"
  exit 0
elif [ "$TERM_PROGRAM" = ghostty ] || [ "$TERM_PROGRAM" = WarpTerminal ]; then
  seq=$(printf '\033]777;notify;%s;%s\007' "${title//;/,}" "${body//;/,}")
else
  # Windows Terminal, WezTerm, iTerm2
  seq=$(printf '\033]9;%s: %s\007' "$title" "$body")
fi
# Bare BEL marks the tab (Windows Terminal tab bell icon).
emit "$seq$(printf '\a')"

sound="$HOME/.claude/notify.wav"
for p in pw-play paplay afplay; do
  command -v "$p" >/dev/null && { (nohup "$p" "$sound" >/dev/null 2>&1 &); break; }
done
exit 0
