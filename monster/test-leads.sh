#!/usr/bin/env bash
# test-leads.sh: monday-leads, the notify hook and monster-ctl against a fake claude (LEADS_CMD) on a
# private tmux socket (LEADS_SOCKET) and a throwaway HOME. Touches no real lead, session or setting.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
T=$(mktemp -d)
export LEADS_SOCKET=leadtest$$ HOME=$T/home MONSTER_DEV=$T/dev SHELL=/bin/bash
trap 'tmux -L "$LEADS_SOCKET" kill-server 2>/dev/null; rm -rf "$T"' EXIT
export LEADS_CMD=$T/bin/claude MONSTER_CLAUDE=$T/bin/claude LEADS_ENV=$T/lead-env LEADS_VERIFY_S=1 LEADS_PROMPT_S=4
export FAKE_LOG=$T/fake.log FAKE_CRASH=$T/crash FAKE_NOHANDOFF=$T/nohandoff FAKE_AGENTS=$T/agents.json FAKE_HOOK=$here/claude-notify.sh
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$T/bin" "$T/stub" "$HOME/.config/monday" "$HOME/bin" "$MONSTER_DEV"
cp "$here/lead-tmux.conf" "$HOME/.config/monday/"; cp "$here/monday-leads" "$HOME/bin/"
echo 'export LEAD_ENV_SOURCED=yes' > "$LEADS_ENV"
# no sound, and logger writes to a file instead of the journal
for s in pw-play paplay afplay; do printf '#!/bin/sh\n' > "$T/stub/$s"; done
# sudo never reaches the real one: monster-ctl off/reboot/sleep must not power anything off here
printf '#!/bin/sh\necho "sudo $*" >> %s/sudo.log\n' "$T" > "$T/stub/sudo"
printf '#!/bin/sh\necho "$*" >> %s/logger.log\n' "$T" > "$T/stub/logger"
chmod +x "$T/stub/"*; export PATH=$T/stub:$PATH

# fake claude: logs its argv, `agents --json` prints $FAKE_AGENTS, else runs as a process named claude
# that shows a prompt and, per input line: HOOK f (hook run by this claude), NESTED f (by a nested claude -p)
cat > "$LEADS_CMD" <<'EOF'
#!/bin/bash
printf '[%s]' "$@" >> "$FAKE_LOG"; echo >> "$FAKE_LOG"
[ "${1:-}" = agents ] && { cat "$FAKE_AGENTS" 2>/dev/null || echo '[]'; exit 0; }
[ -e "$FAKE_CRASH" ] && { echo "boom: fake crash"; exit 3; }
name=; while [ $# -gt 0 ]; do [ "$1" = -n ] && name=$2; shift; done
# /agentkit:handoff: commit a hand-off in this tree, point handoff-pending (main checkout) at it, release
# the master writer when it names this session's name; unless $FAKE_NOHANDOFF exists
exec -a claude bash -c '
  echo "env=${LEAD_ENV_SOURCED:-no}"; echo "❯ "
  while read -r c f; do
    case $c in
      HOOK) bash "$FAKE_HOOK" < "$f" >/dev/null ;;
      NESTED) ( exec -a claude bash -c "bash \"\$0\" < \"\$1\" >/dev/null; true" "$FAKE_HOOK" "$f" ); true ;;
      /agentkit:handoff)
        echo "got: $c $f" >> "$FAKE_LOG"; [ -e "$FAKE_NOHANDOFF" ] && continue
        main=$(git rev-parse --path-format=absolute --git-common-dir); main=${main%/.git}
        echo "claude --model test-model (effort: high, by $0)" > HANDOFF.md
        git add HANDOFF.md && git commit -qm handoff
        echo "$PWD/HANDOFF.md $(git rev-parse --short HEAD)" > "$main/.agentkit/handoff-pending"
        [ "$(sed -n 2p "$main/.agentkit/master-writer" 2>/dev/null)" = "$0" ] && rm "$main/.agentkit/master-writer" ;;
      *) echo "got: $c $f" >> "$FAKE_LOG" ;;
    esac
  done' "$name"
EOF
chmod +x "$LEADS_CMD"

fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: [$3] not in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: [$3] found in: $2"; else ok "$1"; fi; }
L() { "$HOME/bin/monday-leads" "$@" 2>&1; }
t() { tmux -L "$LEADS_SOCKET" "$@"; }
mkrepo() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init; }
sid1=11111111-1111-1111-1111-111111111111 sid2=22222222-2222-2222-2222-222222222222
sid3=33333333-3333-3333-3333-333333333333 sidn=99999999-9999-9999-9999-999999999999
hook() { # hook <lead> <json>: run the hook in the lead's claude (HOOK) or a nested claude (NESTED)
  local f; f=$(mktemp "$T/h.XXXX"); printf '%s' "$3" > "$f"
  t send-keys -t "=leads:=$2" "$1 $f" Enter; sleep 1.5
}

mkrepo "$MONSTER_DEV/pa"; mkrepo "$MONSTER_DEV/pb"; mkrepo "$MONSTER_DEV/pc"
L add a pa $sid1 >/dev/null; L add b pb $sid2 >/dev/null; L add c pc >/dev/null
L set a order=2 >/dev/null; L set b order=1 'claude_name=last web lead' >/dev/null
is "set rejects bad order" "$(L set a order=x)" "order: integer"

echo "== up: order, -n claude_name, resume, lead-env"
out=$(L up); has "up b" "$out" "b: started"; has "up a" "$out" "a: started"
has "c has nothing to start from" "$out" "c: no session id and no hand-off"
is "b started before a" "$(grep -o 'resume\]\[[0-9]*' "$FAKE_LOG" | head -1)" "resume][22222222"
has "claude_name used" "$(cat "$FAKE_LOG")" "[-n][last web lead][--resume][$sid2]"
has "lead name as default claude_name" "$(cat "$FAKE_LOG")" "[-n][a][--resume][$sid1]"
is "one session leads, window per lead" "$(t list-windows -t =leads -F '#W' | sort | tr '\n' ' ')" "a b "
has "lead-env sourced" "$(t capture-pane -p -t =leads:=a)" "env=yes"
has "up again: already running" "$(L up a)" "a: already running"
is "remain-on-exit set" "$(t show-options -wv -t =leads:=a remain-on-exit)" "on"

echo "== up verifies: a crashing claude is FAILED, its window stays readable"
L set c session_id=$sid3 >/dev/null; touch "$FAKE_CRASH"
out=$(L up c); has "crash reported" "$out" "c: FAILED"; has "last output shown" "$out" "boom: fake crash"
has "list shows dead pane" "$(L list)" "c active manual dead"
rm "$FAKE_CRASH"; out=$(L up c); has "dead pane restarted" "$out" "c: started"

echo "== hook: lead's own claude only, status file, no prompt text"
hook HOOK a "{\"hook_event_name\":\"Notification\",\"session_id\":\"$sidn\",\"cwd\":\"/x\",\"message\":\"$(printf 'P%.0s' {1..300})\"}"
is "status file state" "$(jq -r .state "$HOME/.local/state/monday/leads/a.json")" waiting_permission
is "session id tracked" "$(jq -r .a.session_id "$HOME/.config/monday/leads.json")" "$sidn"
is "permission msg max 200" "$(tail -1 "$HOME/.local/state/monday/events.jsonl" | jq -r '.msg | length')" 200
hook NESTED a "{\"hook_event_name\":\"Stop\",\"session_id\":\"$sid3\",\"cwd\":\"/x\"}"
is "nested claude -p ignored (registry)" "$(jq -r .a.session_id "$HOME/.config/monday/leads.json")" "$sidn"
is "nested claude -p ignored (status)" "$(jq -r .state "$HOME/.local/state/monday/leads/a.json")" waiting_permission
hook HOOK a "{\"hook_event_name\":\"StopFailure\",\"session_id\":\"$sidn\",\"cwd\":\"/x\",\"error\":\"rate_limit\"}"
is "StopFailure -> failure" "$(tail -1 "$HOME/.local/state/monday/events.jsonl" | jq -r '.event + " " + .msg')" "failure rate_limit "
is "StopFailure state" "$(jq -r .state "$HOME/.local/state/monday/leads/a.json")" failed
hook HOOK b "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$sid2\",\"cwd\":\"/x\",\"reason\":\"other\"}"
is "SessionEnd -> ended" "$(tail -1 "$HOME/.local/state/monday/events.jsonl" | jq -r '.lead + " " + .event')" "b ended"
hook HOOK a "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$sidn\",\"cwd\":\"/x\",\"prompt\":\"secret words\"}"
hasnt "prompt text not logged" "$(cat "$HOME/.local/state/monday/events.jsonl")" "secret words"
is "prompt event has no msg" "$(tail -1 "$HOME/.local/state/monday/events.jsonl" | jq -c '[.event, has("msg")]')" '["prompt",false]'
hook HOOK a "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$sidn\",\"cwd\":\"/x\",\"tool_name\":\"Bash\"}"
is "PostToolUse with nothing waiting: no event" "$(tail -1 "$HOME/.local/state/monday/events.jsonl" | jq -r .event)" prompt
hook HOOK a "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$sidn\",\"cwd\":\"/x\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Q?\"}]}}"
is "question state" "$(jq -r .state "$HOME/.local/state/monday/leads/a.json")" waiting_question
hook HOOK a "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$sidn\",\"cwd\":\"/x\",\"tool_name\":\"AskUserQuestion\"}"
is "answered -> working" "$(tail -1 "$HOME/.local/state/monday/events.jsonl" | jq -r .event)/$(jq -r .state "$HOME/.local/state/monday/leads/a.json")" answered/working
hook HOOK a "{\"hook_event_name\":\"Stop\",\"session_id\":\"$sidn\",\"cwd\":\"/x\",\"background_tasks\":[{\"id\":\"x\"}]}"
is "Stop with a background shell: logged with bg, lead stays working" "$(tail -1 "$HOME/.local/state/monday/events.jsonl" | jq -r '.event + "/" + (.bg|tostring)')/$(jq -r .state "$HOME/.local/state/monday/leads/a.json")" stop/true/working

echo "== status --json"
pa=$(t display -p -t =leads:=a '#{pane_pid}')
echo "[{\"pid\":$pa,\"sessionId\":\"$sidn\",\"status\":\"idle\",\"name\":\"a\"}]" > "$FAKE_AGENTS"
js=$(L status --json)
is "a alive, working corrected to idle by claude agents" "$(jq -c '.[] | select(.lead.name=="a") | [.schema,.lead.alive,.lead.state]' <<<"$js")" '[1,true,"idle"]'
is "order in status" "$(jq -r 'map(.lead.name) | join(" ")' <<<"$js")" "b a c"
is "claude_name in status" "$(jq -r '.[0].lead.claude_name' <<<"$js")" "last web lead"

echo "== check / park"
is "check clean" "$(L check a)" "a: clean"
touch "$MONSTER_DEV/pa/dirty"; has "check: uncommitted" "$(L check a)" "1 uncommitted change"
git -C "$MONSTER_DEV/pa" worktree add -q "$T/wt" -b wt 2>/dev/null; L set a worktree="$T/wt" >/dev/null
echo "locked by pid 4999999" > "$MONSTER_DEV/pa/.git/worktrees/wt/locked"
touch -d '5 minutes ago' "$MONSTER_DEV/pa/.git/index.lock"; touch "$MONSTER_DEV/pa/.git/MERGE_HEAD"
out=$(L check a); has "check: stale index.lock" "$out" "stale"; has "check: merge" "$out" "merge in progress"
has "check: dead worktree lock pid" "$out" "dead pid 4999999"
if [ -e "$MONSTER_DEV/pa/.git/index.lock" ]; then ok "check removes nothing"; else bad "check removed index.lock"; fi
has "park without handoff refused" "$(L park a)" "handoff not written"
touch -d '3 hours ago' "$MONSTER_DEV/pa/HANDOFF.md"
has "park with old handoff refused" "$(L park a HANDOFF.md --force)" "not written in the last 2 h"
touch "$MONSTER_DEV/pa/HANDOFF.md"
has "park refused on git state" "$(L park a HANDOFF.md)" "uncommitted change"
is "still active after refusals" "$(jq -r .a.state "$HOME/.config/monday/leads.json")" active
wid=$(t display -p -t =leads:=a '#{window_id}')
has "park --force" "$(L park a HANDOFF.md --force)" "parked a"
is "window kept, pane dead" "$(t display -p -t =leads:=a '#{window_id} #{pane_dead}')" "$wid 1"
has "parked placeholder text" "$(t capture-pane -p -t =leads:=a -S -50)" "lead a parked"
has "up reports parked" "$(L up)" "a: parked since"

echo "== unpark policy"
mkdir -p "$HOME/.claude/projects/p"; touch -d '1 hour ago' "$MONSTER_DEV/pa/HANDOFF.md"
touch "$HOME/.claude/projects/p/$sidn.jsonl"   # session newer than handoff, parked < 24 h: resume
: > "$FAKE_LOG"; out=$(L unpark a); has "unpark resumes" "$out" "a: started"; has "resumed" "$out" "resumed $sidn"
is "same window after unpark" "$(t display -p -t =leads:=a '#{window_id}')" "$wid"
L park a HANDOFF.md --force >/dev/null 2>&1; touch "$MONSTER_DEV/pa/HANDOFF.md"   # recent park; handoff newer
L set a master_writer=true >/dev/null
: > "$FAKE_LOG"; out=$(L unpark a); has "handoff newer: fresh" "$out" "fresh from hand-off"
has "fresh prompt" "$(cat "$FAKE_LOG")" "and continue; first report drift before editing."
has "master_writer not claimed" "$out" "needs master_writer claim --force (owner approval)"
L park a HANDOFF.md --force >/dev/null 2>&1; touch -d '2 hours ago' "$MONSTER_DEV/pa/HANDOFF.md"
reg=$HOME/.config/monday/leads.json; jq '.a.parked_at -= 90000' "$reg" > "$reg.t" && mv "$reg.t" "$reg"
: > "$FAKE_LOG"; has "parked >= 24h: fresh" "$(L unpark a)" "fresh from hand-off"
has "unpark of active refused" "$(L unpark a)" "a is not parked"

echo "== events rotation"
ev=$HOME/.local/state/monday/events.jsonl; { head -c 6000000 /dev/zero | tr '\0' 'x'; echo; } >> "$ev"
size=$(stat -c %s "$ev")
is "behind reader: no rotation" "$(L events 0 | tail -1)" "OFFSET $size"
is "caught-up reader: rotated" "$(L events "$size")" "OFFSET 0"
is "viewers: no viewer clients" "$(L viewers)" ""
if [ -s "$ev.1" ] && [ ! -e "$ev" ]; then ok "renamed to .1"; else bad "rotation file state"; fi

echo "== agent-kit project: identity, worktrees, mode, park protocol, limit, stopall"
for x in a b c; do L park "$x" --force >/dev/null 2>&1; L rm "$x" >/dev/null; done   # free the window list
kp=$MONSTER_DEV/kp; mkrepo "$kp"; mkdir -p "$kp/.agentkit/workers" "$kp/.agentkit/autopilot" "$kp/scripts"
printf '.agentkit/\n.claude/\n' > "$kp/.gitignore"
printf 'print("Current mode: solo")\nprint("Owner: present")\n' > "$kp/scripts/working_mode.py"
git -C "$kp" add -A && git -C "$kp" commit -qm kit
git -C "$kp" worktree add -q "$kp/.claude/worktrees/w1" -b w1
sidm=44444444-4444-4444-4444-444444444444 sidw=55555555-5555-5555-5555-555555555555
printf '%s\nkm-name\n' "$sidm" > "$kp/.agentkit/master-writer"
L add km kp >/dev/null; L set km claude_name=km-name order=1 master_writer=true >/dev/null
L add kw kp >/dev/null; L set kw order=2 worktree=.claude/worktrees/w1 >/dev/null
L add kd kp >/dev/null
has "kit: registry mode refused" "$(L set km mode=autopilot)" "the kit keeps the mode"
is "kit: worktree relative to dir" "$(jq -r .kw.worktree "$HOME/.config/monday/leads.json")" "$kp/.claude/worktrees/w1"
echo "[{\"name\":\"kw\",\"cwd\":\"$kp/.claude/worktrees/w1\",\"sessionId\":\"$sidw\",\"startedAt\":2,\"kind\":\"interactive\"}]" > "$FAKE_AGENTS"
: > "$FAKE_LOG"; out=$(L up)
has "same checkout refused" "$out" "kd: REFUSED, same checkout"
has "both twins refused" "$out" "km: REFUSED, same checkout"
L rm kd >/dev/null; L up >/dev/null
has "master writer resumed from master-writer" "$(cat "$FAKE_LOG")" "[-n][km-name][--resume][$sidm]"
has "worktree lead resumed from claude agents" "$(cat "$FAKE_LOG")" "[-n][kw][--resume][$sidw]"
is "worktree lead runs in its worktree" "$(t display -p -t =leads:=kw '#{pane_current_path}')" "$kp/.claude/worktrees/w1"
hook HOOK km "{\"hook_event_name\":\"Stop\",\"session_id\":\"$sidn\",\"cwd\":\"$kp\"}"
is "kit: hook leaves session_id alone" "$(jq -r '.km.session_id // ""' "$HOME/.config/monday/leads.json")" ""
is "kit: status file still written" "$(jq -r .state "$HOME/.local/state/monday/leads/km.json")" idle
: > "$FAKE_LOG"; has "mode away" "$(L mode km away)" "sent /agentkit:mode autopilot"; sleep 1
has "mode command typed" "$(cat "$FAKE_LOG")" "got: /agentkit:mode autopilot"
has "mode takes away|present only" "$(L mode km later)" "Claude Code project leads"

echo "== kit status --json"
echo "working 2026-11-13T01:00:00 1 context_tokens=5" > "$kp/.agentkit/workers/w-new.state"
printf 'Kind: completed\nTask: x\n' > "$kp/.agentkit/workers/w-new.result.md"
echo "idle 2026-11-01T01:00:00 1" > "$kp/.agentkit/workers/w-old.state"; touch -d '3 days ago' "$kp/.agentkit/workers/w-old.state"
touch "$kp/.agentkit/autopilot/2026-11-01.md" "$kp/.agentkit/autopilot/2026-11-12.md"
mkdir -p "$HOME/.claude/projects/kp"
echo '{"message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000}}}' > "$HOME/.claude/projects/kp/$sidm.jsonl"
js=$(L status --json); km=$(jq -c '.[] | select(.lead.name=="km")' <<<"$js")
is "kit: session id from master-writer" "$(jq -r .lead.session_id <<<"$km")" "$sidm"
is "kit: mode = working_mode first line, owner" "$(jq -r '.mode + " / " + .owner' <<<"$km")" "Current mode: solo / present"
is "kit: workers (fresh only) with Kind" "$(jq -c .workers <<<"$km")" '[{"name":"w-new","state":"working","result_kind":"completed"}]'
is "kit: autopilot report" "$(jq -r .autopilot_report <<<"$km")" "$kp/.agentkit/autopilot/2026-11-12.md"
is "kit: context tokens" "$(jq -r .lead.context_tokens <<<"$km")" 3210
is "kit: schema keys" "$(jq -c 'keys' <<<"$km")" '["autopilot_report","handoff","lead","limit","mode","owner","project","schema","workers"]'

echo "== kit park / unpark"
touch "$kp/.claude/worktrees/w1/dirty"
out=$(LEADS_PARK_WAIT_S=10 L park kw); has "park asks the lead to hand off" "$(cat "$FAKE_LOG")" "got: /agentkit:handoff"
has "kit park: check failure keeps claude" "$out" "handed off but check failed"
has "kw still running" "$(L list)" "kw active kit yes"
rm "$kp/.claude/worktrees/w1/dirty"
out=$(LEADS_PARK_WAIT_S=10 L park kw); has "kit park: parked" "$out" "parked kw"
is "kit park: registry handoff = the lead's" "$(jq -r .kw.handoff "$HOME/.config/monday/leads.json")" "$kp/.claude/worktrees/w1/HANDOFF.md"
is "kit park: window kept dead" "$(t display -p -t =leads:=kw '#{pane_dead}')" 1
: > "$FAKE_LOG"; out=$(L unpark kw)
has "kit unpark: fresh from handoff-pending" "$out" "fresh from hand-off $kp/.claude/worktrees/w1/HANDOFF.md"
has "kit unpark: model and effort from the hand-off" "$(cat "$FAKE_LOG")" "[-n][kw][--model][test-model][--effort][high][Read $kp/.claude/worktrees/w1/HANDOFF.md and continue"
touch "$FAKE_NOHANDOFF"
out=$(LEADS_PARK_WAIT_S=2 L park km); has "kit park: no hand-off, not parked" "$out" "NOT parked, no hand-off"
has "kit park timeout: master writer still held" "$out" "master writer still held"
has "km untouched" "$(L list)" "km active kit yes"
rm "$FAKE_NOHANDOFF"
out=$(LEADS_PARK_WAIT_S=10 L park km); has "kit park: master writer released, parked" "$out" "parked km"
if [ ! -s "$kp/.agentkit/master-writer" ]; then ok "master-writer released by the lead"; else bad "master-writer still there"; fi
: > "$FAKE_LOG"; out=$(L unpark km)
has "kit unpark master: fresh" "$out" "fresh from hand-off $kp/HANDOFF.md"
has "kit unpark master: claim needs the owner" "$out" "needs master_writer claim --force (owner approval)"
: > "$FAKE_LOG"; has "park --force skips the protocol" "$(L park kw --force)" "parked kw"
hasnt "no hand-off asked with --force" "$(cat "$FAKE_LOG")" "/agentkit:handoff"

echo "== limit stop (Monday continues, no watchdog)"
echo "$(( $(date +%s) + 3600 )) org-1 $kp/.claude/worktrees/w1/HANDOFF.md" > "$kp/.agentkit/limit-stop"
has "limit: unpark waits for the reset" "$(L unpark kw)" "kw: limit stop until"
is "limit: status state and limit" "$(L status --json | jq -c '.[] | select(.lead.name=="kw") | [.lead.state, .limit.org]')" '["limit","org-1"]'
echo "$(( $(date +%s) - 10 )) org-1 $kp/.claude/worktrees/w1/HANDOFF.md" > "$kp/.agentkit/limit-stop"
: > "$FAKE_LOG"; out=$(L up kw)
has "limit: after the reset up continues from its hand-off" "$out" "fresh from hand-off $kp/.claude/worktrees/w1/HANDOFF.md"
if [ ! -e "$kp/.agentkit/limit-stop" ]; then ok "limit-stop removed after continuing"; else bad "limit-stop left"; fi

echo "== stopall"
: > "$FAKE_LOG"; out=$(L stopall); has "stopall Escape" "$out" "km: Escape, /agentkit:mode present"
has "stopall second lead: Escape only" "$out" "kw: Escape"; sleep 1
is "kit mode set once per project" "$(grep -c '/agentkit:mode present' "$FAKE_LOG")" 1
has "stopall kills nothing" "$(L list)" "kw active kit yes"

echo "== monster-ctl"
C() { "$here/monster-ctl" "$@" 2>&1; }
has "answer digit" "$(C answer kw 2)" sent
has "answer rejects text" "$(C answer kw yes)" usage
has "answer rejects two keys" "$(C answer kw 1 2)" usage
C key kw Enter >/dev/null   # submit the answered digit, so the next line starts empty
has "key rejects -flags" "$(C key kw -t x Enter)" "bad key: -t"
has "send refuses !" "$(printf '  !rm -rf x' | C send kw)" refused
: > "$FAKE_LOG"; has "send pastes" "$(printf 'hello world' | C send kw)" sent; sleep 1
has "pasted text arrived" "$(cat "$FAKE_LOG")" "got: hello world"
has "send --allow-bang" "$(printf '!ls' | C send kw --allow-bang)" sent
has "read a lead" "$(C read kw 5)" "❯"
has "no such target" "$(C read nope)" "no lead or session: nope"
is "--ssh loop refused" "$(SSH_ORIGINAL_COMMAND=--ssh timeout 5 "$here/monster-ctl" --ssh 2>&1 | tr '\n' ' '; echo "${PIPESTATUS[0]}")" "bad command 2"
has "--ssh runs the command" "$(SSH_ORIGINAL_COMMAND='lead list' "$here/monster-ctl" --ssh)" "kw active"
has "lead --json allowed" "$(C lead status --json)" '"name": "kw"'
has "start helper session" "$(C start helper pc)" "started helper"
has "start refuses leads" "$(C start leads pc)" "lead session"
has "stop lead keeps window" "$(C stop kw)" "stopped kw"; sleep 0.5
is "lead window kept" "$(t display -p -t =leads:=kw '#{pane_dead}')" 1
has "stop helper session" "$(C stop helper)" "stopped helper"
logs=$(cat "$T/logger.log"); has "invocations logged" "$logs" "send kw"; hasnt "sent text not logged" "$logs" "hello"

echo "== viewers (grouped sessions)"
# a pty, as a terminal gives; stdin stays open (at EOF script would type ^D into the lead)
script -qc "$here/mon km" /dev/null < <(sleep 20) >/dev/null 2>&1 & mp=$!; sleep 1.5
v=$(t ls -F '#S' | grep '^view-' | head -1)
if [ -n "$v" ]; then ok "mon made a viewer session"; else bad "no viewer session"; fi
is "viewer grouped with leads, on its own window" "$(t display -p -t "=$v:" '#{session_group} #W')" "leads km"
is "viewer goes away on detach" "$(t show-options -v -t "$v" destroy-unattached)" on
t select-window -t "=leads:=kw"
is "leads keeps its own window" "$(t display -p -t '=leads:' '#W')" "kw"
hook HOOK km "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$sidm\",\"cwd\":\"$kp\"}"
is "hook with a viewer present: still the lead" "$(tail -1 "$HOME/.local/state/monday/events.jsonl" | jq -r .lead)" km
hasnt "ls hides viewers" "$("$here/monster-ctl" ls)" "view-"
kill "$mp" 2>/dev/null; wait "$mp" 2>/dev/null; sleep 0.5
is "viewer leaves the lead running" "$(t display -p -t =leads:=km '#{pane_dead}')" 0
is "viewer gone after its client" "$(t ls -F '#S' | grep -c '^view-')" 0

echo "== power guard"
[ "$(command -v sudo)" = "$T/stub/sudo" ] || { echo "sudo stub not first in PATH: stopping before power tests"; exit 1; }
echo '[]' > "$FAKE_AGENTS"
is "power-check: nothing running" "$(L power-check)" "nothing running"
echo 'not json' > "$FAKE_AGENTS"
out=$(L power-check; echo "exit $?"); has "power: claude agents failing blocks (fail closed)" "$out" "cannot list claude sessions"
has "power: fail closed exit 1" "$out" "exit 1"
echo "[{\"kind\":\"background\",\"state\":\"working\",\"name\":\"bgw\",\"cwd\":\"/x\"},{\"kind\":\"interactive\",\"pid\":$$,\"status\":\"idle\",\"name\":\"me\",\"cwd\":\"/y\"},{\"kind\":\"background\",\"state\":\"done\",\"name\":\"old\"}]" > "$FAKE_AGENTS"
out=$(L power-check); has "power: working background worker blocks" "$out" "BLOCKS: claude background session bgw"
has "power: idle session listed, not blocking" "$out" "session me in /y: idle, will be resumable"
hasnt "power: done session ignored" "$out" "session old"
echo "[{\"kind\":\"interactive\",\"pid\":$$,\"status\":\"idle\",\"name\":\"me\",\"cwd\":\"/y\"}]" > "$FAKE_AGENTS"
L power-check >/dev/null; is "power: only idle sessions -> allowed" "$?" 0
hook HOOK km "{\"hook_event_name\":\"Notification\",\"session_id\":\"$sidm\",\"cwd\":\"$kp\",\"message\":\"may I\"}"
has "power: a lead waiting on permission blocks" "$(L power-check)" "BLOCKS: lead km waits on a permission"
hook HOOK km "{\"hook_event_name\":\"Stop\",\"session_id\":\"$sidm\",\"cwd\":\"$kp\"}"
echo '[]' > "$FAKE_AGENTS"
flock "$kp/.agentkit/mode.lock" sleep 30 & fl=$!; sleep 0.5
has "power: held kit lock" "$(L power-check)" "mode.lock held by live pid"
kill "$fl"; wait "$fl" 2>/dev/null
echo $$ > "$kp/.agentkit/workers/w-new.live"
has "power: live worker pid" "$(L power-check)" "worker w-new"
hook HOOK km "{\"hook_event_name\":\"Stop\",\"session_id\":\"$sidm\",\"cwd\":\"$kp\"}"
has "hook: stop while a kit worker runs is not a wait (bg)" "$(tail -n 1 "$HOME/.local/state/monday/events.jsonl")" '"bg":true'
out=$("$here/monster-ctl" off 2>&1; echo "exit $?"); has "off refused" "$out" "refused: off would cut"; has "off refused exit 1" "$out" "exit 1"
has "sleep refused" "$("$here/monster-ctl" sleep 2>&1)" "refused: sleep"
if [ ! -e "$T/sudo.log" ]; then ok "nothing powered"; else bad "sudo was called: $(cat "$T/sudo.log")"; fi
"$here/monster-ctl" sleep --force >/dev/null 2>&1; "$here/monster-ctl" off --force >/dev/null 2>&1
is "--force powers (stub)" "$(tr '\n' ' ' < "$T/sudo.log")" "sudo -n /usr/bin/systemctl suspend sudo -n /usr/bin/systemctl poweroff "
rm "$kp/.agentkit/workers/w-new.live" "$T/sudo.log"
echo "[{\"kind\":\"interactive\",\"pid\":$$,\"status\":\"idle\",\"name\":\"me\",\"cwd\":\"/y\"}]" > "$FAKE_AGENTS"
has "idle only: sleep allowed, idle listed" "$("$here/monster-ctl" sleep 2>&1)" "idle, will be resumable"
is "idle only: sleep reached systemctl" "$(cat "$T/sudo.log")" "sudo -n /usr/bin/systemctl suspend"

exit $fail
