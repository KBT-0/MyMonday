#!/usr/bin/env bash
# check-private.sh [ENV_FILE] [REV_RANGE]: fail when a personal value appears in the tracked files or is
# added by a commit. Values: every KEY=VALUE of ENV_FILE (default local.env) plus one string per line of
# .private-strings (git-ignored, optional: names, project names and the like that are not in local.env).
# History (default HEAD: every commit reachable from it; origin/main..HEAD for unpushed work): lines a
# commit adds, commit messages, author/committer emails. Lines a commit removes do not count (removing
# a value is the fix). Prints the KEY (or "private-strings line N") and where, never the value.
# Skipped: values shorter than 4 characters, values equal to the local.env.example default or to a
# built-in default path, generic settings (CHECK_PRIVATE_SKIP, default: language and on/off keys, and the
# local names WORKSTATION_SSH_ALIAS / LEADS_SOCKET: an ssh alias and a tmux socket name, not addresses), and
# the LICENSE file (the copyright holder is public by choice). No ENV_FILE (e.g. in CI): nothing to check.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
envf=${1:-local.env} range=${2:-HEAD}
skip=" ${CHECK_PRIVATE_SKIP:-ASSISTANT_LANGUAGE OPS_LANG NOTIFY_LANG WORKSTATION_CCGRAM WORKSTATION_SSH_ALIAS LEADS_SOCKET} "
declare -A def=([BRAIN_DIR]=/srv/projects/brain [OPS_DIR]=/srv/projects/monday-ops [WORKSTATION_PROJECTS]=projects)
list=()   # "label<TAB>value"
if [ -f "$envf" ]; then
  while IFS='=' read -r k v; do [ -n "$v" ] && def[$k]=$v; done < <(grep -E '^[A-Z_][A-Z0-9_]*=' local.env.example || true)
  while IFS='=' read -r k v; do
    v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
    [[ "$skip" == *" $k "* ]] && continue
    [ ${#v} -ge 4 ] && [ "${def[$k]-__unset__}" != "$v" ] && list+=("$k"$'\t'"$v")
  done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$envf" || true)
fi
if [ -f .private-strings ]; then
  n=0
  while IFS= read -r v; do
    n=$((n + 1)); [ ${#v} -ge 4 ] && [[ "$v" != \#* ]] && list+=("private-strings line $n"$'\t'"$v")
  done < .private-strings
fi
[ ${#list[@]} -gt 0 ] || { echo "check-private: no $envf and no .private-strings, nothing to check"; exit 0; }

log=$(mktemp); trap 'rm -f "$log"' EXIT
git log -p --no-color --format='@@C %h%n%B' "$range" > "$log"
meta=$(git log --format='%h %ae %ce' "$range")
fail=0
for item in "${list[@]}"; do
  label=${item%%$'\t'*} v=${item#*$'\t'}
  files=$(git grep -l -F -e "$v" -- . ':!LICENSE' ':!local.env.example' 2>/dev/null | tr '\n' ' ' || true)
  [ -z "$files" ] || { echo "TREE    $label: $files"; fail=1; }
  # added lines and message lines (no leading -, space or hunk header) of each commit; emails from metadata
  commits=$( { V=$v awk '/^@@C /{c=$2; next} /^(\+\+\+|---|@@) /{next} !/^[- ]/ && index($0, ENVIRON["V"]) {print c}' "$log"
               grep -F -- "$v" <<<"$meta" | cut -d' ' -f1 || true; } | sort -u | tr '\n' ' ')
  [ -z "$commits" ] || { echo "HISTORY $label ($range): $commits"; fail=1; }
done
[ "$fail" = 0 ] && echo "check-private: ${#list[@]} values, none in the tree or added in $range"
exit "$fail"
