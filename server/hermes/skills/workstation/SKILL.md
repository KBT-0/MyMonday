---
name: workstation
description: Drive the owner's main work PC - wake it, check it, run and steer Claude Code project leads, notify, shut it down.
version: 2.1.0
platforms: [linux]
metadata:
  hermes:
    tags: [workstation, claude-code, remote]
    category: devops
    requires_toolsets: [terminal]
---

# Workstation

The workstation is the owner's main work PC (Linux desktop, wired LAN at home). It is off or asleep unless
there is work. The owner is often away from it and uses you as their hands on it. Claude Code sessions
there run as the owner (their login user), with their own Claude accounts and git keys, so treat
everything you type into them as the owner typing it.

**Owner-specific rules: `references/local.md` (git-ignored; read it first when it exists).**
Addresses are in `~/.ssh/config` (the workstation alias, its waker phones `<alias>-phone1/2`, and `mac`),
written from the repo's local.env by `bootstrap.sh workstation`. The alias is `WORKSTATION_SSH_ALIAS`
(default `workstation`); the installed copy of this skill shows the configured one in every command.

## When to Use
The owner asks to turn the workstation on or off, asks what it is doing, or wants work done in one of their
projects; any message about leads, work mode 1/2, the Mac or phone terminals.

## Procedure
All commands go through `ssh workstation <command>`; the workstation accepts only these (forced command
`workstation-ctl`; the full `lead` table is in `references/leads-system.md`):

| Command | Does |
|---|---|
| `ssh workstation status` | uptime, battery, AC, load, sessions |
| `ssh workstation projects` | project folders (projects root) |
| `ssh workstation start <name> [folder]` | new helper tmux session in the folder, running claude |
| `ssh workstation read <name> [lines]` | last screen lines (default 60) |
| `printf '%s' "<text>" \| ssh workstation send <name>` | paste text + Enter; a leading `!` (Claude shell mode) needs `--allow-bang` |
| `ssh workstation answer <name> <key>` | one key, no Enter (menus): 1-9 y n Escape Enter Up Down Tab BTab |
| `ssh workstation key <name> Escape` | special keys: Escape, C-c, Enter, Up, Down, BTab |
| `ssh workstation stop <name>` | end a helper session; for a lead: end claude, keep its window (prefer `lead park`) |
| `ssh workstation lead ...` | project leads: list, status --json, up, park, unpark, events, power-check, viewers, ccgram |
| `ssh workstation sleep` | suspend: sessions and open windows survive, `workstation-wake` resumes it |
| `ssh workstation off` / `reboot` | power off / reboot (refused while work runs; `--force` only on the owner's word) |
| `ssh workstation root pkg-install\|service-restart <name>` | allow-listed root actions (ask first) |

1. Not reachable (`ssh workstation status` times out)? The workstation is off or asleep: wake it with
   `workstation-wake`, then poll `ssh workstation status` every 15 s for up to 3 min. If `workstation-wake` fails,
   tell the owner the workstation cannot be woken from here.
2. Project leads come first: after a wake, `lead up`; then poll `lead events <offset>` or
   `lead status --json` instead of reading screens; `read`/`send`/`answer` work on leads by name.
   Other work: one helper session per task, named after it (`start web web-app`).
3. After `send`, wait, then `read`. Claude Code is done when the screen shows the empty `❯` prompt and
   no spinner. Long tasks: read every 1-2 min, do not flood.
4. Report to the owner briefly, in their language: what you sent, what the session answered, what is
   waiting for them (a question, a permission prompt, a finished change).
5. Work on a branch, never on master/main, unless the owner says so. Push only when asked.
6. When the owner is done, or nothing ran for 30 min: stop helper sessions, run
   `ssh workstation lead power-check` and power off only when nothing BLOCKS and the owner agreed.
   Cold-start sequence: `references/leads-system.md` (Cold start).

## Leads (project Claude sessions)
Project leads run as windows of ONE tmux session `leads` on the lead tmux server (`tmux -L leads`,
name set by `LEADS_SOCKET`); helper sessions from
`start` are separate sessions and never count as leads; `view-*` sessions are viewers (ignore them).
Always-on rules:
- Roles: you = transport + power + wake + digests (the owner's proxy: you may open/resume leads).
  CCGram (a separate Telegram bot, one topic per lead, button approvals) = per-lead chat. If a project
  uses the agent kit (`LEADS_KIT_DIR`), its work state lives in `<project>/<kit dir>/`: read it through
  `lead status --json`, never duplicate or write it.
- Keep each lead's exact Claude name (`claude_name`): leads address each other by name via SendMessage.
- Menus: `ssh workstation answer NAME KEY` (one key, no Enter). `send` is for text only.
- A fresh master-writer lead reports "needs master_writer claim --force": ask the owner, never claim it
  yourself. Never remove kit/git locks, never `off --force`: report and ask.
- Usage limits are yours to continue: when a lead's `limit` is set, wait until `resets_at`, then
  `lead up <name>`.
- Resume method: resume the same session (`lead up`), send `/clear`, then paste the lead's hand-off
  prompt (saved under `~/.local/state/monday/handoffs/<date>/<lead>.prompt.txt` on the workstation). `/clear`
  changes the session id. Leads with no prompt: resume only.
- Evening stop: tell each busy lead to stop at a good point, commit, write its hand-off and give the
  next-session prompt in a code block, start no workers; then wait for `lead power-check` with no BLOCKS
  twice. Then `ssh workstation off`.
- Next morning, before `lead up`: extract each lead's last next-session prompt from its transcript
  (`~/.claude/projects/*/<session_id>.jsonl`, last assistant message, last fenced block) into the
  handoffs dir, and `lead set NAME session_id=<id>` for every lead whose id changed through `/clear`.
- Tasks that need a project's own accounts or tooling (deploys, databases, cloud CLIs) belong to that
  project's lead on the workstation, which already holds the credentials; do not ask the owner for tokens.
- Opening new sessions from Telegram (CCGram) stays possible: it is restricted (projects root only, no
  skip-permissions), never disabled.
- To consult a lead that is not in tmux (a bare terminal window), give the owner one paste-ready prompt
  that writes its answer to `~/.local/state/monday/<lead>-answer.md`, then fetch that file (below).

## Work modes and notifications
- Mode 1 (default): the owner works through Telegram. `lead_watch.py` (server cron, every minute)
  pings every question, permission, finished turn, failure and ended session at once.
- Mode 2: the owner sits at the Mac terminals. Write `2` to `OPS_DIR/state/work_mode` when they start
  it (`ssh mac open` / `restore`), `1` when they say mode 1. In mode 2 only failures ping at once;
  anything waiting 15+ min is still reported. lead_watch returns to mode 1 by itself when the Mac goes
  offline on the tailnet or a lead waits 30+ min. Mute: lead names or `all` in `state/lead_watch.mute`.
- Mac (`ssh mac`, forced to `~/bin/mac-ctl` there): `open [lead...]` (default: ONE window; the tmux
  status bar shows every lead, Ctrl-b n/p/w switch; all leads only when asked), `save` / `restore`
  (iTerm2 windows, tabs, split panes, full screen), `list`, `check`, `layout`. Before powering the workstation
  off in mode 2: `ssh mac save`; after `lead up`: `ssh mac restore`, then ask the owner whether it looks
  right (osascript success does not prove a window appeared; full-screen windows open on their own
  Spaces). Mac asleep / lid closed = unreachable: say so. Details: `references/leads-system.md`.
- Phone: Termius (or any ssh/mosh client) to the workstation, `lead-attach` lists leads, `lead-attach NAME` attaches,
  Ctrl-b w switches, Ctrl-b d detaches. See the repo's docs/clients.md.

## Waiting for a long session task
Poll in a background terminal with notify instead of blocking: loop `ssh workstation read NAME 14` every
30-45 s, count polls without a spinner line (`… (Xm Ys`), stop after 2 idle polls, then read the last
~150 lines. Dismiss any `✦ Heads up` menu inside the loop (`key NAME 0`) and act on it.

## Getting files off the workstation (HTML, images)
The owner may be away from the workstation, so artifacts made there must be delivered via Telegram
(MEDIA:/path). workstation-ctl has no file transfer, so:
1. In the session, ask Claude to copy ONLY the file into a `mktemp -d` dir and serve it with
   `python3 -m http.server 8765 --bind <workstation tailnet IP>` in the background; it reports PID, dir, sha256.
2. From the server: `curl -m 20 -o ~/.hermes/cache/scratch/<file> http://<workstation tailnet IP>:8765/<file>`
   (the IP is `HostName` of the workstation alias in ~/.ssh/config), verify sha256 and size.
3. Tell the session to kill the server and delete the temp dir; confirm with curl that the port is closed.
4. Send the file with MEDIA:/absolute/path (HTML goes as a document).
Fallback: base64 via `read` (print base64 + sha256, decode here, verify).

## Pitfalls
- `status` shows `DESKTOP: owner is logged in` whenever a graphical session exists, so it does not
  mean the owner is at the machine. The gate is `lead power-check` + the owner's OK; `sleep` is safe for idle sessions.
- Right after `start`, `read` first. A new folder shows Claude Code's "Do you trust the files in this
  folder?" menu: for the owner's own project folders answer `key <name> Enter`; anywhere else, ask.
  Never `send` text before the `❯` prompt shows: if claude is not running, the text goes to the shell.
- A permission or choice menu waits for an answer: show it to the owner and ask, unless the answer is
  obvious and harmless.
- Never send secrets into a session, never ask a session to print keys or tokens.
- The owner may be attached to the same session (`lead-attach`). If the screen shows text you did not send,
  they are there: do not type over them.
- Root on the workstation: only `ssh workstation root pkg-install|service-restart <name>` (allow lists in
  `/etc/monday-root/*.allow`, edited by the owner; never retry other spellings); ask before each call.
  sudo inside a session needs the owner's password: give them the command instead.
- Adding an owner device key to the workstation (only when the owner asks): take only the PUBLIC key
  (`ssh-ed25519 ...`, refuse private keys), have a session back up `~/.ssh/authorized_keys`, append the
  line, keep perms 600/700, report the fingerprint. That a session can do this is why your key counts as
  a shell as the owner (repo README, Security model).
- Session `read` output wraps heavily; ask sessions for terse one-line-per-fact summaries. For long
  reports ask the session to write a file and fetch it.
- Piping text to `send`: never put backticks or `$(...)` inside a double-quoted local string (the local
  shell substitutes them). Use single quotes, or write the text to a scratch file and
  `tr '\n' ' ' < file | ssh workstation send NAME`. Long text shows "paste again to expand" but is submitted;
  confirm with `read` after ~20 s.
- `✦ Heads up · ... 0: Dismiss` in a session flags a real risk: read it, dismiss with `key NAME 0`, then
  send the fix as an instruction.
- Pushing a small file TO the workstation: in a helper session send `! echo <base64> | base64 -d > ~/x; sha256sum ~/x`
  with `ssh workstation send NAME --allow-bang` (runs a shell command as the owner; only for this) and
  compare sha256. `/tmp` is wiped on reboot: anything needed
  after a restart goes under `~/.local/state/monday/`.
- Claude's `!` bash mode runs without the model, so it works when the active account is broken.
- Work done in sessions: branch, commit, no push; have the session list files, tests and the single
  command the owner must run. One-time sudo steps (install scripts) the owner runs over their own SSH.

## workstation-ctl drift
- `/usr/local/bin/workstation-ctl` is overwritten from the repo by `setup.sh` / `install-root.sh` without a
  backup: every subcommand must be in the repo's `workstation/workstation-ctl`. After a reinstall run
  `ssh workstation help`.
- A branch/commit a session reports must be verified with `git log`/`git branch` in a fresh session.

## Verification
`ssh workstation status` lists the session; `read` shows the answer you reported.
