import 'dart:async';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:flutter/foundation.dart';

/// How long one engine call may take before the caller gets
/// [MlsErrorCode.deadline].
const Duration kEngineCallDeadline = Duration(seconds: 30);

class _DeadlineHit implements Exception {
  const _DeadlineHit();
}

/// A [CryptoEngine] that gives every call a deadline and replaces a failed
/// engine (the web worker) at most once per app resume.
///
/// The inner engine is created on the first call. A *failure* is a timeout on
/// an inner engine that is an [EngineHealth], or any error after which that
/// engine reports `failed`. The first failure since start or resume closes the
/// engine and builds a new one with `create`; the call that hit it rethrows its
/// error and is not re-run. The second failure sets [unavailable]: every call
/// then fails at once with [MlsErrorCode.unavailable] until [onAppResumed].
/// Failures are counted per engine instance: calls still in flight on an
/// engine that was already replaced fail with their own error and count
/// nothing. An engine that is not an [EngineHealth] (Android) is never
/// replaced; a timed-out call there fails with [MlsErrorCode.deadline] and its
/// late result is dropped.
///
/// Nothing here logs or keeps arguments, results or state.
class GuardedCryptoEngine implements CryptoEngine {
  GuardedCryptoEngine({
    required CryptoEngine Function() create,
    Duration deadline = kEngineCallDeadline,
  }) : _create = create,
       _deadline = deadline;

  final CryptoEngine Function() _create;
  final Duration _deadline;

  CryptoEngine? _inner;
  int _failures = 0;
  bool _closed = false;
  final ValueNotifier<bool> _unavailable = ValueNotifier<bool>(false);

  /// True from the second failure until [onAppResumed].
  ValueListenable<bool> get unavailable => _unavailable;

  /// Clears [unavailable] and allows one replacement again.
  void onAppResumed() {
    if (_closed) return;
    _failures = 0;
    _unavailable.value = false;
  }

  /// Closes the inner engine; later calls fail with
  /// [MlsErrorCode.unavailable].
  void close() {
    if (_closed) return;
    _closed = true;
    final inner = _inner;
    _inner = null;
    _closeQuietly(inner);
  }

  static const MlsException _unavailableError = MlsException(
    MlsErrorCode.unavailable,
    'the crypto engine is unavailable',
  );

  static void _closeQuietly(CryptoEngine? engine) {
    if (engine is! EngineHealth) return;
    try {
      (engine as EngineHealth).close();
    } on Object {
      // A worker that cannot be stopped is dropped all the same.
    }
  }

  CryptoEngine _engine() {
    final existing = _inner;
    if (existing != null) return existing;
    try {
      return _inner = _create();
    } on Object {
      _countFailure();
      throw const MlsException(
        MlsErrorCode.internal,
        'the crypto engine could not be created',
      );
    }
  }

  void _countFailure() {
    _failures++;
    if (_failures >= 2) _unavailable.value = true;
  }

  // The engine [failed] did not answer or died. Only its current instance
  // counts; a replaced one's stragglers change nothing.
  void _onFailure(CryptoEngine failed) {
    if (_closed || !identical(_inner, failed)) return;
    _inner = null;
    _closeQuietly(failed);
    _countFailure();
    if (_unavailable.value) return;
    try {
      _inner = _create();
    } on Object {
      _countFailure();
    }
  }

  Future<T> _call<T>(Future<T> Function(CryptoEngine engine) op) async {
    if (_closed || _unavailable.value) throw _unavailableError;
    final engine = _engine();
    final Future<T> pending = Future<T>.sync(() => op(engine));
    try {
      return await pending.timeout(
        _deadline,
        onTimeout: () => throw const _DeadlineHit(),
      );
    } on _DeadlineHit {
      // The late result, if any, is dropped: never returned, never stored.
      pending.ignore();
      if (engine is EngineHealth) _onFailure(engine);
      throw const MlsException(MlsErrorCode.deadline, 'engine call timed out');
    } on Object {
      final health = engine;
      if (health is EngineHealth && (health as EngineHealth).failed) {
        _onFailure(engine);
      }
      rethrow;
    }
  }

  @override
  Future<DeviceCreated> createDevice(Uint8List deviceId) =>
      _call((e) => e.createDevice(deviceId));

  @override
  Future<KeyPackagesResult> generateKeyPackages(
    Uint8List deviceState, {
    required int count,
    required bool lastResort,
  }) => _call(
    (e) => e.generateKeyPackages(
      deviceState,
      count: count,
      lastResort: lastResort,
    ),
  );

  @override
  Future<KeyPackageInfo> inspectKeyPackage(Uint8List keyPackage) =>
      _call((e) => e.inspectKeyPackage(keyPackage));

  @override
  Future<Uint8List> createGroup(Uint8List deviceState, Uint8List groupId) =>
      _call((e) => e.createGroup(deviceState, groupId));

  @override
  Future<CommitResult> commitChange(
    Uint8List deviceState,
    Uint8List groupState, {
    List<Uint8List> addKeyPackages = const [],
    List<Uint8List> removeDeviceIds = const [],
  }) => _call(
    (e) => e.commitChange(
      deviceState,
      groupState,
      addKeyPackages: addKeyPackages,
      removeDeviceIds: removeDeviceIds,
    ),
  );

  @override
  Future<CommitResult> selfUpdate(
    Uint8List deviceState,
    Uint8List groupState,
  ) => _call((e) => e.selfUpdate(deviceState, groupState));

  @override
  Future<Uint8List> confirmCommit(
    Uint8List deviceState,
    Uint8List groupState,
  ) => _call((e) => e.confirmCommit(deviceState, groupState));

  @override
  Future<Uint8List> discardCommit(
    Uint8List deviceState,
    Uint8List groupState,
  ) => _call((e) => e.discardCommit(deviceState, groupState));

  @override
  Future<JoinResult> joinFromWelcome(
    Uint8List deviceState,
    Uint8List welcome,
  ) => _call((e) => e.joinFromWelcome(deviceState, welcome));

  @override
  Future<EncryptResult> encrypt(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List plaintext,
  ) => _call((e) => e.encrypt(deviceState, groupState, plaintext));

  @override
  Future<ProcessResult> process(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List wire,
  ) => _call((e) => e.process(deviceState, groupState, wire));

  @override
  Future<GroupDescription> describe(Uint8List groupState) =>
      _call((e) => e.describe(groupState));

  @override
  Future<int> wireEpoch(Uint8List wire) => _call((e) => e.wireEpoch(wire));

  @override
  Future<String> securityCode(SecurityParty a, SecurityParty b) =>
      _call((e) => e.securityCode(a, b));

  @override
  Future<Uint8List> seal(Uint8List key, Uint8List aad, Uint8List plaintext) =>
      _call((e) => e.seal(key, aad, plaintext));

  @override
  Future<Uint8List> open(Uint8List key, Uint8List aad, Uint8List sealed) =>
      _call((e) => e.open(key, aad, sealed));

  @override
  Future<Uint8List> randomBytes(int length) =>
      _call((e) => e.randomBytes(length));
}
