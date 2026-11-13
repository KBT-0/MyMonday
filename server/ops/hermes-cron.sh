#!/usr/bin/env bash
# hermes-cron.sh: create the assistant's Hermes cron jobs, once (a job whose script is already scheduled
# is left alone, whatever its name). Run as the agent user; `bootstrap.sh <admin> ops` calls it.
#   daily spend     23:00, no agent: spend_summary.sh's one line goes to Telegram as is
#   nightly memory  00:30, brain_nightly.py exports yesterday's sessions to brain-raw, then the agent
#                   writes the journal and note updates (skill personal-memory-vault) and reports
# Env: ASSISTANT_LANGUAGE (report language), SERVER_TIMEZONE, BRAIN_DIR, OWNER_NAME.
set -euo pipefail
h="$HOME/.local/bin/hermes"
lang=${ASSISTANT_LANGUAGE:-English} tz=${SERVER_TIMEZONE:-UTC} brain=${BRAIN_DIR:-/srv/projects/brain}
owner=${OWNER_NAME:-the owner}
have() { "$h" cron list 2>/dev/null | grep -qE "Script: +$1\$"; }

if have spend_summary.sh; then echo "spend job exists"; else
  "$h" cron create --name "Daily spend summary" --no-agent --script spend_summary.sh \
    --deliver telegram --timezone "$tz" "0 23 * * *" \
    "23:00 one-line spend summary (the script output is delivered as is)."
fi

prompt="The script output is the manifest of yesterday's Hermes sessions (archived as redacted Markdown \
under brain-raw/hermes/<day>/). Task: update the memory vault following $brain/brain-core/SCHEMA.md to the \
letter. 1) Journal: brain-private/journal/<YYYY>/<day>.md (create it, or only add what is missing): sections \
Summary, Done, Decisions, Open items, Notes; every line with src: hermes:<session_id>; by: \
user_stated|ai_inferred|imported. 2) Durable facts: update the matching brain-core notes (projects/, \
decisions/, tools/, preferences/, profile/, assistant/) or open new ones (frontmatter + permalink required); a \
changed fact moves the old line to History, nothing is deleted, tombstones as in SCHEMA. 3) Health, money, \
people and private context go to brain-private; never touch brain-sensitive; never write secrets anywhere. \
Topics of the sensitive tier (SCHEMA: access: on_request) go neither into the journal nor \
into any note: leave them out and write only 'sensitive topic, not recorded' with its src line. \
4) From subagent sessions take only results and decisions. 5) Never modify files in brain-raw. brain-autocommit \
commits. After writing, check that the files exist and their frontmatter is valid. OUTPUT (goes to $owner on \
Telegram, in $lang, short): on success exactly 2-3 lines: '✅ Nightly memory capture done (<day>)' / '<n> \
sessions archived; journal + <m> notes updated' / '📝 <one-sentence summary of the day>'. If the manifest has \
an error or any step failed: '❌ Nightly memory capture failed (<day>)' / 'Reason: <one sentence>' / 'To do: \
<one sentence>'. No sessions is not a failure: '✅ Nightly memory capture (<day>): no sessions to record'. \
Translate these lines into $lang."

if have brain_nightly.py; then echo "memory job exists"; else
  "$h" cron create --name "Nightly memory capture" --script brain_nightly.py --interpreter python3 \
    --skill personal-memory-vault --deliver telegram --failure-deliver telegram --catch-up on \
    --timezone "$tz" "30 0 * * *" "$prompt"
fi
"$h" cron list
