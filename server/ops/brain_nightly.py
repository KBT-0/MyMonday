#!/usr/bin/env python3
"""Nightly memory capture, step 1 (no LLM): export the Hermes sessions active in the last N hours to
<BRAIN_DIR>/brain-raw/hermes/<YYYY-MM-DD>/ as redacted Markdown, scan them with gitleaks, and print a
JSON manifest for the agent step (journal + note updates; prompt in hermes-cron.sh).

brain-raw is append-only: each night writes a new dated folder; a long session that spans days appears
once per day it was active (snapshot); files are never rewritten. A gitleaks finding moves the night's
folder to <day>.quarantine (kept out of the repo until a human looks) and reports an error instead;
so does any other non-zero gitleaks exit (the export was not scanned).
brain-raw keeps every session as exported (secrets redacted, nothing else filtered), sensitive topics
included: it is not indexed and never read on the assistant's own initiative (SOUL.md, docs/memory.md).
Installed for Hermes cron as ~/.hermes/scripts/brain_nightly.py (a wrapper that runs this file).
Env: BRAIN_HOURS (26), BRAIN_RAW (default <BRAIN_DIR>/brain-raw/hermes).
"""
import json, os, sqlite3, subprocess, sys, time
from datetime import datetime, timedelta
from common import conf

if __name__ != "__main__":  # a script with side effects: importing it must not run the export
    raise ImportError("brain_nightly.py is a script; run it, do not import it")

HOURS = int(os.environ.get("BRAIN_HOURS", "26"))
DB = os.path.expanduser("~/.hermes/state.db")
RAW = os.environ.get("BRAIN_RAW") or os.path.join(conf("BRAIN_DIR", "/srv/projects/brain"), "brain-raw", "hermes")
HERMES = os.path.expanduser("~/.local/bin/hermes")
GITLEAKS = os.path.expanduser("~/.local/bin/gitleaks")
if not os.path.exists(GITLEAKS):
    GITLEAKS = "gitleaks"

day = (datetime.now() - timedelta(hours=3)).strftime("%Y-%m-%d")  # runs ~00:30 -> previous day's label
out = os.path.join(RAW, day)
cut = time.time() - HOURS * 3600

c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
rows = c.execute(
    "select id, source, title, message_count, coalesce(last_activity_at, started_at) "
    "from sessions where coalesce(hidden,0)=0 and message_count>0").fetchall()


def ts(v):
    if v is None:
        return 0
    if isinstance(v, (int, float)):
        return v
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0


recent = [r for r in rows if ts(r[4]) >= cut]
if not recent:
    print(json.dumps({"day": day, "sessions": []}))
    sys.exit(0)

if os.path.isdir(out):
    print(f"brain-raw/{day} already exists; not overwriting (append-only)", file=sys.stderr)
else:
    os.makedirs(out)
    # one export per id: a bulk --newer-than export skips the session that is still active
    for sid, *_ in recent:
        subprocess.run([HERMES, "sessions", "export", "--format", "md", "--redact", "--yes",
                        "--session-id", sid, out + "/"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    leak = subprocess.run([GITLEAKS, "dir", out, "--no-banner", "--exit-code", "3"],
                          capture_output=True, text=True)
    # 3 = secrets found; any other non-zero (old gitleaks without `dir`, bad flag, crash) means the
    # export was NOT scanned: quarantine it the same way, never pass it on unscanned
    if leak.returncode != 0:
        q = out + ".quarantine"
        os.rename(out, q)
        why = "gitleaks found secrets" if leak.returncode == 3 else f"gitleaks failed (rc {leak.returncode}), export not scanned"
        print(json.dumps({"day": day, "error": f"{why}; moved to {q}"}))
        sys.exit(0)

files = sorted(os.listdir(out)) if os.path.isdir(out) else []
manifest = {"day": day, "raw_dir": out, "sessions": [
    {"id": r[0], "source": r[1], "title": r[2], "messages": r[3],
     "file": next((f for f in files if f.startswith(r[0])), None)} for r in recent]}
print(json.dumps(manifest, ensure_ascii=False, indent=1))
