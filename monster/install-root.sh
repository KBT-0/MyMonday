#!/usr/bin/env bash
# install-root.sh: install monday-root (Monday's allow-listed root actions) on Monster. Idempotent.
# Run on Monster from anywhere:  sudo bash monster/install-root.sh [owner]   (default: the sudo caller)
# Existing allow lists are kept, so names added later survive a re-run.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
here=$(dirname "$(readlink -f "$0")")
owner=${1:-${SUDO_USER:?give the owner user}}
id "$owner" >/dev/null || { echo "no such user: $owner"; exit 1; }

install -o root -g root -m 755 "$here/monday-root" /usr/local/sbin/monday-root
install -o root -g root -m 755 "$here/monster-ctl" /usr/local/bin/monster-ctl

install -d -o root -g root -m 755 /etc/monday-root
[ -e /etc/monday-root/packages.allow ] || install -o root -g root -m 644 /dev/null /etc/monday-root/packages.allow
[ -e /etc/monday-root/services.allow ] || { printf 'docker\ntailscaled\n' > /etc/monday-root/services.allow
  chown root:root /etc/monday-root/services.allow; chmod 644 /etc/monday-root/services.allow; }

# sudo skips files with a dot in their name, so the .tmp copy is never live
f=/etc/sudoers.d/81-monday-root
sed "s/^OWNER /$owner /" "$here/sudoers-81-monday-root" > "$f.tmp"; chown root:root "$f.tmp"; chmod 440 "$f.tmp"
visudo -cf "$f.tmp" >/dev/null || { rm -f "$f.tmp"; echo "sudoers rule invalid, nothing changed"; exit 1; }
mv "$f.tmp" "$f"
visudo -c >/dev/null || { rm -f "$f"; echo "sudoers as a whole invalid, rule removed"; exit 1; }

home_o=$(getent passwd "$owner" | cut -d: -f6)
[ -f "$home_o/.config/monday/monster.env" ] || echo "note: $home_o/.config/monday/monster.env missing: run monster/install-user.sh as $owner"
echo "MONDAY-ROOT-OK"
