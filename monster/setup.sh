#!/usr/bin/env bash
# Set up Monster (CachyOS workstation, home city) so Monday can drive it over Tailscale.
# Idempotent. Run as root on Monster, from this folder:  bash setup.sh <owner-user> monday.pub
#
# Monday's key logs in as the owner, but only from the monday server's Tailscale IP and
# only into monster-ctl (forced command): Claude Code sessions run as the owner, with the
# owner's claude-swap accounts and git keys, in a tmux server the owner attaches to with `mon`.
# Accepted risk: text Monday types into a session runs with the owner's rights. The owner's
# sudo password stays the last lock; the owner is taken out of the docker group (= root).
#
# - monster-idle-off.timer: power off after 24 hours with no session, SSH or desktop login
# - sudo without password only for poweroff, reboot and suspend
# - /usr/local/sbin/monday-grant <minutes>|off: the owner gives passwordless sudo for a
#   limited time; typing the owner's sudo password is the approval
set -euo pipefail

owner=${1:?owner user}; pub=${2:?monday ssh public key file}
SERVER_IP=${SERVER_IP:-SERVER_TAILSCALE_IP}
home_o=$(getent passwd "$owner" | cut -d: -f6)
grep -q '^ssh-ed25519 ' "$pub" || { echo "$pub is not an ed25519 public key"; exit 1; }
here=$(dirname "$(readlink -f "$0")")

install -m 755 "$here/monster-ctl" "$here/mon" /usr/local/bin/
install -m 755 "$here/idle-off" /usr/local/sbin/monster-idle-off

# Safety net: power off after 24 idle hours, even if Monday forgets to.
cat > /etc/systemd/system/monster-idle-off.service <<EOF
[Unit]
Description=Power Monster off when idle
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/monster-idle-off $owner 1440
EOF
cat > /etc/systemd/system/monster-idle-off.timer <<'EOF'
[Unit]
Description=Check every 5 min whether Monster is idle
[Timer]
OnBootSec=10min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now monster-idle-off.timer

# Monday's key: forced command, no forwarding, no pty.
ak="$home_o/.ssh/authorized_keys"
key=$(cut -d' ' -f1,2 "$pub")
touch "$ak"; grep -vF "$key" "$ak" > "$ak.tmp" || true
printf 'from="%s",command="/usr/local/bin/monster-ctl --ssh",restrict %s monday@monday\n' "$SERVER_IP" "$key" >> "$ak.tmp"
mv "$ak.tmp" "$ak"; chown "$owner:" "$ak"; chmod 600 "$ak"

gpasswd -d "$owner" docker >/dev/null 2>&1 || true

printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/bin/systemctl reboot, /usr/bin/systemctl suspend\n' "$owner" \
  > /etc/sudoers.d/80-monster
chmod 440 /etc/sudoers.d/80-monster

cat > /usr/local/sbin/monday-grant <<EOF
#!/usr/bin/env bash
# monday-grant <minutes>|off : passwordless sudo for $owner, removed again after <minutes>.
set -euo pipefail
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
visudo -c >/dev/null

# Undo the first layout (separate monday user), if present.
rm -f /etc/sudoers.d/80-monday /etc/tmpfiles.d/monster.conf; rm -rf /run/monster
if id monday >/dev/null 2>&1; then
  setfacl -x u:monday "$home_o" 2>/dev/null || true
  setfacl -R -x u:monday,d:u:monday "$home_o/projects" 2>/dev/null || true
  loginctl disable-linger monday 2>/dev/null || true
  pkill -u monday 2>/dev/null || true; sleep 1
  userdel -r monday 2>/dev/null || true
fi
getent group monster >/dev/null && groupdel monster

echo "MONSTER-SETUP-OK"
