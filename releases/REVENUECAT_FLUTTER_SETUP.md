# Monthly Plus in Flutter

The Subscriptions entry opens the existing `/premium` route. Free includes the
social features and posts up to 280 characters. Plus includes posts up to
15,000 characters and article publishing. The India price is ₹99 per month.

## Sandbox setup

Configure one monthly Test Store product (`plus_monthly`), attach `plus_access`,
and add its monthly package to the current offering. Use the Test Store public
SDK key with the local billing sandbox. Configure any INR product at ₹99.
If an existing sandbox product has a different price, use a new product and
update the client and server catalog together. Historical records describe the
earlier two-tier experiment.

## Checkout and billing

The subscription sheet loads the store price and purchases the displayed
package. Android and iOS handle payment confirmation in the native store.
The sheet shows payment pending, verification and active membership states.
Restore uses the identified store account. Manage subscription opens the
RevenueCat Customer Center, which must be configured in the dashboard.
Web supports checking account status.

The authenticated billing RPC supplies a private customer ID. The Go service
checks RevenueCat and verifies store, product, customer and receipt environment
before authorizing longer posts or article publication. Older Premium grants
in a reviewed server catalog receive the same Plus benefits until expiry.

See [store configuration, testing and deployment](GOOGLE_PLAY_BILLING_SETUP.md).
