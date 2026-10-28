import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';

/// `metadata["limit"]` of a LIMIT_REACHED answer to SendMessage (ADR-0027 D5),
/// as carried by `LimitReachedException.quota`: three messages sent to a
/// request that is not accepted yet.
const kMessagingLimitRequestUnanswered = 'request_unanswered';

/// New conversations started today (per IST day).
const kMessagingLimitDmNewDaily = 'dm_new_daily';

/// Client view of the `messaging` flag (ADR-0027 D6 / F6). The server flag has
/// two meanings, so the gate has two entry points:
///
/// - [run] is for the per-caller RPCs, SendMessage and AcceptMessageRequest.
///   While `GetMe.enabled_features` lacks `messaging` it throws
///   [FeatureDisabledException] without calling the API.
/// - [runRead] is for the RPCs that need the flag only "not globally off":
///   ListConversations, ListMessages, MarkConversationRead and
///   DeleteConversation. A user dropped from an allowlist can still read and
///   clean up, so the local flag does not stop them and `GetMe` cannot tell
///   (it lists the flag per caller): the server decides. Its FEATURE_DISABLED
///   means the flag is globally off.
///
/// A FEATURE_DISABLED answer to a send is per caller: it stops sends, not
/// reads. One to a read is global: it stops everything. Either is forgotten on
/// [reset] (after a fresh `GetMe`). Both ask for a `GetMe` refresh, throttled
/// by the base class.
class MessagingFeatureGate extends ServiceFeatureGate {
  MessagingFeatureGate({
    required bool Function() isMessagingEnabled,
    super.onUnexpectedError,
    super.onDisabledByServer,
    super.now,
  }) : _report = onUnexpectedError,
       super(isEnabled: isMessagingEnabled);

  final void Function(Object error, StackTrace stack)? _report;
  bool _globallyOff = false;

  /// Whether this caller may send and accept (the per-caller flag).
  bool get canSend => enabled;

  /// Whether reads and clean-up may be tried: false only after the server
  /// answered that messaging is globally off.
  bool get canRead => !_globallyOff;

  /// Runs a read or clean-up [call] (not globally off is enough).
  Future<T> runRead<T>(Future<T> Function() call) async {
    if (_globallyOff) {
      throw const FeatureDisabledException('This feature is not available.');
    }
    try {
      return await guardApiCall(call);
    } on FeatureDisabledException catch (error) {
      final alreadyRecorded = disabledByServer;
      _globallyOff = true;
      recordDisabled(error);
      // recordDisabled notifies only on its own change.
      if (alreadyRecorded) notifyListeners();
      rethrow;
    } on UnknownApiException catch (error, stack) {
      _report?.call(error, stack);
      rethrow;
    }
  }

  @override
  void reset() {
    final had = _globallyOff;
    _globallyOff = false;
    if (had && !disabledByServer) notifyListeners();
    super.reset();
  }
}
