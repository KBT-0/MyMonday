# monday server

Always-on personal server that runs the Hermes Agent gateway ("Monday") on Telegram,
plus light dev and deploy work. Heavy builds run elsewhere.

Current host: Hetzner Cloud small ARM VPS (arm64, 2 vCPU, 4 GB RAM, 40 GB), Debian 13, EU.
Nothing in `bootstrap.sh` is arm64-specific; it also runs on x86_64 Debian 13.

## Accounts

| Account | Purpose | Privileges |
|---|---|---|
| `kemal` | Human operator. SSH over Tailscale. | sudo with password (password-less only until the `lockdown` phase). |
| `monday` | Runs Hermes (Monday). | No sudo, locked password, no SSH keys, home `700`. Reached with `sudo -iu monday`. |

Both are in the `projects` group and share `/srv/projects` (setgid, default ACL `g:projects:rwx`),
so either can edit what the other created. Monday cannot read `/home/kemal` and cannot install
packages; for root work it gives the operator the command.

## Files

- `bootstrap.sh` - every system change, split into idempotent phases. Run as root. `--help` lists them.
- `hermes/SOUL.md` - Monday's identity and voice (installed to `~monday/.hermes/SOUL.md`).
- `hermes/skins/monday.yaml` - CLI branding, agent name "Monday" (`display.skin: monday`).
- `hermes/model_map.json` - delegation routes `light` (Sonnet) and `advisor` (Fable), see the `routing` phase.

## Rebuild from zero

1. Create a Debian 13 server with your Mac's SSH key for root. Note its public IP.
   Keep the provider's web console (Hetzner: Console in the server view) open as a fallback.

2. Copy this directory and run the unattended phases:

   ```sh
   IP=<public-ip>
   tar czf - server | ssh root@$IP 'mkdir -p /root/MyMonday && tar xzf - -C /root/MyMonday'
   ssh root@$IP 'bash /root/MyMonday/server/bootstrap.sh kemal base user'
   ssh kemal@$IP true   # operator login works
   ```

3. Tailscale. The phase prints a login URL and waits until you approve it:

   ```sh
   ssh root@$IP 'bash /root/MyMonday/server/bootstrap.sh kemal tailscale'
   ```

   If the old node "monday" still exists in the tailnet, remove it in the admin console first,
   or the new one gets a suffixed name. Then from the Mac (Tailscale running):

   ```sh
   ssh kemal@monday true
   ```

4. Only after step 3 works, harden SSH and enable the firewall. Run it over Tailscale:

   ```sh
   ssh kemal@monday 'sudo CONFIRMED_TAILSCALE_LOGIN=yes bash /root/MyMonday/server/bootstrap.sh kemal harden'
   nc -vz -w 5 $IP 22    # must fail (filtered)
   ssh kemal@monday true # must still work
   ```

5. Agent user, userland, Hermes and persona:

   ```sh
   ssh kemal@monday 'sudo bash /root/MyMonday/server/bootstrap.sh kemal agent userland hermes persona'
   ```

6. Secrets, typed by hand in your own SSH session (never through scripts or chat):

   ```sh
   ssh kemal@monday
   sudo -iu monday
   hermes model           # provider Anthropic + API key(s)
   hermes gateway setup   # Telegram bot token, TELEGRAM_ALLOWED_USERS=<your Telegram user ID>
   stat -c '%a' ~/.hermes/.env ~/.hermes/auth.json   # must be 600
   ```

   Notes from the first install:
   - `hermes model` opens with Nous Portal preselected; move with the arrow keys before Enter.
   - The "Automatic" Telegram option creates the bot through Nous's hosted onboarding bot,
     so the token passes through their service. "Manual" (token from @BotFather) avoids that.
   - "Additional allowed user IDs" takes IDs, not y/n. Leave it empty. Check with
     `grep '^TELEGRAM_ALLOWED_USERS' ~/.hermes/.env` (prints only that line).
   - The wizard may install and start the gateway service itself. That is fine; the
     `service` phase skips the install when one exists (`--if-missing`).

   Claude Code: run `claude` once as `kemal` (and as `monday` if Monday should use it) and log in.

7. Model routing (after `hermes model` stored the Anthropic keys):

   ```sh
   ssh kemal@monday 'sudo bash /root/MyMonday/server/bootstrap.sh kemal routing'
   ```

   Opus 5.5 is the main model and does the work. Through the official `advanced-delegation`
   plugin (`delegation.backend: model_map`, routes in `hermes/model_map.json`) it can hand a
   subagent to `light` (Sonnet 5.5, routine bulk work) or `advisor` (Fable 5.1, advice only).
   Tasks with no option run on Opus. "Advice only" is an instruction in the route description
   and SOUL.md, not a hard limit: subagents inherit the parent's tools.

   Then the memory vault (see [Memory vault](#memory-vault)), once `/srv/projects/brain` exists:

   ```sh
   ssh -t monday 'sudo bash ~/MyMonday/server/bootstrap.sh kemal memory'
   ```

8. Gateway service, then reboot and check:

   ```sh
   ssh kemal@monday 'sudo bash /root/MyMonday/server/bootstrap.sh kemal service'
   ssh kemal@monday 'sudo reboot'
   ssh kemal@monday 'sudo -u monday XDG_RUNTIME_DIR=/run/user/$(id -u monday) systemctl --user status hermes-gateway'
   ```

   Send Monday a Telegram message to confirm it answers.

9. Backups (see [Backups](#backups)): create `/etc/mymonday/restic.env` by hand, then

   ```sh
   ssh kemal@monday 'sudo bash /root/MyMonday/server/bootstrap.sh kemal backup'
   ```

   On a rebuild, restore before step 6 instead of entering secrets again (see [Restore](#restore)).

10. Provider firewall, from the Mac (see [Hetzner Cloud Firewall](#hetzner-cloud-firewall)):

    ```sh
    hcloud context create mymonday     # once; prompts for a project API token
    server/hetzner/firewall.sh <hetzner-server-name>
    ```

11. Last: sudo with a password for the operator. Check you know the password first, then
    lock down, then test in a **new** session within 10 minutes and cancel the automatic revert:

    ```sh
    ssh kemal@monday 'su kemal -c true'   # asks for the password; must succeed
    ssh kemal@monday 'sudo CONFIRMED_SUDO_PASSWORD=yes bash /root/MyMonday/server/bootstrap.sh kemal lockdown'
    ssh -t kemal@monday 'sudo -k && sudo true && sudo systemctl stop mymonday-sudo-revert.timer'
    ```

    If the password does not work, wait 10 minutes: password-less sudo comes back by itself.

## Changes after lockdown

The operator keeps a clone of this repo on the server, pulls changes without sudo, and runs
the affected phase with sudo (it asks for the password):

```sh
ssh kemal@monday 'git clone https://github.com/KBT-0/MyMonday.git ~/MyMonday'   # once
ssh kemal@monday 'git -C ~/MyMonday pull --ff-only'
ssh -t kemal@monday 'sudo bash ~/MyMonday/server/bootstrap.sh kemal persona'    # e.g. after a SOUL.md change
```

Persona changes apply to new sessions: send `/new` to Monday afterwards.

## Backups

`mymonday-backup` runs nightly at 03:30 as root (`mymonday-backup.timer`) and stores an encrypted,
deduplicated restic snapshot in a Cloudflare R2 bucket:

- `~monday` (Hermes config, keys, memories, sessions; not the reinstallable `hermes-agent`,
  `tools`, `installs`, `cache`, `logs`)
- `~kemal`
- `/srv/projects` (without `node_modules`, `.venv`, build output and caches)

Retention: 7 daily, 4 weekly, 6 monthly, 10 yearly. Sundays add `restic check --read-data-subset=5%`.
restic also keeps the oldest snapshot while those buckets are still filling. After changing the
excludes, drop an oversized early snapshot by hand (nothing secret is printed):

```sh
sudo sh -c 'set -a; . /etc/mymonday/restic.env; RESTIC_PASSWORD_FILE=/etc/mymonday/restic.pass; restic forget <id> --prune'
```

On this server the first full snapshot is about 157 MiB of data, 70 MiB stored in R2.
Root-only credentials mean the assistant account can neither read nor delete its backups.

Credentials, all root-owned and mode 600 in `/etc/mymonday/`:

- `restic.pass` - generated by the `backup` phase. Copy it to a password manager once:
  `sudo cat /etc/mymonday/restic.pass`. Without it the backups cannot be decrypted.
- `restic.env` - written by hand (R2 bucket + an API token limited to that bucket):

  ```sh
  sudo install -m 600 /dev/null /etc/mymonday/restic.env
  sudo nano /etc/mymonday/restic.env
  ```

  ```sh
  RESTIC_REPOSITORY=s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>
  AWS_ACCESS_KEY_ID=<r2-access-key-id>
  AWS_SECRET_ACCESS_KEY=<r2-secret-access-key>
  AWS_DEFAULT_REGION=auto
  ```

  `<account-id>` is the 32-character hex Account ID from the R2 overview page. The token screen
  shows three values: use the Access Key ID and the Secret Access Key, not the `cfat_...` token
  value. `mymonday-backup` refuses an R2 URL in any other shape, because a wrong endpoint does not
  fail, it hangs on the TLS handshake.

Useful commands: `sudo mymonday-backup snapshots`, `sudo mymonday-backup stats` (bytes stored in the bucket), `sudo systemctl start mymonday-backup`
(run now), `journalctl -u mymonday-backup`.

## Restore

On a fresh server after steps 1-5 (both users exist, Hermes installed):

```sh
# 1. Put restic.pass (from the password manager) and restic.env back in /etc/mymonday, mode 600.
sudo bash /root/MyMonday/server/bootstrap.sh kemal backup
# 2. Stop the gateway if it already runs, then restore. Files come back with their owners.
sudo mymonday-backup snapshots
sudo mymonday-backup restore            # or: restore <snapshot-id>
```

Then run the `persona`, `routing`, `memory` and `service` phases. The keys and the Telegram setup come
back with `~/.hermes`, so step 6 is skipped.

## Memory vault

Monday's long-term memory is plain Markdown in three git repos under `/srv/projects/brain`,
owned by `monday`, group `projects`:

| Repo | Contents | Indexed |
|---|---|---|
| `brain-core` | profile, projects, decisions, preferences, tools | yes |
| `brain-private` | health, money, people, personal context | yes |
| `brain-raw` | immutable source archives (ChatGPT export, secrets redacted) | no |

`brain-core/SCHEMA.md` is the contract: one note per entity, `## Current` / `## History`,
every observation with `src:` and `by:` (`user_stated` or `ai_inferred`), tombstones instead of
deletes. Each repo has a gitleaks pre-commit hook.

The `memory` phase registers `brain-core` and `brain-private` as Basic Memory projects,
reindexes them and adds Basic Memory to Hermes as the MCP server `brain` (stdio,
`basic-memory mcp`) with `bm_delete` excluded: notes are tombstoned, never deleted. It also installs `brain-autocommit` (hourly user timer as `monday`): every change in
the three repos is committed, through the gitleaks hook, so a note Monday breaks or deletes can
always be restored from git (`git log -- <file>`, `git show <commit>:<file>`). A failed commit
(a secret, for example) leaves the change staged and shows in
`journalctl --user -u brain-autocommit`. The repos themselves are data: they come back from the restic backup,
not from this script. The vault is not pushed anywhere; git history on the server plus the
encrypted R2 backup are the copies.

Commits by hand go through `monday`, so the hook finds gitleaks:

```sh
cd /srv/projects/brain
sudo -u monday -H git -c user.name=Monday -c user.email=monday@monday.local -C brain-core status
```

## What bootstrap.sh changes

| Phase | Changes |
|---|---|
| base | `apt full-upgrade`; packages: git curl jq tmux htop ufw restic build-essential ca-certificates sudo unattended-upgrades unzip libatomic1 gnupg acl; unattended-upgrades security only, no auto reboot (`/etc/apt/apt.conf.d/20auto-upgrades`, `51unattended-upgrades-local`); hostname `monday` (+ cloud-init `preserve_hostname: true`); timezone UTC; 2 GB `/swapfile`, `vm.swappiness=10` |
| user | operator with group sudo, password-less sudo in `/etc/sudoers.d/90-<user>`, root's authorized_keys copied |
| tailscale | official apt repo `pkgs.tailscale.com`, `tailscale up --hostname=monday` |
| harden | `/etc/ssh/sshd_config.d/00-mymonday.conf` (PasswordAuthentication no, KbdInteractiveAuthentication no, PermitRootLogin no); ufw default deny incoming, allow in on tailscale0, allow 41641/udp |
| agent | user `monday` without sudo, locked password, linger; group `projects`; `/srv/projects` (2770 + default ACL) |
| userland | for both users: fnm in `~/.local/share/fnm`, Node LTS as default, `.bashrc` block; Claude Code via `claude.ai/install.sh` (not logged in) |
| hermes | Hermes Agent for `monday` via `hermes-agent.nousresearch.com/install.sh` into `~/.hermes` (no setup; no secrets) |
| persona | `~/.hermes/SOUL.md` (default kept as `SOUL.md.default`), `~/.hermes/skins/monday.yaml`, `display.skin: monday` |
| routing | `advanced-delegation` plugin, `model.default: claude-opus-5-5`, `delegation.backend: model_map` with routes `light` (Sonnet) and `advisor` (Fable) |
| memory | `uv tool install basic-memory` (if missing), Basic Memory projects `brain-core` and `brain-private`, `basic-memory reindex`, Hermes MCP server `brain`, gateway restart, `/usr/local/bin/brain-autocommit` + user timer `brain-autocommit.timer` |
| service | `loginctl enable-linger monday`; `hermes gateway install` (systemd user unit, starts at boot) |
| lockdown | removes `/etc/sudoers.d/90-<admin>` (sudo then asks for the password), marker `/etc/mymonday/sudo-password-required`, 10-minute revert timer `mymonday-sudo-revert` |
| backup | `/usr/local/sbin/mymonday-backup`, `mymonday-backup.{service,timer}` (+ drop-in with the user names), `/etc/mymonday` (700), generated `restic.pass`; `restic init` and the timer once `restic.env` exists |

Override defaults with `AGENT_USER`, `PROJECTS_DIR`, `PROJECTS_GROUP`, `SERVER_HOSTNAME`,
`SERVER_TIMEZONE`, `SWAP_SIZE`.

## Telegram token rotation

Do this whenever the bot token may have been exposed (the first token came through Nous's
hosted onboarding bot). Monday is offline from the revoke until the new token is in.

1. Telegram, @BotFather: `/mybots` → the bot → **API Token** → **Revoke current token**. Copy the new token.
2. On the server, as `monday`:

   ```sh
   ssh -t kemal@monday sudo -iu monday
   hermes gateway setup     # Telegram → Manual → paste the new token; keep the allowlist as is
   systemctl --user restart hermes-gateway
   grep '^TELEGRAM_ALLOWED_USERS' ~/.hermes/.env   # only your user ID
   ```

3. Send Monday a message.

## Hetzner Cloud Firewall

`server/hetzner/firewall.sh` creates (or updates) a provider-side firewall named `mymonday`
from `server/hetzner/firewall-rules.json` and attaches it to the server: inbound only Tailscale
UDP 41641 and ICMP, outbound unrestricted. It is a second layer in front of ufw, so a ufw
mistake does not expose anything. The API token stays in the local hcloud context; the
script never sees it.

## Possible sudo whitelist for Monday (none granted)

Monday has no sudo. If a task later needs root, grant one exact command in
`/etc/sudoers.d/91-monday` (no wildcards, no shells, no editors, no `systemctl edit`), for example:

| Need | Exact command |
|---|---|
| Deploy reload of a specific web server | `/usr/bin/systemctl reload caddy` |
| Restart one app service it deploys | `/usr/bin/systemctl restart <app>.service` |
| Read a system service's logs | `/usr/bin/journalctl -u <app>.service --no-pager -n 200` |
| Check firewall state | `/usr/sbin/ufw status verbose` |
| Run the backup on demand | `/usr/local/sbin/mymonday-backup backup` |

Package installs (`apt`) stay with the operator: an allowed `apt install` can run arbitrary
maintainer scripts as root.

## Known risks and notes

- Monday can run shell commands as `monday`. A prompt injection in content it reads can act with
  that user's rights: its own files, `/srv/projects`, and the API keys in its `~/.hermes`.
  It cannot reach root or the operator's home. Keep project secrets out of `/srv/projects`.
- `kemal`'s sudo asks for its password after the `lockdown` phase. Before that (during the
  unattended phases) it is password-less.
- With ufw `deny`, public port 22 is dropped, so a test shows a timeout rather than "connection refused".
- SSH over the public IP is closed after `harden`. Access is via Tailscale only; the provider's
  web console is the fallback (log in as `kemal` with its console password).
- Hermes's optional `cua-driver` (computer use) does not install on a headless server (needs libX11).
  Not needed here.

## Open items

- Restricted SSH entry for a second machine (forced command).
