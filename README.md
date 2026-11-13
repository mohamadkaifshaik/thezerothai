# Dzeroth

Dzeroth is a text-first social app: posts, replies, a timeline, direct messages, communities, lists, articles,
beacons (plans) and moderation. This repository is a monorepo with a Go backend, a Flutter client, protobuf
contracts and the Terraform that runs it on Google Cloud.

## Layout

| Path | What it is |
|---|---|
| `proto/dzeroth/<pkg>/v1/*.proto` | API contracts (buf v2). Every RPC shape is defined here. |
| `backend/cmd/api` | The single HTTP server: Connect-RPC handlers, `/health`, internal Pub/Sub push and cron endpoints. |
| `backend/cmd/opsctl` | Operator CLI (backfills, moderation levers, trends). |
| `backend/internal/<module>` | Domain modules (identity, graph, posts, timeline, engagement, media, notifications, search, moderation, messaging, communities, lists, articles, beacons, apiserver). Each module owns its Firestore collections; other modules call it only through its `api.go`. |
| `backend/pkg/platform/*` | Shared infrastructure (config, feature flags, auth, errors, cursors, idempotency, rate limits, storage, logging). |
| `backend/gen`, `app/lib/gen` | Generated Go and Dart code. Do not edit by hand; regenerate with `make proto`. |
| `backend/e2e` | Smoke tests against a running API and the emulators. |
| `app/` | Flutter client (web, Android, iOS). See `app/README.md`. |
| `firebase/` | Firestore and Storage rules, index definitions. |
| `infra/terraform/` | Google Cloud infrastructure for the `dev` and `prod` environments. |
| `scripts/` | Dev helpers, CI helpers and the fail-closed promotion validators (`scripts/promotion/`). |
| `loadtest/` | k6 load scenarios (emulators only). |
| `releases/` | Per-release readiness records. |
| `testdata/` | Fixtures shared by the Go and Dart tests. |

## Environments

- **local**: Firebase Emulator Suite with project `demo-dzeroth-local` (Firestore 8080, Auth 9099, Pub/Sub 8085,
  Storage 9199, Emulator UI 4000) and the API on port **8081**.
- **dev**: Google Cloud project `dzeroth-dev`. Every merge to `main` runs `deploy-dev.yml`, which is a dry run
  unless the repository variable `DEV_PROMOTE` is `true`.
- **prod**: Google Cloud project `dzeroth-prod`, deployed from version tags.

## Prerequisites

Go (version in `backend/go.mod`), Flutter (version pinned in `.github/workflows/ci.yml`), the Firebase CLI,
`buf`, `make`, and a POSIX shell (Git Bash on Windows). `golangci-lint` and `shellcheck` are optional locally.

## Run it locally

```
make dev
```

starts the emulators, the API on port 8081 and the Flutter web app in Chrome (`scripts/dev.sh`). To run the
pieces separately:

```
make emulators                       # Firebase emulators (firestore, auth, pubsub, storage)

# in a second terminal: the API, pointed at the emulators
cd backend
FIREBASE_PROJECT_ID=demo-dzeroth-local PORT=8081 \
  FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
  PUBSUB_EMULATOR_HOST=127.0.0.1:8085 STORAGE_EMULATOR_HOST=127.0.0.1:9199 \
  go run ./cmd/api

# in a third terminal: the app
cd app && flutter run -d chrome --web-port=7357 \
  --dart-define=USE_EMULATORS=true \
  --dart-define=API_BASE_URL=http://127.0.0.1:8081 \
  --dart-define=AUTH_EMULATOR_HOST=127.0.0.1:9099
```

`make dev` sets the emulator variables for you (it runs the API inside `firebase emulators:exec`). See
`app/README.md` for the Windows PowerShell variant and notes on mobile builds.

## Make targets

| Target | What it does |
|---|---|
| `make ci` | `fmt vet test buf-check lint flutter-analyze flutter-test`: what the pull request check requires. |
| `make fmt` / `make vet` / `make test` | gofmt check, `go vet`, Go unit tests with a coverage gate on `backend/pkg/platform`. |
| `make lint` | `golangci-lint` (skipped if not installed). |
| `make buf-check` | `buf lint` and `buf breaking` against `origin/main`. |
| `make proto` | Lint, check for breaking changes and regenerate Go and Dart code. Commit the generated diff. |
| `make flutter-analyze` / `make flutter-test` | `flutter analyze` (plus the CSP loader-hash check) and `flutter test`. |
| `make emulators` | Start the Firebase emulators. |
| `make test-int` | Go integration tests against the emulators (build tag `integration`). |
| `make dev` | Emulators, API and Flutter web together. |
| `make loadtest SCENARIO=<name>` | Run `loadtest/<name>.js` with k6. |

## Feature flags

New public RPCs sit behind a `FEATURE_<NAME>` setting, with optional `FEATURE_<NAME>_ALLOWLIST` and
`FEATURE_<NAME>_PERCENT`. Flags are declared in `backend/pkg/platform/config/config.go` and capped per
environment in `scripts/promotion/flag-ceiling.json`. The client shows UI only for features the server reports
as enabled.

## Tests

- Go unit tests: `cd backend && go test ./internal/posts/...`
- Go integration tests (emulators running): `cd backend && FIREBASE_PROJECT_ID=demo-dzeroth-local go test -tags=integration ./internal/posts/`
- Dart tests: `cd app && flutter test test/features/posts/`
- Repo guards: `cd app && flutter test test/guards` and `bash scripts/promotion/test/run.sh`

On slower Windows machines, a complete Go test package can exceed the default
10-minute limit. Run the validation suites sequentially in Git Bash and, when
needed, increase the package limit for the local invocation:

```bash
GOFLAGS="${GOFLAGS:+$GOFLAGS }-timeout=20m" make ci
GOFLAGS="${GOFLAGS:+$GOFLAGS }-timeout=20m" make test-int
```

These overrides leave CI's existing limits and sharding unchanged. Prefer the
whole `make test-int` target on native Windows: the repository-wide test-name
filter used by integration shards can exceed Windows' command-line length limit.

After changing a freezed, json_serializable or drift class run `cd app && dart run build_runner build -d`.

## Release flow

1. Merge to `main`: CI runs and `deploy-dev.yml` deploys to dev (or performs a dry run, see above).
2. Add `releases/vX.Y.Z-readiness.md` containing the line `VERDICT: GO` (see `releases/README.md`).
3. Tag `vX.Y.Z`: the release workflow builds and deploys a zero-traffic candidate to prod.
4. A human runs the `promote-prod` workflow to move traffic. The promotion scripts in `scripts/promotion/`
   validate flags, traffic shape and the rollback target, and fail closed.

Infrastructure changes go through `infra/terraform/`: plans run in CI and are applied by a human.

## Contributing

Branch as `feat/<slug>`, `fix/<slug>`, `chore/<slug>`, `docs/<slug>` or `test/<slug>`; use conventional commit
titles such as `feat(posts): ...`; one concern per pull request, squash-merged. Never put secrets in the repo:
configuration is environment variables and secret-backed values come from Secret Manager.
