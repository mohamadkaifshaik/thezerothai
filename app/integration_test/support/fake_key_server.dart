import 'dart:async';
import 'dart:typed_data';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/well_known_types/google/protobuf/duration.pb.dart'
    as wkt;
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

// Lives under integration_test/ (the web build of an integration test can
// only reach files below it); test/support/fake_key_server.dart re-exports
// it for the VM tests.

/// The key directory (`KeyService`, proto/dzeroth/keys/v1/keys.proto) in
/// memory, for one caller, behind a real `ApiClient.withTransport` so the
/// repository and everything above it run unchanged. It models the rules the
/// client depends on:
///
/// - device id `[A-Za-z0-9_-]{16,64}`, a 32-byte signature key, the
///   idempotency key format: else INVALID_ARGUMENT + VALIDATION (field);
/// - RegisterKeyDevice is idempotent for the same id and key (refreshes
///   last_seen), a different key for a known id is VALIDATION
///   `signature_public_key` (the stored key is kept), a sixth device is
///   FAILED_PRECONDITION + LIMIT_REACHED `key_devices`;
/// - UploadKeyPackages: unknown device NOT_FOUND; packages stored by content
///   (a replay stores nothing twice while unclaimed; a replay after a claim
///   re-adds the claimed one); at most 100 in the pool; the last-resort one
///   replaced when sent; neither => VALIDATION `key_packages`;
/// - RemoveKeyDevice deletes the device, its pool and last-resort package; a
///   missing device is success;
/// - ClaimKeyPackages takes one package per device of the caller (minus the
///   excluded one), else the last-resort one.
///
/// Test knobs: [calls] logs every RPC that reached the server in order
/// (`register`, `list`, `remove`, `upload`, `get`, `claim`); [failNext]
/// refuses the next call of a procedure before anything is applied;
/// [failAfterApply] applies the next call of a procedure and then answers
/// with the error (an outcome the client cannot know); [hold] makes calls of a
/// procedure wait for a completer; [featureEnabled] off answers
/// FEATURE_DISABLED.
class FakeKeyServer {
  FakeKeyServer({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// The caller's devices by id, in registration order.
  final Map<String, FakeKeyDevice> devices = {};

  final List<String> calls = [];

  /// Every request as received, in order.
  final List<Object> requests = [];

  final Map<String, List<connect.ConnectException>> failNext = {};
  final Map<String, List<connect.ConnectException>> failAfterApply = {};
  final Map<String, Completer<void>> hold = {};

  /// Runs once a call is logged, before anything is applied (to interleave
  /// events with an RPC in flight).
  final Map<String, Future<void> Function()> onCall = {};

  bool featureEnabled = true;

  /// The `conversation_id` a claim answers with ('' = none; K2).
  String claimConversationId = '';

  late final _KeyTransport _transport = _KeyTransport(_handle);

  /// A client whose `keys` calls land here.
  late final ApiClient apiClient = ApiClient.withTransport(_transport);

  List<pb.UploadKeyPackagesRequest> get uploads =>
      requests.whereType<pb.UploadKeyPackagesRequest>().toList();
  List<pb.RegisterKeyDeviceRequest> get registrations =>
      requests.whereType<pb.RegisterKeyDeviceRequest>().toList();
  List<pb.RemoveKeyDeviceRequest> get removals =>
      requests.whereType<pb.RemoveKeyDeviceRequest>().toList();

  /// Every procedure that reached the server.
  int get rpcCount => _transport.calls;

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

  static String _short(String procedure) => switch (procedure.split('/').last) {
    'RegisterKeyDevice' => 'register',
    'ListMyKeyDevices' => 'list',
    'RemoveKeyDevice' => 'remove',
    'UploadKeyPackages' => 'upload',
    'GetKeyDevices' => 'get',
    'ClaimKeyPackages' => 'claim',
    final other => other,
  };

  Future<Object> _handle(String procedure, Object input) async {
    final name = _short(procedure);
    calls.add(name);
    requests.add(input);
    final interleave = onCall[name];
    if (interleave != null) await interleave();
    final held = hold[name];
    if (held != null) await held.future;
    final refusals = failNext[name];
    if (refusals != null && refusals.isNotEmpty) throw refusals.removeAt(0);
    final needsFlag = name != 'list' && name != 'remove';
    if (needsFlag && !featureEnabled) {
      throw keyServerError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'e2ee_dm'},
      );
    }
    final Object out = switch (input) {
      pb.RegisterKeyDeviceRequest r => _register(r),
      pb.ListMyKeyDevicesRequest _ => _list(),
      pb.RemoveKeyDeviceRequest r => _remove(r),
      pb.UploadKeyPackagesRequest r => _upload(r),
      pb.ClaimKeyPackagesRequest r => _claim(r),
      pb.GetKeyDevicesRequest r => _get(r),
      _ => throw UnimplementedError(name),
    };
    final late = failAfterApply[name];
    if (late != null && late.isNotEmpty) throw late.removeAt(0);
    return out;
  }

  static connect.ConnectException _validation(String field) => keyServerError(
    connect.Code.invalidArgument,
    common.ErrorReason.ERROR_REASON_VALIDATION,
    metadata: {'field': field},
  );

  void _checkKey(String key) {
    if (!_idPattern.hasMatch(key)) throw _validation('idempotency_key');
  }

  void _checkId(String id) {
    if (!_idPattern.hasMatch(id)) throw _validation('device_id');
  }

  pb.RegisterKeyDeviceResponse _register(pb.RegisterKeyDeviceRequest r) {
    _checkKey(r.idempotencyKey);
    _checkId(r.deviceId);
    if (r.signaturePublicKey.length != 32) {
      throw _validation('signature_public_key');
    }
    final existing = devices[r.deviceId];
    if (existing != null) {
      if (!_same(existing.signatureKey, r.signaturePublicKey)) {
        throw _validation('signature_public_key');
      }
      existing.lastSeen = _now();
      return pb.RegisterKeyDeviceResponse(device: existing.toProto());
    }
    if (devices.length >= 5) {
      throw keyServerError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
        metadata: {'limit': 'key_devices'},
      );
    }
    final device = FakeKeyDevice(
      id: r.deviceId,
      signatureKey: Uint8List.fromList(r.signaturePublicKey),
      createdAt: _now(),
    )..lastSeen = _now();
    devices[r.deviceId] = device;
    return pb.RegisterKeyDeviceResponse(device: device.toProto());
  }

  pb.ListMyKeyDevicesResponse _list() => pb.ListMyKeyDevicesResponse(
    devices: [for (final d in devices.values) d.toProto()],
  );

  pb.RemoveKeyDeviceResponse _remove(pb.RemoveKeyDeviceRequest r) {
    _checkKey(r.idempotencyKey);
    _checkId(r.deviceId);
    devices.remove(r.deviceId);
    return pb.RemoveKeyDeviceResponse();
  }

  pb.UploadKeyPackagesResponse _upload(pb.UploadKeyPackagesRequest r) {
    _checkKey(r.idempotencyKey);
    _checkId(r.deviceId);
    if (r.keyPackages.isEmpty && r.lastResortKeyPackage.isEmpty) {
      throw _validation('key_packages');
    }
    if (r.keyPackages.length > 100 ||
        r.keyPackages.any((p) => p.isEmpty || p.length > 4096)) {
      throw _validation('key_packages');
    }
    final device = devices[r.deviceId];
    if (device == null) {
      throw connect.ConnectException(connect.Code.notFound, 'not found');
    }
    for (final p in r.keyPackages) {
      if (device.pool.length >= 100) break;
      if (device.pool.any((q) => _same(q, p))) continue;
      device.pool.add(Uint8List.fromList(p));
    }
    if (r.lastResortKeyPackage.isNotEmpty) {
      device.lastResort = Uint8List.fromList(r.lastResortKeyPackage);
    }
    device.lastSeen = _now();
    return pb.UploadKeyPackagesResponse(
      keyPackageCount: device.pool.length,
      hasLastResort: device.lastResort != null,
    );
  }

  pb.ClaimKeyPackagesResponse _claim(pb.ClaimKeyPackagesRequest r) {
    _checkKey(r.idempotencyKey);
    final out = <pb.ClaimedKeyPackage>[];
    for (final d in devices.values) {
      if (d.id == r.excludeDeviceId) continue;
      final claimed = pb.ClaimedKeyPackage(
        deviceId: d.id,
        signaturePublicKey: d.signatureKey,
      );
      if (d.pool.isNotEmpty) {
        claimed
          ..keyPackage = d.pool.removeAt(0)
          ..hasKeyPackage_4 = true;
      } else if (d.lastResort != null) {
        claimed
          ..keyPackage = d.lastResort!
          ..hasKeyPackage_4 = true
          ..lastResort = true;
      }
      out.add(claimed);
    }
    return pb.ClaimKeyPackagesResponse(
      keyPackages: out,
      conversationId: claimConversationId,
    );
  }

  /// Every requested user answers with this caller's devices (the fake holds
  /// one user's directory), each carrying its inactive flag.
  pb.GetKeyDevicesResponse _get(pb.GetKeyDevicesRequest r) =>
      pb.GetKeyDevicesResponse(
        users: [
          for (final id in r.userIds)
            pb.UserKeyDevices(
              userId: id,
              devices: [for (final d in devices.values) d.toProto()],
            ),
        ],
      );

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Routes every unary call to the server's handler (no network, no
/// interceptors), counting what reached it.
class _KeyTransport implements connect.Transport {
  _KeyTransport(this._handler);

  final Future<Object> Function(String procedure, Object input) _handler;
  int calls = 0;

  @override
  Future<connect.UnaryResponse<I, O>> unary<I extends Object, O extends Object>(
    connect.Spec<I, O> spec,
    I input, [
    connect.CallOptions? options,
  ]) async {
    calls++;
    final result = await _handler(spec.procedure, input);
    return connect.UnaryResponse<I, O>(
      spec,
      connect.Headers(),
      result as O,
      connect.Headers(),
    );
  }

  @override
  Future<connect.StreamResponse<I, O>> stream<
    I extends Object,
    O extends Object
  >(connect.Spec<I, O> spec, Stream<I> input, [connect.CallOptions? options]) {
    throw UnimplementedError('no streaming RPCs in KeyService');
  }
}

/// One directory entry of [FakeKeyServer].
class FakeKeyDevice {
  FakeKeyDevice({
    required this.id,
    required this.signatureKey,
    required this.createdAt,
  });

  final String id;
  final Uint8List signatureKey;
  final DateTime createdAt;
  DateTime? lastSeen;
  final List<Uint8List> pool = [];
  Uint8List? lastResort;

  /// K5: the device is registered but no longer active.
  bool inactive = false;

  pb.KeyDevice toProto() => pb.KeyDevice(
    deviceId: id,
    signaturePublicKey: signatureKey,
    createdAt: ts.Timestamp.fromDateTime(createdAt),
    lastSeenAt: lastSeen == null ? null : ts.Timestamp.fromDateTime(lastSeen!),
    keyPackageCount: pool.length,
    hasLastResort: lastResort != null,
    inactive: inactive,
  );
}

/// A server error carrying `ErrorDetail(reason, metadata)` and an optional
/// retry hint.
connect.ConnectException keyServerError(
  connect.Code code,
  common.ErrorReason reason, {
  Map<String, String> metadata = const {},
  Duration? retryAfter,
}) {
  final detail = common.ErrorDetail(
    reason: reason,
    message: 'server says no',
    metadata: metadata.entries,
  );
  if (retryAfter != null) {
    detail.retryAfter = wkt.Duration(seconds: Int64(retryAfter.inSeconds));
  }
  return connect.ConnectException(
    code,
    'server says no',
    details: [
      connect.ErrorDetail(
        'type.googleapis.com/dzeroth.common.v1.ErrorDetail',
        detail.writeToBuffer(),
      ),
    ],
  );
}

/// A plain UNAVAILABLE (no detail): the outcome of a mutation is unknown.
connect.ConnectException keyServerUnavailable() =>
    connect.ConnectException(connect.Code.unavailable, 'unavailable');
