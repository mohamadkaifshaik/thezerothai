import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/storage/session_epoch.dart';
import '../../domain/subscription_models.dart';
import '../../domain/subscription_repository.dart';

enum SubscriptionPhase {
  signedOut,
  loading,
  ready,
  purchasing,
  verifying,
  pending,
  unavailable,
}

class SubscriptionState {
  const SubscriptionState({
    this.phase = SubscriptionPhase.signedOut,
    this.uid,
    this.access,
    this.offerings = const [],
  });

  final SubscriptionPhase phase;
  final String? uid;
  final SubscriptionAccess? access;
  final List<SubscriptionOffering> offerings;
}

/// Kept dark until the concrete SDK/Connect adapter and server enforcement
/// ship. No constructor side effects and no purchase calls from widget builds.
class SubscriptionCubit extends Cubit<SubscriptionState> {
  SubscriptionCubit({
    required SubscriptionRepository repository,
    required SessionEpoch sessionEpoch,
    DateTime Function()? now,
  }) : _repository = repository,
       _sessionEpoch = sessionEpoch,
       _now = now ?? DateTime.now,
       super(const SubscriptionState());

  final SubscriptionRepository _repository;
  final SessionEpoch _sessionEpoch;
  final DateTime Function() _now;
  int _generation = 0;
  SubscriptionPhase? _awaitingPurchase;

  /// Call from auth-session wiring, including a direct A-to-B switch. Old
  /// requests may finish, but their result cannot enter the next account's UI.
  Future<void> setAccount(String? uid) async {
    if (isClosed) return;
    _generation++;
    _awaitingPurchase = null;
    _repository.clearSession();
    if (uid == null || uid.isEmpty) {
      emit(const SubscriptionState());
      return;
    }
    emit(SubscriptionState(phase: SubscriptionPhase.loading, uid: uid));
    await refresh();
  }

  bool _current(String uid, int generation, int epoch) =>
      !isClosed &&
      state.uid == uid &&
      _generation == generation &&
      _sessionEpoch.value == epoch;

  Future<void> refresh() async {
    final uid = state.uid;
    if (isClosed ||
        uid == null ||
        state.phase == SubscriptionPhase.purchasing) {
      return;
    }
    final generation = ++_generation;
    final epoch = _sessionEpoch.value;
    try {
      final access = await _repository.getAccess(uid);
      if (!_current(uid, generation, epoch)) return;
      if (access.uid != uid || access.effectiveTier(_now()) == null) {
        emit(SubscriptionState(phase: SubscriptionPhase.unavailable, uid: uid));
        return;
      }
      // Do not load/store prices or expose a purchase action while the server
      // says purchases are disabled. This preserves the coming-soon phase.
      final tier = access.effectiveTier(_now());
      if (tier == SubscriptionTier.plus || tier == SubscriptionTier.premium) {
        _awaitingPurchase = null;
      }
      final offerings = access.purchasesAvailable && _awaitingPurchase == null
          ? await _repository.getOfferings(uid)
          : const <SubscriptionOffering>[];
      if (!_current(uid, generation, epoch)) return;
      emit(
        SubscriptionState(
          phase: _awaitingPurchase ?? SubscriptionPhase.ready,
          uid: uid,
          access: access,
          offerings: List.unmodifiable(offerings),
        ),
      );
    } on Object {
      if (_current(uid, generation, epoch)) {
        emit(SubscriptionState(phase: SubscriptionPhase.unavailable, uid: uid));
      }
    }
  }

  Future<void> purchase(SubscriptionOffering offering) async {
    final uid = state.uid;
    final access = state.access;
    if (isClosed ||
        uid == null ||
        state.phase != SubscriptionPhase.ready ||
        access == null ||
        !access.purchasesAvailable ||
        access.effectiveTier(_now()) != SubscriptionTier.free ||
        !state.offerings.contains(offering) ||
        (offering.tier != SubscriptionTier.plus &&
            offering.tier != SubscriptionTier.premium)) {
      return;
    }
    await _transact(uid, () => _repository.purchase(uid, offering));
  }

  Future<void> showPaywall() async {
    final uid = state.uid;
    final repository = _repository;
    if (isClosed ||
        uid == null ||
        state.phase != SubscriptionPhase.ready ||
        state.access?.purchasesAvailable != true ||
        state.access?.effectiveTier(_now()) != SubscriptionTier.free ||
        repository is! HostedSubscriptionRepository) {
      return;
    }
    await _transact(
      uid,
      () => (repository as HostedSubscriptionRepository).presentPaywall(uid),
    );
  }

  Future<void> manageSubscription() async {
    final uid = state.uid;
    final repository = _repository;
    if (isClosed ||
        uid == null ||
        state.phase == SubscriptionPhase.purchasing ||
        repository is! HostedSubscriptionRepository) {
      return;
    }
    await _transact(uid, () async {
      await (repository as HostedSubscriptionRepository).presentCustomerCenter(
        uid,
      );
      return const SubscriptionPurchaseResult(PurchaseDisposition.verifying);
    }, startsPurchase: false);
  }

  /// Restore remains available even when new sales are off or status refresh
  /// failed. A pending or verified purchase is never a client-side grant.
  Future<void> restore() async {
    final uid = state.uid;
    if (isClosed ||
        uid == null ||
        state.phase == SubscriptionPhase.purchasing ||
        state.phase == SubscriptionPhase.pending) {
      return;
    }
    await _transact(uid, () => _repository.restore(uid));
  }

  Future<void> _transact(
    String uid,
    Future<SubscriptionPurchaseResult> Function() action, {
    bool startsPurchase = true,
  }) async {
    final generation = ++_generation;
    final epoch = _sessionEpoch.value;
    emit(SubscriptionState(phase: SubscriptionPhase.purchasing, uid: uid));
    try {
      final result = await action();
      if (!_current(uid, generation, epoch)) return;
      switch (result.disposition) {
        case PurchaseDisposition.refreshed:
          emit(SubscriptionState(phase: SubscriptionPhase.loading, uid: uid));
          await refresh();
        case PurchaseDisposition.canceled:
          _awaitingPurchase = null;
          emit(SubscriptionState(phase: SubscriptionPhase.loading, uid: uid));
          await refresh();
        case PurchaseDisposition.pending:
          _awaitingPurchase = SubscriptionPhase.pending;
          emit(SubscriptionState(phase: SubscriptionPhase.pending, uid: uid));
        case PurchaseDisposition.verifying:
          if (startsPurchase) _awaitingPurchase = SubscriptionPhase.verifying;
          emit(SubscriptionState(phase: SubscriptionPhase.verifying, uid: uid));
          await refresh();
      }
    } on Object {
      if (_current(uid, generation, epoch)) {
        emit(SubscriptionState(phase: SubscriptionPhase.unavailable, uid: uid));
      }
    }
  }

  @override
  Future<void> close() {
    _generation++;
    _repository.clearSession();
    return super.close();
  }
}
