#!/usr/bin/env bash
# test-monday-root.sh: monday-root's checks, as a normal user (dry run, fake lists, no sudo).
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf 'htop\n' > "$tmp/packages.allow"; printf 'docker\ntailscaled\n' > "$tmp/services.allow"
export MONDAY_ROOT_ALLOW=$tmp
fail=0
check() { # check <want exit> <args...>
  local want=$1; shift; "$here/monday-root" "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$want" ]; then echo "ok   exit $got: $(printf '%q ' "$@")"
  else echo "FAIL exit $got, want $want: $(printf '%q ' "$@")"; fail=1; fi
}
check 0 pkg-install htop
check 0 service-restart docker
check 0 service-restart tailscaled
check 2 pkg-install vim                     # valid name, not listed
check 2 service-restart sshd
check 2 pkg-install docker                  # listed, but in the other list
check 2 pkg-install htop-git                # longer than a listed name, exact match only
check 2 pkg-install htp                     # substring of a listed name
check 2 pkg-install 'htop;id'
# shellcheck disable=SC2016  # literal on purpose
check 2 pkg-install '$(id)'
check 2 pkg-install '--overwrite=*'
check 2 pkg-install -htop
check 2 pkg-install HTOP
check 2 pkg-install extra/htop
check 2 pkg-install ../htop
check 2 pkg-install "$(printf 'htop\nvim')"  # newline
check 2 pkg-install 'htop '
check 2 pkg-install ''
check 2 pkg-install
check 2 pkg-install htop vim                # extra argument
check 2 remove htop                         # unknown command
check 2
[ "$fail" = 0 ] && echo "ALL OK"; exit "$fail"
