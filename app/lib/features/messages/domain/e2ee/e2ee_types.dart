import 'dart:typed_data';

import '../../../../core/network/app_exception.dart';

/// Where a conversation stands in the encrypted messaging pipeline.
enum ConversationPhase {
  /// No MLS group known and the server has not said MLS.
  notEncrypted,

  /// Member of the current group.
  ready,

  /// This device started or reset encryption; the server's answer is not
  /// known yet.
  provisional,

  /// The conversation is MLS and this device has no usable group.
  waitingForWelcome,

  /// A member that cannot go on: needs a reset.
  stuck,
}

/// Why this device will not encrypt and send in the conversation right now.
/// [none] means it may.
enum SendBlock {
  none,
  unavailable,
  notSynced,
  provisional,
  waitingForWelcome,
  stuck,
  unknownDevice,
  epochMustAdvance,
  peerHasNoDevice,
  cannotMessage,
}

/// Immutable crypto state of one conversation. [toString] prints enum names,
/// booleans and counts only.
class ConversationCryptoState {
  const ConversationCryptoState({
    required this.phase,
    required this.sendBlock,
    required this.requestAccepted,
    required this.incomingRequest,
    required this.deviceListUnverifiable,
    required this.unknownDevicePresent,
    required this.committingPausedToday,
    required this.unattributedPresent,
    required this.myDeviceCount,
    required this.theirDeviceCount,
    required this.canReset,
    this.resetAllowedAt,
    this.keyHistoryClosed = false,
    this.mayAllowMoreDevices = false,
  });

  final ConversationPhase phase;
  final SendBlock sendBlock;
  final bool requestAccepted;
  final bool incomingRequest;
  final bool deviceListUnverifiable;
  final bool unknownDevicePresent;
  final bool committingPausedToday;

  /// Any pin is unattributed (pending, deferred or unknown).
  final bool unattributedPresent;
  final int myDeviceCount;
  final int theirDeviceCount;
  final bool canReset;
  final DateTime? resetAllowedAt;

  /// This conversation's device key history is closed: every device id
  /// first seen from now on stays an unknown device here until the user
  /// allows new devices.
  final bool keyHistoryClosed;

  /// [keyHistoryClosed], and the user may still allow new devices here (the
  /// allowance is below its maximum).
  final bool mayAllowMoreDevices;

  /// `ready` excludes provisional (its own phase): no code on a provisional
  /// group.
  bool get codeAvailable =>
      phase == ConversationPhase.ready &&
      requestAccepted &&
      !unknownDevicePresent &&
      !deviceListUnverifiable &&
      !unattributedPresent;

  static const ConversationCryptoState initial = ConversationCryptoState(
    phase: ConversationPhase.notEncrypted,
    sendBlock: SendBlock.none,
    requestAccepted: false,
    incomingRequest: false,
    deviceListUnverifiable: false,
    unknownDevicePresent: false,
    committingPausedToday: false,
    unattributedPresent: false,
    myDeviceCount: 0,
    theirDeviceCount: 0,
    canReset: false,
  );

  @override
  bool operator ==(Object other) =>
      other is ConversationCryptoState &&
      other.phase == phase &&
      other.sendBlock == sendBlock &&
      other.requestAccepted == requestAccepted &&
      other.incomingRequest == incomingRequest &&
      other.deviceListUnverifiable == deviceListUnverifiable &&
      other.unknownDevicePresent == unknownDevicePresent &&
      other.committingPausedToday == committingPausedToday &&
      other.unattributedPresent == unattributedPresent &&
      other.myDeviceCount == myDeviceCount &&
      other.theirDeviceCount == theirDeviceCount &&
      other.canReset == canReset &&
      other.resetAllowedAt == resetAllowedAt &&
      other.keyHistoryClosed == keyHistoryClosed &&
      other.mayAllowMoreDevices == mayAllowMoreDevices;

  @override
  int get hashCode => Object.hash(
    phase,
    sendBlock,
    requestAccepted,
    incomingRequest,
    deviceListUnverifiable,
    unknownDevicePresent,
    committingPausedToday,
    unattributedPresent,
    myDeviceCount,
    theirDeviceCount,
    canReset,
    resetAllowedAt,
    keyHistoryClosed,
    mayAllowMoreDevices,
  );

  @override
  String toString() =>
      'ConversationCryptoState(phase: ${phase.name}, '
      'sendBlock: ${sendBlock.name}, requestAccepted: $requestAccepted, '
      'incomingRequest: $incomingRequest, '
      'deviceListUnverifiable: $deviceListUnverifiable, '
      'unknownDevicePresent: $unknownDevicePresent, '
      'committingPausedToday: $committingPausedToday, '
      'unattributedPresent: $unattributedPresent, '
      'myDeviceCount: $myDeviceCount, theirDeviceCount: $theirDeviceCount, '
      'canReset: $canReset, hasResetAllowedAt: ${resetAllowedAt != null}, '
      'keyHistoryClosed: $keyHistoryClosed, '
      'mayAllowMoreDevices: $mayAllowMoreDevices)';
}

/// `OutgoingStatus` is taken by `message_outbox.dart`, hence the suffix.
enum OutgoingStatus5a { waiting, sending, failed }

/// One outgoing encrypted message in the pipeline. Defines no `toString`.
class OutgoingRow {
  const OutgoingRow({
    required this.localId,
    required this.conversationId,
    required this.content,
    required this.createdAt,
    required this.status,
    required this.waitingOn,
    required this.error,
    required this.retryable,
    required this.tryTomorrow,
  });

  final String localId;
  final String? conversationId;
  final Uint8List content;
  final DateTime createdAt;
  final OutgoingStatus5a status;
  final SendBlock waitingOn;
  final AppException? error;
  final bool retryable;
  final bool tryTomorrow;
}

enum E2eeRefusal {
  unavailable,
  flagOff,
  notMember,
  notAccepted,
  peerHasNoDevice,
  tryAgainTomorrow,
  refusedByServer,
}

class E2eeActionException implements Exception {
  const E2eeActionException(this.refusal, {this.cause});

  final E2eeRefusal refusal;
  final AppException? cause;
}

/// An unexpected pipeline failure. Names the step only: never an id, key,
/// bytes or the original message.
class E2eePipelineError implements Exception {
  const E2eePipelineError(this.step);

  final String step;

  @override
  String toString() => 'E2eePipelineError($step)';
}
