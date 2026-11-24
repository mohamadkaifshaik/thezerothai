# Dzeroth production readiness review

Reviewed local commit `127d28c2` on 2026-11-24. The checkout contained 3,870 tracked files. The local tracking ref for main was two commits ahead. This review covers the checkout and uses the November 23 audit's remediation table as the baseline. Untracked scratch material was excluded.

## Remediation in this checkout

All six findings below have corresponding code or documentation changes. The release workflow checks the configured mobile endpoint against the canonical production Cloud Run service URL, versions both packages from the tag and workflow run, verifies the packaged version metadata and archives the unsigned iOS app. Release operators should confirm the workflow build number exceeds any build already distributed independently.

Beacon acceptance now reads account status, block relationships, and the applicable community status and membership through the same Firestore transaction that claims the seat. The emulator regression commits a suspension while acceptance is in progress and checks both the participant state and capacity. Failed block retries now belong to the account's Plans session and retain their original idempotency key across navigation. An account reset discards them. These retries live in memory until session reset or process exit.

The ignored local development tfvars file was formatted, and the recursive Terraform format check now passes. The service-pause probe closes its HTTP client after each attempt. Beacon route registration and cross-module binding moved into the Beacon wiring file. The release documentation describes the separate Android signing job. The deployed IAM state, real signed store packages, and live production promotion remain environment-specific acceptance checks.

## Final audit follow-up

The release and promotion jobs now use the triggering revision for checkout. Promotion checks the candidate's digest against both the release tag and the registry tag containing that release and source SHA. A candidate staged by the older workflow must be staged again with the updated workflow before these checks can pass. Final mobile artifact names include the workflow attempt number so a rerun can retain both artifacts.

An old snackbar could retry a block against a closed Beacon screen while its session still held the pending intent. The action now exits before emitting state or sending a request. The regression covers the old callback and a successful retry on the reopened screen using the same key.

Verification for this pass included workflow lint, five simulated registry cases and 25 focused Flutter tests. Production promotion and store signing remain unverified.

## Findings in release order

| Priority | Finding and consequence | Remediation and acceptance |
|---|---|---|
| High for mobile distribution | The mobile build jobs embed `PROD_API_BASE_URL` without verifying the destination. An empty value can survive compilation and leave every installation on the configuration error screen. An unintended HTTPS host passes the runtime URL policy and can receive Firebase ID and App Check tokens. This requires release misconfiguration. No disclosure was observed. See `.github/workflows/release-prod.yml:242`, `:329`, `app/lib/app/app_config.dart:336`, `:386`, and `app/lib/app/bootstrap.dart:124`. | Bind the release to the approved production service origin. Validate it before building either platform. Exercise missing, wrong-host and valid settings in the release fixtures. |
| Medium, privacy and consistency | Beacon acceptance checks the target's account, block relationship and community membership through ordinary service reads. The callback runs inside the transaction body but receives no transaction handle. The participant and capacity writes can therefore commit against an outdated eligibility decision. The observable consequence is an accepted participant row and an occupied spot. Access to private content was not established. See `backend/internal/beacons/service_participation.go:154` and `backend/internal/beacons/repo_participation.go:398`. | Include authoritative eligibility records or a revocation version in the transaction read set. Verify that a concurrent revocation invalidates a pending acceptance while a replay of an already committed request preserves idempotency. |
| Medium, user safety | When declining a Beacon request succeeds but the block fails, the screen offers a retry. The target and retry key live in the screen cubit. Leaving the screen loses the retry, while the decline has already removed the request. The user remains unblocked. See `app/lib/features/beacons/presentation/bloc/beacon_people_cubit.dart:145` and `app/lib/features/beacons/presentation/beacon_people_screen.dart:293`. | Retain the outstanding block intent and its idempotency key per signed-in account. Test navigation away and back after partial success, followed by a retry that performs only the block. |
| Medium, distribution | Both mobile builds inherit `1.0.0+1` from `app/pubspec.yaml:5`. A new Git tag can produce the same Android version code and iOS build number as a previous tag. The workflow contains no monotonicity check. See `app/android/app/build.gradle.kts:46`, `app/ios/Runner/Info.plist:26` and `.github/workflows/release-prod.yml:250`. | Set and verify the intended mobile version and build number for each distributable release. Check the packaged metadata before signing or handoff. |
| Low, reliability | Every service-pause retry creates an HTTP client. Neither the caller nor the probe closes it, including after the eight-second timeout. Repeated retries during an outage can leave network resources awaiting cleanup. See `app/lib/app/bootstrap.dart:252` and `app/lib/core/network/service_paused_cubit.dart:45`. | Give the client an owner. For a per-attempt client, close it in a finally block, including when the probe times out. |
| Low, operational documentation | The active limitations list still describes Android release signing as a possible debug-key fallback. The tag workflow explicitly builds an unsigned AAB, passes it to a separate signing job and verifies its signature. See `docs/remember/known-limitations.md:74` and `.github/workflows/release-prod.yml:240`, `:267`. | Distinguish local Gradle behavior from the tagged release workflow. Link operators to the signing and verification job. |

## Structure and dead code

The top-level boundaries correspond to deployable components, contracts, platform configuration and release evidence. Keep them. The largest maintenance risk examined is inside the API composition root. One function, `backend/internal/apiserver/apiserver.go:109`, wires domains, lifecycle hooks, middleware and handlers through line 1018. Its line 616 comment says search is unregistered, while line 944 constructs its registered handler. Remove the obsolete comment and extract cohesive registration groups when those domains next change. Preserve middleware order with the existing handler-chain tests.

A static traversal from `app/lib/main.dart` followed library imports, exports, parts and conditional platform branches. It reached 973 of 1,022 tracked Dart files under `app/lib`. All 49 outside that graph were under the generated tree. This provides no basis for deleting a handwritten Flutter library. Symbol-level reachability, platform-specific native registration, Go build tags and operator-only commands require separate analysis before deletion. The search service's unimplemented responses are conditional on missing dependencies. Its production handler exists.

## Security controls and outstanding evidence

Firestore and Firebase Storage rules deny direct client reads and writes. The API uses privileged access, so the rules alone cannot establish per-user authorization. Both Terraform environments track provider lockfiles. The release installs a digest-verified Firebase CLI. The Rust policy checks the selected Android and WebAssembly graphs and time-limits accepted advisory exceptions. Deployment-specific controls from the [previous audit](REPOSITORY_AUDIT_2026-11-23.md), especially private media IAM, signed-link expiry and authenticated canary promotion, still need evidence from the intended environment.

The iOS tag job performs an unsigned build and ends without uploading an artifact. It provides a compilation check. A later signing operator would need a separate build or an archived, traceable handoff. The repository defers iOS distribution, so this is an acceptance item for that milestone.

## Verification scope

The default Go test suite, Go vet, protobuf lint and the Rust target-graph advisory policy passed locally. Go vulnerability scans for the host and Linux/amd64 reported no vulnerabilities. Flutter analysis passed, as did 65 focused Flutter tests for app configuration and service-pause handling and all 117 CI script fixtures. A recursive Terraform format check identified only the ignored local `envs/dev/terraform.tfvars`. Its contents were neither printed nor modified.

The review sampled production paths across the monorepo. It did not exercise deployed IAM, actual store signing, a production load profile, every feature flag combination or a cryptographic protocol assessment. Generated files were inventoried. The complete test matrix and a manual line-by-line review of every file were outside the evidence collected here.
