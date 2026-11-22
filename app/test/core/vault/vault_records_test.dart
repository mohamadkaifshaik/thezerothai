import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int length, int seed) => Uint8List.fromList([
  for (var i = 0; i < length; i++) (i * 31 + seed) & 255,
]);

Uint8List _json(Map<String, Object?> m) =>
    Uint8List.fromList(utf8.encode(jsonEncode(m)));

final Matcher _corrupt = throwsA(isA<VaultCorruptException>());

/// Some `YYYY-MM-DD` day string for the sync record (not read as a date).
final String _day = istDay(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));

void main() {
  group('PendingCommit', () {
    test('round-trips a 65536-byte welcome and 10 device ids', () {
      final original = PendingCommit(
        kind: PendingKind.change,
        builtOn: const MlsPair(3, 9),
        commit: _bytes(300, 1),
        welcome: _bytes(65536, 2),
        welcomeDeviceIds: [for (var i = 0; i < 10; i++) 'device-$i'],
      );
      final back = PendingCommit.decode(original.encode());
      expect(back.kind, PendingKind.change);
      expect(back.builtOn, const MlsPair(3, 9));
      expect(back.commit, original.commit);
      expect(back.welcome, original.welcome);
      expect(back.welcome!.length, 65536);
      expect(back.welcomeDeviceIds, original.welcomeDeviceIds);
    });

    test('round-trips every kind and an absent welcome', () {
      for (final kind in PendingKind.values) {
        final back = PendingCommit.decode(
          PendingCommit(
            kind: kind,
            builtOn: const MlsPair(0, 0),
            commit: Uint8List(1),
          ).encode(),
        );
        expect(back.kind, kind);
        expect(back.welcome, isNull);
        expect(back.welcomeDeviceIds, isEmpty);
        expect(back.commit, hasLength(1));
      }
    });

    test('keptAfterSelfRemoval round-trips; absent reads false and is not '
        'written while false', () {
      PendingCommit make({required bool kept}) => PendingCommit(
        kind: PendingKind.reset,
        builtOn: const MlsPair(2, 0),
        commit: Uint8List(3),
        keptAfterSelfRemoval: kept,
      );
      expect(
        PendingCommit.decode(make(kept: true).encode()).keptAfterSelfRemoval,
        isTrue,
      );
      final plain = make(kept: false).encode();
      expect(PendingCommit.decode(plain).keptAfterSelfRemoval, isFalse);
      final m = jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
      expect(m.containsKey('keptAfterSelfRemoval'), isFalse);
      expect(
        () =>
            PendingCommit.decode(_json({...m, 'keptAfterSelfRemoval': 'yes'})),
        _corrupt,
      );
    });

    test('the encoding is JSON with v 1, base64 bytes and a [g, e] pair', () {
      final text = utf8.decode(
        PendingCommit(
          kind: PendingKind.init,
          builtOn: const MlsPair(1, 2),
          commit: Uint8List.fromList([1, 2, 3, 4]),
        ).encode(),
      );
      final m = jsonDecode(text) as Map<String, Object?>;
      expect(m['v'], 1);
      expect(m['builtOn'], [1, 2]);
      expect(m['commit'], 'AQIDBA==');
    });

    test('a value above 2^53 - 1 or a malformed value is refused', () {
      final ok = {
        'v': 1,
        'kind': 'init',
        'builtOn': [1, 2],
        'commit': 'AQID',
        'welcomeDeviceIds': <String>[],
      };
      expect(PendingCommit.decode(_json(ok)).builtOn, const MlsPair(1, 2));
      expect(
        () => PendingCommit.decode(
          _json({
            ...ok,
            'builtOn': [9007199254740992, 1],
          }),
        ),
        throwsA(isA<VaultCorruptException>()),
      );
      expect(
        () => PendingCommit.decode(
          _json({
            ...ok,
            'builtOn': [-1, 1],
          }),
        ),
        throwsA(isA<VaultCorruptException>()),
      );
      expect(
        () => PendingCommit.decode(_json({...ok, 'kind': 'nope'})),
        throwsA(isA<VaultCorruptException>()),
      );
      expect(
        () => PendingCommit.decode(_json({...ok, 'commit': 'AQI'})),
        throwsA(isA<VaultCorruptException>()),
      );
      expect(
        () => PendingCommit.decode(_json({...ok, 'commit': 'AQ-_'})),
        throwsA(isA<VaultCorruptException>()),
      );
    });

    test('v 2 is refused', () {
      final good = jsonDecode(
        utf8.decode(
          PendingCommit(
            kind: PendingKind.init,
            builtOn: const MlsPair(1, 1),
            commit: Uint8List(1),
          ).encode(),
        ),
      ) as Map<String, Object?>;
      expect(PendingCommit.decode(_json(good)).kind, PendingKind.init);
      expect(() => PendingCommit.decode(_json({...good, 'v': 2})), _corrupt);
    });

    test('a value that is not JSON is VaultCorruptException for the table', () {
      expect(
        () => PendingCommit.decode(Uint8List.fromList([0xff, 0xfe, 0x00])),
        throwsA(
          isA<VaultCorruptException>().having(
            (e) => e.table,
            'table',
            'vault_group_states',
          ),
        ),
      );
      expect(() => PendingCommit.decode(_json({})), _corrupt);
    });
  });

  group('ConversationSync', () {
    test('round-trips every field', () {
      final original = ConversationSync(
        firstSawGeneration: 4,
        firstSawGenerationAtMicros: 1700000000000000,
        lastSelfUpdateAtMicros: 1700000001000000,
        sinceToken: 'token with / and + and = =',
        clearedAtMicros: 1700000002000000,
        completedEpochs: const [MlsPair(1, 1), MlsPair(1, 2), MlsPair(2, 0)],
        commitCallsDay: _day,
        commitCallsToday: 7,
        epochMustAdvance: true,
        requestAccepted: true,
      );
      final back = ConversationSync.decode(original.encode());
      expect(back.firstSawGeneration, 4);
      expect(back.firstSawGenerationAtMicros, 1700000000000000);
      expect(back.lastSelfUpdateAtMicros, 1700000001000000);
      expect(back.sinceToken, 'token with / and + and = =');
      expect(back.clearedAtMicros, 1700000002000000);
      expect(back.completedEpochs, original.completedEpochs);
      expect(back.commitCallsDay, _day);
      expect(back.commitCallsToday, 7);
      expect(back.epochMustAdvance, isTrue);
      expect(back.requestAccepted, isTrue);
    });

    test('the default round-trips and copyWith can set a field to null', () {
      final back = ConversationSync.decode(const ConversationSync().encode());
      expect(back.firstSawGeneration, isNull);
      expect(back.clearedAtMicros, isNull);
      expect(back.sinceToken, '');
      expect(back.completedEpochs, isEmpty);
      expect(back.commitCallsToday, 0);
      expect(back.epochMustAdvance, isFalse);

      const set = ConversationSync(clearedAtMicros: 5, sinceToken: 'a');
      expect(set.copyWith(clearedAtMicros: null).clearedAtMicros, isNull);
      expect(set.copyWith(sinceToken: 'b').clearedAtMicros, 5);
      expect(set.copyWith(sinceToken: 'b').sinceToken, 'b');
      expect(set.copyWith().sinceToken, 'a');
    });

    test('v 2 and a malformed value are refused', () {
      final good = jsonDecode(
        utf8.decode(const ConversationSync().encode()),
      ) as Map<String, Object?>;
      expect(() => ConversationSync.decode(_json({...good, 'v': 2})), _corrupt);
      expect(
        () => ConversationSync.decode(_json({...good, 'v': null})),
        _corrupt,
      );
      expect(
        () =>
            ConversationSync.decode(_json({...good, 'commitCallsToday': 'x'})),
        _corrupt,
      );
      expect(
        () => ConversationSync.decode(
          _json({
            ...good,
            'completedEpochs': [
              [1],
            ],
          }),
        ),
        _corrupt,
      );
    });
  });

  group('RemovalQueue', () {
    test('round-trips entries and the not-before time', () {
      final original = RemovalQueue(
        entries: [
          RemovalQueueEntry(deviceId: _bytes(16, 3), conversationId: 'c1'),
          RemovalQueueEntry(
            deviceId: _bytes(16, 4),
            conversationId: 'c2',
            parked: true,
          ),
        ],
        notBeforeMicros: 1700000000000000,
      );
      final back = RemovalQueue.decode(original.encode());
      expect(back.entries.length, 2);
      expect(back.entries[0].deviceId, _bytes(16, 3));
      expect(back.entries[0].conversationId, 'c1');
      expect(back.entries[0].parked, isFalse);
      expect(back.entries[1].parked, isTrue);
      expect(back.notBeforeMicros, 1700000000000000);

      final empty = RemovalQueue.decode(const RemovalQueue().encode());
      expect(empty.entries, isEmpty);
      expect(empty.notBeforeMicros, isNull);
    });

    test('v 2 is refused', () {
      final good = jsonDecode(
        utf8.decode(const RemovalQueue().encode()),
      ) as Map<String, Object?>;
      expect(() => RemovalQueue.decode(_json({...good, 'v': 2})), _corrupt);
      expect(() => RemovalQueue.decode(Uint8List.fromList([1, 2])), _corrupt);
    });
  });

  group('SystemLineContent', () {
    test('round-trips, and a value that cannot be read decodes to null', () {
      final original = SystemLineContent(
        line: SystemLine.deviceAdded,
        deviceId: _bytes(16, 9),
        side: MemberSide.theirs,
      );
      final back = SystemLineContent.decode(original.encode())!;
      expect(back.line, SystemLine.deviceAdded);
      expect(back.deviceId, _bytes(16, 9));
      expect(back.side, MemberSide.theirs);

      final plain = SystemLineContent.decode(
        const SystemLineContent(line: SystemLine.encryptionReset).encode(),
      )!;
      expect(plain.deviceId, isNull);
      expect(plain.side, isNull);

      expect(SystemLineContent.decode(Uint8List.fromList([0xff])), isNull);
      expect(SystemLineContent.decode(_json({'v': 2, 'line': 'x'})), isNull);
      expect(SystemLineContent.decode(_json({'v': 1})), isNull);
    });

    test(
      'systemLineId is 32 lower-case hex, stable, and depends on every part',
      () {
        final id = systemLineId(
          'c1',
          const MlsPair(1, 2),
          SystemLine.deviceAdded,
          deviceId: Uint8List.fromList([0xab, 0x01]),
        );
        expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
        // Pinned to the formula: first 32 hex of SHA-256 of the literal text.
        String expected(String text) =>
            sha256.convert(utf8.encode(text)).toString().substring(0, 32);
        expect(id, expected('dz-sysline-v1|c1|1|2|deviceAdded|ab01'));
        expect(
          systemLineId('c1', const MlsPair(1, 2), SystemLine.encryptionReset),
          expected('dz-sysline-v1|c1|1|2|encryptionReset|'),
        );
        expect(
          systemLineId(
            'c1',
            const MlsPair(1, 2),
            SystemLine.deviceAdded,
            deviceId: Uint8List.fromList([0xab, 0x01]),
          ),
          id,
        );
        for (final other in [
          systemLineId(
            'c2',
            const MlsPair(1, 2),
            SystemLine.deviceAdded,
            deviceId: Uint8List.fromList([0xab, 0x01]),
          ),
          systemLineId(
            'c1',
            const MlsPair(1, 3),
            SystemLine.deviceAdded,
            deviceId: Uint8List.fromList([0xab, 0x01]),
          ),
          systemLineId(
            'c1',
            const MlsPair(2, 2),
            SystemLine.deviceAdded,
            deviceId: Uint8List.fromList([0xab, 0x01]),
          ),
          systemLineId(
            'c1',
            const MlsPair(1, 2),
            SystemLine.deviceRemoved,
            deviceId: Uint8List.fromList([0xab, 0x01]),
          ),
          systemLineId('c1', const MlsPair(1, 2), SystemLine.deviceAdded),
        ]) {
          expect(other, isNot(id));
        }
      },
    );
  });

  group('istDay', () {
    test('the day turns at 18:30 UTC', () {
      expect(istDay(DateTime.utc(2026, 11, 19, 18, 29, 59)), '2026-11-19');
      expect(istDay(DateTime.utc(2026, 11, 19, 18, 30)), '2026-11-20');
    });

    test('zero-pads and crosses a year', () {
      expect(istDay(DateTime.utc(2026, 1, 5, 0, 0)), '2026-01-05');
      expect(istDay(DateTime.utc(2026, 12, 31, 18, 30)), '2027-01-01');
    });
  });

  test('the two setting keys', () {
    expect(kVaultSettingRegisteredOnce, 'keys.device.registeredOnce');
    expect(kVaultSettingRemovalQueue, 'messages.removalQueue');
  });
}
