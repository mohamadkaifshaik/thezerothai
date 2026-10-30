import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';

/// `metadata["limit"]` of a LIMIT_REACHED answer to SendMessage (ADR-0027 D5),
/// as carried by `LimitReachedException.quota`: three messages sent to a
/// request that is not accepted yet.
const kMessagingLimitRequestUnanswered = 'request_unanswered';

/// New conversations started today (per IST day).
const kMessagingLimitDmNewDaily = 'dm_new_daily';

/// What Messages offers the caller (W7-26): everything, the clean-up subset
/// (list, read, mark-read, delete, report, block; no sending), or nothing.
enum MessagingAccess { full, readOnly, hidden }

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
       _flagOn = isMessagingEnabled,
       super(isEnabled: isMessagingEnabled);

  final void Function(Object error, StackTrace stack)? _report;
  final bool Function() _flagOn;
  bool _globallyOff = false;
  bool _probeOk = false;
  int _probeGeneration = 0;

  /// What Messages shows this caller (W7-26, ADR-0027 F6(a)). The one place
  /// that decides; every screen and the router read it.
  ///
  /// - [MessagingAccess.full]: `messaging` is in `GetMe.enabled_features`. Read
  ///   from the flag alone, so a per-caller FEATURE_DISABLED answer to a send
  ///   never hides the screens (a fresh `GetMe` decides).
  /// - [MessagingAccess.readOnly]: not enabled, and this session's [probe]
  ///   succeeded (it ran only because the owner's cache holds a conversation).
  /// - [MessagingAccess.hidden]: anything else, including globally off.
  MessagingAccess get access {
    if (_flagOn()) return MessagingAccess.full;
    if (_probeOk && !_globallyOff) return MessagingAccess.readOnly;
    return MessagingAccess.hidden;
  }

  /// The one probe of a session (and again when the flag set changes): decides
  /// [MessagingAccess.readOnly] for a caller outside the rollout.
  ///
  /// Sends nothing when messaging is enabled for the caller or [hasCached]
  /// (a local query) says the owner's cache holds no conversation. Otherwise
  /// [refresh] (one INBOX ListConversations through [runRead]) runs, and only
  /// a **success** gives `readOnly`. FEATURE_DISABLED (globally off, recorded
  /// by [runRead]) and every other failure (offline, RATE_LIMITED,
  /// UNAVAILABLE) leave `hidden` at session start: nothing flashes while the
  /// answer is unknown. A later probe (the flag set changed) that fails for any
  /// other reason keeps the earlier answer, so a screen is not pulled away on
  /// a bad connection. A probe that returns after the flag set changed, the user signed out
  /// ([endSession]) or a newer probe started is dropped.
  Future<void> probe({
    required Future<bool> Function() hasCached,
    required Future<void> Function() refresh,
  }) async {
    final generation = ++_probeGeneration;
    if (_flagOn()) {
      _setProbeOk(false);
      return;
    }
    if (_globallyOff) return;
    bool cached;
    try {
      cached = await hasCached();
    } on Object {
      return;
    }
    if (generation != _probeGeneration) return;
    if (!cached || _flagOn()) {
      _setProbeOk(false);
      return;
    }
    try {
      await refresh();
    } on Object {
      return;
    }
    if (generation != _probeGeneration || _flagOn() || _globallyOff) return;
    _setProbeOk(true);
  }

  /// Sign-out: forgets the probe (and drops one still in flight), so the next
  /// user starts `hidden`.
  void endSession() {
    _probeGeneration++;
    _setProbeOk(false);
  }

  void _setProbeOk(bool value) {
    if (_probeOk == value) return;
    _probeOk = value;
    notifyListeners();
  }

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
      // The kill switch outlives reset(): readOnly needs a new probe.
      _probeOk = false;
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
