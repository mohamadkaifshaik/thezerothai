# Subscription integration

## Security audit fixes (2026-11-12)

New article publication now fails closed when its server-injected subscription
verifier is absent, including dev/prod with sales disabled. Completed publication
replays remain readable after expiry or billing shutdown. The transaction checks
that an unverified replay is still published; a deleted/recreated draft with the
same ID and revision cannot inherit the old article's exemption. Verification
stays outside Firestore transaction retries. No schema migration is required.

Webhook recovery now receives up to 15 seconds within the existing 28-second cron
budget. It requires at least 12 seconds before starting each provider readback
(10-second HTTP timeout plus storage margin), does not advance the cursor for
unstarted work, and fails promptly when another recovery holds the process lock.
The daily-maintenance chain no longer attempts billing recovery under its shorter
10-second step budget. The five-minute cron and authenticated 20-second operator
route remain. The original sweep response and overall request limit are preserved.

CI and release workflows now pin Go 1.26.11, which includes the net/http security
fix for GO-2026-6859. The patched toolchain was downloaded and selected locally;
the installed launcher delegates to 1.26.11 through the Go toolchain setting.
The Go module's language minimum and application dependencies are unchanged.

Regression coverage includes an unconfigured publisher, a replacement draft
reusing the completed replay's ID/revision/key, completed reads with billing off,
Firestore-backed replay replacement, recovery deadlines and overlapping recovery.
Deployment/store setup remains pending; these changes do not build/push images or
change production traffic.

Validation on Go 1.26.11: unit suites for articles, billing, apiserver, posts/text
and config pass; full-backend `go vet ./...` passes. Firestore-backed subscription
gate/replacement-replay, binding erasure, and webhook durability/fencing tests pass
against the isolated demo-dzeroth-local emulator. Workflow actionlint, Go formatting
and `git diff --check` pass. `govulncheck ./...` exits successfully with zero affected
code vulnerabilities and zero vulnerable imported packages. It still notes
GO-2026-5932 for the unimported OpenPGP package within required x/crypto v0.58.0;
this backend does not use OpenPGP. No unrelated dependency change was made.

`make ci` and `make test-int` still abort before running checks with Windows native
error 0xC0000008. The CI shell fixture command also exits 1 without test output.
These gates/coverage thresholds are not claimed clean; targeted checks above were
run directly. The temporary Firestore emulator was stopped after validation.

## Article entitlement enforcement and approved draft storage bound

Local enabled billing sandbox now injects a verified Premium authorization check
into article publication. It reads the authenticated owner's binding and current
provider snapshot, denies Free/Plus, and reports verification outages as unavailable.
No audience/block predicates change. A rejection happens before draft freezing or
root-post creation. An already completed matching publication replay remains a
read and survives subscription expiry. Reading/deleting owned articles and working
with drafts retain their existing rules. Non-sandbox behavior is unchanged.

The founder separately approved raising device-local draft text storage from
2,000 to 15,000 code points while retaining the 50-draft count. Added a regression
for saving 15,000 emoji code points without truncation. Posting itself remains
280 code points until composer, request policy and scheduling are coordinated.

Articles, billing and API-server unit suites pass. All 25 draft repository tests
report passed; the Flutter native process then returns invalid-handle status
0xC0000008, so this is not a clean command-exit result. Stable Go build cache for
local verification: `C:\Users\skmk1\.cache\dzeroth-go-build`; the default otherwise
resolves to a sandbox-specific directory and repeatedly recompiles dependencies.
Emulator launch was retried and still exited before any integration test evidence.
Targeted Dart analysis and whitespace checks pass. `make ci` was retried after
these changes and still aborts before checks with native invalid-handle status
0xC0000008. No clean full-CI or native sandbox-purchase result is claimed.

## Failure fixes and local sandbox RPC continuation

Identified all five full-suite failures from a saved JSON/text report: one route
scanner mistook Premium import paths for navigation; three static-shell guards
still included the now-integrated Premium feature; one fixed-date guard rejected
two new fixtures. The route scanner ignores import/export/part lines, static
checks still cover every remaining static feature, and subscription fixtures use
one captured/injected time. The focused guards/Premium rerun passed all 90 tests.
Targeted Dart analysis has no issues. The earlier full run reproduced exactly the
five failures before these fixes; a post-fix full-suite pass is not claimed.
Billing, configuration and API-server Go package tests pass after the lifecycle
coverage updates. Saved diagnostic evidence is under the ignored local directory
`docs/subscription-validation-20261112/`.

Added owner-only BillingService handlers and registered them through the existing
full Connect interceptor chain. Billing bindings/projections and reverse mappings
are registered for paired erasure and minimal private-ID-free export regardless
of sandbox enablement; lifecycle coverage rows document both collections.
Added local-only secret-backed configuration and sandbox checkout availability.
`BILLING_SANDBOX_ENABLED=true` requires `ENV=local` and a server secret API key;
it is rejected in dev/prod. Disabled configuration cannot allocate identities or
enable checkout. Local enabled mode verifies `monthly` / `test_store` /
`dzeroth_pro` through current provider state on each status refresh.

This is manual-refresh Test Store wiring, not production billing rollout.
Durable webhook dispatch, production configuration and paid-post/article
enforcement remain pending. Test Store purchases do not demonstrate those
capabilities. Founder chose SDK fallback UI for checkout; the custom paywall
stays unpublished and Terms stay local for review.

### Local sandbox run (normal terminal, no secret in chat or files)

From repository root in PowerShell, set the server key without echoing it:

```powershell
$env:ENV = 'local'
$env:PROJECT_ID = 'demo-dzeroth-local'
$env:BILLING_SANDBOX_ENABLED = 'true'
$billingSecret = Read-Host 'RevenueCat secret API key (not the test_ SDK key)' -AsSecureString
$env:REVENUECAT_SECRET_API_KEY = [System.Net.NetworkCredential]::new('', $billingSecret).Password
& 'C:\Program Files\Git\bin\bash.exe' scripts/with-private-tmp.sh firebase emulators:exec --only auth,firestore,pubsub,storage --project demo-dzeroth-local 'go -C backend run ./cmd/api'
# After stopping the server, clear the key from this terminal's environment.
Remove-Item Env:REVENUECAT_SECRET_API_KEY
```

In a second terminal, select an Android emulator when prompted:

```powershell
Set-Location app
flutter run --dart-define=USE_EMULATORS=true --dart-define=AUTH_EMULATOR_HOST=10.0.2.2:9099 --dart-define=API_BASE_URL=http://10.0.2.2:8081 --dart-define=REVENUECAT_PUBLIC_API_KEY=test_VzVxsDKkeDorBmgYvoXAygIJexv
```

Use only a demo-emulator account, complete onboarding, open Premium, and test
fallback checkout, cancellation, purchase, refresh to verified Premium, restart,
sign-out/account switch and restore. Do not test with real accounts. The backend
needs internet access to RevenueCat; Auth/Firestore remain demo emulators.

For persistence validation from repository root:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' scripts/with-private-tmp.sh firebase emulators:exec --only firestore --project demo-dzeroth-local 'go -C backend test -tags=integration ./internal/billing -timeout 120s'
```

The agent environment's Git Bash emulator-launch attempt still exits before
startup. A normal-terminal emulator run and a device Test Store transaction are
required evidence before calling this end-to-end validated.

## App startup and Premium route wiring

Bootstrap now constructs the concrete Connect/RevenueCat repository when
`REVENUECAT_PUBLIC_API_KEY` is supplied. AppWidget owns/provides the Cubit, starts
it after onboarding has claimed the session cache, and registers sign-out/direct
account-switch clearing with AccountSessionReset. The Cubit is closed with the app.

The existing Premium route now displays billing status, localized provider prices,
server-gated native paywall, restore/refresh and native Customer Center actions
when configured. Without billing configuration it retains the coming-soon screen.
Web does not expose native paywall/Customer Center calls. Successful hosted UI
still waits for backend verification and cannot grant API permissions.

Targeted app/Premium/auth-session checks passed (82 tests), and the new app-level
billing onboarding/sign-out regression passed separately. Targeted Dart analysis
passes. Full Flutter validation was attempted separately; see its final result
below before claiming broad validation. Make CI remains unable to start because
the executable throws native invalid-handle error 0xC0000008. Live backend billing
RPC registration, durable webhook dispatch and paid feature enforcement are still
pending; until those ship, configured clients may show subscription unavailable.

Full Flutter run result: 11,776 passed, 5 failed, exit 1. Failure identities were
not retained in the truncated compact-reporter output; they remain untriaged and
must not be described as pre-existing or unrelated without reproduction. The
standalone new lifecycle regression reported its assertion passed, but that
process returned exit 1 after reporting success (the known native shutdown-status
discrepancy). The earlier combined 82-test run returned exit 0. No device sandbox
purchase, native app build, deployment or complete CI pass is claimed.

## Terms draft and hosted billing UI

Added `app/web/terms.html` as a local review draft for Dzeroth, India. It includes
user content, conduct, subscription renewal/cancellation/refund terms and preserves
mandatory consumer rights. Operator identity/address, support details and effective
date require completion. Founder selected local review, so it has not been deployed.
The unpublished RevenueCat paywall draft now points its Terms action to the intended
URL `https://dzeroth.com/terms.html` with label `Terms (draft)`; this is not a live URL
claim. Paywall id: `pwb8cf275b03994dbc` in project `proj2679c219`.

The installed UI SDK now has concrete native paywall and Customer Center gateway
methods and serialized repository operations. Checkout rechecks server sales,
validates monthly package products and preserves uncertainty after ambiguous
failures. Management stays available with sales disabled. Existing 49 Premium
tests passed; the repository suite with three added hosted-UI regressions also
passed (10 tests). Native render/purchase validation, live app route/bootstrap
wiring, billing RPC registration and paid feature enforcement remain incomplete.

## dzeroth_pro Test Store configuration

Founder selected `dzeroth_pro` as an additional Premium entitlement, retaining
Plus. Go policy and provider product validation accept that identifier; existing
`premium_access` remains supported. Flutter gateway has a build-time public-key
factory mapping `monthly` to Premium, customer info retrieval and a provider-only
Pro entitlement check. Android activity now derives from FlutterFragmentActivity
for native paywalls, preserving notification initialization.

The complete Pub/dashboard/Flutter sample is in REVENUECAT_FLUTTER_SETUP.md.
`purchases_ui_flutter` installation was rejected before execution by the session
approval policy. Native paywall/Customer Center code is provided as a sandbox
guide, not compiled or wired into production. Core billing unit tests and targeted
vet pass. Native build validation and full production wiring remain outstanding.

## Provider readback and reconciliation continuation

Added a bounded, timeout-controlled RevenueCat REST readback adapter with
redirect rejection, generic/redacted errors, explicit product/store/environment
validation, refund exclusion, expiry/grace intervals and private-owner checks.
Unknown or malformed provider responses cannot become confirmed Free status.
Alias/transfer adoption remains disabled pending its ownership policy.

Added a reconciliation coordinator and Firestore generation-fenced snapshot
commits on private binding documents. Transactions recheck active account,
forward/reverse ownership and generation. Existing paired binding erasure removes
the projection too. Added provider/coordinator unit cases and an emulator case
for older generation rejection. These remain unregistered; durable event inbox,
worker dispatch, lifecycle registration, billing RPCs and paid feature enforcement
are still outstanding.

Provider tests and targeted vet passed. The isolated emulator execution attempt
failed before startup because Git Bash could not create its MSYS Windows object
(NtCreateDirectoryObject, access denied 0xC0000022). Firestore generation behavior
is therefore not yet validated against the emulator. Founder selected RevenueCat
Test Store setup as the next external sandbox task.

## Installed SDK and concrete adapters

The founder installed `purchases_flutter` 11.0.1. Added an unregistered
`RevenueCatPurchaseGateway`: private identity configuration, configured monthly
product allowlist, current-offering package handles, localized prices, cancellation
and pending-payment mapping, native restore and Web customer refresh. SDK results
never grant server access. Added `ConnectSubscriptionStatusSource` through the
shared authenticated ApiClient, with owner rechecks and conservative enum mapping.
Both adapters remain unregistered pending backend processing and lifecycle wiring.

Adapter tests cover rejecting public identities, preventing anonymous SDK setup,
same-owner initialization and rejecting invented offerings. Targeted Dart analysis
passes. All 49 Premium tests report passed; the process still returns exit 1,
so the native shutdown-status issue remains. Scoop Make 4.4.1 downloaded successfully but junction/shim creation was
denied; direct executable invocation also failed with native invalid-handle status
0xC0000008 before CI ran. This is not passing CI evidence.

## Execution update: 2026-11-12

The founder selected longer posts and Premium articles for the first paid
release, deferring the remaining proposed benefits. Merchant accounts and
store products are not configured yet. Required SDK/test dependency installation
is approved, but `flutter pub add purchases_flutter` was rejected by the execution
policy because native approval prompts are disabled.

Generated billing Go and Dart files are now present in the working tree; earlier
statements below that generation is pending are historical, not current inventory.
Their reproducibility and compatibility checks remain outstanding.

Added `NewSignedWebhookHandler` with bounded raw-body HMAC verification,
timestamp freshness checks and strict signature-header parsing. Tests cover valid
delivery, altered bytes, old/future signatures, duplicate fields and missing
authorization. The handler remains unregistered; durable storage and reconciliation
are still prerequisites. This addition does not complete the integration.

Validation: automatic formatting ran on the new Go files. `make ci` failed to
start because the installed make executable encountered a Windows system DLL
relocation error. The isolated webhook/signature Go tests passed. The full billing
package test attempt was stopped without a result; full-package validation and
release readiness remain outstanding.

Local-blocker retry on 2026-11-12: the full billing package unit tests and
`go vet ./internal/billing` now pass with installed dependencies. SDK installation
is still rejected because native approvals are disabled. GNU Make still fails
to start with a Windows DLL relocation error. `flutter test --no-pub
test/features/premium` exited 1 without diagnostics, so Flutter behavioral
validation remains unresolved.
Direct Dart analysis of `lib/features/premium` and `test/features/premium`
passed with no issues. Tracked diff whitespace checks also passed.

Diagnostic investigation on 2026-11-12: `cmd /d /c` running the pinned Flutter
test command reached all 47 Premium tests and reported `All tests passed!`.
The execution result nevertheless returned exit code 1; this is an unresolved
launcher/shutdown status discrepancy, not evidence of a failing test assertion.
Flutter version output confirms 3.47.5 / Dart 3.13.4. SDK installation is rejected
before execution by the approval policy, so no RevenueCat dependency-resolution
or compatibility failure has been demonstrated. The installed Make is GnuWin32
3.81, PE machine 0x014C (32-bit); Windows rejects startup with Illegal System DLL
Relocation before reading the Makefile. The exact conflicting DLL was not exposed
by the loader message. A supported replacement Make executable is needed; changes
to the application Makefile cannot fix this loader failure.
A direct Dart invocation of the Flutter tool printed its version then returned
native status -1073741816 (0xC0000008, invalid handle). This narrows the shutdown
investigation to the native process/runtime or execution environment; the exact
offending handle and the relationship to the test runner exit remain unproven.

Status: **foundation only; purchases are disabled and no billing routes are registered**.

The founder selected preparation of both monthly tiers: Plus INR 235 and
Premium INR 850. These remain informational India prices. Actual localized
purchase prices must come from the storefront/checkout provider. Neither
planned tier is purchasable in this change.

## Implemented foundation

- `backend/internal/billing/` defines provider and binding-store seams, opaque
  random billing identities, environment/owner checks, verified entitlement
  expiry/freshness evaluation, Premium inheritance, per-feature availability
  and a non-purchasable planned catalog.
- `app/lib/features/premium/` adds server-access models, a repository contract
  and a session-epoch-aware Cubit. Pending/verifying purchases cannot grant
  client access or offer a duplicate purchase. Restore remains available while
  sales are disabled. The Cubit is not yet wired into the live app.
- `proto/dzeroth/billing/v1/billing.proto` specifies owner-only subscription
  status, plan availability and idempotent private billing identity allocation.
  Generated clients and handlers remain pending because Buf execution was
  denied by this environment. No existing service contract was modified.

No existing Free quotas, post validators, privacy checks, badge booleans,
Firestore rules/indexes, feature ceilings, dependencies, native configuration
or CI/deployment configuration were changed. The Firestore binding implementation is present but unregistered and awaiting
emulator validation; subscription projection/event storage is still pending. The current Premium dialog remains
the existing coming-soon experience, without a checkout action.

## Verification

The initial foundation billing Go tests passed with 96.4% package statement coverage; the policy,
catalog and binding validation functions have full coverage. Targeted Go vet
and full-app Dart analysis pass (the latter used the installed Dart executable
directly, without invoking Flutter SDK-cache setup). Test cases cover stale/expired/mismatched
entitlements, unknown grants, concurrent identity allocation, account switches,
pending payment, delayed verification and restore while sales are off.

Flutter behavioral tests were written but could not execute: the installed
Flutter SDK cache lockfile is inaccessible in the sandbox. RevenueCat SDK
installation was approved by the founder, but the execution policy rejected
the installation because its native approval prompt is unavailable. Buf lint
and generation both returned access denied. These are unresolved validation
and integration prerequisites, not passing checks.

The full Go unit suite and broad `go vet ./...` passed during `make ci`.
The platform coverage gate passes at 89.1% (70% requirement) when rerun with
Git Bash and the workspace-local Go cache. The original make target stopped
when its shell script resolved `bash` to an inaccessible Windows launcher;
full CI did not pass. The CSP script was also attempted separately and blocked
by access denied to the installed jq executable. Local CGO is disabled, so the race
detector was not run. The installed Go toolchain is 1.27.0; CI pins 1.26.10
and that exact toolchain was not installed or downloaded here.

`golangci-lint` also failed before analysis because it could not resolve the
working-directory path under the sandbox. No new storage implementation was
added, so emulator persistence tests are deferred with that implementation.
New files were independently checked for whitespace because they are not yet
staged and `git diff --check` alone does not inspect untracked files. No release
readiness verdict or deployment is implied by this foundation.

## Next execution slice

1. Restore permitted SDK-cache/tool execution and generate both billing clients
   using the existing pinned Buf configuration; do not hand-write generated
   code. Resolve the approved RevenueCat SDK dependency and native lockfiles.
2. Implement private binding persistence with active-account checks, uniqueness,
   deletion/export lifecycle and emulator integration tests before registering
   the identity RPC. Bind to the authenticated caller, never an arbitrary UID.
3. Implement provider readback, durable authenticated webhook intake,
   reconciliation, fencing and environment/product validation with failure tests.
4. Register the owner Connect service through the full protected interceptor
   chain and provider callbacks through their separately reviewed route class.
5. Wire the concrete repository/Cubit through existing bootstrap/auth/session
   reset seams; use supported platform purchase/restore operations. The Web
   SDK does not support native `restorePurchases`/`purchaseProduct` operations.
6. Enforce and validate each advertised benefit server-side before enabling
   sales. Keep current Free limits until their separately reviewed transition;
   do not automatically raise scaling ceilings to meet a plan's target.
7. Complete provider/store sandbox, native build and rollout evidence. Paddle
   seller/product eligibility and actual store products remain external gates.

The detailed proposed architecture and file coverage ledger are saved locally
under `docs/` (ignored by this repository). Foundation approval is not merchant
approval, a production sale enablement, or deployment authorization.

## Persistence and webhook follow-up

Added an unregistered Firestore binding repository with transactional active-account
checks, forward/reverse uniqueness checks, idempotent lookup, minimal owner export
and paired erasure. Added an emulator integration case for replay, deletion status
and export privacy. Lifecycle methods must be registered before exposing the RPC.

Added an unregistered webhook HTTP handler with bounded bodies, constant-time
Authorization verification, explicit app/environment scope and a durable-inbox
interface. It grants no access. Signed webhook verification, the concrete durable
inbox/outbox and reconciliation worker are still required before route registration.

SDK installation and Buf generation were retried under the existing approval:
installation was again rejected by the execution policy (native approvals disabled),
and Buf still returned access denied. No SDK dependency or generated output was
manually substituted. Firebase CLI was not found; emulator validation remains
unexecuted rather than treating an integration-test skip as a pass.

Follow-up validation: billing unit tests and targeted vet passed. The
emulator-tagged suite compiled; its Firestore case explicitly skipped without
FIRESTORE_EMULATOR_HOST. The earlier foundation coverage is not a measurement
of the subsequently added Firestore implementation.

The follow-up make ci attempt was interrupted after remaining in the formatting stage without further output. It is not a passing CI result.

## Client repository continuation

Added the unregistered `ServerSubscriptionRepository` and explicit server-status
and purchase-gateway interfaces. All gateway operations share one queue, including
across account resets. Session generation, shared epoch and current owner checks
reject stale work before subsequent SDK calls. Purchase attempts recheck server
availability and accept only offerings loaded in the current session. Successful,
pending or ambiguous SDK results cannot grant access or initiate another checkout
until server verification; restore remains available with sales disabled.

The SDK adapter must use the server-issued private billing identity, map only
configured products and use customer refresh on Web instead of native restore.
The repository remains unregistered; concrete RevenueCat and generated Connect
adapters, provider processing and lifecycle registration are still outstanding.
Purchase uncertainty is currently an in-memory guard, not a durable cross-device
deduplication mechanism. It does not replace the backend reconciliation work.

Seven repository regression tests cover disabled sales, server rechecks, duplicate
checkout prevention, ambiguous failures, wrong ownership, epoch invalidation and
serialization through account switches. Targeted Dart analysis passes with no
issues; formatting and whitespace checks pass. Flutter tests could not start due
to the SDK cache lockfile, and the escalated attempt failed during execution-helper
approval setup. Tests are written but not validated by execution.

Buf 1.73.0 can print its version, but lint, breaking checks and generation still
return access denied; escalated lint and generation fail the same way. The
previously approved `flutter pub add purchases_flutter` attempt was stopped after
no output, and its escalated retry failed during execution-helper setup. No
dependency or generated-client changes were made. The next `make ci` attempt again
stalled at formatting and was interrupted; it is not a passing check.
## Longer posts and production webhook processing (2026-11-12)

Local sandbox publishing now supports Free 280, Plus 3,000 and Premium 15,000
NFC code points. New long content requires provider-verified access. Completed
create/schedule replays survive downgrade. Create, schedule, edit, Post now and
automatic publication share the parser; publication rechecks access. Confirmed
over-limit scheduled content becomes INVALID_CONTENT under the existing terminal
draft policy. Verification outages follow existing bounded transient retries.
Scheduled publication checks the snapshot update time to avoid stale edits.
Ten-line, mention, hashtag, audience and scheduling-count limits are unchanged.

Composer, reply and thread-footer counters use account-scoped server access,
react to policy changes/expiry and recheck before submit. Unknown/stale access
uses 280. Downgrades preserve text. Input and local drafts support the approved
15,000-code-point cap. Production checkout/identity allocation remain disabled.

Production callback code is opt-in through BILLING_WEBHOOK_ENABLED=true in dev
or prod. POST /webhooks/revenuecat also works under /api. Its dedicated route
class requires Authorization, raw-body HMAC, a five-minute signature window,
256 KiB body limit and app/PRODUCTION allowlists. Intake/readback has a 15-second
deadline; failures return 503 for retry. Events never directly supply grants.
Known private IDs, aliases and transfer participants trigger current provider
verification; unknown/deleted identities cannot allocate bindings. Aliases or
transfers that fail strict provider identity matching require support review.

Pending work, a webhook version and 64 hashed event receipts live on the existing
billingCustomers document. Intake atomically fences older verification and clears
its projection. Version checks prevent lost pending work; duplicate retained IDs
are harmless and conflicting payloads fail closed. Older IDs outside the bounded
ring may trigger another safe readback. Raw payloads/alias lists are not stored.
Paired erasure removes this metadata. Private IDs/operational receipts remain
excluded from export. No index, TTL, migration, security-rule or IAM change.

Recovery shares the existing five-minute publish/outbox cron and daily maintenance
budget. Bounded pagination advances past failed items. OIDC-protected
POST /internal/cron/billing-webhooks runs an operator recovery batch. Read-only
mode returns 503 without modifying records. Monitor billing_webhook_recovery
retry_pending/skipped_deadline and RevenueCat delivery failures before rollout.

Required deployment inputs, supplied through reviewed configuration and Secret
Manager references (never commit secret values):

- REVENUECAT_SECRET_API_KEY: server key; public test_ key is rejected.
- REVENUECAT_WEBHOOK_AUTHORIZATION: exact dashboard header, at least 32 characters.
- REVENUECAT_WEBHOOK_SIGNING_SECRET: HMAC secret, at least 32 characters.
- REVENUECAT_WEBHOOK_APP_IDS: reviewed production app IDs, comma separated.
- REVENUECAT_PRODUCTS_JSON: product-ID map containing Store and Entitlement.
  Example shape: `{"your.monthly.product":{"Store":"app_store","Entitlement":"dzeroth_pro"}}`.
  Only app_store/play_store and the reviewed paid entitlements are accepted;
  Test Store products are rejected by this production configuration.

Enable HMAC and match Authorization/app/environment filters in RevenueCat after
deployment validation. Coordinate signing-secret rotation with server configuration.
No deployment or dashboard webhook integration has been created. Terms and custom
paywall publication remain pending. Protocol checked against the
[RevenueCat webhook documentation](https://www.revenuecat.com/docs/integrations/webhooks).

Go unit tests and targeted vet pass. Billing/posts/articles Firestore integration
suites pass against isolated demo-dzeroth-local. Focused Flutter composer/draft
tests pass 48 assertions. Full-suite final results are recorded below. GNU Make
still aborts before CI with native invalid-handle 0xC0000008. Direct installed
Firebase CLI launch with private TEMP/TMP/TMPDIR succeeded after Git Bash failed.

Final Flutter run: all 11,785 tests report passed in the terminal run (16m22s).
The native process exits 1 after its all-passed report; the earlier pipe-based
attempt aborted with 0xC0000008 before producing a report. Full CI is therefore
not claimed clean. Targeted Dart analysis reports no issues. The follow-up
Firestore webhook regression also passes revocation and newer-event fencing.
Dev rollout review is in REVENUECAT_DEV_ROLLOUT.md. The selected next store is
Google Play, package com.dzeroth.dzeroth. RevenueCat still has only Test Store
and monthly. The user confirmed the Play Console app has not been created;
production catalog and secret resource references are pending. No real store
app/product or webhook was created. Final unit/vet reruns and the repeated
Firestore webhook regression exit successfully. Local Go is 1.27.0; the pinned
CI toolchain was not installed or changed. No coverage-threshold/full-CI claim.

