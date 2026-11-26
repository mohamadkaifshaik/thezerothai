import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_claim.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Case = ({
  String name,
  bool known,
  Set<String> f,
  String p,
  VaultStatus v,
  bool blocked,
  bool want,
});

void main() {
  const live = {kFeatureClaimLive, kFeatureE2eeRequired};
  const ready = VaultStatus.ready;

  _Case row(
    String name, {
    bool known = true,
    Set<String> f = live,
    String p = 'android',
    VaultStatus v = ready,
    bool blocked = false,
    required bool want,
  }) => (
    name: name,
    known: known,
    f: f,
    p: p,
    v: v,
    blocked: blocked,
    want: want,
  );

  group('claimVisible', () {
    final cases = <_Case>[
      row('all hold, android', want: true),
      row('all hold, web', p: 'web', want: true),
      row(
        'flag set not known (pending or another user)',
        known: false,
        want: false,
      ),
      row('without claim_live', f: {kFeatureE2eeRequired}, want: false),
      row('without e2ee_required', f: {kFeatureClaimLive}, want: false),
      row('no flags', f: const {}, p: 'web', want: false),
      row('on iOS', p: 'ios', want: false),
      row('on another platform (level 0)', p: 'other', want: false),
      row('status blocks messaging', blocked: true, want: false),
      row('vault unavailable', v: VaultStatus.unavailable, want: false),
      row(
        'vault unsupported',
        p: 'web',
        v: VaultStatus.unsupported,
        want: false,
      ),
      row('vault key lost', v: VaultStatus.keyLost, want: false),
      row(
        'vault storage changed',
        p: 'web',
        v: VaultStatus.storageChanged,
        want: false,
      ),
      row(
        'vault open in another tab',
        p: 'web',
        v: VaultStatus.heldElsewhere,
        want: false,
      ),
      row('vault off', v: VaultStatus.off, want: false),
      row('vault opening', v: VaultStatus.opening, want: false),
    ];
    for (final c in cases) {
      test(c.name, () {
        expect(
          claimVisible(
            featuresKnown: c.known,
            features: c.f,
            platform: c.p,
            vault: c.v,
            messagingBlocked: c.blocked,
          ),
          c.want,
        );
      });
    }

    test('only an open vault shows it, for every vault state', () {
      // A new VaultStatus must be placed on purpose: shown only if listed.
      expect(kClaimVaultStates, {VaultStatus.ready});
      for (final v in VaultStatus.values) {
        expect(
          claimVisible(
            featuresKnown: true,
            features: live,
            platform: 'android',
            vault: v,
            messagingBlocked: false,
          ),
          v == VaultStatus.ready,
          reason: v.name,
        );
      }
    });
  });
}
