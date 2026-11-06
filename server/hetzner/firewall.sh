#!/usr/bin/env bash
# Hetzner Cloud Firewall in front of ufw: a second layer at the provider's edge.
# Runs on the operator's machine with the hcloud CLI. Idempotent.
#
# Usage: server/hetzner/firewall.sh <hetzner-server-name> [firewall-name]
#
# The API token is never passed here. Create an hcloud context once, in your own terminal:
#   hcloud context create mymonday     (prompts for a project API token with read/write access)
#
# Inbound: only the rules in firewall-rules.json (Tailscale UDP 41641, ICMP). Everything else,
# including SSH on 22, is dropped before it reaches the server. Outbound is unrestricted
# (a Hetzner firewall without outbound rules allows all outbound traffic).
set -euo pipefail

SERVER="${1:-}"
[ -n "$SERVER" ] || { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0" >&2; exit 2; }
FIREWALL="${2:-mymonday}"
RULES="$(cd "$(dirname "$0")" && pwd)/firewall-rules.json"

command -v hcloud >/dev/null || { echo "hcloud CLI not found (brew install hcloud)" >&2; exit 1; }
hcloud server describe "$SERVER" >/dev/null || { echo "no server named $SERVER in the active hcloud context" >&2; exit 1; }

if hcloud firewall describe "$FIREWALL" >/dev/null 2>&1; then
  echo "updating rules of firewall $FIREWALL"
  hcloud firewall replace-rules --rules-file "$RULES" "$FIREWALL"
else
  echo "creating firewall $FIREWALL"
  hcloud firewall create --name "$FIREWALL" --label managed-by=mymonday --rules-file "$RULES"
fi

server_id="$(hcloud server describe "$SERVER" -o json | jq -r .id)"
if hcloud firewall describe "$FIREWALL" -o json |
   jq -e --argjson id "$server_id" '.applied_to[] | select(.type == "server" and .server.id == $id)' >/dev/null; then
  echo "firewall $FIREWALL already applied to $SERVER"
else
  hcloud firewall apply-to-resource --type server --server "$SERVER" "$FIREWALL"
fi

hcloud firewall describe "$FIREWALL"
