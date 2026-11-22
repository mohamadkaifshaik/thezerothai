import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'device_keys_service.dart' show kKeyPackagePoolTarget;

/// The largest key package (and last-resort package) the directory
/// accepts: the backend's `keys.MaxKeyPackageBytes`
/// (backend/internal/keys/model.go).
const int kMaxKeyPackageBytes = 4096;

/// The base64 length of a [kMaxKeyPackageBytes] package (padded).
const int _maxPackageBase64 = (kMaxKeyPackageBytes + 2) ~/ 3 * 4;

/// The largest record: [kKeyPackagePoolTarget] one-time packages and a
/// last-resort one at their largest, each quoted and comma-separated, and
/// the fixed keys, the count and `lastResortAt` (about 140 bytes with both
/// integers at 19 digits).
const int kMaxPendingUploadBytes =
    (kKeyPackagePoolTarget + 1) * (_maxPackageBase64 + 3) + 192;

/// A generated batch whose upload is not confirmed (see
/// `kVaultSettingPendingUpload`).
class PendingUpload {
  const PendingUpload(
    this.oneTime,
    this.lastResort,
    this.countBefore, {
    this.failed = false,
    this.lastResortMicros = 0,
  });

  static const empty = PendingUpload([], null, 0);
  final List<Uint8List> oneTime;
  final Uint8List? lastResort;
  final int countBefore;
  final bool failed;

  /// When [lastResort] was generated (microseconds since the epoch; 0 with
  /// none). Written to `kVaultSettingLastResortAt` once it uploads, so a
  /// resend does not restart its 30 days (SA L2).
  final int lastResortMicros;

  bool get isEmpty => oneTime.isEmpty && lastResort == null;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'oneTime': oneTime.map(base64Encode).toList(),
        'lastResort': lastResort == null ? null : base64Encode(lastResort!),
        'lastResortAt': lastResort == null ? null : lastResortMicros,
        'countBefore': countBefore,
        'outcome': failed ? 'failed' : 'unknown',
      }),
    ),
  );

  /// A record without `lastResortAt` (written before it existed) reads its
  /// last-resort package as generated at [nowMicros], the time the resend
  /// then records: what every upload wrote before. Safe: no such record has
  /// shipped.
  static PendingUpload decode(Uint8List bytes, {required int nowMicros}) {
    if (bytes.length > kMaxPendingUploadBytes) {
      throw const FormatException();
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map || value['v'] != 1) throw const FormatException();
    final packages = value['oneTime'];
    final count = value['countBefore'];
    final outcome = value['outcome'];
    final at = value['lastResortAt'];
    if (packages is! List ||
        packages.length > kKeyPackagePoolTarget ||
        count is! int ||
        count < 0 ||
        !value.containsKey('lastResort') ||
        (at != null && (at is! int || at <= 0)) ||
        (outcome != 'failed' && outcome != 'unknown')) {
      throw const FormatException();
    }
    Uint8List package(Object? raw) {
      if (raw is! String || raw.length > _maxPackageBase64) {
        throw const FormatException();
      }
      final decoded = base64Decode(raw);
      if (decoded.isEmpty || decoded.length > kMaxKeyPackageBytes) {
        throw const FormatException();
      }
      return decoded;
    }

    final last = value['lastResort'];
    return PendingUpload(
      packages.map(package).toList(),
      last == null ? null : package(last),
      count,
      failed: outcome == 'failed',
      lastResortMicros: last == null ? 0 : (at as int?) ?? nowMicros,
    );
  }
}
