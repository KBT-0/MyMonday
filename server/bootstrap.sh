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
#   memory    the memory vault BRAIN_DIR (brain-core, brain-private, brain-sensitive, brain-raw: git
#             repos with a gitleaks hook; created only with CREATE_VAULT=yes, else restored from
#             backup), SCHEMA.md on first run, Basic Memory as the Hermes MCP server "brain", the
#             personal-memory-vault skill, hourly auto-commit of the vault repos as AGENT_USER
#   desktop   visible browser for AGENT_USER: Xvfb, x11vnc + noVNC (loopback only), Chromium with
#             CDP, and Hermes WebUI on the tailnet (tailscale serve :443). Run after `service`.
#   service   run the Hermes gateway as AGENT_USER's service that survives reboot
#   workstation  SSH keys + `ssh <WORKSTATION_SSH_ALIAS>` (default workstation), waker phone and
#             (optional) `ssh mac` aliases for AGENT_USER, the workstation skill and workstation-wake (the
#             owner's main work PC; its side is workstation/setup.sh). Prints the public keys.
#   ops       server/ops jobs in OPS_DIR (lead notifications, spend summary, nightly memory capture),
#             AGENT_USER's crontab block and Hermes cron jobs. After workstation.
#   backup    nightly encrypted restic backup to R2 as root. Enables the timer once
#             /etc/mymonday/restic.env (R2 credentials, entered by hand) exists.
#   lockdown  last step: <admin-user>'s sudo requires its password. Needs a password set and
#             CONFIRMED_SUDO_PASSWORD=yes; restores itself in 10 min unless cancelled.
#
# With no phase given, runs: base user tailscale agent userland hermes persona
# (harden, routing, memory, service, desktop, workstation, ops, backup and lockdown are always explicit: they need a human step first).
#
# Environment overrides:
#   AGENT_USER        default: monday
#   PROJECTS_DIR      default: /srv/projects   (group PROJECTS_GROUP, default: projects)
#   SERVER_HOSTNAME   default: monday
#   SERVER_TIMEZONE   default: UTC
#   SWAP_SIZE         default: 2G
#   BRAIN_DIR         default: PROJECTS_DIR/brain;  OPS_DIR default: PROJECTS_DIR/monday-ops
#   OWNER_NAME, ASSISTANT_LANGUAGE, ASSISTANT_WELCOME (persona), WORKSTATION_HOST/USER, optional
#   WORKSTATION_SSH_ALIAS, WORKSTATION_PHONE1/2 and MAC_HOST/USER (workstation):
#   personal values, read from local.env next to this repo's README
#   (git-ignored; template local.env.example). A key set in local.env wins over the same
#   variable in the environment: one source of truth.
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_ENV="$SCRIPT_DIR/../local.env"
# shellcheck disable=SC1090  # personal values, not in git
[ -f "$LOCAL_ENV" ] && . "$LOCAL_ENV"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-monday}"
SERVER_TIMEZONE="${SERVER_TIMEZONE:-UTC}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
BRAIN_DIR="${BRAIN_DIR:-$PROJECTS_DIR/brain}"
OPS_DIR="${OPS_DIR:-$PROJECTS_DIR/monday-ops}"

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

# agent_install <mode> <dest> < content: write a file into an agent-owned place AS the agent (temp file
# in the same folder, then rename), so root never writes through a path the agent controls (a symlink
# planted there would otherwise turn a root write into a write anywhere). Folders are created 700 by the
# agent when missing. Paths come from this script, never from the agent.
agent_install() {
  local d; d="$(dirname "$2")"
  as_agent "set -e; umask 077; mkdir -p '$d'; t=\$(mktemp '$d/.mymonday.XXXXXX'); cat > \"\$t\"; chmod $1 \"\$t\"; mv -f \"\$t\" '$2'"
}

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
  as_agent 'grep -q "# systemd user bus (mymonday)" ~/.bashrc 2>/dev/null ||
    printf "\n# systemd user bus (mymonday)\nexport XDG_RUNTIME_DIR=\"/run/user/\$(id -u)\"\n" >> ~/.bashrc'

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
  as_agent '[ ! -f ~/.hermes/SOUL.md ] || [ -e ~/.hermes/SOUL.md.default ] || cp -p ~/.hermes/SOUL.md ~/.hermes/SOUL.md.default'
  [ -n "${OWNER_NAME:-}" ] || die "set OWNER_NAME (and ASSISTANT_LANGUAGE) in local.env"
  # SOUL.md is a template: {{KEY}} -> value (| and & escaped for sed), the template note dropped
  local k v sedargs=(-e '/^<!-- Template:/,/^$/d')
  for k in OWNER_NAME ASSISTANT_LANGUAGE SERVER_HOSTNAME AGENT_USER PROJECTS_DIR BRAIN_DIR; do
    v="${!k:-}"; [ "$k" != ASSISTANT_LANGUAGE ] || v="${v:-English}"
    v="${v//\\/\\\\}"; v="${v//|/\\|}"; v="${v//&/\\&}"
    sedargs+=(-e "s|{{$k}}|$v|g")
  done
  local soul; soul="$(mktemp)"   # root's own temp file, checked before the agent gets it
  sed "${sedargs[@]}" "$src/SOUL.md" > "$soul"
  ! grep -q '{{[A-Z_]*}}' "$soul" || { rm -f "$soul"; die "unfilled placeholder in SOUL.md"; }
  agent_install 600 "$hh/SOUL.md" < "$soul"; rm -f "$soul"
  # skin: the welcome line from local.env (ASSISTANT_WELCOME), else the file's default
  local w="${ASSISTANT_WELCOME:-}"; w="${w//[\"\\|&]/}"   # no quote, backslash, | or & (YAML + sed)
  if [ -n "$w" ]; then sed "s|^  welcome: .*|  welcome: \"$w\"|" "$src/skins/monday.yaml"; else cat "$src/skins/monday.yaml"; fi |
    agent_install 644 "$hh/skins/monday.yaml"
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

GITLEAKS_VERSION=8.30.1
# sha256 of the release tarballs, from gitleaks_<version>_checksums.txt of the GitHub release
GITLEAKS_SHA256_arm64=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
GITLEAKS_SHA256_x64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb

# install_gitleaks: the pinned release binary to /usr/local/bin/gitleaks (root-owned), checked against
# the sha256 above; skipped when that version is already there. Any other gitleaks first in PATH that
# is older than 8.19 fails the phase loudly.
install_gitleaks() {
  local arch sum tmp v
  case "$(uname -m)" in
    aarch64) arch=arm64 sum=$GITLEAKS_SHA256_arm64 ;;
    x86_64) arch=x64 sum=$GITLEAKS_SHA256_x64 ;;
    *) die "no pinned gitleaks for $(uname -m)" ;;
  esac
  if [ "$(/usr/local/bin/gitleaks version 2>/dev/null)" != "$GITLEAKS_VERSION" ]; then
    log "gitleaks $GITLEAKS_VERSION ($arch), sha256-checked"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/gl.tgz" \
      "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_linux_$arch.tar.gz"
    echo "$sum  $tmp/gl.tgz" | sha256sum -c --quiet - || { rm -rf "$tmp"; die "gitleaks download: sha256 mismatch"; }
    tar -xzf "$tmp/gl.tgz" -C "$tmp" gitleaks
    install -o root -g root -m 755 "$tmp/gitleaks" /usr/local/bin/gitleaks
    rm -rf "$tmp"
  fi
  v="$(PATH=/usr/local/bin:/usr/bin:/bin gitleaks version 2>/dev/null | sed 's/^v//')"
  [ "$(printf '%s\n8.19.0\n' "$v" | sort -V | head -n1)" = 8.19.0 ] || die "gitleaks ${v:-missing} is older than 8.19"
}

BASIC_MEMORY_VERSION=1.0.0

# install_skill <name> <dest under ~/.hermes/skills> [sed script]: SKILL.md (through the optional sed
# script, e.g. the configured ssh alias) + references/*.md of server/hermes/skills/<name>, written as
# the agent. references/local.md (the owner's private rules, git-ignored) is never overwritten:
# a copy in the repo tree is installed only when the live skill has none.
install_skill() {
  local src="$SCRIPT_DIR/hermes/skills/$1" dst; dst="$(home_of "$AGENT_USER")/.hermes/skills/$2"
  local f to
  sed "${3:-}" "$src/SKILL.md" | agent_install 644 "$dst/SKILL.md"
  for f in "$src/references/"*.md; do
    [ -e "$f" ] || continue
    to="$dst/references/${f##*/}"
    if [ "${f##*/}" = local.md ] && [ -e "$to" ]; then continue; fi
    agent_install 644 "$to" < "$f"
  done
}

phase_memory() {
  require_agent
  local brain="$BRAIN_DIR" r
  log "memory: vault $brain, Basic Memory as MCP server \"brain\" for $AGENT_USER"
  # gitleaks for the vault's pre-commit hook and the nightly export scan (both use the `git`/`dir`
  # subcommands of gitleaks >= 8.19; Debian 13's package is older)
  install_gitleaks
  if [ ! -d "$brain/brain-core/.git" ]; then
    # A rebuild restores the vault from backup first (server/README.md, Restore): creating empty repos
    # over a restore target would mix two histories, so a new vault needs an explicit yes.
    [ "${CREATE_VAULT:-}" = yes ] ||
      die "missing $brain/brain-core: restore it from backup, or set CREATE_VAULT=yes for a new, empty vault"
  fi
  # the vault lives in agent-owned PROJECTS_DIR (setgid group): folders and files are made by the agent
  for r in brain-core brain-private brain-sensitive brain-raw; do
    as_agent "set -e; umask 007; mkdir -p '$brain/$r'; chmod 2770 '$brain' '$brain/$r'
      [ -d '$brain/$r/.git' ] || git -C '$brain/$r' init -q -b main"
    # same hook in every repo, from the repo copy (re-run = update)
    agent_install 755 "$brain/$r/.git/hooks/pre-commit" < "$SCRIPT_DIR/memory/pre-commit-gitleaks"
  done
  # SCHEMA.md: the vault contract, first run only (afterwards it is the owner's file)
  if [ ! -e "$brain/brain-core/SCHEMA.md" ]; then
    agent_install 660 "$brain/brain-core/SCHEMA.md" < "$SCRIPT_DIR/memory/SCHEMA.md"
  fi
  # a night whose export tripped gitleaks is moved to <day>.quarantine: never auto-commit it
  as_agent "grep -qxF '*.quarantine/' '$brain/brain-raw/.gitignore' 2>/dev/null || echo '*.quarantine/' >> '$brain/brain-raw/.gitignore'"
  # how the assistant works with the vault (procedures, Basic Memory pitfalls, nightly capture)
  install_skill personal-memory-vault productivity/personal-memory-vault
  # Hourly auto-commit, so the git history (the "never lose a memory" layer) has everything.
  # Script root-owned; units are user units limited to AGENT_USER.
  install -m 755 "$SCRIPT_DIR/memory/brain-autocommit" /usr/local/bin/brain-autocommit
  local u
  install -d -m 755 /etc/systemd/user
  for u in brain-autocommit.service brain-autocommit.timer; do
    sed -e "s/^ConditionUser=.*/ConditionUser=$AGENT_USER/" -e "s|^Environment=BRAIN=.*|Environment=BRAIN=$brain|" \
      "$SCRIPT_DIR/memory/$u" > "/etc/systemd/user/$u"
    chmod 644 "/etc/systemd/user/$u"
  done
  as_agent "BRAIN='$brain' BM_VERSION='$BASIC_MEMORY_VERSION'"'
    set -euo pipefail
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null || { echo "uv not found for $USER (installed by the hermes phase)" >&2; exit 1; }
    # pinned on first install (Monday may update it later, like any tool it owns)
    command -v basic-memory >/dev/null || uv tool install "basic-memory==$BM_VERSION"
    bm="$(command -v basic-memory)"
    projects() { python3 -c "import json,os; print(*json.load(open(os.path.expanduser(\"~/.basic-memory/config.json\")))[\"projects\"])" 2>/dev/null || true; }
    # brain-raw stays out of the index: it is an immutable archive, not notes.
    for r in brain-core brain-private; do
      projects | tr " " "\n" | grep -qx "$r" || "$bm" project add "$r" "$BRAIN/$r"
    done
    # Sensitive notes (SCHEMA: access: on_request) live in their own repo, brain-sensitive, which is
    # its own Basic Memory project: automatic search over brain-core/brain-private never returns
    # them, and Monday opens the project only when the owner explicitly asks (SOUL.md).
    # (Basic Memory does not allow nested projects, so it cannot sit inside brain-private.)
    s="$BRAIN/brain-sensitive"
    projects | tr " " "\n" | grep -qx brain-sensitive || "$bm" project add brain-sensitive "$s"
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

WEBUI_REPO=https://github.com/nesquena/hermes-webui.git
WEBUI_COMMIT=75cc1ba813c8d320036a55a90e54aa0a170f4c46   # first clone only; Monday may update it later
DESKTOP_UNITS=(xvfb x11vnc novnc vnc-chromium hermes-webui)

phase_desktop() {
  require_agent
  log "desktop: Xvfb + x11vnc + noVNC + visible Chromium (loopback), Hermes WebUI (tailnet :443)"
  apt-get "${APT_OPTS[@]}" install xvfb x11vnc novnc websockify
  # Root-owned units in /etc/systemd/user (not in the agent's home), limited to AGENT_USER.
  local u
  install -d -m 755 /etc/systemd/user
  for u in "${DESKTOP_UNITS[@]}"; do
    sed "s/^ConditionUser=.*/ConditionUser=$AGENT_USER/" "$SCRIPT_DIR/desktop/$u.service" > "/etc/systemd/user/$u.service"
    chmod 644 "/etc/systemd/user/$u.service"
  done
  as_agent "UNITS='${DESKTOP_UNITS[*]}' REPO='$WEBUI_REPO' COMMIT='$WEBUI_COMMIT'"'
    set -euo pipefail
    w="$HOME/apps/hermes-webui"
    if [ ! -d "$w/.git" ]; then
      git clone -q "$REPO" "$w"
      git -C "$w" -c advice.detachedHead=false checkout -q "$COMMIT"
    fi
    # Units made by hand in ~/.config would shadow the managed ones in /etc/systemd/user.
    for u in $UNITS; do
      if [ -f "$HOME/.config/systemd/user/$u.service" ]; then
        systemctl --user disable "$u.service" 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/$u.service"
      fi
    done
    systemctl --user daemon-reload
    systemctl --user enable xvfb x11vnc novnc vnc-chromium
    systemctl --user restart xvfb x11vnc novnc vnc-chromium
    if [ -s "$HOME/.config/hermes-webui/env" ]; then
      systemctl --user enable hermes-webui
      systemctl --user restart hermes-webui
    else
      echo "missing ~/.config/hermes-webui/env (login settings, entered by hand): webui not started" >&2
    fi
    systemctl --user --no-pager --no-legend list-units $(printf "%s.service " $UNITS)
  '
  # Tailnet gets the webui (it has its own login), never the passwordless VNC.
  tailscale serve --https=6080 off 2>/dev/null || true
  tailscale serve --bg --https=443 http://127.0.0.1:8787
  tailscale serve status
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

phase_workstation() {
  require_agent
  log "workstation: ssh aliases and skill for $AGENT_USER"
  local host="${WORKSTATION_HOST:?set WORKSTATION_HOST in local.env}" user="${WORKSTATION_USER:?set WORKSTATION_USER in local.env}"
  local phone1="${WORKSTATION_PHONE1:-}" phone2="${WORKSTATION_PHONE2:-}"   # optional wakers (workstation-wake)
  local alias="${WORKSTATION_SSH_ALIAS:-workstation}"
  [[ "$alias" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "WORKSTATION_SSH_ALIAS: letters, digits, . _ - only"
  local mac="${MAC_HOST:-}" macuser="${MAC_USER:-}"
  # the skill and its references (procedures only; personal values stay in local.env / ~/.ssh/config,
  # the owner's private rules in the live references/local.md, which is kept)
  # (its `ssh workstation <verb>` lines are written with the configured alias)
  install_skill workstation workstation "s/ssh workstation /ssh $alias /g"
  sed "s/^WAKERS_DEFAULT=.*/WAKERS_DEFAULT=\"$alias-phone1 $alias-phone2\"/" "$SCRIPT_DIR/workstation/workstation-wake" > /usr/local/bin/workstation-wake
  chmod 755 /usr/local/bin/workstation-wake
  as_agent "HOST='$host' USER_M='$user' P1='$phone1' P2='$phone2' MAC='$mac' MACUSER='$macuser' A='$alias'"'
    set -euo pipefail
    install -d -m 700 ~/.ssh
    [ -f ~/.ssh/id_ed25519_workstation ] || ssh-keygen -q -t ed25519 -N "" -C monday@monday -f ~/.ssh/id_ed25519_workstation
    # ~/.ssh/config: only the managed block is replaced; anything else in the file stays (block first,
    # so its values win: ssh keeps the first value it reads)
    touch ~/.ssh/config; chmod 600 ~/.ssh/config
    # a config written whole by an older version of this phase (no markers): keep a copy, start fresh
    if ! grep -q "^# BEGIN MyMonday" ~/.ssh/config && [ "$(head -n 1 ~/.ssh/config)" = "Host $A" ]; then
      cp -p ~/.ssh/config ~/.ssh/config.bak-mymonday; : > ~/.ssh/config
    fi
    {
      echo "# BEGIN MyMonday (bootstrap.sh workstation; edits inside this block are replaced)"
      printf "Host %s\n  HostName %s\n  User %s\n\n" "$A" "$HOST" "$USER_M"
      [ -z "$P1" ] || printf "Host %s-phone1\n  HostName %s\n  Port 8022\n\n" "$A" "$P1"
      [ -z "$P2" ] || printf "Host %s-phone2\n  HostName %s\n  Port 8022\n\n" "$A" "$P2"
      printf "Host %s %s-phone*\n  IdentityFile ~/.ssh/id_ed25519_workstation\n  IdentitiesOnly yes\n  ConnectTimeout 10\n  StrictHostKeyChecking accept-new\n" "$A" "$A"
      if [ -n "$MAC" ]; then
        # the Mac client (clients/mac): its own key, forced to mac-ctl there
        printf "\nHost mac\n  HostName %s\n  User %s\n  IdentityFile ~/.ssh/id_ed25519_mac\n  IdentitiesOnly yes\n  ConnectTimeout 10\n  StrictHostKeyChecking accept-new\n" "$MAC" "$MACUSER"
      fi
      echo "# END MyMonday"
      sed "/^# BEGIN MyMonday/,/^# END MyMonday/d" ~/.ssh/config
    } > ~/.ssh/config.new
    chmod 600 ~/.ssh/config.new; mv ~/.ssh/config.new ~/.ssh/config
    echo "workstation + phone key:"; cat ~/.ssh/id_ed25519_workstation.pub
    if [ -n "$MAC" ]; then
      [ -f ~/.ssh/id_ed25519_mac ] || ssh-keygen -q -t ed25519 -N "" -C monday-mac@monday -f ~/.ssh/id_ed25519_mac
      echo "Mac key (clients/mac/install.sh):"; cat ~/.ssh/id_ed25519_mac.pub
    fi'
}

phase_ops() {
  require_agent
  log "ops: server jobs in $OPS_DIR, crontab block and Hermes cron jobs for $AGENT_USER"
  local h f to; h="$(home_of "$AGENT_USER")"
  [ -f "$LOCAL_ENV" ] || die "missing $LOCAL_ENV (the ops jobs read their settings from it)"
  # Only code and the local.env copy are written; state/ and anything else in OPS_DIR stay untouched.
  # OPS_DIR is in agent-owned PROJECTS_DIR: written by the agent (setgid group from PROJECTS_DIR)
  as_agent "set -e; umask 007; mkdir -p '$OPS_DIR/state'; chmod 2770 '$OPS_DIR' '$OPS_DIR/state'"
  for f in "$SCRIPT_DIR"/ops/*.py "$SCRIPT_DIR"/ops/hermes-cron.sh; do
    to="$OPS_DIR/${f##*/}"
    agent_install 660 "$to" < "$f"
  done
  agent_install 640 "$OPS_DIR/local.env" < "$LOCAL_ENV"
  # Hermes cron scripts must live in ~/.hermes/scripts: thin wrappers that run the OPS_DIR copies
  printf '#!/bin/sh\nexec python3 %s/spend_summary.py\n' "$OPS_DIR" | agent_install 700 "$h/.hermes/scripts/spend_summary.sh"
  printf 'import runpy, sys\nsys.path.insert(0, "%s")\nrunpy.run_path("%s/brain_nightly.py", run_name="__main__")\n' \
    "$OPS_DIR" "$OPS_DIR" | agent_install 700 "$h/.hermes/scripts/brain_nightly.py"
  # crontab: replace the managed block, drop older unmarked lines that run the same jobs, keep the rest
  local block cur new
  block="$(sed -e "s|@OPS_DIR@|$OPS_DIR|g" "$SCRIPT_DIR/ops/crontab.in")"
  cur="$(crontab -u "$AGENT_USER" -l 2>/dev/null || true)"
  new="$(mktemp)"   # root's own temp file, not in the agent's folders
  printf '%s\n' "$cur" | sed '/^# BEGIN MyMonday ops/,/^# END MyMonday ops/d' |
    grep -vE "$OPS_DIR/lead_watch\.py" | sed '/^$/d' > "$new" || true
  printf '%s\n' "$block" >> "$new"
  crontab -u "$AGENT_USER" "$new"; rm -f "$new"
  crontab -u "$AGENT_USER" -l
  # Hermes cron jobs (created once, by name)
  as_agent "OPS_LANG='${OPS_LANG:-en}' ASSISTANT_LANGUAGE='${ASSISTANT_LANGUAGE:-English}' SERVER_TIMEZONE='$SERVER_TIMEZONE' BRAIN_DIR='$BRAIN_DIR' OWNER_NAME='${OWNER_NAME:-the owner}' bash '$OPS_DIR/hermes-cron.sh'"
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
    base|user|tailscale|harden|agent|userland|hermes|persona|routing|memory|service|desktop|workstation|ops|backup|lockdown) "phase_$p" ;;
    *) die "unknown phase: $p" ;;
  esac
done
log "done: ${PHASES[*]}"
