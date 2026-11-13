# Remote workstation ("Monster")

The server assistant drives a Linux workstation at the owner's home: it wakes it, runs Claude Code
project leads on it, relays their questions to Telegram, parks them at night and powers the machine
down. The workstation is the owner's real desktop (here CachyOS + Hyprland); the leads run as the
owner, with the owner's Claude accounts, git keys and project credentials.

```mermaid
flowchart LR
    subgraph server["server (always on)"]
        hermes["assistant (Hermes)<br/>user monday"] -->|"ssh monster &lt;verb&gt;"| key1(("key → monster-ctl"))
        cron["cron: lead_watch"] --> key1
        hermes -->|monster-wake| key2(("key → wol.py"))
    end
    subgraph home["owner's home LAN"]
        phone["phone waker<br/>Termux sshd"] -->|"WoL broadcast"| ws
        subgraph ws["workstation, user = owner"]
            ctl["monster-ctl<br/>(forced command)"] --> leads["tmux -L monster<br/>session leads: one window per lead"]
            ccgram["CCGram"] --> leads
            leads --> hook["notify hook → events.jsonl"]
        end
    end
    key1 -->|"tailnet, from=server IP"| ctl
    key2 -->|tailnet| phone
    ccgram <-->|"Telegram topics, buttons"| tg(("Telegram"))
    hermes <--> tg
```

## Install

On the server (`local.env`: `MONSTER_HOST`, `MONSTER_USER`, `SERVER_IP`, optional `MONSTER_PHONE1/2`, ...):

```sh
sudo bash server/bootstrap.sh <admin> monster   # assistant keys, ssh aliases, skill, monster-wake
sudo bash server/bootstrap.sh <admin> ops       # lead_watch cron, Hermes cron jobs
```

On the workstation, from a checkout with the same `local.env` (`MONSTER_PROJECTS`, `LEADS_KIT_*`,
`TELEGRAM_USER_ID`, `SERVER_IP`, optional `NOTIFY_LANG`, `LEAD_CLAUDE_VERSION`, `MONSTER_CCGRAM`):

```sh
sudo bash monster/setup.sh <owner> monday.pub     # forced-command key, sudo for poweroff/suspend, idle-off, monday-grant
sudo bash monster/install-root.sh <owner>         # monster-ctl, monday-root + allow lists + sudoers rule
bash monster/install-user.sh                      # (also run by setup.sh) monday-leads, hook, tmux conf, CCGram
bash monster/test-leads.sh && bash monster/test-monday-root.sh
```

Requirements on the workstation: tmux, jq, python3, git, Claude Code (native installer), uv (for
CCGram), mosh (for clients), Tailscale. Then the phone waker (`clients/phone-waker/`) and,
optionally, the Mac (`clients/mac/`).

CCGram's secrets (`TELEGRAM_BOT_TOKEN`, `CCGRAM_GROUP_ID`) go into `~/.config/monday/ccgram.env`
(mode 600) by hand; `install-user.sh` adds the non-secret settings and enables the unit once the file
exists. Use a separate bot from the assistant's.

## Command surface

Everything the server can do on the workstation is one script, `monster-ctl`, run as the forced command
of the server's key (`from="<server tailnet IP>",command="/usr/local/bin/monster-ctl --ssh",restrict`):
status, projects, helper sessions (`start/read/send/answer/key/stop`), `lead ...` (see
[leads.md](leads.md)), `sleep/off/reboot` behind a power guard, `root pkg-install|service-restart`
for allow-listed names only. Every word is validated by regex and `monster-ctl` never evaluates its
input as shell code; journald logs verbs and names but never the text sent. What it types, though, lands
in sessions running as the owner: a Claude Code prompt, the login shell of a helper session once claude
exits, and `send --allow-bang` text runs as a shell command on purpose. The key is effectively a shell
as the owner (see Security model).

## Power

- **Wake:** `monster-wake` asks the phone waker (Wake-on-LAN cannot cross the internet).
- **Guard:** `off`, `reboot`, `sleep` and the idle timer refuse while a Claude session or background
  worker is working or waiting on a question, or a kit lock is held by a live pid
  (`monday-leads power-check`). Idle sessions do not block: transcripts are on disk and resume by id.
  `--force` exists for the owner's explicit word.
- **Idle-off:** a root timer powers off after 24 awake hours with no lead or helper session running
  claude, no running claude work or held kit lock, no interactive SSH or mosh login and no active desktop
  (monotonic clock: days of suspend never count as idle). The server's per-minute poll, CCGram and dead
  panes do not keep the machine on. A logged-in desktop counts as active unless logind reports it idle or
  locked (an idle daemon or screen locker sets that); without one, a desktop session keeps the machine on.
- **Sleep vs off:** suspend keeps open windows and sessions; a cold boot is used when nothing needs to
  survive.

## Security model

What the server's workstation key can do, by construction:

- Log in only from the server's tailnet address, only into `monster-ctl`; no login shell of its own, no
  forwarding, no pty. Through the sessions below it is still effectively a shell as the owner.
- Type into Claude Code sessions that run **as the owner**. This is the accepted, central risk: text the
  assistant sends acts with the owner's rights (projects, git keys, credentials those projects hold).
  A compromised server, or a prompt injection that steers the assistant, can therefore instruct a lead
  to read or change anything the owner's account can, push code with the owner's keys, run commands
  (`send --allow-bang`, a helper session's shell) and add SSH keys to the owner's account.
- Root: only `pkg-install` / `service-restart` of names the owner put in `/etc/monday-root/*.allow`,
  enforced twice (sudoers regex + monday-root). Power off/reboot/suspend via sudo without password.
  Anything else needs the owner's password; `monday-grant <minutes>` lends password-less sudo for a
  limited time when the owner types it.

Mitigations: the owner is out of the `docker` group (= root); sudo needs the owner's password; leads
work on branches and never push without the owner (a rule the assistant follows, not a hard control);
Telegram-started sessions are limited to the projects root and refuse permission bypass flags; the
key cannot change `monster-ctl`, `monday-root`, the allow lists or the sudoers rules (root-owned; sudo
needs the owner's password); the phone and Mac keys are forced to single-purpose scripts that cannot
update themselves. Not mitigated: anything a
Claude session can do as the owner. Keep high-value credentials (password manager, cloud root keys)
out of the owner's shell environment on this machine, or use a separate workstation account for leads.
