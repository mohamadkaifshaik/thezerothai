import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('result types never print their bytes', () {
    final bytes = Uint8List.fromList(List.filled(8, 0xAB));
    final printed = [
      EncryptResult(groupState: bytes, ciphertext: bytes, epoch: 7),
      ProcessResult(
        groupState: bytes,
        event: MlsMessageEvent(plaintext: bytes, senderDeviceId: bytes),
      ),
      ProcessResult(
        groupState: bytes,
        event: MlsCommitEvent(
          epoch: 2,
          committerDeviceId: bytes,
          added: [bytes],
          addedSignatureKeys: [bytes],
          removed: [bytes],
          selfRemoved: false,
        ),
      ),
    ].map((r) => r.toString());
    for (final p in printed) {
      expect(p, isNot(contains('171')), reason: p);
      expect(p, isNot(contains('[')), reason: p);
    }
  });

  test('KeyPackageInfo keeps Object.toString and own_leaf parses', () {
    final bytes = Uint8List.fromList(List.filled(8, 0xAB));
    final info = KeyPackageInfo(deviceId: bytes, signaturePublicKey: bytes);
    expect(info.toString(), "Instance of 'KeyPackageInfo'");
    expect(MlsErrorCode.parse('own_leaf'), MlsErrorCode.ownLeaf);
    expect(MlsErrorCode.ownLeaf.wire, 'own_leaf');
  });
}
