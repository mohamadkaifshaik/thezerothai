import 'dart:typed_data';

/// Stable machine-readable failure codes shared with the Rust core
/// (`crypto/dzmls/src/error.rs`), carried across the binding as strings.
enum MlsErrorCode {
  /// An argument outside the documented limits or of the wrong shape.
  badInput('bad_input'),

  /// A state blob that cannot be decoded or is inconsistent, including a group
  /// state passed with the device state of another device.
  corruptState('corrupt_state'),

  /// A message that belongs to an epoch other than the group's current one.
  wrongEpoch('wrong_epoch'),

  /// This device is no longer a member of the group.
  evicted('evicted'),

  /// A commit of this device is already waiting for the server's decision.
  pendingCommit('pending_commit'),

  /// Confirm or discard was called with no commit waiting.
  noPendingCommit('no_pending_commit'),

  /// The message was already processed (a replay, or this device's own echo).
  duplicate('duplicate'),

  /// An unexpected failure inside the engine.
  internal('internal');

  const MlsErrorCode(this.wire);

  /// The string the Rust core uses for this code.
  final String wire;

  /// The code for [wire]; an unknown string is [internal].
  static MlsErrorCode parse(String wire) {
    for (final code in values) {
      if (code.wire == wire) return code;
    }
    return internal;
  }
}

/// A failed engine call. [message] carries codes and sizes only, never state,
/// keys, plaintext or wire bytes.
class MlsException implements Exception {
  const MlsException(this.code, this.message);

  final MlsErrorCode code;
  final String message;

  @override
  String toString() => 'MlsException(${code.wire}): $message';
}

// The result and event types below carry state blobs, keys, plaintext and
// wire bytes. Never give them a generated toString, Equatable or freezed: those
// print every byte list into logs and test output. They keep Object.toString
// (pinned by test/core/crypto/crypto_types_test.dart).

/// A new device: its state blob and the public half of its signature key.
class DeviceCreated {
  const DeviceCreated({
    required this.deviceState,
    required this.signaturePublicKey,
  });

  final Uint8List deviceState;
  final Uint8List signaturePublicKey;
}

/// Key packages to publish, and the device state after generating them.
class KeyPackagesResult {
  const KeyPackagesResult({
    required this.deviceState,
    required this.keyPackages,
  });

  final Uint8List deviceState;

  /// With a last-resort package, it is the last element.
  final List<Uint8List> keyPackages;
}

/// A staged commit. The group stays in its epoch until the commit is confirmed
/// or discarded.
class CommitResult {
  const CommitResult({
    required this.groupState,
    required this.commit,
    required this.welcome,
    required this.epoch,
  });

  /// The group state with the commit pending.
  final Uint8List groupState;

  /// The commit message to send to the server.
  final Uint8List commit;

  /// The Welcome for the added devices; null when the commit only removes.
  final Uint8List? welcome;

  /// The epoch the commit was made in (the group's epoch before the commit).
  final int epoch;
}

/// A joined group.
class JoinResult {
  const JoinResult({
    required this.deviceState,
    required this.groupState,
    required this.groupId,
    required this.epoch,
  });

  final Uint8List deviceState;
  final Uint8List groupState;
  final Uint8List groupId;
  final int epoch;
}

/// An encrypted message and the group state after sending.
class EncryptResult {
  const EncryptResult({
    required this.groupState,
    required this.ciphertext,
    required this.epoch,
  });

  final Uint8List groupState;
  final Uint8List ciphertext;
  final int epoch;
}

/// What processing one server message produced.
class ProcessResult {
  const ProcessResult({required this.groupState, required this.event});

  final Uint8List groupState;
  final MlsEvent event;
}

/// The outcome of processing a message.
sealed class MlsEvent {
  const MlsEvent();
}

/// An application message from another member.
class MlsMessageEvent extends MlsEvent {
  const MlsMessageEvent({
    required this.plaintext,
    required this.senderDeviceId,
  });

  final Uint8List plaintext;
  final Uint8List senderDeviceId;
}

/// Another member's commit, now merged.
class MlsCommitEvent extends MlsEvent {
  const MlsCommitEvent({
    required this.epoch,
    required this.added,
    required this.removed,
    required this.selfRemoved,
  });

  /// The epoch the group is in after the commit.
  final int epoch;

  /// Device ids added by the commit, in commit order.
  final List<Uint8List> added;

  /// Device ids removed by the commit, in commit order.
  final List<Uint8List> removed;

  /// This device was removed; every later call on the group fails with
  /// [MlsErrorCode.evicted] and the caller should delete the group state.
  final bool selfRemoved;
}

/// A group state blob, read.
class GroupDescription {
  const GroupDescription({
    required this.groupId,
    required this.epoch,
    required this.members,
    required this.hasPendingCommit,
  });

  final Uint8List groupId;
  final int epoch;

  /// Sorted by device id.
  final List<GroupMember> members;
  final bool hasPendingCommit;
}

/// One device in a group.
class GroupMember {
  const GroupMember({required this.deviceId, required this.signaturePublicKey});

  final Uint8List deviceId;
  final Uint8List signaturePublicKey;
}

/// One side of a security code comparison: a user and the signature public
/// keys of all their devices.
class SecurityParty {
  const SecurityParty({required this.userId, required this.deviceKeys});

  /// The user id bytes (UTF-8 of the uid).
  final Uint8List userId;
  final List<Uint8List> deviceKeys;
}
