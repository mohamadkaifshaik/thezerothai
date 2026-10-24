# Phase 0 code review — 2026-09-27

Reviewer: code-reviewer agent (read-only). Scope: all uncommitted Phase 0 bootstrap work (generated code excluded).
**Verdict: ready after blockers fixed.** Fix B1–B4 before any deploy; M1, M3, M5, M6 before the first prod tag.

## Blockers
| ID | Where | Issue | Fix |
|---|---|---|---|
| B1 | `backend/internal/apiserver/apiserver.go:100`, `firebase.json`, `app/lib/app/app_config.dart:84` | Hosting passes `/api/...` to Cloud Run unchanged; the mux only serves `/dzeroth.*` → every web call 404s | `http.StripPrefix("/api", …)` mount + e2e test via `/api` |
| B2 | `pkg/platform/config/config.go:116-146`, `modules/cloud-run-api/main.tf:92`, envs `secret_ids = []` | Terraform sets `GCP_PROJECT_ID` (config reads FIREBASE_PROJECT_ID/GOOGLE_CLOUD_PROJECT); `CURSOR_HMAC_KEY` required but never provisioned → container can't start | Set `FIREBASE_PROJECT_ID`; add `cursor-hmac-key` secret + `secret_key_ref` support in module |
| B3 | `deploy-dev.yml:66`, `release-prod.yml:163` | `ko build ./backend/cmd/api` from repo root: no go.mod there → build fails; `.ko.yaml` ignored | `working-directory: backend`, `ko build ./cmd/api` |
| B4 | `app_config.dart:67-84`, CI flutter builds | `USE_EMULATORS` defaults true; CI passes no dart-defines → deployed apps talk to localhost emulators | default `!kReleaseMode`; pass `USE_EMULATORS=false`, `API_BASE_URL`, `RECAPTCHA_SITE_KEY` from `vars.*` |

## Major
| ID | Where | Issue | Fix |
|---|---|---|---|
| M1 | `apiserver.go:84-86`, `authn/interceptor.go:138`, `identity/service.go` | Account-status lookup (1 Firestore read, not negatively cached) runs before rate limiting → profile-less signups can burn the daily read quota | Rate limit before account status (amend ADR-0006 §2) and/or ~10 s negative cache |
| M2 | `mw/mw.go:66,77` | Log line can't see `uid_hash`/`app_check_failed` (set on child ctx) → App Check monitor-mode metrics impossible | mutable `*requestInfo` in ctx filled by interceptors + test |
| M3 | `apierr.go:87`, `mw.go:34,83,104` | Unknown errors lose their cause; no `ReportedErrorEvent`, stack key `stack` → nothing in Error Reporting | log raw err in ErrorMapping with `@type`; `stack_trace` |
| M4 | `identity/service.go:200-214`, `repo_firestore.go:295-301` | ChangeHandle checks cooldown/no-op against instance cache; retry on another instance → HANDLE_TAKEN; case-only rename no-op | do checks in the transaction; own `handles/{new}` = success; case-only update |
| M5 | `release-prod.yml:140` | `${{ github.event.inputs.tag \|\| github.ref_name }}` interpolated in `run:` with prod WIF creds → script injection | pass via `env:` + semver regex |
| M6 | `modules/iam/main.tf:85,197,229`, `envs/prod/main.tf:26` | WIF only checks repo + `refs/tags/v*`; any writer can tag and run a modified workflow skipping approval gates; ci-deploy has `run.admin` | tag ruleset; pin `job_workflow_ref` + `environment`; `run.developer` |
| M7 | `Makefile:67-73` | `make ci` lacks `buf breaking`, 70% coverage gate, golangci-lint | add all three (`origin/main` baseline) |
| M8 | `cloud-run-api/main.tf:89-95`, `apiserver.go:107` | `APP_CHECK_MODE` unset → enforce everywhere (ADR says monitor); App Check API not enabled; `INTERNAL_OIDC_*` unset → `/internal/*` unauthenticated | set envs; enable API; fail closed when audience empty outside local |
| M9 | `release-prod.yml:253-258` | prod web deploy step silently skipped (no checkout/build) | checkout tag + flutter build web with defines |
| M10 | `Makefile:98-103`, `app_config.dart:84` | `make dev`: API on 8081 but app defaults to 8080 (Firestore emulator); no CORS for web | pass `API_BASE_URL`; local-only connect CORS middleware |

## Minor
- `repo_firestore.go:343` unread count query has no `Limit` (rule 5) → `.Limit(100)`, show "99+".
- `repo_firestore.go:205-211` "benign race" branch falls through to `Create` → AlreadyExists → Internal.
- `repo_firestore.go:263,312` whole-doc `Set` clobbers other modules' fields; UpdateProfile writes on no-op.
- `identity/service.go` GetProfile doesn't validate `user_id` (charset, ≤128).
- Handle rules differ: client 3–20, server 3–15 + reserved list; raw reason code shown in UI (`onboarding_bloc.dart:13,136`).
- `auth_bloc.dart:142-146` no `getIdToken(forceRefresh: true)` after verification → stale `email_verified` up to 1 h.
- App Check token errors not caught client-side (`interceptors.dart:43`) → all calls fail even in monitor mode.
- IAM: runtime project-wide `secretAccessor` (`iam/main.tf:25`); plan SA `roles/viewer` federatable from any branch (`:143`).
- Artifact Registry cleanup only deletes untagged; all images tagged → grows past 0.5 GB.
- `monitoring/main.tf:175` "5xx > 5%" alert is actually a rate (0.05/s).
- Supply chain: actions not SHA-pinned; `govulncheck@latest`, `firebase-tools@latest`, BSR plugins unpinned.
- No CSP header in `firebase.json`.

## Nits
Unimplemented message leaks roadmap (`identity/server.go:143`); bio length pre-trim, no NFC (`validate.go:44`);
duplicate procedure-set helper (`authn.ProfileExemptProcedures` vs `degraded.NewProcedureSet`); ratelimit first-bucket
race; all `unavailable` mapped to DegradedModeException; `AppDatabase.clearAll` never called on sign-out; no
`http.Server.IdleTimeout`; cursor not bound to query/owner, no expiry.

## Verified OK
Interceptor order per ADR-0006; local token verification, no caller-supplied uid; CreateProfile 2R/3W, replay 1R/0W;
budget counters match proto comments + cost model; deny-all Firestore rules, storage rules single-object `get` on
`*-media` only; 8 s shutdown; Cloud Run min 0/max 3/cpu-idle/512Mi; no fixed-cost resources; budget thresholds;
Pub/Sub DLQs; 1 Scheduler job.

## Resolution — 2026-09-27
All blockers (B1–B4) and majors (M1–M10) fixed and verified by a re-review; the re-review's new findings are fixed too:
N1 (release-prod.yml didn't parse), N2 (WIF display names over 32 chars), N3 (Flutter web cached as immutable),
N5 (panics unlogged), N6 (web built after the traffic shift), N7 (release dispatch input), N8 (`make dev` on Windows) and N9 (`-race` without cgo).
golangci-lint is now enforced in CI (pinned to v1.62.0). Its SA1019 findings are resolved: h2c is now stdlib `http.Protocols`, and WriteBatch is annotated because it is still the only atomic batch.
ADR-0006 §2 is amended with the new interceptor order.

Verified locally:
- `make ci`: exit 0 (fmt, vet, unit tests, 81% coverage on `pkg/platform`, buf lint/breaking, golangci-lint, flutter analyze, 58/58 flutter tests).
- `make test-int` against the emulators: exit 0, 87.4% combined coverage on `internal/`.
- actionlint: clean.
- `terraform validate`: dev and prod both pass.
- `-race` runs only on the Linux CI runner, because this machine has no cgo.

Still open:
- The minor items from the first review that are not listed above.
- N4, the 10 s cross-instance negative cache (accepted as is).
- The CSP is report-only until tested against real sign-in.
- `TRUSTED_PROXY_HOPS` needs measuring in dev.
- The Terraform plan account still has `roles/viewer`.
