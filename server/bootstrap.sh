#!/usr/bin/env bash
# Bootstrap the "monday" server (Debian 13). Idempotent: safe to re-run.
#
# Usage (as root on the server):
#   bash bootstrap.sh <admin-user> [phase ...]
#
# Two accounts: <admin-user> is the human operator (SSH, sudo). The assistant runs
# as AGENT_USER, which has no sudo and no SSH keys, so a prompt injection that
# reaches the assistant's shell does not reach root.
#
# Phases, in order:
#   base      apt upgrade, packages, unattended-upgrades, hostname, timezone, swap
#   user      create <admin-user> with sudo and root's SSH keys
#   tailscale install Tailscale from the official repo and run `tailscale up`
#   harden    sshd drop-in (no passwords, no root) + ufw. Refuses to run unless
#             Tailscale is up and CONFIRMED_TAILSCALE_LOGIN=yes is set.
#   agent     create AGENT_USER: no sudo, no SSH login, systemd linger;
#             shared PROJECTS_DIR (setgid + default ACL) for both users
#   userland  fnm + Node LTS + Claude Code for <admin-user> and AGENT_USER
#   hermes    Hermes Agent for AGENT_USER
#   persona   install the Monday persona (SOUL.md) for AGENT_USER
#   routing   Opus main model + delegation routes (Sonnet "light", Fable "advisor").
#             Run after `hermes model` has stored the Anthropic key(s).
#   memory    Basic Memory over the brain vault (PROJECTS_DIR/brain/brain-core and
#             brain-private), wired into Hermes as the MCP server "brain"; hourly
#             auto-commit of the vault repos as AGENT_USER
#   service   run the Hermes gateway as AGENT_USER's service that survives reboot
#   backup    nightly encrypted restic backup to R2 as root. Enables the timer once
#             /etc/mymonday/restic.env (R2 credentials, entered by hand) exists.
#   lockdown  last step: <admin-user>'s sudo requires its password. Needs a password set and
#             CONFIRMED_SUDO_PASSWORD=yes; restores itself in 10 min unless cancelled.
#
# With no phase given, runs: base user tailscale agent userland hermes persona
# (harden, routing, memory, service, backup and lockdown are always explicit: they need a human step first).
#
# Environment overrides:
#   AGENT_USER        default: monday
#   PROJECTS_DIR      default: /srv/projects   (group PROJECTS_GROUP, default: projects)
#   SERVER_HOSTNAME   default: monday
#   SERVER_TIMEZONE   default: UTC
#   SWAP_SIZE         default: 2G
#
# shellcheck disable=SC2016  # as_user bodies are single-quoted on purpose: they expand
#                            # in the target user's shell ($HOME, $PATH), not root's.
set -euo pipefail

usage() { sed -n '2,/^# shellcheck/{/^# shellcheck/d;s/^# \{0,1\}//;p;}' "$0"; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
esac

USERNAME="$1"
shift
PHASES=("$@")
[ ${#PHASES[@]} -gt 0 ] || PHASES=(base user tailscale agent userland hermes persona)

AGENT_USER="${AGENT_USER:-monday}"
PROJECTS_DIR="${PROJECTS_DIR:-/srv/projects}"
PROJECTS_GROUP="${PROJECTS_GROUP:-projects}"
SUDO_LOCK_MARKER=/etc/mymonday/sudo-password-required
REVERT_UNIT=mymonday-sudo-revert
[ "$AGENT_USER" != "$USERNAME" ] || { echo "AGENT_USER must differ from <admin-user>" >&2; exit 2; }
SERVER_HOSTNAME="${SERVER_HOSTNAME:-monday}"
SERVER_TIMEZONE="${SERVER_TIMEZONE:-UTC}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

home_of() { getent passwd "$1" | cut -d: -f6; }

# as_user <user> <script>: run <script> as <user> in a clean login shell.
as_user() {
  local user="$1" home; home="$(home_of "$1")"
  ( cd "$home" && runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" \
      SHELL=/bin/bash LANG=C.UTF-8 PATH=/usr/local/bin:/usr/bin:/bin \
      XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" bash -lc "$2" )
}

# as_agent <script>: as_user for AGENT_USER.
as_agent() { as_user "$AGENT_USER" "$1"; }

phase_base() {
  log "apt full-upgrade"
  apt-get update
  apt-get "${APT_OPTS[@]}" full-upgrade

  log "packages"
  apt-get "${APT_OPTS[@]}" install \
    git curl jq tmux htop ufw restic build-essential ca-certificates \
    sudo unattended-upgrades unzip libatomic1 gnupg acl

  log "unattended-upgrades: security only, no automatic reboot"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  cat > /etc/apt/apt.conf.d/51unattended-upgrades-local <<'EOF'
// Managed by MyMonday/server/bootstrap.sh
// Replace Debian's default origins (which include point releases) with security only.
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  systemctl enable --now unattended-upgrades

  log "hostname: $SERVER_HOSTNAME"
  hostnamectl set-hostname "$SERVER_HOSTNAME"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $SERVER_HOSTNAME/" /etc/hosts
  else
    echo "127.0.1.1 $SERVER_HOSTNAME" >> /etc/hosts
  fi
  if [ -d /etc/cloud/cloud.cfg.d ]; then
    # Hetzner's cloud-init ships preserve_hostname: false; keep ours across reboots.
    printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-mymonday-hostname.cfg
  fi

  log "timezone: $SERVER_TIMEZONE"
  timedatectl set-timezone "$SERVER_TIMEZONE"

  log "swap: $SWAP_SIZE at /swapfile, swappiness 10"
  if [ ! -f /swapfile ]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
  sysctl -q -p /etc/sysctl.d/99-swappiness.conf
}

write_nopasswd_sudoers() {
  echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$1.tmp"
  chmod 440 "$1.tmp"
  visudo -cf "$1.tmp" >/dev/null
  mv "$1.tmp" "$1"
}

phase_user() {
  log "user: $USERNAME"
  if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --groups sudo "$USERNAME"
  fi
  usermod -aG sudo "$USERNAME"
  # Password-less sudo only until the lockdown phase: a fresh operator has no password yet,
  # and the unattended phases need sudo. After lockdown this is never written again.
  if [ -e "$SUDO_LOCK_MARKER" ]; then
    log "sudo for $USERNAME requires a password (lockdown applied); leaving it"
  else
    write_nopasswd_sudoers "/etc/sudoers.d/90-$USERNAME"
  fi

  local home; home="$(getent passwd "$USERNAME" | cut -d: -f6)"
  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$home/.ssh"
  local ak="$home/.ssh/authorized_keys"
  touch "$ak"
  # Add any root key the user does not have yet.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qxF "$key" "$ak" || echo "$key" >> "$ak"
  done < /root/.ssh/authorized_keys
  chown "$USERNAME:$USERNAME" "$ak"
  chmod 600 "$ak"
}

tailscale_running() {
  command -v tailscale >/dev/null 2>&1 &&
    [ "$(tailscale status --json 2>/dev/null | jq -r .BackendState)" = Running ]
}

phase_tailscale() {
  log "tailscale (official apt repo)"
  # shellcheck source=/dev/null
  . /etc/os-release
  local base="https://pkgs.tailscale.com/stable/debian"
  if [ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]; then
    curl -fsSL "$base/$VERSION_CODENAME.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  fi
  curl -fsSL "$base/$VERSION_CODENAME.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
  apt-get update
  apt-get "${APT_OPTS[@]}" install tailscale
  systemctl enable --now tailscaled

  if tailscale_running; then
    log "tailscale already logged in"
    tailscale set --hostname="$SERVER_HOSTNAME"
  else
    # Prints a login URL and waits until it is approved in the browser.
    tailscale up --hostname="$SERVER_HOSTNAME"
  fi
  tailscale ip -4
}

phase_harden() {
  tailscale_running || die "Tailscale is not up; refusing to harden (lockout risk)"
  [ "${CONFIRMED_TAILSCALE_LOGIN:-}" = yes ] ||
    die "set CONFIRMED_TAILSCALE_LOGIN=yes after confirming 'ssh $USERNAME@$SERVER_HOSTNAME' works over Tailscale"
  local home; home="$(getent passwd "$USERNAME" | cut -d: -f6)"
  [ -s "$home/.ssh/authorized_keys" ] || die "$USERNAME has no authorized_keys"

  log "sshd: no passwords, no root login"
  # 00- so it wins: sshd uses the first value it reads for each option.
  cat > /etc/ssh/sshd_config.d/00-mymonday.conf <<'EOF'
# Managed by MyMonday/server/bootstrap.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  sshd -t
  systemctl reload ssh

  log "ufw: deny incoming, allow tailscale0 and 41641/udp"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on tailscale0
  ufw allow 41641/udp
  ufw --force enable
  ufw status verbose
}

phase_agent() {
  log "agent user: $AGENT_USER (no sudo, no SSH login)"
  if ! id "$AGENT_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$AGENT_USER"
  fi
  # Make sure it never gains sudo, even if the account existed before.
  if id -nG "$AGENT_USER" | tr ' ' '\n' | grep -qx sudo; then gpasswd -d "$AGENT_USER" sudo; fi
  rm -f "/etc/sudoers.d/90-$AGENT_USER"
  passwd -l "$AGENT_USER" >/dev/null   # no password login; the operator uses: sudo -iu $AGENT_USER
  chmod 700 "$(home_of "$AGENT_USER")"
  # Keep the user's systemd manager running without a login, for the gateway service.
  loginctl enable-linger "$AGENT_USER"
  # So `sudo -iu monday` can reach its systemd user manager (systemctl --user, hermes gateway).
  local rc; rc="$(home_of "$AGENT_USER")/.bashrc"
  grep -q '# systemd user bus (mymonday)' "$rc" 2>/dev/null ||
    printf '\n# systemd user bus (mymonday)\nexport XDG_RUNTIME_DIR="/run/user/$(id -u)"\n' >> "$rc"
  chown "$AGENT_USER:$AGENT_USER" "$rc"

  log "agent projects: $PROJECTS_DIR (owner $AGENT_USER; $USERNAME works there via sudo -u $AGENT_USER)"
  command -v setfacl >/dev/null || apt-get "${APT_OPTS[@]}" install acl
  getent group "$PROJECTS_GROUP" >/dev/null || groupadd "$PROJECTS_GROUP"
  usermod -aG "$PROJECTS_GROUP" "$AGENT_USER"
  # The operator stays out: anything here is agent-writable (git config, hooks, scripts), and
  # running it as $USERNAME would hand a prompt injection the operator account and its sudo.
  if id -nG "$USERNAME" | tr ' ' '\n' | grep -qx "$PROJECTS_GROUP"; then gpasswd -d "$USERNAME" "$PROJECTS_GROUP"; fi
  install -d -m 2770 -o "$AGENT_USER" -g "$PROJECTS_GROUP" "$PROJECTS_DIR"
  chown -R "$AGENT_USER:$PROJECTS_GROUP" "$PROJECTS_DIR"
  setfacl -m "g:$PROJECTS_GROUP:rwx" -d -m "g:$PROJECTS_GROUP:rwx" "$PROJECTS_DIR"
}

install_node_and_claude() {
  local user="$1"
  log "fnm + Node LTS for $user"
  as_user "$user" '
    set -euo pipefail
    FNM_DIR="$HOME/.local/share/fnm"
    if [ ! -x "$FNM_DIR/fnm" ]; then
      curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell
    fi
    if ! grep -q "# fnm (mymonday)" "$HOME/.bashrc"; then
      cat >> "$HOME/.bashrc" <<"EOF"

# fnm (mymonday)
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env --use-on-cd --shell bash)"
EOF
    fi
    export PATH="$FNM_DIR:$PATH"
    eval "$(fnm env --shell bash)"
    fnm install --lts
    fnm default lts-latest
    node --version
  '

  log "Claude Code for $user (not logged in)"
  as_user "$user" '
    set -euo pipefail
    if [ ! -x "$HOME/.local/bin/claude" ]; then
      curl -fsSL https://claude.ai/install.sh | bash
    fi
    "$HOME/.local/bin/claude" --version
  '
}

phase_userland() {
  install_node_and_claude "$USERNAME"
  install_node_and_claude "$AGENT_USER"
}

require_agent() {
  id "$AGENT_USER" >/dev/null 2>&1 || die "$AGENT_USER does not exist (run the agent phase)"
}

phase_hermes() {
  require_agent
  [ "$(uname -s)-$(uname -m)" = Linux-aarch64 ] || [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] ||
    die "unsupported platform for Hermes: $(uname -s) $(uname -m)"
  log "Hermes Agent for $AGENT_USER"
  as_agent '
    set -euo pipefail
    if [ ! -d "$HOME/.hermes/hermes-agent/.git" ]; then
      # No terminal here, so the installer skips its interactive setup/gateway stages.
      curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
    fi
    "$HOME/.local/bin/hermes" --version
    stat -c "%a %n" "$HOME/.hermes/.env"
  '
}

phase_persona() {
  require_agent
  log "persona: Monday (SOUL.md + skin) for $AGENT_USER"
  local hh src="$SCRIPT_DIR/hermes"
  hh="$(home_of "$AGENT_USER")/.hermes"
  [ -d "$hh" ] || die "Hermes is not installed for $AGENT_USER (run the hermes phase)"
  # Keep Hermes's seeded default once, for reference.
  if [ -f "$hh/SOUL.md" ] && [ ! -f "$hh/SOUL.md.default" ]; then
    cp -p "$hh/SOUL.md" "$hh/SOUL.md.default"
  fi
  install -m 600 -o "$AGENT_USER" -g "$AGENT_USER" "$src/SOUL.md" "$hh/SOUL.md"
  install -d -m 700 -o "$AGENT_USER" -g "$AGENT_USER" "$hh/skins"
  install -m 644 -o "$AGENT_USER" -g "$AGENT_USER" "$src/skins/monday.yaml" "$hh/skins/monday.yaml"
  as_agent '"$HOME/.local/bin/hermes" config set display.skin monday'
}

phase_routing() {
  require_agent
  log "models: Opus main, delegation routes light (Sonnet) and advisor (Fable)"
  install -m 600 -o "$AGENT_USER" -g "$AGENT_USER" "$SCRIPT_DIR/hermes/model_map.json" \
    "$(home_of "$AGENT_USER")/.hermes/model_map.json"
  as_agent '
    set -euo pipefail
    h="$HOME/.local/bin/hermes"
    [ -d "$HOME/.hermes/plugins/advanced-delegation" ] || "$h" plugins install advanced-delegation
    "$h" plugins enable advanced-delegation
    "$h" config set model.provider anthropic
    "$h" config set model.default claude-opus-5-5
    "$h" config set delegation.backends.model_map.options "$(jq -c . "$HOME/.hermes/model_map.json")"
    "$h" config set delegation.backend model_map
  '
}

phase_memory() {
  require_agent
  local brain="$PROJECTS_DIR/brain"
  log "memory: Basic Memory over $brain, MCP server \"brain\" for $AGENT_USER"
  [ -d "$brain/brain-core/.git" ] || die "missing $brain/brain-core (the vault repos are restored from backup, see README)"
  # Hourly auto-commit, so the git history (the "never lose a memory" layer) has everything.
  # Script root-owned; units are user units limited to AGENT_USER.
  install -m 755 "$SCRIPT_DIR/memory/brain-autocommit" /usr/local/bin/brain-autocommit
  local u
  install -d -m 755 /etc/systemd/user
  for u in brain-autocommit.service brain-autocommit.timer; do
    sed "s/^ConditionUser=.*/ConditionUser=$AGENT_USER/" "$SCRIPT_DIR/memory/$u" > "/etc/systemd/user/$u"
    chmod 644 "/etc/systemd/user/$u"
  done
  as_agent "BRAIN='$brain'"'
    set -euo pipefail
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null || { echo "uv not found for $USER (installed by the hermes phase)" >&2; exit 1; }
    command -v basic-memory >/dev/null || uv tool install basic-memory
    bm="$(command -v basic-memory)"
    projects() { python3 -c "import json,os; print(*json.load(open(os.path.expanduser(\"~/.basic-memory/config.json\")))[\"projects\"])" 2>/dev/null || true; }
    # brain-raw stays out of the index: it is an immutable archive, not notes.
    for r in brain-core brain-private; do
      projects | tr " " "\n" | grep -qx "$r" || "$bm" project add "$r" "$BRAIN/$r"
    done
    # Sensitive notes (SCHEMA: access: on_request) live in brain-private/sensitive/. The brain-private
    # index skips that folder (.bmignore), so automatic search never returns them; the folder is its
    # own project, brain-sensitive, which Monday opens only when the owner explicitly asks (SOUL.md).
    bmi="$HOME/.basic-memory/.bmignore"
    # A .bmignore with entries replaces the built-in defaults, so create the default file first.
    [ -f "$bmi" ] || "$(uv tool dir)/basic-memory/bin/python" -c "from basic_memory.ignore_utils import create_default_bmignore as c; c()"
    grep -qx "sensitive/" "$bmi" || printf "\n# brain-private/sensitive is its own project (access: on_request)\nsensitive/\n" >> "$bmi"
    mkdir -p "$BRAIN/brain-private/sensitive"   # setgid parent: group projects, same ACL
    projects | tr " " "\n" | grep -qx brain-sensitive || "$bm" project add brain-sensitive "$BRAIN/brain-private/sensitive"
    "$bm" reindex
    "$bm" status
    h="$HOME/.local/bin/hermes"
    # "Enable all tools?" is answered yes; bm_delete is then filtered out below.
    "$h" mcp list 2>/dev/null | grep -qw brain || printf "y\n" | "$h" mcp add brain --command "$bm" --args mcp
    # SCHEMA.md: notes are never deleted, only tombstoned (bm_edit). Git keeps the rest.
    "$h" config set mcp_servers.brain.tools.exclude "[bm_delete]"
    grep -A12 "^  brain:" "$HOME/.hermes/config.yaml"
    "$h" mcp list
    systemctl --user daemon-reload
    systemctl --user enable --now brain-autocommit.timer
    systemctl --user start brain-autocommit.service || echo "first auto-commit failed: journalctl --user -u brain-autocommit" >&2
    systemctl --user --no-pager list-timers brain-autocommit.timer
    # A running gateway only picks up new MCP servers on restart.
    if systemctl --user --quiet is-active "hermes-gateway*" 2>/dev/null; then
      systemctl --user restart "hermes-gateway*"
    fi
  '
}

phase_service() {
  require_agent
  log "gateway service for $AGENT_USER (systemd user unit + linger)"
  loginctl enable-linger "$AGENT_USER"
  # Wait for the user's systemd manager that linger starts.
  local uid; uid="$(id -u "$AGENT_USER")"
  for _ in $(seq 1 20); do [ -S "/run/user/$uid/bus" ] && break; sleep 1; done
  as_agent '
    set -euo pipefail
    "$HOME/.local/bin/hermes" gateway install --if-missing --start-on-login --start-now
    systemctl --user --no-pager list-units "*hermes*" --all
  '
}

phase_lockdown() {
  log "lockdown: sudo for $USERNAME requires its password"
  [ "$(passwd -S "$USERNAME" | cut -d' ' -f2)" = P ] ||
    die "$USERNAME has no usable password; set one first (passwd $USERNAME) and store it safely"
  [ "${CONFIRMED_SUDO_PASSWORD:-}" = yes ] ||
    die "set CONFIRMED_SUDO_PASSWORD=yes after checking you know $USERNAME's password (su $USERNAME -c true)"
  local sudoers="/etc/sudoers.d/90-$USERNAME"
  install -d -m 700 "$(dirname "$SUDO_LOCK_MARKER")"
  touch "$SUDO_LOCK_MARKER"
  if [ ! -e "$sudoers" ]; then
    log "already locked down"
    return 0
  fi
  # Dead man's switch: restore password-less sudo in 10 minutes unless the operator cancels it
  # after testing `sudo` with the password. Protects against a mistyped or forgotten password.
  systemctl stop "$REVERT_UNIT.timer" 2>/dev/null || true
  systemd-run --quiet --unit="$REVERT_UNIT" --on-active=10min \
    /bin/sh -c "echo '$USERNAME ALL=(ALL) NOPASSWD:ALL' > $sudoers && chmod 440 $sudoers && rm -f $SUDO_LOCK_MARKER"
  rm -f "$sudoers"
  visudo -c >/dev/null
  echo "NOPASSWD removed. It comes back automatically in 10 minutes unless you run, in a NEW session:"
  echo "  sudo -k && sudo true && sudo systemctl stop $REVERT_UNIT.timer"
}

phase_backup() {
  log "backup: restic to R2, nightly timer (root only)"
  local conf=/etc/mymonday src="$SCRIPT_DIR/backup"
  install -m 755 "$src/mymonday-backup" /usr/local/sbin/mymonday-backup
  install -m 644 "$src/mymonday-backup.service" "$src/mymonday-backup.timer" /etc/systemd/system/
  install -d -m 755 /etc/systemd/system/mymonday-backup.service.d
  printf '[Service]\nEnvironment=ADMIN_USER=%s AGENT_USER=%s PROJECTS_DIR=%s\n' \
    "$USERNAME" "$AGENT_USER" "$PROJECTS_DIR" > /etc/systemd/system/mymonday-backup.service.d/users.conf
  systemctl daemon-reload
  install -d -m 700 "$conf" /var/cache/restic

  # Repository password: generated here, never printed. The operator copies it to a
  # password manager with `sudo cat /etc/mymonday/restic.pass` in their own terminal.
  if [ ! -s "$conf/restic.pass" ]; then
    ( umask 077; head -c 32 /dev/urandom | base64 > "$conf/restic.pass" )
    echo "generated $conf/restic.pass (save a copy in your password manager)"
  fi
  chmod 600 "$conf/restic.pass"

  if [ ! -s "$conf/restic.env" ]; then
    echo "missing $conf/restic.env: R2 credentials are entered by hand (server/README.md, Backups)."
    echo "timer not enabled yet; re-run this phase after creating it."
    return 0
  fi
  chmod 600 "$conf/restic.env"
  /usr/local/sbin/mymonday-backup init
  systemctl enable --now mymonday-backup.timer
  systemctl list-timers mymonday-backup.timer --no-pager
}

for p in "${PHASES[@]}"; do
  case "$p" in
    base|user|tailscale|harden|agent|userland|hermes|persona|routing|memory|service|backup|lockdown) "phase_$p" ;;
    *) die "unknown phase: $p" ;;
  esac
done
log "done: ${PHASES[*]}"
