---
name: reuse-first
description: Prevents duplicate functions, types, SQL queries, widgets and helpers across features. Use BEFORE writing any new function, method, struct, repository, middleware, query, Flutter widget, provider, model or utility, and when reviewing code for duplication or cleaning it up.
---

# Reuse-first protocol

Claude has no memory of the codebase between sessions. Duplicates appear when something is written without looking first. Follow this protocol every time; it is cheap compared to cleaning up duplicates later.

## Step 1: Read the catalogs (30 seconds)
- Backend (Go): `docs/code-map.md`
- Flutter: `docs/ui-catalog.md`
If a catalog does not exist yet, create it from the templates below and fill it by scanning the code.

## Step 2: Search by behavior, not just by name
Search with Grep/Glob for at least 3 variants: the exact name, synonyms, and the behavior.
- Names: `formatDate` -> also `timeAgo`, `relativeTime`, `humanize`, `prettyDate`
- Behavior: look for the same imports/calls (`time.Since`, `DateFormat`, `pgx.Rows`, `Dio(`, `showModalBottomSheet`)
- Types: check `internal/domain`, `pkg/`, `internal/platform`, `app/lib/core`, `app/lib/shared`, and the generated API client before defining any struct/model
- SQL: search `backend/**/queries/*.sql` (sqlc) for an existing query that selects the same data; extend with a parameter instead of a near-copy
- Widgets: search `app/lib/shared/widgets` and `app/lib/features/*/presentation` for similar layout (avatar, post card, empty state, error state, skeleton, button, sheet, dialog)
- Blocs/repositories: search for an existing bloc or repository for the same entity before adding another (state management is BLoC only)

## Step 3: Decide (in this order)
1. **Reuse as-is** if it fits.
2. **Extend** with a small, backward-compatible change (new optional parameter, new variant, new method). Update existing tests. Do not change the meaning of existing behavior.
3. **Generalize and move** if two features now need the same thing: extract it to the shared location, update all callers, run tests.
4. **Create new** only if nothing fits. State briefly why nothing existing fit.

Never copy-paste a block that already exists elsewhere.

## Step 4: Put new shared code in the right place
Go:
- Cross-cutting infrastructure -> `backend/internal/platform/` (http middleware, logging, config, db helpers)
- Pure reusable helpers with no domain knowledge -> `backend/pkg/`
- Domain logic -> its own `backend/internal/<domain>/` package; other domains use it through its exported interface, never its internals
- Infra access (cache, queue, search, storage, push, media) -> only through the ports; never call AWS/Valkey SDKs from domain code
Flutter:
- Reusable widgets -> `app/lib/shared/widgets/` (feature-specific ones stay in `features/<f>/presentation/`)
- Theme, spacing, colors, text styles -> theme tokens only; no hardcoded colors or sizes
- Networking, storage, routing -> `app/lib/core/`
- API models -> generated client only; never hand-write a model that the OpenAPI spec already defines

## Step 5: Update the catalog
Every new shared function, type or widget gets ONE line in the catalog in the same change. Removing or moving an item updates the line. A change that adds shared code without a catalog line is incomplete.

## Step 6: Report
End your work with:
```
Reuse report
- Reused: <item> (<path>), ...
- Extended: <item> - <what changed>, ...
- Generalized/moved: <item> - <from> -> <to>, callers updated: <n>
- Created: <item> (<path>) - why nothing existing fit
- Catalog updated: yes/no
```

## Anti-patterns to avoid
- Creating `utils2.go`, `helpers_new.dart`, `PostCardV2`, `AvatarWidget` next to `AppAvatar`
- A second date formatter, pagination helper, error mapper, HTTP client wrapper, retry helper or rate limiter
- A second SQL query that differs only by a filter or order
- A feature-local copy of a shared widget "to avoid touching shared code"
- Duplicating a model instead of using the generated API type
- Wrapping an existing helper just to rename it

## Reviewer checklist (code-reviewer, tester)
For each new function, type, query or widget in the diff: search for an existing equivalent. If found and not justified -> Blocker. Confirm the reuse report exists and the catalog was updated.

## Cleanup procedure (run every 2-3 features, or when asked)
1. Scan `backend/` and `app/` for duplicated or near-duplicate functions, widgets, models and SQL queries (grep for repeated signatures, run `jscpd`, and `golangci-lint` with `dupl`).
2. Group them and pick the canonical version (best tested, most general, best located).
3. Run the full test suite first and record the result.
4. Refactor callers to the canonical version in small commits; delete the duplicates.
5. Re-run all tests, `go vet`, `flutter analyze`. Behavior must not change.
6. Update both catalogs and report what was merged.

## Automated guards (infra-engineer adds to CI)
- Go: `golangci-lint` with `dupl` enabled (threshold ~100 tokens)
- Go + Dart: `jscpd` with a threshold (fail above ~3% duplication), ignoring generated files
- Flutter: `very_good_analysis` lints; custom lint or grep check for hardcoded `Color(0x` / `Colors.` outside theme files
- Go: import-boundary check so one domain cannot import another domain's internals

## Catalog templates

`docs/code-map.md`
```markdown
# Code map (backend). One line per reusable item. Keep sorted by area.
| Item | Location | Use it for |
|---|---|---|
| pagination.EncodeCursor / DecodeCursor | backend/pkg/pagination | opaque cursor pagination |
| httpx.WriteError | backend/internal/platform/http | standard error JSON |
| middleware.RateLimit | backend/internal/platform/http | per-user/IP rate limits (Valkey) |
| ports.Cache / ports.Queue / ports.Search | backend/internal/ports | infra access from domain code |
```

`docs/ui-catalog.md`
```markdown
# UI catalog (Flutter). One line per reusable widget/bloc/helper.
| Item | Location | Use it for |
|---|---|---|
| AppAvatar | app/lib/shared/widgets/app_avatar.dart | user avatar, all sizes |
| PostCard | app/lib/shared/widgets/post_card.dart | any post row |
| AppErrorView | app/lib/core/widgets/app_error_view.dart | typed, friendly error state |
| ApiClient | app/lib/core/network/api_client.dart | the one Connect-RPC client |
```
