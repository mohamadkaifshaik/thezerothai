# RevenueCat dev rollout review

Status: prepared for review; no build/push/deployment or traffic change executed.
This is a configuration and validation proposal, not a release readiness verdict.

## Target and release path

Use the existing `deploy-dev.yml` and `scripts/promotion/promote-dev.sh` path.
Resolve the target from `DEV_PROJECT_ID`, `DEV_REGION`, `DEV_SERVICE_NAME` and
`DEV_ARTIFACT_REGISTRY_URL`; do not copy production project values. Use an image
pinned by `@sha256:` built by the existing authorized CI process. Preserve the
current flag/scaling ceilings, rollback floors, authenticated smoke and soak.
The workflow's dry run still builds/pushes and deploys a zero-traffic candidate;
it requires separate execution approval. No workflow was dispatched here.

## Candidate configuration to review

| Setting | Proposed dev value |
| --- | --- |
| ENV | dev, inherited from the existing service |
| BILLING_SANDBOX_ENABLED | false |
| BILLING_WEBHOOK_ENABLED | true only after the inputs below are confirmed |
| REVENUECAT_WEBHOOK_APP_IDS | Reviewed RevenueCat production app IDs; pending |
| REVENUECAT_PRODUCTS_JSON | Reviewed app_store/play_store product map; pending |
| REVENUECAT_SECRET_API_KEY | Secret Manager reference and pinned version; pending |
| REVENUECAT_WEBHOOK_AUTHORIZATION | Secret Manager reference and pinned version; pending |
| REVENUECAT_WEBHOOK_SIGNING_SECRET | Secret Manager reference and pinned version; pending |

Only secret resource names/version numbers are needed for review, never their
contents. Preserve all unrelated environment variables and secret bindings.
Candidate configuration must be applied to its zero-traffic revision through a
reviewed extension of the existing promotion path before running its smoke checks;
the current script inherits service configuration and does not add these settings.
Do not update the serving service configuration as a substitute for that review.

This webhook configuration intentionally accepts PRODUCTION transactions only,
even in dev. The currently configured Test Store/monthly catalog cannot fill the
production product map. Local emulator tests exercise durable processing with a
fake provider; they do not prove a live App Store/Google Play transaction.
Production purchase identity allocation and checkout remain disabled in this code.
Enablement of those paths needs a separate reviewed rollout after store setup.

## Checks before traffic or dashboard changes

1. Complete the normal CI gates and capture a clean image digest. `make ci` is
   currently blocked locally by the Windows invalid-handle error.
2. Confirm Secret Manager resource/version references and existing runtime access;
   review any required IAM change separately. Do not print secret values.
3. Deploy only the approved candidate through the gated dev path. Verify health
   returns 200 and unauthenticated Connect requests still return 401.
4. On the candidate URL, verify unsigned/bad-signature webhook requests return
   401; signed wrong-app/environment requests return 400; unknown private customer
   IDs return 200 without creating a binding. Use synthetic identifiers only.
5. Verify duplicate delivery is harmless and provider outages return 503 with
   durable pending work. Use isolated fixtures; do not make real-account purchases
   to reproduce tests. Confirm the authenticated recovery route rejects missing
   OIDC and recovers staged work with approved authentication.
6. Inspect outcome-only recovery logs. Confirm no credentials, raw webhook bodies,
   private customer IDs or user data are logged. Existing emulator regressions
   cover revocation, generation fencing, retry recovery, deduplication and erasure.
7. Obtain approval before traffic promotion and before creating/updating the
   RevenueCat dashboard integration. Its endpoint will be the approved dev URL
   plus `/webhooks/revenuecat`, with HMAC enabled and matching Authorization,
   production-app and PRODUCTION filters. Do not register a temporary candidate
   tag URL that the promotion script removes after a dry run.

Rollback uses the existing `last-good` path. Retain the old secret versions until
rollback compatibility is reviewed. Webhook work stays on the private billing
binding, so disabling the route does not erase pending work. This change requires
no Firestore index, migration, security-rule or hosting deployment.

## Remaining inputs

- Confirm actual production store apps/products exist in RevenueCat and provide
  their app IDs, product identifiers, storefronts and entitlement mappings.
- Confirm the dev target variables and the three Secret Manager resource names
  and version numbers. Keep secret contents in your own terminal/secret manager.
- Review the candidate configuration/promotion-path change, then explicitly
  approve CI execution/deployment when a concrete digest/configuration is ready.

## Android-first preparation

Selected platform: Google Play. The checked-in Android applicationId and namespace
are both `com.dzeroth.dzeroth`. Confirm that this is the Play Console app's package
before creating its real RevenueCat app; the repository package is not changed.

1. Create/confirm the Play Console app and complete the developer/merchant setup.
2. Prepare the monthly subscription and an active monthly base plan. Proposed
   product identifier: `monthly`; confirm the real product/base-plan identifiers
   before importing them. Confirm launch price, regions and renewal terms in Play
   Console; existing UI prices and Test Store pricing are not live store approval.
3. Configure the Google Play service-account connection in RevenueCat's dashboard
   using its current setup guide. Enter credentials there; do not put private JSON
   or key contents in this repository or chat.
4. Create the RevenueCat play_store app for the confirmed package, import the
   actual subscription/base plan, attach it to `dzeroth_pro`, then attach the Android
   product to the existing default offering's monthly package. Preserve the Test
   Store product and existing Plus plan.
5. Review SDK product-identifier handling and the backend production allowlist
   against the imported Play identifiers. Supply the Android public SDK key through
   the existing dart-define path, using a store-specific build configuration.
   The public Test Store key remains for the local sandbox.
6. Prepare an internal-testing build and license tester. A real Play purchase test
   needs the matching account, signed installed build, active product/base plan,
   configured RevenueCat store connection and server verification. This has not
   been performed by the local emulator suite.

Confirmed: the Play Console app has not been created yet. Complete the checklist
above before creating/importing the real RevenueCat Android app and products.

Official setup references:

- [Create and set up the Play Console app](https://support.google.com/googleplay/android-developer/answer/9859152)
- [Create subscriptions and activate a base plan](https://support.google.com/googleplay/android-developer/answer/140504)
- [RevenueCat Google Play connection](https://www.revenuecat.com/docs/service-credentials/creating-play-service-credentials)
- [RevenueCat product/base-plan mapping](https://www.revenuecat.com/docs/getting-started/entitlements/android-products)

