import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_claim.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const live = {kFeatureClaimLive, kFeatureE2eeRequired};

  group('claimVisible', () {
    final cases =
        <({String name, Set<String> f, String p, VaultStatus v, bool want})>[
          (
            name: 'all hold, android',
            f: live,
            p: 'android',
            v: VaultStatus.ready,
            want: true,
          ),
          (
            name: 'all hold, web',
            f: live,
            p: 'web',
            v: VaultStatus.ready,
            want: true,
          ),
          (
            name: 'web, open in another tab',
            f: live,
            p: 'web',
            v: VaultStatus.heldElsewhere,
            want: true,
          ),
          (
            name: 'without claim_live',
            f: {kFeatureE2eeRequired},
            p: 'android',
            v: VaultStatus.ready,
            want: false,
          ),
          (
            name: 'without e2ee_required',
            f: {kFeatureClaimLive},
            p: 'android',
            v: VaultStatus.ready,
            want: false,
          ),
          (
            name: 'no flags',
            f: const {},
            p: 'web',
            v: VaultStatus.ready,
            want: false,
          ),
          (
            name: 'on iOS',
            f: live,
            p: 'ios',
            v: VaultStatus.ready,
            want: false,
          ),
          (
            name: 'on another platform (level 0)',
            f: live,
            p: 'other',
            v: VaultStatus.ready,
            want: false,
          ),
          (
            name: 'vault unavailable',
            f: live,
            p: 'android',
            v: VaultStatus.unavailable,
            want: false,
          ),
          (
            name: 'vault unsupported',
            f: live,
            p: 'web',
            v: VaultStatus.unsupported,
            want: false,
          ),
          (
            name: 'vault key lost',
            f: live,
            p: 'android',
            v: VaultStatus.keyLost,
            want: false,
          ),
          (
            name: 'vault storage changed',
            f: live,
            p: 'web',
            v: VaultStatus.storageChanged,
            want: false,
          ),
          (
            name: 'vault off',
            f: live,
            p: 'android',
            v: VaultStatus.off,
            want: false,
          ),
          (
            name: 'vault opening',
            f: live,
            p: 'android',
            v: VaultStatus.opening,
            want: false,
          ),
        ];
    for (final c in cases) {
      test(c.name, () {
        expect(claimVisible(features: c.f, platform: c.p, vault: c.v), c.want);
      });
    }

    test('every vault state is decided by the table above', () {
      // A new VaultStatus must be placed on purpose: shown only if listed.
      expect(kClaimVaultStates, {VaultStatus.ready, VaultStatus.heldElsewhere});
      for (final v in VaultStatus.values) {
        expect(
          claimVisible(features: live, platform: 'android', vault: v),
          kClaimVaultStates.contains(v),
          reason: v.name,
        );
      }
    });
  });
}
