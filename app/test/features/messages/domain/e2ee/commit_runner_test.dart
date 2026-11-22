import 'dart:typed_data';

import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/daily_ledger.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late RigOffer offer;

  /// Pipeline errors the running test expects (checked by the tearDown).
  var expectedErrors = <String>[];

  tearDown(() async {
    final refused = rig.server.refusedAcks.length;
    final unexpected = [
      for (final e in rig.unexpected) e is E2eePipelineError ? e.step : '$e',
    ];
    final expected = expectedErrors;
    expectedErrors = [];
    await rig.dispose();
    expect(refused, 0, reason: 'the rig refused an AckWelcomes call');
    expect(unexpected, expected, reason: 'unexpected pipeline errors');
  });

  /// This device joins [_c1] from bob's welcome (generation 1); bob is
  /// pinned `theirs` by attribution. [accepted]: the stored sync record says
  /// so.
  Future<void> setUpJoined({bool accepted = true}) async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    if (accepted) await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    offer = await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    rig.device.engine.calls.clear();
    rig.server.calls.clear();
  }

  /// Bob commits [add] and [remove] on the server's current pair.
  Future<void> bobCommits({
    List<Uint8List> add = const [],
    List<Uint8List> remove = const [],
  }) async {
    final at = rig.server.current(_c1);
    final c = await rigCommit(offer.add.group, add: add, remove: remove);
    rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
  }

  /// Bob commits a self-update on the server's current pair.
  Future<void> bobSelfUpdate() async {
    final g = offer.add.group;
    final at = rig.server.current(_c1);
    final c = await bob.engine.selfUpdate(bob.state, g.state);
    g.state = await bob.engine.confirmCommit(bob.state, c.groupState);
    rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
  }

  Future<ConversationCryptoState> state() => rig.crypto.describeState(_c1);

  group('M5 in commit apply', () {
    test('a commit by another device that removes a device this device added '
        'today raises the undo count', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      await bobCommits(add: [await carol.keyPackage()]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      // As this device's own add of today (the runner records it so).
      await rig.ledger.noteOwnChange(_c1, added: [carol.id]);
      expect(await rig.ledger.undone(_c1), 0);

      await bobCommits(remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await rig.ledger.undone(_c1), 1);
      expect((await state()).committingPausedToday, isFalse);
      // The reversed change is used up: nothing is left to undo again.
      expect(
        await rig.ledger.isUndoOfOwnChange(_c1, carol.id, removing: true),
        isFalse,
      );
    });

    test('a commit that adds back a device this device removed today is an '
        'undo', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      await rig.ledger.noteOwnChange(_c1, removed: [carol.id]);

      await bobCommits(add: [await carol.keyPackage()]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await rig.ledger.undone(_c1), 1);
    });

    test(
      'a commit that reverses no own change of today is not counted',
      () async {
        await setUpJoined();
        final carol = await RigPeer.create('carol');
        final dave = await RigPeer.create('dave');
        await rig.ledger.noteOwnChange(_c1, added: [dave.id]);

        // One commit per catch-up (each closes an epoch's walk).
        await bobSelfUpdate();
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        await bobCommits(add: [await carol.keyPackage()]);
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        await bobCommits(remove: [carol.id]);
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

        expect(await rig.ledger.undone(_c1), 0);
        expect((await state()).committingPausedToday, isFalse);
      },
    );

    test('two undos in one day: describeState reports committingPausedToday '
        'until the next IST day', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await bobCommits(add: [await carol.keyPackage()]);
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        await rig.ledger.noteOwnChange(_c1, added: [carol.id]);
        expect((await state()).committingPausedToday, isFalse);
        await bobCommits(remove: [carol.id]);
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      }

      expect(await rig.ledger.undone(_c1), kAntiFlapUndosPerDay);
      expect((await state()).committingPausedToday, isTrue);

      rig.clock.advance(const Duration(days: 1));
      expect((await state()).committingPausedToday, isFalse);
    });

    test('an own change of an earlier IST day is not undone today', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      await bobCommits(add: [await carol.keyPackage()]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await rig.ledger.noteOwnChange(_c1, added: [carol.id]);
      rig.clock.advance(const Duration(days: 1));

      await bobCommits(remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await rig.ledger.undone(_c1), 0);
    });

    test('an unreadable ledger reads as paused, and a change by another '
        'device still applies', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(kVaultSettingE2eeDaily, rigBytes('not json')),
      );
      expectedErrors = ['daily.read'];

      expect((await state()).committingPausedToday, isTrue);
      await bobCommits(add: [await carol.keyPackage()]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      expect((await rig.ledger.read()).exhausted, isTrue);
      expect((await state()).committingPausedToday, isTrue);
    });
  });
}
