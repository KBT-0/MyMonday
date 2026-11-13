#!/usr/bin/env bash
# mac-leads.sh [NAME]: on the owner's Mac, open the leads on the workstation in iTerm2 through tmux control mode (-CC):
# every lead is a window of session "leads", so iTerm2 shows each as a native window. Each call opens its
# own viewer session view-mac-* grouped with "leads" (gone on detach), so the Mac picks windows without
# moving anyone else's view. NAME selects that lead.
set -euo pipefail
host=${WORKSTATION_HOST:?set WORKSTATION_HOST=user@workstation-host (ssh destination of the workstation)}
# the lead tmux server there: LEADS_SOCKET of its workstation.env (default leads)
sock=${LEADS_SOCKET:-leads}
[[ "$sock" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "bad LEADS_SOCKET: $sock" >&2; exit 2; }
remote="tmux -L $sock -CC new-session -t leads -s view-mac-$$-$RANDOM \\\; set-option destroy-unattached on"
if [ -n "${1:-}" ]; then
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { echo "bad lead name: $1" >&2; exit 2; }
  remote+=" \\\; select-window -t :=$1"
fi
osascript -e "tell application \"iTerm2\" to create window with default profile command \"ssh -t $host $remote\""
