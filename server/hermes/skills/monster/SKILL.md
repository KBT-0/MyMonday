---
name: monster
description: Drive the owner's workstation Monster in home city - wake it, check it, run and steer Claude Code sessions in his projects, shut it down.
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [monster, claude-code, remote]
    category: devops
    requires_toolsets: [terminal]
---

# Monster

Monster is the owner's main machine (CachyOS laptop, home, wired LAN). It is off unless
there is work. the owner is away and uses you as his hands on it. The Claude Code sessions there
run as the owner (user owner) with his own claude-swap accounts and git keys, so treat everything
you type into them as the owner typing it.

## When to Use
the owner asks to turn Monster on or off, asks what it is doing, or wants work done in one of his
projects (project-a, agent-kit, project-b, project-c, ...).

## Procedure
All commands go through `ssh monster <command>`; Monster only accepts these:

| Command | Does |
|---|---|
| `ssh monster status` | uptime, battery, AC, load, sessions |
| `ssh monster projects` | project folders |
| `ssh monster start <name> [folder]` | new tmux session in the folder, running claude |
| `ssh monster read <name> [lines]` | last screen lines (default 60) |
| `printf '%s' "<text>" \| ssh monster send <name>` | type text into the session + Enter |
| `ssh monster key <name> Escape` | special keys: Escape, C-c, Enter, Up, Down, BTab |
| `ssh monster stop <name>` | end the session |
| `ssh monster sleep` | suspend: sessions and the owner's open windows survive, `monster-wake` resumes it |
| `ssh monster off` / `reboot` | power off / reboot |

1. Not reachable (`ssh monster status` times out)? Monster is off: wake it with
   `monster-wake`, then poll `ssh monster status` every 15 s for up to 3 min. If
   `monster-wake` is missing or fails, tell the owner: Monster is off and cannot be woken from here.
2. Start one session per project, named after it (`start project-a project-a`).
3. After `send`, wait, then `read`. Claude Code is done when the screen shows the empty `❯`
   prompt and no spinner. Long tasks: read every 1-2 min, do not flood.
4. Report to the owner in short Turkish: what you sent, what the session answered, what is
   waiting for him (a question, a permission prompt, a finished change).
5. Work on a branch, never on master/main, unless the owner says so. Push only when the owner asks.
6. When the owner says he is done, or nothing ran for 30 min: stop the sessions and `ssh monster off`,
   after telling him (not when `status` shows `DESKTOP`, see Pitfalls).

## Pitfalls
- `status` showing `DESKTOP: the owner is logged in` means his own open work (often resumed from
  sleep). Never `off` or `reboot` then, not even when idle: ask him first. `sleep` is safe.
- Right after `start`, `read` first. A new folder shows Claude Code's "Do you trust the files in
  this folder?" menu: for the owner's own project folders answer with `key <name> Enter` (option 1 is
  already selected); anywhere else, ask the owner. Never `send` text before the `❯` prompt is shown:
  if claude is not running, the text goes to the shell (fish) instead.
- A permission or choice menu in the session waits for an answer: show it to the owner and ask,
  unless the answer is obvious and harmless.
- The 5-hour limit message in a session: tell the owner; claude-swap may switch accounts by itself.
- Never send secrets into a session, never ask a session to print keys or tokens.
- the owner may be attached to the same session (`mon <name>` on his side). If the screen shows
  text you did not send, he is there: do not type over him.
- sudo inside a session needs the owner's password. If a task needs root, ask him to run
  `sudo monday-grant 30` on Monster; never try to work around it.

## Verification
`ssh monster status` lists the session; `read` shows the answer you reported.
