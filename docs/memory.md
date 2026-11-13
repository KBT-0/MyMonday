# Memory: an auditable vault

The assistant's long-term memory is plain Markdown in git, indexed by Basic Memory and exposed to Hermes
as the MCP server `brain`. Every index is disposable; the files are the truth.

## Layout (`BRAIN_DIR`, default `/srv/projects/brain`)

| Repo | Contents | Indexed |
|---|---|---|
| `brain-core` | profile, projects, decisions, preferences, tools; `SCHEMA.md` | yes |
| `brain-private` | health, money, people, journal | yes |
| `brain-sensitive` | notes with `access: on_request` | own project, opened only on explicit request |
| `brain-raw` | immutable source archives (chat exports, nightly session exports) | no |

Four separate git repos, each with the same gitleaks pre-commit hook (`server/memory/pre-commit-gitleaks`,
fails closed). `bootstrap.sh <admin> memory` creates them (`CREATE_VAULT=yes` on a first install),
installs `SCHEMA.md` into brain-core on first run only, registers the Basic Memory projects, adds the MCP
server with `bm_delete` excluded, installs the `personal-memory-vault` skill and an hourly
`brain-autocommit` timer.

## The contract (`server/memory/SCHEMA.md`)

- One note per entity, frontmatter with a `permalink` (without it Basic Memory rewrites the file).
- `## Current` holds what is true now; `## History` is append-only; a changed fact moves with a closed
  `@valid:[start,end)` range.
- Every observation line carries `src:` (where it came from) and `by:` (`user_stated`, `ai_inferred`,
  `imported`): text from an assistant turn is never `user_stated`.
- Nothing is deleted: tombstones (`status: deleted` + reason) keep links and history.
- Writes to `brain-private` need the owner's approval (standing approval for the nightly journal);
  `brain-sensitive` is a convention enforced by the assistant's instructions, not access control.

## Nightly capture

Hermes cron job "Nightly memory capture" (00:30, `server/ops/hermes-cron.sh`):

1. `brain_nightly.py` (no LLM) exports every Hermes session active in the last 26 h with
   `hermes sessions export --redact` into `brain-raw/hermes/<day>/` (append-only; per-id export, because
   a bulk export skips the session still running), scans the folder with gitleaks and moves it to
   `<day>.quarantine` (git-ignored) on a finding; it prints a manifest.
2. The agent step (skill `personal-memory-vault`) writes the day's journal into `brain-private`, updates
   or creates brain-core notes for durable facts, never touches brain-sensitive, and reports 2-3 lines to
   Telegram in `ASSISTANT_LANGUAGE`.
3. `brain-autocommit` commits within the hour, through the gitleaks hook.

Sensitive tier and the nightly export: `brain-raw` receives every session as exported, with secrets
redacted and nothing else filtered, so a conversation about a sensitive topic is archived there too.
`brain-raw` is not indexed and is read only to check a source. The agent step is told to keep
sensitive-tier topics (`access: on_request`) out of the journal and the notes and to record only that
one was skipped. To keep such sessions out of the archive entirely, delete them in Hermes before 00:30
or move the day's folder out by hand; there is no automatic filter.

## Backups

The vault is under `PROJECTS_DIR`, which the nightly restic backup to Cloudflare R2 covers (encrypted,
root-only credentials: the assistant can neither read nor delete its backups). Git history on the server
plus the backup are the copies; the vault is not pushed anywhere.

## Basic Memory notes from use

- The default semantic floor (`semantic_min_similarity` 0.55) hides every EmbeddingGemma result (its
  scores sit around 0.2-0.5). Measure with `--min-similarity 0` and lower it with `bm config set` if you
  use that model; the bootstrap does not change it for you.
- EmbeddingGemma wants task prefixes (`task: search result | query: ` / `title: none | text: `) and about
  1.1 GB RAM per process; a multilingual MiniLM is the light alternative.
- Lexical search folds `I→i` but not Turkish `ı→i` (FTS5 `unicode61`), so dotless-i words miss their
  upper-case forms; semantic search mostly compensates. Details and a fix plan in
  `server/hermes/skills/personal-memory-vault/references/`.
