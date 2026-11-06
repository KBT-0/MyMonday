#!/usr/bin/env bash
# Bootstrap the "monday" server (Debian 13). Idempotent: safe to re-run.
#
# Usage (as root on the server):
#   bash bootstrap.sh <username> [phase ...]
#
# Phases, in order:
#   base      apt upgrade, packages, unattended-upgrades, hostname, timezone, swap
#   user      create <username> with sudo and root's SSH keys
#   tailscale install Tailscale from the official repo and run `tailscale up`
#   harden    sshd drop-in (no passwords, no root) + ufw. Refuses to run unless
#             Tailscale is up and CONFIRMED_TAILSCALE_LOGIN=yes is set.
#   userland  fnm + Node LTS + Claude Code for <username>
#   hermes    Hermes Agent for <username>
#   persona   install the Monday persona (SOUL.md) for <username>
#   routing   Opus main model + delegation routes (Sonnet "light", Fable "advisor").
#             Run after `hermes model` has stored the Anthropic key(s).
#   service   run the Hermes gateway as a service that survives reboot
#
# With no phase given, runs: base user tailscale userland hermes persona
# (harden, routing and service are always explicit: they need a human step first).
#
# Environment overrides:
#   SERVER_HOSTNAME   default: monday
#   SERVER_TIMEZONE   default: UTC
#   SWAP_SIZE         default: 2G
set -euo pipefail

USERNAME="${1:-}"
[ -n "$USERNAME" ] || { echo "usage: $0 <username> [phase ...]" >&2; exit 2; }
shift
PHASES=("$@")
[ ${#PHASES[@]} -gt 0 ] || PHASES=(base user tailscale userland hermes persona)

SERVER_HOSTNAME="${SERVER_HOSTNAME:-monday}"
SERVER_TIMEZONE="${SERVER_TIMEZONE:-UTC}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

# Run a command as the target user in a login shell (HOME, PATH from profile).
as_user() {
  local home; home="$(getent passwd "$USERNAME" | cut -d: -f6)"
  ( cd "$home" && runuser -u "$USERNAME" -- env -i HOME="$home" USER="$USERNAME" LOGNAME="$USERNAME" \
      SHELL=/bin/bash LANG=C.UTF-8 PATH=/usr/local/bin:/usr/bin:/bin \
      XDG_RUNTIME_DIR="/run/user/$(id -u "$USERNAME")" bash -lc "$1" )
}

phase_base() {
  log "apt full-upgrade"
  apt-get update
  apt-get "${APT_OPTS[@]}" full-upgrade

  log "packages"
  apt-get "${APT_OPTS[@]}" install \
    git curl jq tmux htop ufw restic build-essential ca-certificates \
    sudo unattended-upgrades unzip libatomic1 gnupg

  log "unattended-upgrades: security only, no automatic reboot"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  cat > /etc/apt/apt.conf.d/51unattended-upgrades-local <<'EOF'
// Managed by agent-station/server/bootstrap.sh
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
    printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-agent-station-hostname.cfg
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

phase_user() {
  log "user: $USERNAME"
  if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --groups sudo "$USERNAME"
  fi
  usermod -aG sudo "$USERNAME"
  # Password-less sudo (see README: revisit before giving the agent more reach).
  local sudoers="/etc/sudoers.d/90-$USERNAME"
  echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$sudoers.tmp"
  chmod 440 "$sudoers.tmp"
  visudo -cf "$sudoers.tmp" >/dev/null
  mv "$sudoers.tmp" "$sudoers"

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
  cat > /etc/ssh/sshd_config.d/00-agent-station.conf <<'EOF'
# Managed by agent-station/server/bootstrap.sh
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

phase_userland() {
  log "fnm + Node LTS for $USERNAME"
  as_user '
    set -euo pipefail
    FNM_DIR="$HOME/.local/share/fnm"
    if [ ! -x "$FNM_DIR/fnm" ]; then
      curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell
    fi
    if ! grep -q "# fnm (agent-station)" "$HOME/.bashrc"; then
      cat >> "$HOME/.bashrc" <<"EOF"

# fnm (agent-station)
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

  log "Claude Code for $USERNAME (not logged in)"
  as_user '
    set -euo pipefail
    if [ ! -x "$HOME/.local/bin/claude" ]; then
      curl -fsSL https://claude.ai/install.sh | bash
    fi
    "$HOME/.local/bin/claude" --version
  '
}

phase_hermes() {
  [ "$(uname -s)-$(uname -m)" = Linux-aarch64 ] || [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] ||
    die "unsupported platform for Hermes: $(uname -s) $(uname -m)"
  log "Hermes Agent for $USERNAME"
  as_user '
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
  log "persona: Monday (SOUL.md + skin)"
  local home; home="$(getent passwd "$USERNAME" | cut -d: -f6)"
  local hh="$home/.hermes" src="$SCRIPT_DIR/hermes"
  [ -d "$hh" ] || die "Hermes is not installed for $USERNAME (run the hermes phase)"
  # Keep Hermes's seeded default once, for reference.
  if [ -f "$hh/SOUL.md" ] && [ ! -f "$hh/SOUL.md.default" ]; then
    cp -p "$hh/SOUL.md" "$hh/SOUL.md.default"
  fi
  install -m 600 -o "$USERNAME" -g "$USERNAME" "$src/SOUL.md" "$hh/SOUL.md"
  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$hh/skins"
  install -m 644 -o "$USERNAME" -g "$USERNAME" "$src/skins/monday.yaml" "$hh/skins/monday.yaml"
  as_user '"$HOME/.local/bin/hermes" config set display.skin monday'
}

phase_routing() {
  log "models: Opus main, delegation routes light (Sonnet) and advisor (Fable)"
  local home; home="$(getent passwd "$USERNAME" | cut -d: -f6)"
  install -m 600 -o "$USERNAME" -g "$USERNAME" "$SCRIPT_DIR/hermes/model_map.json" "$home/.hermes/model_map.json"
  as_user '
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

phase_service() {
  log "gateway service (systemd user unit + linger)"
  loginctl enable-linger "$USERNAME"
  # Wait for the user's systemd manager that linger starts.
  local uid; uid="$(id -u "$USERNAME")"
  for _ in $(seq 1 20); do [ -S "/run/user/$uid/bus" ] && break; sleep 1; done
  as_user '
    set -euo pipefail
    "$HOME/.local/bin/hermes" gateway install --if-missing --start-on-login --start-now
    systemctl --user --no-pager list-units "*hermes*" --all
  '
}

for p in "${PHASES[@]}"; do
  case "$p" in
    base|user|tailscale|harden|userland|hermes|persona|routing|service) "phase_$p" ;;
    *) die "unknown phase: $p" ;;
  esac
done
log "done: ${PHASES[*]}"
