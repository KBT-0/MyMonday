#!/usr/bin/env bash
# Set up the workstation (Arch-based Linux, here CachyOS + Hyprland) so Monday can drive it over Tailscale.
# Idempotent. Run as root on the workstation, from this folder:  bash setup.sh <owner-user> <monday-ssh-pubkey-file>
#
# Monday's key logs in as the owner, but only from the monday server's Tailscale IP and
# only into workstation-ctl (forced command): Claude Code sessions run as the owner, with the
# owner's claude-swap accounts and git keys, in a tmux server the owner attaches to with `lead-attach`.
# Accepted risk: text Monday types into a session runs with the owner's rights. The owner's
# sudo password stays the last lock; the owner is taken out of the docker group (= root).
#
# - workstation-idle-off.timer: power off after 24 awake hours with no running claude, interactive login or
#   active desktop (see idle-off)
# - sudo without password only for poweroff, reboot and suspend
# - /usr/local/sbin/monday-grant <minutes>|off: the owner gives passwordless sudo for a
#   limited time; typing the owner's sudo password is the approval; a reboot always ends it
set -euo pipefail

owner=${1:?owner user}; pub=${2:?monday ssh public key file}
# shellcheck disable=SC1091  # personal values, not in git
[ -f "$(dirname "$(readlink -f "$0")")/../local.env" ] && . "$(dirname "$(readlink -f "$0")")/../local.env"
SERVER_IP=${SERVER_IP:?set SERVER_IP (the monday server Tailscale IP) in local.env}
home_o=$(getent passwd "$owner" | cut -d: -f6)
grep -q '^ssh-ed25519 ' "$pub" || { echo "$pub is not an ed25519 public key"; exit 1; }
here=$(dirname "$(readlink -f "$0")")

install -m 755 "$here/workstation-ctl" "$here/lead-attach" /usr/local/bin/
install -m 755 "$here/idle-off" /usr/local/sbin/workstation-idle-off
# monday-leads, notify hook, lead tmux config; XDG_RUNTIME_DIR: runuser does not set it (systemctl --user)
runuser -u "$owner" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$owner")" bash "$here/install-user.sh"

# Safety net: power off after 24 idle hours, even if Monday forgets to.
cat > /etc/systemd/system/workstation-idle-off.service <<EOF
[Unit]
Description=Power the workstation off when idle
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/workstation-idle-off $owner 1440
EOF
cat > /etc/systemd/system/workstation-idle-off.timer <<'EOF'
[Unit]
Description=Check every 5 min whether the workstation is idle
[Timer]
OnBootSec=10min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now workstation-idle-off.timer

# Monday's key: forced command, no forwarding, no pty.
ak="$home_o/.ssh/authorized_keys"
key=$(cut -d' ' -f1,2 "$pub")
touch "$ak"; grep -vF "$key" "$ak" > "$ak.tmp" || true
printf 'from="%s",command="/usr/local/bin/workstation-ctl --ssh",restrict %s monday@monday\n' "$SERVER_IP" "$key" >> "$ak.tmp"
mv "$ak.tmp" "$ak"; chown "$owner:" "$ak"; chmod 600 "$ak"

gpasswd -d "$owner" docker >/dev/null 2>&1 || true

printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/bin/systemctl reboot, /usr/bin/systemctl suspend\n' "$owner" \
  > /etc/sudoers.d/80-workstation-power
chmod 440 /etc/sudoers.d/80-workstation-power

cat > /usr/local/sbin/monday-grant <<EOF
#!/bin/bash
# monday-grant <minutes>|off : passwordless sudo for $owner, removed again after <minutes>.
# The expiry timer is transient (lost on reboot), so monday-grant-reset.service also removes the
# grant at every boot: a reboot always ends it.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
f=/etc/sudoers.d/90-monday-grant
[ "\$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
systemctl stop monday-grant-expire.timer 2>/dev/null || true
if [ "\${1:-}" = off ]; then rm -f "\$f"; echo "no extra sudo"; exit 0; fi
m=\${1:?minutes or off}; [[ "\$m" =~ ^[0-9]+\$ ]] && [ "\$m" -ge 1 ] && [ "\$m" -le 720 ] || { echo "1-720 minutes"; exit 1; }
echo '$owner ALL=(ALL) NOPASSWD: ALL' > "\$f.tmp"; chmod 440 "\$f.tmp"
visudo -cf "\$f.tmp" >/dev/null && mv "\$f.tmp" "\$f"
systemd-run -q --unit=monday-grant-expire --on-active="\${m}m" /usr/bin/rm -f "\$f"
logger -t monday-grant "passwordless sudo for $owner, \${m} min"
echo "passwordless sudo for \$m min"
EOF
chmod 755 /usr/local/sbin/monday-grant
cat > /etc/systemd/system/monday-grant-reset.service <<'EOF'
[Unit]
Description=Remove a passwordless sudo grant left from before the reboot (monday-grant)
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target
[Service]
Type=oneshot
ExecStart=/usr/bin/rm -f /etc/sudoers.d/90-monday-grant /etc/sudoers.d/90-monday-grant.tmp
[Install]
WantedBy=sysinit.target
EOF
systemctl daemon-reload
systemctl enable monday-grant-reset.service
visudo -c >/dev/null

echo "WORKSTATION-SETUP-OK"
