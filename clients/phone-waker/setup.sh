#!/data/data/com.termux/files/usr/bin/sh
# setup.sh: turn an always-on Android phone on the workstation's LAN into a Wake-on-LAN relay.
# Run inside Termux (from F-Droid or GitHub, not the Play Store build), from this folder:
#   sh setup.sh <workstation-mac-address> <lan-broadcast> '<server ssh-ed25519 public key>' [server-tailnet-ip]
# Idempotent. Installs openssh + python, wol.py, the Termux:Boot script, ~/.config/wol.env and the
# forced-command line for the server's key. Tailscale (Android app), Termux:Boot and the battery
# settings are manual: see README.md.
set -eu
mac=${1:?workstation MAC address, e.g. aa:bb:cc:dd:ee:ff}
bcast=${2:?LAN broadcast address, e.g. 192.168.1.255}
key=${3:?the server key: ssh-ed25519 AAAA... monday@monday}
from=${4:-}
here=$(cd "$(dirname "$0")" && pwd)
case $key in ssh-ed25519\ *) ;; *) echo "not an ssh-ed25519 public key" >&2; exit 2 ;; esac

pkg install -y openssh python termux-api >/dev/null
install -m 700 "$here/wol.py" "$HOME/wol.py"
mkdir -p "$HOME/.config" "$HOME/.termux/boot" "$HOME/.ssh"
printf 'WOL_MAC=%s\nWOL_BROADCAST=%s\nWOL_NAME=Monster\n' "$mac" "$bcast" > "$HOME/.config/wol.env"
install -m 700 "$here/start-sshd" "$HOME/.termux/boot/start-sshd"

ak=$HOME/.ssh/authorized_keys
touch "$ak"; chmod 700 "$HOME/.ssh"; chmod 600 "$ak"
b64=$(echo "$key" | cut -d' ' -f2)
grep -vF "$b64" "$ak" > "$ak.tmp" || true
opts='command="python3 ~/wol.py",restrict'
[ -n "$from" ] && opts="from=\"$from\",$opts"
echo "$opts $key" >> "$ak.tmp"
mv "$ak.tmp" "$ak"; chmod 600 "$ak"

# password login off: only keys (Termux sshd listens on 8022)
cfg=$PREFIX/etc/ssh/sshd_config
grep -q '^PasswordAuthentication no' "$cfg" || echo 'PasswordAuthentication no' >> "$cfg"
pgrep -x sshd >/dev/null || sshd
python3 "$HOME/wol.py" >/dev/null && echo "test packet sent"
echo "done. From the server: monster-wake   (expects: wake sent via monster-phone1)"
