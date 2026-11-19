import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';

/// An engine that can die and be replaced (the web worker). [failed] is true
/// once it can answer nothing any more; [close] stops it.
abstract interface class EngineHealth {
  bool get failed;
  void close();
}

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

  /// Reads the device id and signature public key out of a key package
  /// ([keyPackage] is 1 to 65536 bytes) after full validation: what
  /// [commitChange] applies to a package it adds, plus the 16 to 64 byte
  /// identity rule. Any failure is [MlsErrorCode.badInput]. Takes no state.
  Future<KeyPackageInfo> inspectKeyPackage(Uint8List keyPackage);

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

  /// Replaces this device's own leaf keys in the group. Pending like [commitChange].
  ///
  /// The commit changes no membership (its welcome is null); the device id
  /// and signature key stay the same and only the leaf encryption key is new.
  /// Fails like [commitChange]: corruptState for another device's group
  /// state, then pendingCommit, then evicted.
  Future<CommitResult> selfUpdate(Uint8List deviceState, Uint8List groupState);

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

  // Local-storage sealing ---------------------------------------------------
  //
  // AES-256-GCM for values the app stores on the device; not part of MLS.
  // These calls take no state blob and need no serialization.

  /// Encrypts [plaintext] (0 to 1,048,576 bytes, not the 4096-byte MLS limit)
  /// under [key] (exactly 32 bytes), authenticating [aad].
  ///
  /// Returns `nonce (12 bytes) || ciphertext || tag (16 bytes)`, 28 bytes
  /// longer than [plaintext]. The nonce is fresh random on every call, so two
  /// seals of the same input differ. [aad] is not stored: pass the same bytes
  /// (for example the table and row key) to [open]. Any other key length or a
  /// larger plaintext fails with [MlsErrorCode.badInput].
  Future<Uint8List> seal(Uint8List key, Uint8List aad, Uint8List plaintext);

  /// Decrypts a value made by [seal] with the same [key] and [aad].
  ///
  /// A wrong key, a wrong [aad], altered bytes, or a [sealed] value shorter
  /// than 28 bytes or longer than 1,048,576 + 28 bytes all fail with
  /// [MlsErrorCode.badInput], with the same message for every authentication
  /// failure.
  Future<Uint8List> open(Uint8List key, Uint8List aad, Uint8List sealed);

  /// [length] (1 to 64) bytes from the engine's CSPRNG, for example a new
  /// 32-byte [seal] key. Any other length fails with [MlsErrorCode.badInput].
  Future<Uint8List> randomBytes(int length);
}
