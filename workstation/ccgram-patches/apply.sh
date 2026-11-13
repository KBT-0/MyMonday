#!/usr/bin/env bash
# apply.sh: the local CCGram patches (*.patch here) on the uv tool install, then a self-check.
# Idempotent (an applied patch is skipped); fails loudly when a patch no longer applies (a new
# ccgram version: refresh the patch). Prints "patched: <name>" for each newly applied one.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
py=$HOME/.local/share/uv/tools/ccgram/bin/python
site=$("$py" -c 'import ccgram, os; print(os.path.dirname(os.path.dirname(ccgram.__file__)))')
for p in "$here"/*.patch; do
  if patch -d "$site" -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1; then continue; fi
  patch -d "$site" -p1 --dry-run -s -f < "$p" >/dev/null \
    || { echo "ccgram-patches: $(basename "$p") does not apply to $("$py" -m ccgram --version 2>/dev/null || echo ccgram)" >&2; exit 1; }
  patch -d "$site" -p1 -s -f --no-backup-if-mismatch < "$p"
  echo "patched: $(basename "$p")"
done
"$py" -I "$here/check.py"
