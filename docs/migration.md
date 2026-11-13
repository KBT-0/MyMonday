# Migration: "monster" names to "workstation"

Earlier versions named the workstation after the author's own machine. Everything now uses the generic
name **workstation**. An existing install keeps working unchanged until you migrate it; the old names
are read as a fallback for **one release** and will then be removed.

## What was renamed

| Before | Now |
|---|---|
| repo folder `monster/`, `server/monster/` | `workstation/`, `server/workstation/` |
| `MONSTER_HOST`, `_USER`, `_PROJECTS`, `_PHONE1`, `_PHONE2`, `_CCGRAM` (local.env) | `WORKSTATION_*` (same values) |
| `MONSTER_DEV`, `MONSTER_CLAUDE`, `MONSTER_WAKERS` (run-time env) | `WORKSTATION_DEV`, `WORKSTATION_CLAUDE`, `WORKSTATION_WAKERS` |
| ssh alias `monster`, `monster-phone1/2` | `WORKSTATION_SSH_ALIAS` (new key, default `workstation`), `<alias>-phone1/2` |
| bootstrap phase `monster` | `workstation` |
| Hermes skill `monster` | `workstation` |
| `monster-ctl` (forced command), `mon` (viewer) | `workstation-ctl`, `lead-attach` |
| `monster-wake` | `workstation-wake` |
| `monster-idle-off` (+ `.service`/`.timer`), `/etc/sudoers.d/80-monster` | `workstation-idle-off`, `/etc/sudoers.d/80-workstation-power` |
| `~/.config/monday/monster.env` (workstation) | `~/.config/monday/workstation.env` |
| agent key `~/.ssh/id_ed25519_monster` | `~/.ssh/id_ed25519_workstation` (a copy of the old key) |
| lead tmux server `tmux -L monster` | `tmux -L leads` (new key `LEADS_SOCKET`) |
| Mac: `install.sh --monster`, `MONSTER_HOST` in `mac.env` | `--workstation`, `WORKSTATION_HOST` |

## Fallbacks for one release

- **local.env:** `server/ops/common.py` (`conf()`), `bootstrap.sh` and `install-user.sh` read
  `MONSTER_X` when `WORKSTATION_X` is unset. A local.env with only old keys also keeps the old ssh alias
  `monster` as the default.
- **Workstation config:** every script that reads `workstation.env` falls back to `monster.env` (keys
  `MONSTER_*` mapped to `WORKSTATION_*`) and then keeps the old tmux server name `monster`, so running
  leads stay reachable. `install-user.sh` turns an existing `monster.env` into `workstation.env` (keys
  renamed, `LEADS_SOCKET=monster` added) and leaves the old file in place.
- **Commands:** `setup.sh` / `install-root.sh` replace an existing `/usr/local/bin/monster-ctl` and
  `/usr/local/bin/mon` with links to the new commands (keys in `authorized_keys` with the old forced
  command keep working); the `workstation` phase does the same for `monster-wake`. The links are created
  only where the old name exists. The old idle-off timer and sudoers file are removed, their new copies
  installed.
- **Phase and Mac flag:** `bootstrap.sh <admin> monster` runs the `workstation` phase; `install.sh
  --monster` still works.
- **CCGram patch:** if the installed CCGram carries the earlier wording of the local patch,
  `install-user.sh` reinstalls the pinned version clean once and applies the current patch.

## Migrating an existing install

Order: workstation first (the new Mac client calls `lead-attach`, which the workstation gets in step 2).

1. `local.env`: rename the keys `MONSTER_*` to `WORKSTATION_*`. To keep your existing ssh alias, add
   `WORKSTATION_SSH_ALIAS=monster` (or leave it out to switch to `workstation`, see step 4).
2. Workstation, from the updated checkout: `sudo bash workstation/setup.sh <owner> <key-file>` and
   `sudo bash workstation/install-root.sh <owner>`. Leads keep running on their old tmux server
   (`LEADS_SOCKET=monster` in `workstation.env`). To move them to the new name later: park them, remove
   that line, run `bash workstation/install-user.sh`, reboot or restart `ccgram.service`, then `lead up`.
3. Server: `sudo bash server/bootstrap.sh <admin> workstation ops`. It installs the `workstation` skill;
   move `references/local.md` from `~/.hermes/skills/monster/` to `~/.hermes/skills/workstation/`, then
   delete the old skill folder so only one skill answers.
4. Changing the alias to `workstation`: set (or remove) `WORKSTATION_SSH_ALIAS`, run the `workstation`
   and `ops` phases again; the managed `~/.ssh/config` block and the skill follow.
5. Mac (optional): `zsh clients/mac/install.sh --workstation <user>@<ip> --key '<key>'`.
6. When all of it works: delete `~/.config/monday/monster.env` on the workstation and
   `~/.ssh/id_ed25519_monster*` on the server, and the links `monster-ctl`, `mon`, `monster-wake` once
   no key or script uses them (re-run `setup.sh` first so `authorized_keys` names `workstation-ctl`).
