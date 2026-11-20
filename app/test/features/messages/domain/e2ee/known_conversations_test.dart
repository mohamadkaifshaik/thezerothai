import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/known_conversations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';
const _c3 = '33333333333333333333333333333333';

void main() {
  late Directory dir;
  late RigClock clock;
  late RigDevice device;
  late KnownConversations known;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('known_test');
    clock = RigClock();
    device = await RigDevice.create(dir: dir, clock: clock);
    known = KnownConversations(session: device.session);
    await known.load(device.vault);
  });

  tearDown(() async {
    await device.dispose();
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Windows can hold the file briefly.
    }
  });

  test('the known set and peer refs survive a new instance on the same '
      'vault', () async {
    await known.add(_c1, peerUserId: 'peer-ref-1');
    await known.add(_c2);
    final again = KnownConversations(session: device.session);
    await again.load(device.vault);
    expect(again.contains(_c1), isTrue);
    expect(again.contains(_c2), isTrue);
    expect(again.contains(_c3), isFalse);
    expect(await again.conversationForPeer(device.vault, 'peer-ref-1'), _c1);
    // And after a restart of the whole device.
    await device.restart();
    final third = KnownConversations(session: device.session);
    await third.load(device.vault);
    expect(third.contains(_c1), isTrue);
    expect(third.peerOf(_c1), 'peer-ref-1');
  });

  test('the raw settings value holds no id in clear', () async {
    await known.add(_c1, peerUserId: 'peer-ref-1');
    final rows = await device.db
        .customSelect(
          'SELECT value FROM vault_settings WHERE setting_key = ?',
          variables: [Variable.withString(kVaultSettingKnownConversations)],
        )
        .get();
    expect(rows, hasLength(1));
    final raw = rows.single.read<Uint8List>('value');
    final text = latin1.decode(raw);
    expect(text.contains(_c1), isFalse);
    expect(text.contains('peer-ref-1'), isFalse);
  });

  test("addIn is written in the caller's transaction", () async {
    // A failing transaction leaves the stored record and the image unchanged.
    await expectLater(
      device.session.runWrite(
        (vault) => vault.transaction((tx) async {
          await known.addIn(tx, vault, _c1, peerUserId: 'peer-ref-1');
          throw StateError('the transaction fails');
        }),
      ),
      throwsStateError,
    );
    known.discardStaged();
    expect(known.contains(_c1), isFalse);
    final fresh = KnownConversations(session: device.session);
    await fresh.load(device.vault);
    expect(fresh.contains(_c1), isFalse);
    // A committed one is written, and visible once the caller settles it.
    await device.session.runWrite(
      (vault) => vault.transaction((tx) => known.addIn(tx, vault, _c1)),
    );
    expect(known.contains(_c1), isFalse, reason: 'not before commitStaged');
    known.commitStaged();
    expect(known.contains(_c1), isTrue);
    final stored = KnownConversations(session: device.session);
    await stored.load(device.vault);
    expect(stored.contains(_c1), isTrue);
  });

  test("a known set loaded for another vault is never written into this "
      "vault's transaction", () async {
    // Another user's vault (another session); the set stays loaded for the
    // first one.
    final other = await RigDevice.create(
      dir: dir,
      clock: clock,
      uid: 'user-b',
      name: 'two',
    );
    addTearDown(other.dispose);
    await known.add(_c1, peerUserId: 'peer-ref-1');
    expect(known.isLoadedFor(device.vault), isTrue);
    expect(known.isLoadedFor(other.vault), isFalse);

    await expectLater(
      other.session.runWrite(
        (vault) => vault.transaction((tx) => known.addIn(tx, vault, _c2)),
      ),
      throwsStateError,
    );
    known.discardStaged();
    expect(await other.vault.setting(kVaultSettingKnownConversations), isNull);
    expect(known.contains(_c2), isFalse);
    // This vault's record is unchanged.
    final again = KnownConversations(session: device.session);
    await again.load(device.vault);
    expect(again.ids, [_c1]);
  });

  test('two conversations added under their own locks both stay in the '
      'set', () async {
    // Two bodies serialised by the session, each reading the record fresh.
    await Future.wait([
      known.add(_c1, peerUserId: 'peer-ref-1'),
      known.add(_c2, peerUserId: 'peer-ref-2'),
    ]);
    final stored = KnownConversations(session: device.session);
    await stored.load(device.vault);
    expect(stored.contains(_c1), isTrue);
    expect(stored.contains(_c2), isTrue);
    expect(known.contains(_c1) && known.contains(_c2), isTrue);
    expect(stored.peerOf(_c1), 'peer-ref-1');
    expect(stored.peerOf(_c2), 'peer-ref-2');
  });

  test('conversationForPeer resolves a stored peer ref', () async {
    await known.add(_c1, peerUserId: 'peer-ref-1');
    expect(await known.conversationForPeer(device.vault, 'peer-ref-1'), _c1);
    expect(await known.conversationForPeer(device.vault, 'nobody'), isNull);
  });

  test('a peer ref is never overwritten', () async {
    await known.add(_c1, peerUserId: 'peer-ref-1');
    await known.add(_c1, peerUserId: 'peer-ref-other');
    expect(known.peerOf(_c1), 'peer-ref-1');
    expect(
      await known.conversationForPeer(device.vault, 'peer-ref-other'),
      isNull,
    );
    final stored = KnownConversations(session: device.session);
    await stored.load(device.vault);
    expect(stored.peerOf(_c1), 'peer-ref-1');
  });

  test('two conversations attributed to one ref resolve to the newer one '
      'with a group, never plaintext', () async {
    await known.add(_c1, peerUserId: 'shared-ref');
    await known.add(_c2, peerUserId: 'shared-ref');
    // Neither has a group or a message: the one stored first.
    expect(await known.conversationForPeer(device.vault, 'shared-ref'), _c1);
    // The second has a stored group: it wins over the first.
    await device.session.runWrite(
      (vault) => vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c2,
            generation: 1,
            epoch: 1,
            state: Uint8List.fromList([1]),
          ),
        ),
      ),
    );
    expect(await known.conversationForPeer(device.vault, 'shared-ref'), _c2);
    // Both have a group: the newest stored message decides.
    await device.session.runWrite(
      (vault) => vault.transaction((tx) async {
        await tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 1,
            epoch: 1,
            state: Uint8List.fromList([1]),
          ),
        );
        await tx.putMessage(
          StoredMessage(
            conversationId: _c1,
            messageId: 'm1',
            createdAtMicros: clock.now().microsecondsSinceEpoch,
            mine: false,
            state: StoredMessageState.visible,
            generation: 1,
            epoch: 1,
            content: Uint8List.fromList([1]),
          ),
        );
      }),
    );
    expect(await known.conversationForPeer(device.vault, 'shared-ref'), _c1);
  });

  group('peer refs from a join', () {
    late RigCrypto rig;
    late RigPeer bob;

    setUp(() async {
      rig = await RigCrypto.create();
      bob = await RigPeer.create('bob');
    });

    tearDown(() async {
      await rig.dispose();
    });

    test("a joined conversation's peer ref is added once the header gives it "
        "and its theirs-side pins were attributed against that ref's "
        'list', () async {
      rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
      // No header yet: the join cannot look the peer up.
      await rig.offer(_c1, bob);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      expect(rig.known.contains(_c1), isTrue);
      expect(rig.known.peerOf(_c1), isNull);
      expect(rig.keys.getCalls, isEmpty);

      // The header arrives; attribution reads that ref's list and pins bob.
      rig.header(_c1, 'ref-bob');
      await rig.crypto.attributeMembers(_c1);
      final pin = (await rig.device.vault.members(_c1))
          .singleWhere((m) => rigEq(m.deviceId, bob.id));
      expect(pin.side, MemberSide.theirs);
      expect(rig.keys.getCalls, [
        ['ref-bob'],
      ]);
      expect(rig.known.peerOf(_c1), 'ref-bob');
      final again = KnownConversations(session: rig.device.session);
      await again.load(rig.device.vault);
      expect(again.peerOf(_c1), 'ref-bob');
      expect(await again.conversationForPeer(rig.device.vault, 'ref-bob'), _c1);
    });

    test('a header ref that differs from the ref the theirs-side pins were '
        'attributed against is not recorded', () async {
      rig.keys.peers['ref-one'] = [rigKeyDevice(bob.idString, bob.key)];
      rig.keys.peers['ref-two'] = [rigKeyDevice(bob.idString, bob.key)];
      // This run looked the peer up as ref-one; the header says ref-two.
      rig.contexts.of(_c1).peerUserId = 'ref-one';
      rig.header(_c1, 'ref-two');
      await rig.offer(_c1, bob);

      expect(await rig.crypto.processWelcomes(), [_c1]);

      expect(rig.keys.getCalls, [
        ['ref-one'],
      ]);
      expect(rig.known.peerOf(_c1), 'ref-one');
      final again = KnownConversations(session: rig.device.session);
      await again.load(rig.device.vault);
      expect(again.peerOf(_c1), 'ref-one');
      expect(
        await again.conversationForPeer(rig.device.vault, 'ref-two'),
        isNull,
      );
    });
  });
}
