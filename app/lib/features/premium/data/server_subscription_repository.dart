import '../../../../core/storage/session_epoch.dart';
import '../domain/subscription_models.dart';
import '../domain/subscription_repository.dart';
import 'subscription_sources.dart';

/// Composes server authority with a serialized, account-bound purchase SDK.
/// Kept unregistered until the concrete RPC/SDK adapters and lifecycle ship.
class ServerSubscriptionRepository
    implements SubscriptionRepository, HostedSubscriptionRepository {
  ServerSubscriptionRepository({
    required SubscriptionStatusSource source,
    required SubscriptionPurchaseGateway gateway,
    required SessionEpoch sessionEpoch,
    required String? Function() currentUid,
    DateTime Function()? now,
  }) : _source = source,
       _gateway = gateway,
       _epoch = sessionEpoch,
       _currentUid = currentUid,
       _now = now ?? DateTime.now;

  final SubscriptionStatusSource _source;
  final SubscriptionPurchaseGateway _gateway;
  final SessionEpoch _epoch;
  final String? Function() _currentUid;
  final DateTime Function() _now;
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  List<SubscriptionOffering> _offerings = const [];
  bool _awaitingVerification = false;

  @override
  void clearSession() {
    _generation++;
    _offerings = const [];
    _awaitingVerification = false;
    // Do not reset the queue: a purchase already in the store must finish
    // before the SDK can identify another account. Never log out anonymously.
  }

  Future<T> _run<T>(String uid, Future<T> Function(void Function()) work) {
    final generation = _generation;
    final epoch = _epoch.value;
    void check() {
      if (uid.isEmpty ||
          _currentUid() != uid ||
          generation != _generation ||
          epoch != _epoch.value) {
        throw StateError('Subscription session changed');
      }
    }

    final result = _tail.then((_) async {
      check();
      final value = await work(check);
      check();
      return value;
    });
    // An old operation's error must not poison the next account's queue.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<SubscriptionAccess> _access(String uid, void Function() check) async {
    final access = await _source.getAccess();
    check();
    if (access.uid != uid) throw StateError('Subscription owner mismatch');
    final tier = access.effectiveTier(_now());
    if (tier == SubscriptionTier.plus || tier == SubscriptionTier.premium) {
      _awaitingVerification = false;
    }
    return access;
  }

  Future<void> _identify(void Function() check) async {
    final id = await _source.ensureBillingIdentity();
    check();
    if (!RegExp(r'^dzb_[A-Za-z0-9_-]{43}$').hasMatch(id)) {
      throw StateError('Invalid private billing identity');
    }
    await _gateway.identify(id);
    check();
  }

  bool _canBuy(SubscriptionAccess access) =>
      access.purchasesAvailable &&
      access.effectiveTier(_now()) == SubscriptionTier.free &&
      !_awaitingVerification;

  @override
  Future<SubscriptionAccess> getAccess(String uid) =>
      _run(uid, (check) => _access(uid, check));

  @override
  Future<List<SubscriptionOffering>> getOfferings(String uid) =>
      _run(uid, (check) async {
        _offerings = const [];
        if (!_canBuy(await _access(uid, check))) return _offerings;
        await _identify(check);
        final offerings = await _gateway.getOfferings();
        check();
        _offerings = List.unmodifiable(
          offerings.where(
            (o) =>
                (o.tier == SubscriptionTier.plus ||
                    o.tier == SubscriptionTier.premium) &&
                o.packageIdentifier.isNotEmpty &&
                o.productIdentifier.isNotEmpty &&
                o.localizedPrice.isNotEmpty &&
                o.billingPeriod == 'monthly',
          ),
        );
        return _offerings;
      });

  @override
  Future<SubscriptionPurchaseResult> purchase(
    String uid,
    SubscriptionOffering offering,
  ) => _run(uid, (check) async {
    if (!_offerings.contains(offering) || !_canBuy(await _access(uid, check))) {
      throw StateError('Subscription purchase unavailable');
    }
    await _identify(check);
    // Retain uncertainty on SDK errors: a timeout may follow a real charge.
    _awaitingVerification = true;
    _offerings = const [];
    final result = await _gateway.purchase(offering);
    check();
    if (result.disposition == PurchaseDisposition.canceled) {
      _awaitingVerification = false;
    }
    return result;
  });

  @override
  Future<SubscriptionPurchaseResult> restore(String uid) =>
      _run(uid, (check) async {
        await _identify(check);
        _awaitingVerification = true;
        _offerings = const [];
        final result = await _gateway.restore();
        check();
        return result;
      });

  /// Hosted UI shares the SDK queue and purchase uncertainty guard.
  @override
  Future<SubscriptionPurchaseResult> presentPaywall(String uid) =>
      _run(uid, (check) async {
        final gateway = _gateway;
        if (gateway is! SubscriptionHostedUiGateway ||
            !_canBuy(await _access(uid, check))) {
          throw StateError('Subscription purchase unavailable');
        }
        await _identify(check);
        _awaitingVerification = true;
        _offerings = const [];
        final result = await (gateway as SubscriptionHostedUiGateway)
            .presentPaywall();
        check();
        if (result.disposition == PurchaseDisposition.canceled) {
          _awaitingVerification = false;
        }
        return result;
      });

  @override
  Future<void> presentCustomerCenter(String uid) => _run(uid, (check) async {
    final gateway = _gateway;
    if (gateway is! SubscriptionHostedUiGateway) {
      throw UnsupportedError('Subscription management unavailable');
    }
    await _identify(check);
    _offerings = const [];
    await (gateway as SubscriptionHostedUiGateway).presentCustomerCenter();
    check();
  });
}
