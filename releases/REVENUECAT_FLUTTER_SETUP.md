# RevenueCat Flutter setup

`dzeroth_pro` maps to Premium; Plus remains supported. `monthly` is the
Premium Test Store product identifier. This guide is a complete SDK sandbox
example, not registration of the unfinished production billing service.

## 1. Install from a normal local PowerShell terminal

```powershell
Set-Location 'C:\Users\skmk1\Documents\cloned-projects\codex\thezerothai\app'
flutter pub add purchases_flutter purchases_ui_flutter
flutter run --dart-define=REVENUECAT_PUBLIC_API_KEY=test_VzVxsDKkeDorBmgYvoXAygIJexv
```

The public Test Store key may be included in client builds. Use separate Android,
iOS and Web public SDK keys for real stores; never embed a secret server API key.

## 2. Configure the RevenueCat dashboard

1. Select the project owning the supplied Test Store public key.
2. Create entitlement `dzeroth_pro`.
3. Create subscription product ID `monthly`, display name Monthly, period monthly.
4. Attach that product to `dzeroth_pro`.
5. Create an offering (for example `default`) and mark it current.
6. Add its Monthly package (`$rc_monthly`) and attach product `monthly`.
   A package ID and product ID are different identifiers.
7. Create, configure and publish a paywall attached to this offering. Add the
   actual terms/privacy links and restore/manage actions. Use localized price
   variables rather than literal currency amounts.
8. Configure Customer Center in the dashboard before testing management flows.
   Real cancellation/refund behavior needs actual store sandbox validation.

The Plus product remains separate and attached to `plus_access`; do not attach
`dzeroth_pro` to Plus. Production products must be created/imported separately
for Apple, Google and Web billing. Test Store does not configure those stores.

## 3. Complete mobile sandbox controller example

After installing the UI dependency, this example can live in a sandbox target.
It assumes SDK ownership is exclusive: do not initialize it alongside another
RevenueCat gateway. Production Dzeroth must route every SDK mutation through its
existing serialized subscription repository, including a hosted paywall.

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

class ProSandboxController extends ChangeNotifier {
  CustomerInfo? customerInfo;
  String? message;
  bool busy = false;
  bool _ready = false;
  bool _disposed = false;
  bool _listening = false;

  // This is provider UI status, NOT authorization for Dzeroth API operations.
  bool get providerReportsPro =>
      customerInfo?.entitlements.active.containsKey('dzeroth_pro') ?? false;

  void _updated(CustomerInfo info) {
    if (_disposed) return;
    customerInfo = info;
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_disposed || busy) return;
    busy = true;
    message = null;
    notifyListeners();
    try {
      await action();
    } on PlatformException catch (error) {
      final code = PurchasesErrorHelper.getErrorCode(error);
      message = switch (code) {
        PurchasesErrorCode.purchaseCancelledError => 'Purchase cancelled.',
        PurchasesErrorCode.paymentPendingError => 'Payment pending approval.',
        _ => 'Billing is unavailable. Refresh your subscription before retrying.',
      };
    } catch (_) {
      message = 'Unable to load billing. Please try again.';
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  // Obtain this opaque identity from the authenticated backend, not user input.
  Future<void> initialize(String privateBillingId) => _run(() async {
    if (_ready) return;
    if (!RegExp(r'^dzb_[A-Za-z0-9_-]{43}$').hasMatch(privateBillingId)) {
      throw StateError('Server-issued billing identity required');
    }
    const key = String.fromEnvironment('REVENUECAT_PUBLIC_API_KEY');
    if (key.isEmpty) throw StateError('Missing public SDK key');
    final config = PurchasesConfiguration(key)..appUserID = privateBillingId;
    await Purchases.configure(config);
    if (_disposed) return;
    Purchases.addCustomerInfoUpdateListener(_updated);
    _listening = true;
    _ready = true;
    _updated(await Purchases.getCustomerInfo());
  });

  void _requireMobile() {
    if (!_ready) throw StateError('Initialize billing first');
    if (kIsWeb || (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.android)) {
      throw UnsupportedError('This example uses native billing UI');
    }
  }

  Future<void> refresh() => _run(() async {
    if (!_ready) throw StateError('Initialize billing first');
    await Purchases.invalidateCustomerInfoCache();
    _updated(await Purchases.getCustomerInfo());
  });

  // Customer cancellation is normal. Successful checkout still needs backend
  // reconciliation before Dzeroth enables longer posts or article publication.
  Future<void> showPaywall() => _run(() async {
    _requireMobile();
    final offering = (await Purchases.getOfferings()).current;
    if (offering == null || offering.monthly?.storeProduct.identifier != 'monthly') {
      throw StateError('Current offering must contain monthly product');
    }
    final result = await RevenueCatUI.presentPaywallIfNeeded(
      'dzeroth_pro', offering: offering, displayCloseButton: true,
    );
    _updated(await Purchases.getCustomerInfo());
    message = switch (result) {
      PaywallResult.purchased || PaywallResult.restored =>
        'Store completed. Waiting for server verification.',
      PaywallResult.cancelled => 'Purchase cancelled.',
      PaywallResult.notPresented => 'Pro is already active in RevenueCat.',
      PaywallResult.error => 'Checkout unavailable. Refresh before retrying.',
    };
  });

  Future<void> restore() => _run(() async {
    _requireMobile();
    _updated(await Purchases.restorePurchases());
    message = 'Restore finished. Waiting for server verification.';
  });

  Future<void> showCustomerCenter() => _run(() async {
    _requireMobile();
    await RevenueCatUI.presentCustomerCenter();
    await Purchases.invalidateCustomerInfoCache();
    _updated(await Purchases.getCustomerInfo());
  });

  @override
  void dispose() {
    _disposed = true;
    if (_listening) Purchases.removeCustomerInfoUpdateListener(_updated);
    super.dispose();
  }
}
```

Bind buttons to `showPaywall`, `restore`, `refresh`, and `showCustomerCenter`;
disable them while `busy`. Render `message` as accessible status text. Create
the controller once outside widget builds and dispose it with the sandbox screen.
Do not switch accounts while a native sheet is open. Dispose account-scoped
listeners on sign-out; route account changes through Dzeroth's session queue.

For a custom checkout, use the fetched package and the modern purchase API:

```dart
final monthly = (await Purchases.getOfferings()).current?.monthly;
if (monthly == null || monthly.storeProduct.identifier != 'monthly') {
  throw StateError('Monthly subscription is not configured');
}
final priceForDisplay = monthly.storeProduct.priceString;
final purchase = await Purchases.purchase(PurchaseParams.package(monthly));
final providerReportsPro =
    purchase.customerInfo.entitlements.active.containsKey('dzeroth_pro');
// Reconcile on the backend; providerReportsPro alone cannot grant API access.
```

## 4. Existing Dzeroth integration

`RevenueCatPurchaseGateway.fromEnvironment()` selects the supplied build-time
public key and maps product `monthly` to Premium. Its `getCustomerInfo()` and
`hasProEntitlement()` support billing status; existing repository purchase/restore
flows retain their account/epoch checks and server-verification guards.
Go recognizes both `premium_access` and `dzeroth_pro` as Premium and preserves
Plus inheritance. Provider catalog entries must explicitly allow `dzeroth_pro`
for the actual product/store/environment before server readback can grant it.

The native paywall must NOT bypass the repository's purchase guard or server
sales-availability check. The example above is not wired into the production
Premium dialog. Production registration still requires the billing RPCs, durable
webhook reconciliation and feature enforcement described in SUBSCRIPTIONS.md.

Android MainActivity now extends FlutterFragmentActivity for native paywalls;
existing notification initialization is retained. Existing launchMode singleTop,
Kotlin 2.4.0 and iOS deployment target 15.0 satisfy the documented basic setup.
Native builds and Xcode capabilities remain to validate on their target platforms.

## 5. Validation and account management

- Test purchase, cancellation, pending approval, renewal, expiry and restore.
- Test sign-out/account switching and late callbacks; never copy one user's info
  into another session. Never initialize anonymous customers in Dzeroth.
- Refresh customer information on return from management and on app resume;
  offline cached status must not override server freshness/expiry rules.
- Cancellation normally preserves access until paid expiry; refund/revocation
  requires provider reconciliation. Do not infer status from auto-renew intent.
- A successful store charge followed by a timeout is ambiguous: refresh/reconcile
  before enabling another checkout. Never log receipts, raw customer info or keys.
- Native paywalls and native restore are not Flutter Web APIs. Use a supported
  Web billing engine and custom checkout/management UI there. Customer Center
  store actions need platform testing; do not promise them from Test Store alone.

Sources: https://www.revenuecat.com/docs/getting-started/installation/flutter,
https://www.revenuecat.com/docs/tools/paywalls/displaying-paywalls,
https://www.revenuecat.com/docs/tools/customer-center/customer-center-flutter.
