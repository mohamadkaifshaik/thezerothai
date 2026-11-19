import 'dart:typed_data';

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../gen/dzeroth/keys/v1/keys.pb.dart' as pb;

/// The only caller of `KeyService`, the end-to-end encryption key directory
/// (proto/dzeroth/keys/v1/keys.proto).
///
/// - **Flag.** Every RPC goes through the `e2ee_dm` [ServiceFeatureGate]:
///   with the flag off nothing is sent and [FeatureDisabledException] is
///   thrown; a server FEATURE_DISABLED is remembered until the next `GetMe`.
///   (The server would accept ListMyKeyDevices and RemoveKeyDevice with the
///   user's flag off, as long as it is not globally off; this client sends
///   nothing to `KeyService` with the flag off, per the plan.)
/// - **Errors** are typed by the shared mapper: [ValidationException] with
///   its `field` (`signature_public_key`: a known id with another key),
///   [LimitReachedException] with `quota` = `key_devices` (a sixth device),
///   [RateLimitedException] with its retry hint, [NotFoundException] (an
///   upload for an unregistered device), [NetworkException] (offline,
///   UNAVAILABLE, timeouts).
/// - **Idempotency.** Every mutation takes the caller's `idempotencyKey`; a
///   retry of the same logical request passes the same key. Nothing is
///   retried here.
/// - Key bytes and device ids are never logged.
class KeysRepository {
  KeysRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
  }) : _apiClient = apiClient,
       _gate = gate;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;

  /// Whether `e2ee_dm` is on for the caller (and the server has not said
  /// otherwise since the last `GetMe`).
  bool get enabled => _gate.enabled;

  /// Publishes this device (idempotent for the same id and key).
  Future<pb.RegisterKeyDeviceResponse> registerDevice({
    required String deviceId,
    required List<int> signaturePublicKey,
    required String idempotencyKey,
  }) => _gate.run(
    () => _apiClient.keys.registerKeyDevice(
      pb.RegisterKeyDeviceRequest(
        idempotencyKey: idempotencyKey,
        deviceId: deviceId,
        signaturePublicKey: signaturePublicKey,
      ),
    ),
  );

  /// The caller's devices (at most 5, oldest first, inactive included).
  Future<pb.ListMyKeyDevicesResponse> listMine() => _gate.run(
    () => _apiClient.keys.listMyKeyDevices(pb.ListMyKeyDevicesRequest()),
  );

  /// Removes one of the caller's devices with its pool (a missing device is
  /// success).
  Future<pb.RemoveKeyDeviceResponse> removeDevice({
    required String deviceId,
    required String idempotencyKey,
  }) => _gate.run(
    () => _apiClient.keys.removeKeyDevice(
      pb.RemoveKeyDeviceRequest(
        idempotencyKey: idempotencyKey,
        deviceId: deviceId,
      ),
    ),
  );

  /// Adds [keyPackages] (0-100) to the device's pool and, when given,
  /// replaces its last-resort package. The private parts of every package
  /// must already be persisted (the caller's rule).
  Future<pb.UploadKeyPackagesResponse> uploadKeyPackages({
    required String deviceId,
    required List<Uint8List> keyPackages,
    Uint8List? lastResortKeyPackage,
    required String idempotencyKey,
  }) => _gate.run(
    () => _apiClient.keys.uploadKeyPackages(
      pb.UploadKeyPackagesRequest(
        idempotencyKey: idempotencyKey,
        deviceId: deviceId,
        keyPackages: keyPackages,
        lastResortKeyPackage: lastResortKeyPackage,
      ),
    ),
  );

  /// Active devices of 1-10 users (later plans; unused in this one).
  Future<pb.GetKeyDevicesResponse> getDevices(List<String> userIds) =>
      _gate.run(
        () => _apiClient.keys.getKeyDevices(
          pb.GetKeyDevicesRequest(userIds: userIds),
        ),
      );

  /// Claims one key package per active device of [userId]. NOT replayable:
  /// a retry consumes fresh packages (later plans; unused in this one).
  Future<pb.ClaimKeyPackagesResponse> claim({
    required String userId,
    String excludeDeviceId = '',
    required String idempotencyKey,
  }) => _gate.run(
    () => _apiClient.keys.claimKeyPackages(
      pb.ClaimKeyPackagesRequest(
        idempotencyKey: idempotencyKey,
        userId: userId,
        excludeDeviceId: excludeDeviceId,
      ),
    ),
  );
}
