---
name: personal-memory-vault
description: "Use when building, testing or writing the owner's memory vault."
version: 1.1.0
author: MyMonday
license: MIT
metadata:
  hermes:
    tags: [memory, markdown, basic-memory, mcp, vault]
---

# Personal memory vault ("brain")

The owner's long-term memory: git repos of Markdown notes under the vault dir (`BRAIN_DIR` in the
repo's local.env, default `/srv/projects/brain`): `brain-core`, `brain-private` (incl. people),
`brain-sensitive`, `brain-raw`. Markdown is the source of truth; Basic Memory is the index + MCP
layer (MCP server `brain`). Every index is disposable. The note grammar is in
`brain-core/SCHEMA.md`: read it before writing any note.

## When to Use

Setting up or testing the vault, its Basic Memory index or MCP wiring; importing/distilling chat
archives into notes; writing or correcting memories; evaluating retrieval quality.

## Standing rules

- Decisions are the owner's: research and report with trade-offs; do not switch the base tool
  (Basic Memory, not a custom index) or the tier layout without approval.
- Reports short, in the owner's language: passed / failed / next step.
- Never put secrets in any repo; every repo has a gitleaks pre-commit hook (`gitleaks git --pre-commit --staged`).
- Deletion is a tombstone (`status: deleted` + reason); never rewrite git history.
- Observations carry `src:` and `by:` (`user_stated` / `ai_inferred` / `imported`); text from an
  assistant turn in a chat log is never `user_stated`.
- Writes to `brain-private` need the owner's approval first. Standing approval: the nightly journal
  (`brain-private/journal/YYYY/YYYY-MM-DD.md`; the journal lives only in brain-private per SCHEMA).
- `brain-sensitive` is opened only when the owner explicitly asks about its topic.
- The vault is the primary memory, not Hermes `MEMORY.md`/`USER.md`: anything worth remembering in two
  years (what was done, decisions, why) must land in vault notes. Hermes's background
  "self-improvement review" proposals (`/memory pending`) only touch Hermes memory; explain the
  distinction if asked.
- Before saying something is missing (backup, sync, a service), check the timers and the repo's
  `server/` dir. Off-site backup: root `mymonday-backup.timer`, daily restic to R2, covering
  PROJECTS_DIR (the vault included), the agent's home and the operator's home.

## Nightly capture
Hermes cron "Nightly memory capture" (00:30 server time, this skill attached, delivers to Telegram;
created by `server/ops/hermes-cron.sh`):
1. Script `~/.hermes/scripts/brain_nightly.py` (wrapper of `OPS_DIR/brain_nightly.py`, no LLM): selects
   sessions with `last_activity_at` in the last 26 h from `~/.hermes/state.db` (read-only) and exports
   each with `hermes sessions export --format md --redact --yes --session-id ID` into
   `brain-raw/hermes/<day>/` (append-only: never rewrites an existing day dir), runs gitleaks and moves
   the dir to `<day>.quarantine` on findings (git-ignored, review by hand); prints a JSON manifest.
   A bulk `--newer-than` export skips the still-active session, so export by id.
2. Agent step: journal (Summary / Done / Decisions / Open items / Notes, `src: hermes:<session_id>`),
   durable facts into brain-core notes, private topics to brain-private, never brain-sensitive.
3. Telegram report: success line + counts + a one-sentence note of the day; failure line + reason +
   what to do. 2-3 lines.
When a big piece of work happens mid-session, write the decision note and journal entries right away
instead of waiting for the night run. Use the full Hermes session id in `src:` (`hermes:<id>`, from
`hermes sessions list`), and refresh "Open items" before showing the note: items resolved later the
same day otherwise read as still open.

## Basic Memory operation

```bash
export PATH=$HOME/.local/bin:$PATH BASIC_MEMORY_NO_PROMOS=1
bm project add brain-core "$BRAIN_DIR/brain-core"
bm project index brain-core            # (re)index; `bm status --project X` shows stages
bm tool search "q" --mode text|semantic|hybrid --project brain-core --json
bm config set <key> <value>            # ~/.basic-memory/config.json
bm man show bm-search                  # built-in manual; `bm man apropos <word>`
```

MCP tools are `bm_*` (`bm_write`, `bm_edit`, `bm_search`, `bm_context`, ...) and every project-scoped
call needs `project`. Pre-1.0 names (`write_note`, `search_notes`) no longer exist. `bm_delete` is
excluded in the Hermes MCP config: notes are tombstoned, never deleted.

## Pitfalls

- **Always write `permalink:` in frontmatter** (`<project>/<path-without-.md>`, e.g. `brain-core/schema`).
  Sync adds a missing permalink by rewriting the file: it also adds title/type to frontmatter-less
  files, converts CRLF to LF and drops the final newline. With a correct permalink present, indexing
  leaves hand-written files byte-identical.
- **Time:** use Basic Memory's authored valid-time qualifier in observation lines,
  `@valid:[2026-06-01,)` or `@valid:[start,end)`, so `--valid-at` filtering works. Relative dates
  (`yesterday`, bare month names) are ignored as qualifiers.
- **Semantic floor:** the default `semantic_min_similarity` (0.55) hides all EmbeddingGemma results (its
  scores sit around 0.2-0.5). Measure first (`--min-similarity 0` shows raw scores), then lower it
  (about 0.2) with `bm config set` before judging semantic search. The bootstrap does not change it.
- **EmbeddingGemma needs prompts:** `semantic_embedding_query_prefix "task: search result | query: "`,
  `semantic_embedding_document_prefix "title: none | text: "`, dimensions 768, then reindex.
  It costs about 1.1 GB RSS per process; a multilingual MiniLM is the light fallback.
- **Turkish lexical search is limited upstream:** FTS5 `unicode61` folds I→i but never ı→i, so
  `ısparta`↔`ISPARTA`, `ışık`↔`IŞIK`, `çalışma`↔`ÇALIŞMA` do not match. Suffixes are fine (prefix
  matching). Details and a fix plan: `references/basic-memory-turkish-search.md`.
- **Search tests need neutral file names and titles** (`n1.md`, `Test 1`): permalink, title and path are
  indexed too, so a file named after the query word passes the test for the wrong reason.
- Each `bm tool` CLI call starts a fresh process and loads the model: batch queries in one script and
  run long query sets in the background.

## Smoke-test recipe (before importing real data)

1. Note sha256 of hand-written test files; index; `sha256sum -c` to detect rewrites.
2. Run a case set in your language(s) in text, semantic (with `--min-similarity 0`) and hybrid mode.
3. Measure peak RSS by polling `/proc/<pid>/statm` of the process tree while one command runs.
4. Delete the test folder, reindex, commit only real files.
