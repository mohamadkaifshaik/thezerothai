import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/frb_generated/api.dart' as rust;
import 'package:dzeroth/core/crypto/frb_generated/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

/// The library the Android build bundles (app/rust, built by app/rust_builder).
const _library = 'libdzmls_flutter.so';

/// Loading the library is process-wide and happens once, on the first call of
/// any engine. A failed load is remembered: every later call fails the same
/// way.
Future<void>? _loaded;

Future<void> _load() => _loaded ??= Future.sync(
  () => RustLib.init(externalLibrary: ExternalLibrary.open(_library)),
);

/// A [CryptoEngine] over the Rust core (`crypto/dzmls`) through
/// flutter_rust_bridge, for Android.
///
/// Every call runs on the bridge's Rust worker threads and completes a
/// [Future], so no cryptography runs on the UI isolate. A core error becomes
/// [MlsException] with its code. Anything else (the library failed to load,
/// a Rust panic, an unexpected result) becomes [MlsErrorCode.internal] with a
/// fixed message: panic text is never passed on. Nothing here logs or keeps
/// arguments, results or state.
class NativeCryptoEngine implements CryptoEngine {
  static const _notLoaded = MlsException(
    MlsErrorCode.internal,
    'the mls library could not be loaded',
  );
  static const _failed = MlsException(
    MlsErrorCode.internal,
    'the mls library failed',
  );
  static const _malformed = MlsException(
    MlsErrorCode.internal,
    'malformed mls library result',
  );

  Future<T> _call<T>(Future<T> Function() call) async {
    try {
      await _load();
    } on Object {
      throw _notLoaded;
    }
    try {
      return await call();
    } on rust.MlsError catch (e) {
      throw MlsException(MlsErrorCode.parse(e.code), e.message);
    } on MlsException {
      rethrow;
    } on Object {
      // PanicException and anything else the bridge throws. Its text may
      // describe internals, so it is dropped.
      throw _failed;
    }
  }

  static int _int(BigInt value) {
    if (!value.isValidInt) throw _malformed;
    return value.toInt();
  }

  static CommitResult _commit(rust.Commit c) => CommitResult(
    groupState: c.groupState,
    commit: c.commit,
    welcome: c.welcome,
    epoch: _int(c.epoch),
  );

  static rust.Party _party(SecurityParty p) =>
      rust.Party(userId: p.userId, deviceKeys: p.deviceKeys);

  @override
  Future<DeviceCreated> createDevice(Uint8List deviceId) => _call(() async {
    final d = await rust.createDevice(deviceId: deviceId);
    return DeviceCreated(
      deviceState: d.deviceState,
      signaturePublicKey: d.signaturePublicKey,
    );
  });

  @override
  Future<KeyPackagesResult> generateKeyPackages(
    Uint8List deviceState, {
    required int count,
    required bool lastResort,
  }) => _call(() async {
    // u32 on the Rust side: a count outside it is refused here, as the core
    // would refuse it (at most 100), rather than wrapped by the bridge.
    if (count < 0 || count > 0xFFFFFFFF) {
      throw const MlsException(
        MlsErrorCode.badInput,
        'key package count out of range',
      );
    }
    final k = await rust.generateKeyPackages(
      deviceState: deviceState,
      count: count,
      lastResort: lastResort,
    );
    return KeyPackagesResult(
      deviceState: k.deviceState,
      keyPackages: k.keyPackages,
    );
  });

  @override
  Future<Uint8List> createGroup(Uint8List deviceState, Uint8List groupId) =>
      _call(() => rust.createGroup(deviceState: deviceState, groupId: groupId));

  @override
  Future<CommitResult> commitChange(
    Uint8List deviceState,
    Uint8List groupState, {
    List<Uint8List> addKeyPackages = const [],
    List<Uint8List> removeDeviceIds = const [],
  }) => _call(
    () async => _commit(
      await rust.commitChange(
        deviceState: deviceState,
        groupState: groupState,
        addKeyPackages: addKeyPackages,
        removeDeviceIds: removeDeviceIds,
      ),
    ),
  );

  @override
  Future<CommitResult> selfUpdate(
    Uint8List deviceState,
    Uint8List groupState,
  ) => _call(
    () async => _commit(
      await rust.selfUpdate(deviceState: deviceState, groupState: groupState),
    ),
  );

  @override
  Future<Uint8List> confirmCommit(
    Uint8List deviceState,
    Uint8List groupState,
  ) => _call(
    () => rust.confirmCommit(deviceState: deviceState, groupState: groupState),
  );

  @override
  Future<Uint8List> discardCommit(
    Uint8List deviceState,
    Uint8List groupState,
  ) => _call(
    () => rust.discardCommit(deviceState: deviceState, groupState: groupState),
  );

  @override
  Future<JoinResult> joinFromWelcome(
    Uint8List deviceState,
    Uint8List welcome,
  ) => _call(() async {
    final j = await rust.joinFromWelcome(
      deviceState: deviceState,
      welcome: welcome,
    );
    return JoinResult(
      deviceState: j.deviceState,
      groupState: j.groupState,
      groupId: j.groupId,
      epoch: _int(j.epoch),
    );
  });

  @override
  Future<EncryptResult> encrypt(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List plaintext,
  ) => _call(() async {
    final e = await rust.encrypt(
      deviceState: deviceState,
      groupState: groupState,
      plaintext: plaintext,
    );
    return EncryptResult(
      groupState: e.groupState,
      ciphertext: e.ciphertext,
      epoch: _int(e.epoch),
    );
  });

  @override
  Future<ProcessResult> process(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List wire,
  ) => _call(() async {
    final p = await rust.process(
      deviceState: deviceState,
      groupState: groupState,
      wire: wire,
    );
    final MlsEvent event;
    switch ((p.message, p.commit)) {
      case (final rust.MessageEvent m, null):
        event = MlsMessageEvent(
          plaintext: m.plaintext,
          senderDeviceId: m.senderDeviceId,
        );
      case (null, final rust.CommitEvent c):
        event = MlsCommitEvent(
          epoch: _int(c.epoch),
          added: c.added,
          removed: c.removed,
          selfRemoved: c.selfRemoved,
        );
      default:
        throw _malformed;
    }
    return ProcessResult(groupState: p.groupState, event: event);
  });

  @override
  Future<GroupDescription> describe(Uint8List groupState) => _call(() async {
    final g = await rust.describe(groupState: groupState);
    return GroupDescription(
      groupId: g.groupId,
      epoch: _int(g.epoch),
      members: [
        for (final m in g.members)
          GroupMember(
            deviceId: m.deviceId,
            signaturePublicKey: m.signaturePublicKey,
          ),
      ],
      hasPendingCommit: g.hasPendingCommit,
    );
  });

  @override
  Future<int> wireEpoch(Uint8List wire) =>
      _call(() async => _int(await rust.wireEpoch(wire: wire)));

  @override
  Future<String> securityCode(SecurityParty a, SecurityParty b) =>
      _call(() => rust.securityCode(a: _party(a), b: _party(b)));

  @override
  Future<Uint8List> seal(Uint8List key, Uint8List aad, Uint8List plaintext) =>
      _call(() => rust.seal(key: key, aad: aad, plaintext: plaintext));

  @override
  Future<Uint8List> open(Uint8List key, Uint8List aad, Uint8List sealed) =>
      _call(() => rust.open(key: key, aad: aad, sealed: sealed));

  @override
  Future<Uint8List> randomBytes(int length) => _call(() {
    // u32 on the Rust side: refused here rather than wrapped by the bridge.
    if (length < 1 || length > 64) {
      throw const MlsException(
        MlsErrorCode.badInput,
        'random length out of range',
      );
    }
    return rust.randomBytes(length: length);
  });
}
