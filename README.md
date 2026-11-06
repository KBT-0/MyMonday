# MyMonday

Reproducible setup for "monday", my always-on personal server, and Monday, the
[Hermes Agent](https://hermes-agent.nousresearch.com) assistant that runs on it and talks to me on Telegram.

- `server/bootstrap.sh` - idempotent Debian 13 bootstrap, split into phases (base system, user,
  Tailscale, SSH/firewall hardening, Node + Claude Code, Hermes, persona, model routing, service).
- `server/hermes/` - Monday's persona (`SOUL.md`), CLI skin and model routes.
- `server/README.md` - how to rebuild the server from zero.

No secrets live in this repo. API keys and the bot token are entered by hand on the server and
stay in `~/.hermes/.env` / `auth.json` (mode 600). Server data backups go to encrypted storage, not here.
