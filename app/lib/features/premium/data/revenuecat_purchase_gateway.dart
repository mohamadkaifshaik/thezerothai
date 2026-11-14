import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart' as rc;
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart' as ui;

import '../domain/subscription_models.dart';
import '../domain/subscription_catalog.dart';
import 'subscription_sources.dart';

/// One application-scoped instance, serialized by ServerSubscriptionRepository.
/// CustomerInfo never becomes an authorization decision.
class RevenueCatPurchaseGateway
    implements SubscriptionPurchaseGateway, SubscriptionHostedUiGateway {
  static const proEntitlement = 'dzeroth_pro';

  /// Public SDK key is selected per build/platform; never use a secret API key.
  factory RevenueCatPurchaseGateway.fromEnvironment() {
    const key = String.fromEnvironment('REVENUECAT_PUBLIC_API_KEY');
    const catalog = String.fromEnvironment('REVENUECAT_MONTHLY_PRODUCTS_JSON');
    return RevenueCatPurchaseGateway(
      publicApiKey: key,
      monthlyProducts: catalog.isNotEmpty
          ? parseMonthlySubscriptionProducts(catalog)
          : key.startsWith('test_')
          ? const {'monthly': SubscriptionTier.premium}
          : const {},
    );
  }
  RevenueCatPurchaseGateway({
    required String publicApiKey,
    required Map<String, SubscriptionTier> monthlyProducts,
  }) : _publicApiKey = publicApiKey,
       _monthlyProducts = Map.unmodifiable(monthlyProducts);

  final String _publicApiKey;
  final Map<String, SubscriptionTier> _monthlyProducts;
  bool _configured = false;
  String? _customerId;
  final Map<SubscriptionOffering, rc.Package> _packages = {};

  @override
  Future<void> identify(String privateCustomerId) async {
    if (!RegExp(r'^dzb_[A-Za-z0-9_-]{43}$').hasMatch(privateCustomerId) ||
        _publicApiKey.isEmpty) {
      throw StateError('Billing configuration unavailable');
    }
    if (!kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      throw UnsupportedError('Billing platform unavailable');
    }
    if (_customerId != privateCustomerId) _packages.clear();
    if (!_configured) {
      final configuration = rc.PurchasesConfiguration(_publicApiKey)
        ..appUserID = privateCustomerId;
      await rc.Purchases.configure(configuration);
      _configured = true;
    } else if (_customerId != privateCustomerId) {
      await rc.Purchases.logIn(privateCustomerId);
    }
    _customerId = privateCustomerId;
  }

  void _requireIdentity() {
    if (_customerId == null) throw StateError('Billing identity required');
  }

  /// Provider status for billing UI only. API access remains server-authorized.
  Future<rc.CustomerInfo> getCustomerInfo({bool refresh = false}) async {
    _requireIdentity();
    if (refresh) await rc.Purchases.invalidateCustomerInfoCache();
    return rc.Purchases.getCustomerInfo();
  }

  Future<bool> hasProEntitlement() async =>
      (await getCustomerInfo()).entitlements.active.containsKey(proEntitlement);

  void _requireNativeUi() {
    _requireIdentity();
    if (kIsWeb) throw UnsupportedError('Native billing UI unavailable on Web');
  }

  @override
  Future<SubscriptionPurchaseResult> presentPaywall() async {
    _requireNativeUi();
    final offering = (await rc.Purchases.getOfferings()).current;
    if (offering == null ||
        offering.availablePackages.isEmpty ||
        offering.availablePackages.any(
          (p) =>
              p.storeProduct.subscriptionPeriod != 'P1M' ||
              !_monthlyProducts.containsKey(p.storeProduct.identifier),
        )) {
      throw StateError('Paywall catalog unavailable');
    }
    _packages.clear();
    final result = await ui.RevenueCatUI.presentPaywallIfNeeded(
      proEntitlement,
      offering: offering,
      displayCloseButton: true,
    );
    if (result == ui.PaywallResult.error) {
      throw StateError('Paywall unavailable');
    }
    return SubscriptionPurchaseResult(
      result == ui.PaywallResult.cancelled
          ? PurchaseDisposition.canceled
          : PurchaseDisposition.verifying,
    );
  }

  @override
  Future<void> presentCustomerCenter() async {
    _requireNativeUi();
    await ui.RevenueCatUI.presentCustomerCenter();
  }

  @override
  Future<List<SubscriptionOffering>> getOfferings() async {
    _requireIdentity();
    _packages.clear();
    final offerings = await rc.Purchases.getOfferings();
    for (final package
        in offerings.current?.availablePackages ?? <rc.Package>[]) {
      final product = package.storeProduct;
      final tier = _monthlyProducts[product.identifier];
      if ((tier != SubscriptionTier.plus && tier != SubscriptionTier.premium) ||
          product.subscriptionPeriod != 'P1M') {
        continue;
      }
      final offering = SubscriptionOffering(
        packageIdentifier: package.identifier,
        productIdentifier: product.identifier,
        tier: tier!,
        localizedPrice: product.priceString,
        billingPeriod: 'monthly',
      );
      _packages[offering] = package;
    }
    return List.unmodifiable(_packages.keys);
  }

  @override
  Future<SubscriptionPurchaseResult> purchase(
    SubscriptionOffering offering,
  ) async {
    _requireIdentity();
    final package = _packages[offering];
    if (package == null) throw StateError('Reload subscription offerings');
    _packages.clear();
    try {
      await rc.Purchases.purchase(rc.PurchaseParams.package(package));
      return const SubscriptionPurchaseResult(PurchaseDisposition.verifying);
    } on PlatformException catch (error) {
      switch (rc.PurchasesErrorHelper.getErrorCode(error)) {
        case rc.PurchasesErrorCode.purchaseCancelledError:
          return const SubscriptionPurchaseResult(PurchaseDisposition.canceled);
        case rc.PurchasesErrorCode.paymentPendingError:
          return const SubscriptionPurchaseResult(PurchaseDisposition.pending);
        default:
          // A timeout can follow a real charge. The repository retains its guard.
          rethrow;
      }
    }
  }

  @override
  Future<SubscriptionPurchaseResult> restore() async {
    _requireIdentity();
    _packages.clear();
    if (kIsWeb) {
      await rc.Purchases.invalidateCustomerInfoCache();
      await rc.Purchases.getCustomerInfo();
    } else {
      await rc.Purchases.restorePurchases();
    }
    return const SubscriptionPurchaseResult(PurchaseDisposition.verifying);
  }
}
