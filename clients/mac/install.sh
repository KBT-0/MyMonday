#!/bin/zsh
# install.sh: set up a Mac as the owner's terminal client for the workstation ("mode 2"). Idempotent, no sudo.
#   zsh clients/mac/install.sh --workstation <user>@<workstation-tailnet-ip> --key '<ssh-ed25519 ... monday-mac@monday>' \
#       [--from <server-tailnet-ip>]
# --key is the server assistant's Mac PUBLIC key (printed by `bootstrap.sh <admin> workstation` when MAC_HOST
# is set). --from limits that key to the server's tailnet address (recommended).
# Does: Homebrew mosh, ~/bin/mac-ctl, ~/.config/monday-mac/mac.env, the iTerm2 dynamic profile for native
# full screen, and the forced-command line in ~/.ssh/authorized_keys. Remote Login (System Settings >
# General > Sharing) and Tailscale are yours to switch on; see clients/mac/README.md.
set -eu
here=${0:A:h}
workstation="" key="" from=""
while (( $# )); do
  case $1 in
    --workstation) workstation=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --from) from=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ $workstation == *@* ]] || { echo "--workstation user@ip required" >&2; exit 2; }
[[ $key == ssh-ed25519\ * ]] || { echo "--key must be an ssh-ed25519 PUBLIC key line" >&2; exit 2; }

# mosh (the lead windows survive Wi-Fi changes and sleep), from Homebrew
if command -v brew >/dev/null; then
  command -v mosh >/dev/null || brew install mosh
else
  echo "Homebrew missing: install it (https://brew.sh) and re-run, or windows fall back to plain ssh" >&2
fi

install -d -m 755 "$HOME/bin"
install -m 755 "$here/mac-ctl" "$HOME/bin/mac-ctl"
install -d -m 700 "$HOME/.config/monday-mac"
print -r -- "WORKSTATION_HOST=$workstation" > "$HOME/.config/monday-mac/mac.env"
chmod 600 "$HOME/.config/monday-mac/mac.env"

# iTerm2 dynamic profile "Monday Lead Fullscreen": the default profile + Window Type 4 (native full screen)
if [ -d /Applications/iTerm.app ]; then
  dir="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
  parent="$(defaults read com.googlecode.iterm2 'Default Bookmark Guid' 2>/dev/null || true)"
  mkdir -p "$dir"
  print -r -- '{"Profiles":[{"Name":"Monday Lead Fullscreen","Guid":"monday-lead-fullscreen","Dynamic Profile Parent GUID":"'"$parent"'","Window Type":4}]}' \
    > "$dir/monday-lead-fullscreen.json"
else
  echo "iTerm2 not found: mac-ctl falls back to Terminal.app (no save/restore)" >&2
fi

# the assistant's key: forced to mac-ctl, no forwarding, no pty (restrict); optionally only from the server
ak="$HOME/.ssh/authorized_keys"
install -d -m 700 "$HOME/.ssh"; touch "$ak"; chmod 600 "$ak"
k2=${key#* }; k2=${k2%% *}                      # the base64 part identifies the key
grep -vF -- "$k2" "$ak" > "$ak.tmp" || true
opts='command="~/bin/mac-ctl",restrict'
[ -n "$from" ] && opts="from=\"$from\",$opts"
print -r -- "$opts $key" >> "$ak.tmp"
mv "$ak.tmp" "$ak"; chmod 600 "$ak"

echo "installed. Check with: ~/bin/mac-ctl check"
echo "From the server: ssh mac check   (first osascript use shows a macOS Automation prompt: Allow)"
