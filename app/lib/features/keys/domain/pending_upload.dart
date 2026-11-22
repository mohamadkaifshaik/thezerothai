import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'device_keys_service.dart' show kKeyPackagePoolTarget;

/// A generated batch whose upload is not confirmed (see
/// `kVaultSettingPendingUpload`).
class PendingUpload {
  const PendingUpload(
    this.oneTime,
    this.lastResort,
    this.countBefore, {
    this.failed = false,
  });

  static const empty = PendingUpload([], null, 0);
  final List<Uint8List> oneTime;
  final Uint8List? lastResort;
  final int countBefore;
  final bool failed;

  bool get isEmpty => oneTime.isEmpty && lastResort == null;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'oneTime': oneTime.map(base64Encode).toList(),
        'lastResort': lastResort == null ? null : base64Encode(lastResort!),
        'countBefore': countBefore,
        'outcome': failed ? 'failed' : 'unknown',
      }),
    ),
  );

  static PendingUpload decode(Uint8List bytes) {
    // The directory accepts at most 4096 bytes per package.
    if (bytes.length > (kKeyPackagePoolTarget + 1) * 5500 + 128) {
      throw const FormatException();
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map || value['v'] != 1) throw const FormatException();
    final packages = value['oneTime'];
    final count = value['countBefore'];
    final outcome = value['outcome'];
    if (packages is! List ||
        packages.length > kKeyPackagePoolTarget ||
        count is! int ||
        count < 0 ||
        !value.containsKey('lastResort') ||
        (outcome != 'failed' && outcome != 'unknown')) {
      throw const FormatException();
    }
    Uint8List package(Object? raw) {
      if (raw is! String || raw.length > 5464) throw const FormatException();
      final decoded = base64Decode(raw);
      if (decoded.isEmpty || decoded.length > 4096) {
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
    );
  }
}
