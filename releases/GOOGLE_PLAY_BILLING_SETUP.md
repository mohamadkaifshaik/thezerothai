# Google Play → RevenueCat → Dzeroth dev

Status: implementation prepared; no Google Play app, real store product, credential,
RevenueCat real-store app or webhook has been created by this change. Live sales
remain off until store setup, native testing and the gated dev deployment finish.

## 1. Create the Play app and subscription

Use Google Play Console to complete developer verification and your payments
profile. Create the Dzeroth app and upload a correctly signed Android App Bundle
with package `com.dzeroth.dzeroth` to an appropriate testing track.

On **Monetize with Play → Products → Subscriptions**, create a subscription and
an auto-renewing **monthly** base plan. Review the price, countries, renewal terms,
store listing and cancellation information before activating it. IDs are permanent
after creation/activation; the following are proposed names, not created products:

| Item | Proposed value |
| --- | --- |
| Android package | `com.dzeroth.dzeroth` |
| Play subscription | `premium` |
| Play base plan | `monthly` |
| RevenueCat product | `premium:monthly` |
| RevenueCat entitlement | existing `dzeroth_pro` |
| Offering | existing `default` |
| Package | existing `$rc_monthly`, with the new Android product attached |

Keep the Test Store product attached for Test Store builds. Do not replace its key
with a real-store key. No launch price or trial is selected by this code.

Official instructions: [create subscriptions and base plans](https://support.google.com/googleplay/android-developer/answer/140504),
[RevenueCat Google product identifiers](https://www.revenuecat.com/docs/getting-started/entitlements/android-products).

## 2. Connect Google Play to RevenueCat

In the Dzeroth RevenueCat project's Apps section, add a Google Play app using the
same Android package. Complete the service-account setup in RevenueCat's current
[Google Play connection guide](https://www.revenuecat.com/docs/service-credentials/creating-play-service-credentials):

1. Enable the Play Developer and Reporting APIs in the selected Google Cloud project.
2. Create a dedicated RevenueCat service account and configure the documented
   Pub/Sub and monitoring access for Google real-time developer notifications.
3. Grant that account access to this app in Play Console, including the documented
   catalog/report, financial/order, subscription-management and store-presence permissions.
4. Upload its JSON credential **directly to RevenueCat's app settings**, then verify
   the credential checks. Never put its contents in this repository or chat.
5. Configure Google's real-time developer notifications (RTDN) to RevenueCat using
   the [RTDN guide](https://www.revenuecat.com/docs/platform-resources/server-notifications/google-server-notifications).

Google → RevenueCat RTDN and RevenueCat → Dzeroth webhooks are separate connections.
Neither uses the application's ordinary messaging Pub/Sub subscription.

## 3. Map the product

Import the actual Play subscription/base plan into RevenueCat. Attach that product
to `dzeroth_pro`, then to the monthly package in the current `default` offering.
Check its store state and credential validation in the dashboard. Only actual
store identifiers belong in the following configuration examples.

For the proposed Premium mapping:

```json
{"premium:monthly":{"Store":"play_store","Entitlement":"dzeroth_pro"}}
```

The Flutter monthly-product mapping is:

```json
{"premium:monthly":"premium"}
```

Optional future Plus products map to `plus_access` on the server and `plus` in the
client. Give each tier its own store product and package. Custom package names
are supported, but their actual store billing period must be `P1M`.

The verifier matches the subscription **and** base plan. RevenueCat's v1 customer
response supplies the plan separately from the subscription key; an unknown,
missing or mismatched plan cannot inherit the reviewed monthly product's access.

## 4. Configure dev without exposing secrets

These inputs are repository/environment variables consumed by `deploy-dev.yml`.
They are not secret values. Keep the opt-in unset until all inputs exist.

| Variable | Initial value / purpose |
| --- | --- |
| `DEV_BILLING_CONFIG_ENABLED` | `true` to apply billing settings to the candidate |
| `DEV_BILLING_PURCHASES_ENABLED` | `false` initially; permits checkout only when explicitly `true` |
| `DEV_REVENUECAT_PURCHASE_ENVIRONMENT` | `SANDBOX` for Play license testing; `PRODUCTION` for real transactions |
| `DEV_REVENUECAT_WEBHOOK_APP_IDS` | Actual RevenueCat Google Play app ID(s), comma-separated |
| `DEV_REVENUECAT_PRODUCTS_JSON` | Reviewed server mapping above |
| `DEV_REVENUECAT_SECRET_API_KEY_REF` | Secret Manager short name and numeric version, e.g. `rc-api-key:1` |
| `DEV_REVENUECAT_WEBHOOK_AUTHORIZATION_REF` | Pinned authorization-header secret reference |
| `DEV_REVENUECAT_WEBHOOK_SIGNING_SECRET_REF` | Pinned HMAC secret reference |

Store a RevenueCat **V1-compatible secret API key**, webhook Authorization value and webhook
signing secret in Secret Manager through your own console/terminal. The existing
Cloud Run runtime identity must be able to access the reviewed versions; review
any required IAM change separately. Never use `latest` references or copy a
production project's secret reference into dev.

The verifier calls `/v1/subscribers`; select the V1 key version in RevenueCat's
API-key settings. The public `goog_` SDK key and dashboard-automation V2 key are
separate credentials. See the [V1 API reference](https://www.revenuecat.com/docs/api-v1).

The promotion script applies only validated billing environment values and secret
references to a **new zero-traffic candidate**. It preserves unrelated settings,
traffic validation, flag/scaling ceilings, authenticated smoke, soak and rollback.
An unset/false `DEV_BILLING_CONFIG_ENABLED` leaves existing configuration alone;
it is not an instruction to remove previously configured billing. To stop new
sales while preserving verification, keep configuration enabled and set
`DEV_BILLING_PURCHASES_ENABLED=false`, then redeploy through the same path.

New real-store checkout is restricted to `ENV=dev` in this rollout. This does not
authorize deployment to the GCP production project. Verified subscription status,
restore and paid-feature enforcement are independent of the new-sales switch.

## 5. Connect RevenueCat webhooks to the deployed dev API

After the billing-configured revision is serving, add a RevenueCat webhook:

- URL: `https://dzeroth-dev.web.app/api/webhooks/revenuecat`
- Filter to the real RevenueCat Play app ID and the selected receipt environment.
- Configure a strong Authorization value matching the backend secret.
- Enable HMAC signing and store the corresponding signing secret in the backend.
- Include the subscription lifecycle/transfer events; avoid a purchase-only filter.

Use the stable dev URL, not a temporary candidate tag. The handler verifies the
signature over the original wire bytes, enforces app/environment filters, deduplicates
durably and performs server-side readback before deriving access. Recovery uses
the existing cron. Unsigned requests must return 401. Test with synthetic IDs and
dashboard test events before enabling checkout; no customer data is required.

See [webhook setup and signature verification](https://www.revenuecat.com/docs/integrations/webhooks).

## 6. Build and validate Android checkout

Use the Google Play app's **public** `goog_…` SDK key in the Android build, with:

- `FIREBASE_ENV=dev`
- `USE_EMULATORS=false`
- `API_BASE_URL=https://dzeroth-dev.web.app/api`
- `REVENUECAT_PUBLIC_API_KEY`: the Android public SDK key
- `REVENUECAT_MONTHLY_PRODUCTS_JSON`: the client mapping above
- Existing dev reCAPTCHA/Google client settings supplied by the build environment

Preserve the existing signing/build process. Never put the server API key or the
Google service-account JSON in Flutter defines. Web reads verified subscription
status without initializing a purchase SDK and cannot start native checkout.
The dev workflow enables this status-only UI with `BILLING_STATUS_ENABLED` when
`DEV_BILLING_CONFIG_ENABLED=true`. With both that define and a public SDK key
absent, billing stays dark as before.

For Play license testing, use `SANDBOX`, an approved testing-track build, a dedicated
license tester and a dedicated dev app account. Enable checkout only for that
validated configuration. Verify purchase, cancellation, pending payment, refresh,
restore, Customer Center, renewal, expiry/refund, account switching and outage
recovery. A store success alone must never grant server access.

`SANDBOX` selects backend receipt verification; it does not force Google Play to
use test payments. Confirm the purchasing Google account is a license tester and
the Play payment sheet identifies a test purchase. Testing-track users who are not
license testers can incur real charges. See Google's
[billing testing guide](https://developer.android.com/google/play/billing/test).

Before real sales, configure `PRODUCTION` consistently in the backend and webhook
filters, review the real store catalog and run the gated dev deployment. Sandbox
and production bindings are not automatically migrated or reassigned: use separate
test accounts/environments and review any transition for existing bindings.

Store connection, native-device validation, secret provisioning and real-sale
enablement remain external rollout prerequisites, not completed work.
