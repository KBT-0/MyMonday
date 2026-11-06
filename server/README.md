# monday server

Always-on personal server that runs the Hermes Agent gateway ("Monday") on Telegram,
plus light dev and deploy work. Heavy builds run elsewhere.

Current host: Hetzner Cloud CAX11 (arm64, 2 vCPU, 4 GB RAM, 40 GB), Debian 13, Falkenstein.
Nothing in `bootstrap.sh` is arm64-specific; it also runs on x86_64 Debian 13.

## Accounts

| Account | Purpose | Privileges |
|---|---|---|
| `kemal` | Human operator. SSH over Tailscale. | Password-less sudo. |
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

8. Gateway service, then reboot and check:

   ```sh
   ssh kemal@monday 'sudo bash /root/MyMonday/server/bootstrap.sh kemal service'
   ssh kemal@monday 'sudo reboot'
   ssh kemal@monday 'sudo -u monday XDG_RUNTIME_DIR=/run/user/$(id -u monday) systemctl --user status hermes-gateway'
   ```

   Send Monday a Telegram message to confirm it answers.

Restoring state (sessions, memories, `.env`) from backup is not covered yet (see open items).

## What bootstrap.sh changes

| Phase | Changes |
|---|---|
| base | `apt full-upgrade`; packages: git curl jq tmux htop ufw restic build-essential ca-certificates sudo unattended-upgrades unzip libatomic1 gnupg acl; unattended-upgrades security only, no auto reboot (`/etc/apt/apt.conf.d/20auto-upgrades`, `51unattended-upgrades-local`); hostname `monday` (+ cloud-init `preserve_hostname: true`); timezone Europe/Istanbul; 2 GB `/swapfile`, `vm.swappiness=10` |
| user | operator with group sudo, password-less sudo in `/etc/sudoers.d/90-<user>`, root's authorized_keys copied |
| tailscale | official apt repo `pkgs.tailscale.com`, `tailscale up --hostname=monday` |
| harden | `/etc/ssh/sshd_config.d/00-mymonday.conf` (PasswordAuthentication no, KbdInteractiveAuthentication no, PermitRootLogin no); ufw default deny incoming, allow in on tailscale0, allow 41641/udp |
| agent | user `monday` without sudo, locked password, linger; group `projects`; `/srv/projects` (2770 + default ACL) |
| userland | for both users: fnm in `~/.local/share/fnm`, Node LTS as default, `.bashrc` block; Claude Code via `claude.ai/install.sh` (not logged in) |
| hermes | Hermes Agent for `monday` via `hermes-agent.nousresearch.com/install.sh` into `~/.hermes` (no setup; no secrets) |
| persona | `~/.hermes/SOUL.md` (default kept as `SOUL.md.default`), `~/.hermes/skins/monday.yaml`, `display.skin: monday` |
| routing | `advanced-delegation` plugin, `model.default: claude-opus-5-5`, `delegation.backend: model_map` with routes `light` (Sonnet) and `advisor` (Fable) |
| service | `loginctl enable-linger monday`; `hermes gateway install` (systemd user unit, starts at boot) |

Override defaults with `AGENT_USER`, `PROJECTS_DIR`, `PROJECTS_GROUP`, `SERVER_HOSTNAME`,
`SERVER_TIMEZONE`, `SWAP_SIZE`.

## Known risks and notes

- Monday can run shell commands as `monday`. A prompt injection in content it reads can act with
  that user's rights: its own files, `/srv/projects`, and the API keys in its `~/.hermes`.
  It cannot reach root or the operator's home. Keep project secrets out of `/srv/projects`.
- `kemal` keeps password-less sudo for convenience. It is only reachable over Tailscale with
  an SSH key.
- With ufw `deny`, public port 22 is dropped, so a test shows a timeout rather than "connection refused".
- SSH over the public IP is closed after `harden`. Access is via Tailscale only; the provider's
  web console is the fallback (log in as `kemal` with its console password).
- Hermes's optional `cua-driver` (computer use) does not install on a headless server (needs libX11).
  Not needed here.

## Open items

- restic backups of `~monday/.hermes` and `/srv/projects` to Cloudflare R2, with a restore path.
- Restricted SSH entry for a second machine (forced command).
- Hetzner Cloud Firewall as a second layer in front of ufw.
