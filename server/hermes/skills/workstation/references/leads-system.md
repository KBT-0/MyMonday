# Leads system on the workstation (depth)

Code: MyMonday repo, `workstation/` (`monday-leads`, `claude-notify.sh`, `lead-env`, `lead-tmux.conf`,
`lead-attach`, `lead-claude`, `ccgram.service`, `idle-off`, `install-user.sh`). Changes to
`/usr/local/bin/workstation-ctl` and `/usr/local/sbin/workstation-idle-off` need the owner's sudo
(`install-root.sh`); everything else installs as the owner with `bash workstation/install-user.sh`.
Personal values on the workstation: `~/.config/monday/workstation.env` (WORKSTATION_DEV, LEADS_KIT_DIR/CMD, LEADS_SOCKET).

## Layout
- tmux server `-L leads` (name: LEADS_SOCKET), session `leads`, one window per lead (window name = registry key).
  `__main__` window runs the CCGram service shell. Viewers (`lead-attach NAME`, mac-leads) open grouped
  `view-*` sessions so each screen/device shows its own lead; status and CCGram ignore them.
- Registry `~/.config/monday/leads.json`: key -> dir, worktree, claude_name, order, master_writer,
  state. `up` starts in `order`, verifies the pane still runs claude after ~8 s, keeps dead panes
  (remain-on-exit) so CCGram topics survive. Two leads on one checkout without distinct worktrees
  are refused.
- `lead-env`: PATH (fnm node, ~/.local/bin, ~/bin), SSH agent discovery, `DISABLE_AUTOUPDATER=1`,
  `LEAD_CLAUDE` pinned version path (bump after a manual `claude update`).

## Commands (`ssh workstation lead ...`)
| Command | Does |
|---|---|
| `list` | leads in `order`: name, state, mode, running (yes/no/dead), last state + age |
| `status --json` | per lead `{schema:1, project, lead:{name, claude_name, session_id, alive, state: working\|idle\|waiting_permission\|waiting_question\|limit\|parked\|dead, since, context_tokens}, mode, owner, handoff, limit:{resets_at, org, handoff}, workers:[...], autopilot_report}` |
| `up [NAME]` | start active leads one by one in `order`, each verified (FAILED + last output if claude died); lists parked ones |
| `unpark NAME\|all` | make parked leads active and start them (resume, or fresh from the hand-off) |
| `park NAME\|all [HANDOFF] [--force]` | kit lead: hand-off protocol (below), then end claude; non-kit: needs a recent HANDOFF and a clean `check`. `--force` only on the owner's OK |
| `check NAME` | git state of the lead folder/worktree: uncommitted, merge/rebase, stale locks |
| `mode NAME away\|present` | kit: types `<kit-cmd>:mode autopilot\|present` into the lead |
| `stopall` | emergency brake: Escape to every lead, kit mode back to present; kills nothing |
| `power-check` | exit 1 + `BLOCKS:` lines when something would be cut by off/reboot/sleep |
| `events OFFSET` | new events after byte OFFSET; last line `OFFSET <n>` (`OFFSET 0` after a rotation) |
| `viewers` | one line per client of a lead/viewer session: session, last key, created, terminal, client IP |
| `ccgram status\|restart` | the CCGram unit and the windows it sees |
| `add NAME DIR [SID]`, `rm NAME`, `set NAME k=v...` | registry edits |

## Agent-kit projects (`<project>/$LEADS_KIT_DIR/`, read-only for you)
Some projects run a coordination kit (a Claude Code plugin that keeps lead state in files). monday-leads
reads it; nothing is copied. Its folder and slash-command namespace come from workstation.env.
| Question | Source |
|---|---|
| who is lead / session id | `master-writer` (line 1 session id, line 2 SendMessage name) + `claude agents --json --all` |
| owner mode | the kit's working-mode script, first line |
| parked | `handoff-pending` present + master-writer empty |
| usage limit | `limit-stop` (RESETS_AT ORG HANDOFF) |
| workers | `workers/*.state`, result file `Kind:` |
| night report | `autopilot/YYYY-MM-DD.md` (forward it, do not rewrite) |

- Park: `lead park` sends `<kit-cmd>:handoff`, waits (<=20 min) for a fresh handoff-pending and an
  empty master-writer, runs `check` (uncommitted work, MERGING/rebase, dead-pid locks), then ends
  claude. Unpark: handoff-pending -> fresh claude with its first-line model/effort; else `--resume`.
- A project with several leads: the main lead is master writer in the main checkout; the others work in
  `.claude/worktrees/lead-<task>`; wake the master writer first.
- Usage limit: the kit's own limit watchdog is NOT installed (it would start leads outside tmux). You
  wait for RESETS_AT, then `lead up NAME`.

## Power guard
off/reboot/sleep/idle-off refuse while a session or background worker is busy or waiting, or a kit
lock has a live pid; idle sessions are listed as resumable and do not block. Claude transcripts are
saved continuously, so idle sessions resume by id after a cold boot.

## Cold start (also the rehearsal before relying on it)
1. Ask leads (or the owner does) to stop at a clean point and leave a hand-off + new-session prompt.
2. `lead power-check`; wait for BLOCKS to clear (background loop, 2 clean polls) unless the owner says close.
3. Pin identities: `claude agents --json --all` (name, pid, sessionId) and `lead set NAME session_id=...`
   for every lead; ids change after `/clear` or a restart, and the registry goes stale silently.
4. Copy each lead's last prompt to `~/.local/state/monday/handoffs/<date>/<lead>.prompt.txt`
   (extract from `~/.claude/projects/*/<id>.jsonl`); /tmp does not survive the reboot.
5. `off` (the owner's OK for `--force`), wait ~1 min, `workstation-wake`, poll `status` (~30 s to boot;
   ccgram.service recreates `leads` via linger).
6. Check that Claude works BEFORE `lead up`: a NEW helper session answers `Reply with just: ok`.
7. `lead up` (master writer first). It starts a lead fresh from handoff-pending when one exists,
   otherwise resumes by id. Then for the rest: `send /clear`, wait, paste the prompt. Rewrite relative
   paths in a prompt written from the main checkout when the lead now runs in its worktree.
8. `lead status --json` (all alive, states), read each window, report who waits for the owner.
9. Git key: after any boot the ssh-agent is empty; if the owner's git key has a passphrase, leads cannot
   fetch/push until they load it. Tell them right after the wake. They run `ssh-add` in a PLAIN ssh
   shell to the workstation (with `SSH_AUTH_SOCK` pointing at the systemd user agent socket), not via `!` in a
   lead (no tty for the passphrase) and not in a new window of `leads` (CCGram turns every new window
   there into a Telegram topic).

## Mac side (mode 2)
- `~/bin/mac-ctl` on the Mac is the forced command of your Mac key, so you cannot update it (by design:
  a self-update verb would let a compromised server push code to the Mac). To ship a new version: put
  the new file in a temp dir, serve it with `timeout 3600 python3 -m http.server 8799 --bind <server
  tailnet IP>` (background), have the owner run `curl -fsS http://<server tailnet IP>:8799/mac-ctl -o
  ~/bin/mac-ctl && ~/bin/mac-ctl check`, then kill the server. Restart it if it timed out
  (`curl -o /dev/null -w '%{http_code}'` first).
- Windows open `mosh <user>@<workstation tailnet IP> -- lead-attach <lead>`; use the IP, not a host name the Mac
  may not resolve or have a host key for.
- Commands handed to iTerm/Terminal via osascript run without the login PATH: absolute paths
  (`$(command -v mosh) --client=$(command -v mosh-client)`), or the window opens and closes instantly
  while osascript still reports success. Ask the owner whether a window actually appeared.
- First osascript call from sshd triggers a macOS Automation prompt; the owner clicks Allow once.
- Layout save/restore: `save` reads every iTerm2 window/tab/pane (bounds, columns, rows, pane title)
  into `~/.config/monday-mac/layout.tsv`; the lead is the part of the pane title after the last `:`
  (`[mosh] view-…:web`); column 11 marks full-screen windows (origin 0,0 or panes spanning >=180
  columns). Restore skips panes whose name is not a registered lead. Rules learned building it:
  - In iTerm2's AppleScript `tab` is the tab class, not a tab character: build separators with
    `ASCII character 9` / `ASCII character 10`, or every row comes back unparseable.
  - Native macOS full screen in a (dynamic) profile is `"Window Type":4`; open such windows with
    `create window with profile "<name>"` and sleep ~1.5-2 s before splitting.
  - Target the created window by id (`tell window id N`), never "current window": focus stays on the
    owner's own window. iTerm's automatic default window (opened on launch) is closed afterwards.
  - Recreate split order by splitting `last session of current tab`, not `current session`.
  - Capture osascript stderr to a file and print it; `>/dev/null` hid failures.
  - `mac-ctl check` only reports the profile file; `restore` is what writes it.
- Copying: tmux `mouse on` captures selections. iTerm2: allow OSC 52 clipboard (Settings > General >
  Selection), Option-drag bypasses tmux; lead-tmux.conf has `set-clipboard on`. Terminal.app has no
  OSC 52: there ⌘R toggles mouse reporting.

## Notifications
- Hook (`~/.claude/notify.sh`) appends events (`permission|question|stop|failure|ended|prompt|answered`,
  epoch `ts`) to `~/.local/state/monday/events.jsonl` for claude running in a lead window; prompt text is
  never logged.
- Server cron `OPS_DIR/lead_watch.py` (every minute): registered leads only, drops events older than 30
  min, a later `prompt`/`answered` cancels a pending wait, saves state per message, no screen dumps, one
  alert after 3 non-255 ssh failures. `state/lead_watch.mode`: keep `full` (with CCGram's group muted,
  your pings are the owner's only alerts; `escalation` let leads sit unnoticed). Reminds when a lead
  waits on a question/permission >15 min, then every 30 min. Work mode file `state/work_mode`: `1`
  (default) or `2` (Mac terminals: no instant pings except failure/ended, anything waiting 15+ min is
  still reported). lead_watch leaves mode 2 by itself when the Mac is offline on the tailnet (checked
  with `tailscale status --json` on the server: zero cost on the Mac) or a lead waited 30+ min.
  Mute: names or `all` in `state/lead_watch.mute`.

## CCGram
- `uv tool install ccgram==<pinned>` plus the local patch `workstation/ccgram-patches/` (one Telegram button
  per menu option, prompts ahead of the delivery queue; `apply.sh` refuses an unknown version). User unit
  `ccgram.service` with `TMUX=/tmp/tmux-%U/<LEADS_SOCKET>,...` and `KillMode=process` (linger on). Config
  `~/.config/monday/ccgram.env` (600; `~/.ccgram/.env` links to it): TELEGRAM_BOT_TOKEN, ALLOWED_USERS,
  TMUX_SESSION_NAME=leads, CCGRAM_GROUP_ID, CCGRAM_AUTODELETE_DEAD_TOPICS=false,
  CCGRAM_DEFAULT_MODE=normal, CCGRAM_PROJECTS_ROOTS. Never print the env file; check names only.
- Group setup by the owner: BotFather Group Privacy off; group with Topics; bot admin (Manage Topics,
  Delete Messages, Pin Messages); a message in General. Read the chat id from the ccgram log (ccgram
  already consumes getUpdates), set CCGRAM_GROUP_ID, restart.
- Telegram-started sessions: CCGRAM_PROVIDERS_ENABLED=claude, CCGRAM_CLAUDE_COMMAND=~/bin/lead-claude
  (projects root only, refuses skip/bypass permissions, auto `monday-leads add` + window rename + `-n`).
  Such a window is closed by ccgram when claude exits: re-opening makes a new topic.
- `ccgram status` shows windows as "(unbound)" even when bound; the bindings are in
  `~/.ccgram/state.json`. The Telegram Esc button cancels a menu (shows as "user declined").
- Risky defaults turned off: topic deletion when a window closes, auto-close of unbound windows
  (UNBOUND_WINDOW_TTL_MINUTES=0), skip-permissions for Telegram-started sessions. `ccgram doctor --fix`
  closes unbound windows: never run it while leads are parked. Telegram's "Update ccgram" upgrades past
  the pin (and drops the patch).
- `ccgram hook --install` adds its own hooks to `~/.claude/settings.json`: back up first, check JSON
  validity and that the notify.sh entries remain.
