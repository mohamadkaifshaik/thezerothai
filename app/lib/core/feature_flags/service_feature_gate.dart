import 'package:flutter/foundation.dart';

import '../network/api_client.dart';
import '../network/app_exception.dart';

/// Minimum spacing between GetMe refreshes asked for by a [ServiceFeatureGate].
const kServiceGateRefreshInterval = Duration(seconds: 60);

/// Client-side view of one whole-service server flag (`notifications`,
/// `reports`; ADR-0017 D7 / ADR-0016). `PostsFeatureGate` extends it and adds
/// only the sub-feature set.
///
/// - The flag comes from `GetMe.enabled_features` via [isEnabled]. While it
///   is off, [run] throws [FeatureDisabledException] **without calling the
///   API** (0 RPCs, the server would answer FEATURE_DISABLED with 0 reads).
/// - A FEATURE_DISABLED answer is remembered until [reset] (called after a
///   fresh `GetMe`) and asks for one GetMe refresh (at most every
///   [kServiceGateRefreshInterval]), so the flag set decides, not a sticky
///   local override.
class ServiceFeatureGate extends ChangeNotifier {
  ServiceFeatureGate({
    required bool Function() isEnabled,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    void Function()? onDisabledByServer,
    DateTime Function() now = DateTime.now,
  }) : _isEnabled = isEnabled,
       _onUnexpectedError = onUnexpectedError,
       _onDisabledByServer = onDisabledByServer,
       _now = now;

  final bool Function() _isEnabled;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final void Function()? _onDisabledByServer;
  final DateTime Function() _now;
  DateTime? _lastRefreshRequest;
  bool _disabledByServer = false;

  /// Whether RPCs of this service may be sent at all.
  bool get enabled => _isEnabled() && !_disabledByServer;

  /// Whether the server itself turned this whole service off (remembered
  /// FEATURE_DISABLED), independent of the `GetMe` flag.
  @protected
  bool get disabledByServer => _disabledByServer;

  /// Records a FEATURE_DISABLED answer; subclasses may narrow it (posts
  /// sub-features). Fires the refresh callback only on a real change.
  @protected
  void recordDisabled(FeatureDisabledException exception) {
    if (_disabledByServer) return;
    _disabledByServer = true;
    _requestRefresh();
    notifyListeners();
  }

  /// Forgets a remembered FEATURE_DISABLED answer (after a fresh `GetMe`).
  void reset() {
    if (!_disabledByServer) return;
    _disabledByServer = false;
    notifyListeners();
  }

  /// Runs an API [call]: no RPC while the flag is off; errors are converted
  /// by [guardApiCall]; FEATURE_DISABLED is remembered; an unexpected
  /// [UnknownApiException] goes to `onUnexpectedError` (never the URL).
  Future<T> run<T>(Future<T> Function() call) async {
    if (!enabled) {
      throw const FeatureDisabledException('This feature is not available.');
    }
    try {
      return await guardApiCall(call);
    } on FeatureDisabledException catch (error) {
      recordDisabled(error);
      rethrow;
    } on UnknownApiException catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      rethrow;
    }
  }

  void _requestRefresh() {
    final callback = _onDisabledByServer;
    if (callback == null) return;
    final now = _now();
    final last = _lastRefreshRequest;
    if (last != null && now.difference(last) < kServiceGateRefreshInterval) {
      return;
    }
    _lastRefreshRequest = now;
    callback();
  }
}
