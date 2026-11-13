#!/usr/bin/env bash
# install-user.sh: the user-space half of the workstation (no root). Run as the owner, idempotent:
#   bash workstation/install-user.sh
# monday-leads -> ~/bin, the Claude Code notify hook -> ~/.claude/notify.sh (an existing different copy is
# kept as notify.sh.bak-<time>), lead tmux config and env, the monday-leads user unit (not enabled), and
# the hook's entries in ~/.claude/settings.json (created when missing; other hooks untouched);
# CCGram unless WORKSTATION_CCGRAM=no (pinned uv tool, its Claude hooks after a settings.json backup, the
# ccgram user unit, enabled once its config exists).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
# systemctl --user needs the user bus; runuser/sudo -u do not set this
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
# Personal values come from the repo's git-ignored local.env (see local.env.example) and are copied
# to ~/.config/monday/workstation.env, which workstation-ctl, monday-leads, lead-claude, lead-env,
# lead-attach, idle-off and the notify hook read at run time. A key missing from local.env keeps its
# line in workstation.env.
# shellcheck disable=SC1091
[ -f "$here/../local.env" ] && . "$here/../local.env"
menv=$HOME/.config/monday/workstation.env
install -d -m 700 "$HOME/.config/monday"
touch "$menv"; chmod 600 "$menv"
setkv() {  # setkv KEY VALUE [empty-ok]: replace or append KEY=VALUE in workstation.env (empty VALUE: leave it alone, unless empty-ok)
  [ -n "$2" ] || [ -n "${3:-}" ] || return 0
  grep -v "^$1=" "$menv" > "$menv.tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$menv.tmp" && mv "$menv.tmp" "$menv"
}
setkv WORKSTATION_DEV "${WORKSTATION_PROJECTS:+$HOME/$WORKSTATION_PROJECTS}"
setkv LEADS_KIT_DIR "${LEADS_KIT_DIR:-}"
setkv LEADS_KIT_CMD "${LEADS_KIT_CMD:-}"
setkv NOTIFY_LANG "${NOTIFY_LANG:-}"
setkv LEADS_SOCKET "${LEADS_SOCKET:-}"
# an empty pin in local.env removes an older one (no pin)
[ -z "${LEAD_CLAUDE_VERSION+x}" ] || setkv LEAD_CLAUDE_VERSION "$LEAD_CLAUDE_VERSION" empty-ok
dev=$(sed -n 's/^WORKSTATION_DEV=//p' "$menv"); dev=${dev:-$HOME/projects}
sock=$(sed -n 's/^LEADS_SOCKET=//p' "$menv" | tail -n 1); sock=${sock//[^A-Za-z0-9_.-]/}; sock=${sock:-leads}
install -D -m 755 "$here/monday-leads" "$HOME/bin/monday-leads"
install -D -m 755 "$here/lead-claude" "$HOME/bin/lead-claude"
n=$HOME/.claude/notify.sh
if [ -f "$n" ] && ! cmp -s "$here/claude-notify.sh" "$n"; then cp -p "$n" "$n.bak-$(date +%Y%m%d-%H%M%S)"; fi
install -D -m 755 "$here/claude-notify.sh" "$n"
install -D -m 644 "$here/lead-tmux.conf" "$HOME/.config/monday/lead-tmux.conf"
install -D -m 644 "$here/lead-env" "$HOME/.config/monday/lead-env"
install -D -m 644 "$here/monday-leads.service" "$HOME/.config/systemd/user/monday-leads.service"
systemctl --user daemon-reload 2>/dev/null || true
# Register the notify hook for every event it handles, once each (an entry with the same command is
# left alone; other hooks untouched): Notification (permission prompts), PreToolUse of AskUserQuestion
# (questions), Stop, StopFailure, SessionEnd, UserPromptSubmit, PostToolUse (the answer to a question
# or permission prompt).
s=$HOME/.claude/settings.json hook="bash $HOME/.claude/notify.sh"
install -d -m 700 "$HOME/.claude"
[ -s "$s" ] || echo '{}' > "$s"
cp -p "$s" "$s.bak-monday"
jq --arg c "$hook" '
  reduce (["Notification", "permission_prompt"], ["PreToolUse", "AskUserQuestion"], ["Stop", ""],
          ["StopFailure", ""], ["SessionEnd", ""], ["UserPromptSubmit", ""], ["PostToolUse", ""]) as [$e, $m] (.;
    if any(.hooks[$e][]?.hooks[]?; .command == $c) then .
    else .hooks[$e] += [(if $m == "" then {} else {matcher: $m} end) + {hooks: [{type: "command", command: $c}]}] end)' \
  "$s" > "$s.tmp" && jq empty "$s.tmp" && mv "$s.tmp" "$s"

if [ "${WORKSTATION_CCGRAM:-yes}" = no ]; then
  echo "ccgram: skipped (WORKSTATION_CCGRAM=no)"; echo "WORKSTATION-USER-OK"; exit 0
fi
# CCGram (Telegram topic per lead window), pinned. Its config is ~/.config/monday/ccgram.env (mode 600,
# TELEGRAM_BOT_TOKEN written by the owner); its hook reads TMUX_SESSION_NAME from ~/.ccgram/.env: a link to it.
ccgram_version=4.22.0
[ "$("$HOME/.local/bin/ccgram" --version 2>/dev/null)" = "ccgram, version $ccgram_version" ] \
  || uv tool install --force "ccgram==$ccgram_version"
# local patches (one button per menu option, prompts ahead of the delivery queue); fails on a new ccgram
# (a copy carrying an older version of a patch matches neither way: reinstall it clean once)
patched=$("$here/ccgram-patches/apply.sh") || {
  echo "ccgram: patches do not apply to the installed copy, reinstalling ccgram $ccgram_version clean"
  uv tool install --force --reinstall "ccgram==$ccgram_version"
  patched=$("$here/ccgram-patches/apply.sh")
}
echo "$patched"
# the non-secret settings, added when missing (lead windows never closed by a timer; Telegram launches only
# claude, through lead-claude: projects root only, no skip-permissions, registered as a lead)
env=$HOME/.config/monday/ccgram.env
if [ -f "$env" ]; then
  [ -z "$(tail -c1 "$env")" ] || echo >> "$env"
  for kv in ${TELEGRAM_USER_ID:+"ALLOWED_USERS=$TELEGRAM_USER_ID"} TMUX_SESSION_NAME=leads CCGRAM_AUTODELETE_DEAD_TOPICS=false \
      CCGRAM_DEFAULT_MODE=normal "CCGRAM_PROJECTS_ROOTS=$dev" UNBOUND_WINDOW_TTL_MINUTES=0 \
      CCGRAM_PROVIDERS_ENABLED=claude "CCGRAM_CLAUDE_COMMAND=$HOME/bin/lead-claude"; do
    grep -q "^${kv%%=*}=" "$env" || echo "$kv" >> "$env"
  done
  grep -q '^ALLOWED_USERS=' "$env" || echo "ccgram: set ALLOWED_USERS (your Telegram user id) in $env or TELEGRAM_USER_ID in local.env"
fi
install -d -m 700 "$HOME/.ccgram"
ln -sfn "$HOME/.config/monday/ccgram.env" "$HOME/.ccgram/.env"
# the unit with this install's lead tmux server (LEADS_SOCKET)
unit=$HOME/.config/systemd/user/ccgram.service
sed "s|/tmux-%U/leads,|/tmux-%U/$sock,|; s|tmux -L leads |tmux -L $sock |g" "$here/ccgram.service" > "$unit.tmp"
if cmp -s "$unit.tmp" "$unit"; then rm -f "$unit.tmp"; else install -d "${unit%/*}"; mv "$unit.tmp" "$unit"; chmod 644 "$unit"; patched+=" patched: unit"; fi   # restart below
cp -p "$s" "$s.bak-ccgram" && "$HOME/.local/bin/ccgram" hook --install && jq empty "$s"
systemctl --user daemon-reload 2>/dev/null || true
if [ ! -f "$HOME/.config/monday/ccgram.env" ]; then
  echo "ccgram: no ~/.config/monday/ccgram.env yet, service not enabled"
elif systemctl --user enable --now ccgram.service; then
  case $patched in *patched:*) systemctl --user restart ccgram.service ;; esac
else
  echo "ccgram: could not reach the user's systemd (no session or linger?); run later: systemctl --user enable --now ccgram.service"
fi
echo "WORKSTATION-USER-OK"
