import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';

/// The one interface the app uses for end-to-end encryption (MLS, RFC 9420).
///
/// The engine is stateless: every method takes opaque state blobs and returns
/// the new ones, and the caller persists them (encrypted at rest). Nothing is
/// kept in memory between calls, so repeating a call with the same old blobs
/// succeeds again, which is how a crash between processing and persisting is
/// recovered.
///
/// **Callers must serialize calls.** Run one call at a time per device state
/// and one call at a time per group state: two concurrent calls on the same
/// blob both succeed and one result is lost. Every call that takes or returns
/// a `deviceState` is serialized per device; every call on a `groupState` is
/// serialized per group.
///
/// Failures throw [MlsException] with a stable [MlsErrorCode]. A failed call
/// returns no state, so the caller keeps its old blobs. State, keys, plaintext
/// and wire bytes never appear in a message or a log.
///
/// Limits: device and group ids are 16 to 64 bytes; plaintext is at most 4096
/// bytes; wire input is at most 65536 bytes; at most 100 key packages per call.
abstract interface class CryptoEngine {
  /// Creates a device with a fresh signature key. [deviceId] is 16 to 64 bytes
  /// and is the only identity the MLS credential carries.
  Future<DeviceCreated> createDevice(Uint8List deviceId);

  /// Generates [count] (at most 100) one-time key packages, plus one
  /// last-resort package when [lastResort] is set (returned last). A one-time
  /// package admits one join; the last-resort one any number.
  Future<KeyPackagesResult> generateKeyPackages(
    Uint8List deviceState, {
    required int count,
    required bool lastResort,
  });

  /// Creates a group with this device as its only member, at epoch 0.
  Future<Uint8List> createGroup(Uint8List deviceState, Uint8List groupId);

  /// Stages one commit that adds the devices behind [addKeyPackages] and
  /// removes [removeDeviceIds]. The group keeps its epoch until
  /// [confirmCommit] or [discardCommit].
  Future<CommitResult> commitChange(
    Uint8List deviceState,
    Uint8List groupState, {
    List<Uint8List> addKeyPackages = const [],
    List<Uint8List> removeDeviceIds = const [],
  });

  /// The server accepted the pending commit: merge it, moving to the next
  /// epoch.
  Future<Uint8List> confirmCommit(Uint8List deviceState, Uint8List groupState);

  /// The server refused the pending commit: drop it.
  Future<Uint8List> discardCommit(Uint8List deviceState, Uint8List groupState);

  /// Joins a group from a Welcome.
  Future<JoinResult> joinFromWelcome(Uint8List deviceState, Uint8List welcome);

  /// Encrypts [plaintext] (at most 4096 bytes) for the group.
  Future<EncryptResult> encrypt(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List plaintext,
  );

  /// Processes one message from the server: an application message or another
  /// member's commit.
  Future<ProcessResult> process(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List wire,
  );

  /// Reads a group state: id, epoch, members and pending-commit flag.
  Future<GroupDescription> describe(Uint8List groupState);

  /// The epoch in a message's header, read without any state.
  Future<int> wireEpoch(Uint8List wire);

  /// The 60-digit code (12 groups of 5) two users compare out of band.
  /// Symmetric in [a] and [b].
  Future<String> securityCode(SecurityParty a, SecurityParty b);
}
