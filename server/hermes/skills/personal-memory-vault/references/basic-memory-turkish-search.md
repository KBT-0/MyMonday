# Turkish search in Basic Memory 1.0

## Behaviour (unicode61 tokenizer, Basic Memory 1.0)

| Query | Stored | Text mode |
|---|---|---|
| `istanbul` / `ISTANBUL` | `İstanbul` | match |
| `isparta` / `ISPARTA` | `ISPARTA` | match |
| `ısparta` | `ISPARTA` | **miss** |
| `ışık`, `IŞIK`, `isik` | `Işık` | **miss** (only exact-case `Işık` hits) |
| `çalışma` vs `ÇALIŞMA` | each other | **miss** (each only finds itself) |
| `ev`, `evler`, `evlerimiz` | `Evlerimizden` | match (prefix queries) |

Semantic mode (EmbeddingGemma, floor lowered) ranks meaning queries and most ı-variants correctly;
hybrid with the default floor behaves like text mode.

## Normalizer for an upstream PR

Fold function (same on index and query side): Turkish lowercase (İ→i, I→ı), then ı→i, ş→s,
ç→c, ğ→g, ö→o, ü→u. Note Python `'İ'.lower()` yields `i` + U+0307 — map İ explicitly first.

Plug-in points in `basic_memory/`:
1. Index side — append a folded copy of content/title to `content_stems`:
   `services/search_service.py` (entity row build, `content_stems` list; `_generate_variants`) and
   `indexing/accepted_note_search.py` (`accepted_note_content_stems`, `search_text_variants`).
2. Query side — fold the term and OR it with the original:
   `repository/sqlite_search_query.py` `prepare_single_term` / `prepare_search_term`, and the
   Postgres twins in `repository/postgres_search_query.py`.
3. No schema change: tokenizer stays `unicode61 tokenchars 0x2F` (`models/search.py`), no migration,
   only a reindex. Gate it behind a config key (e.g. `search_locale_folding: ["tr"]`) in a new
   `text_normalization.py` module.
