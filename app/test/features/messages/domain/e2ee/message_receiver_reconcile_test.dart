import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/deferred_record.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart';
import 'package:dzeroth/features/messages/domain/e2ee/receive_record.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';

/// A message id of the server's shape (32 lower-case hex).
String _mid(int n) => n.toRadixString(16).padLeft(32, '0');

Uint8List _content(String text) => encodeMessageContent(
  text: text,
  reportKey: Uint8List.fromList(List.filled(32, 7)),
);

Duration _seconds(int n) => Duration(seconds: n);

const _removed = MessageState.MESSAGE_STATE_REMOVED;
const _deleted = MessageState.MESSAGE_STATE_DELETED_ACCOUNT;

/// Step 2b: tombstones and reconciliation by id (design rev 3 §8, the
/// carry-overs 8 to 20).
void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late RigOffer offer;
  late DateTime t0;

  tearDown(() async {
    final unexpected = [...rig.unexpected];
    await rig.dispose();
    expect(unexpected, isEmpty, reason: 'unexpected pipeline errors');
  });

  Future<void> setUpJoined() async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    offer = await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    t0 = rig.clock.now();
    rig.device.engine.calls.clear();
  }

  RigGroup bobGroup() => offer.add.group;

  /// Bob's message [n], created [at] after t0.
  Future<pb.Message> say(int n, {Duration at = Duration.zero}) async {
    final g = bobGroup();
    final content = _content('hello $n');
    final r = await g.owner.engine.encrypt(g.owner.state, g.state, content);
    g.state = r.groupState;
    final m = pb.Message(
      id: _mid(n),
      conversationId: _c1,
      state: MessageState.MESSAGE_STATE_VISIBLE,
      createdAt: ts.Timestamp.fromDateTime(t0.add(at)),
      ciphertext: r.ciphertext,
      mlsGeneration: Int64(1),
      mlsEpoch: Int64(r.epoch),
      reportCommitment: reportCommitment(content),
    );
    rig.server.addMessage(m);
    return m;
  }

  /// A message of an epoch before this device joined that the server holds
  /// only as a tombstone: this device never stores anything for it.
  void ghost(int n, [MessageState state = _removed]) => rig.server.addMessage(
    pb.Message(
      id: _mid(n),
      conversationId: _c1,
      state: state,
      createdAt: ts.Timestamp.fromDateTime(t0),
      ciphertextRemoved: true,
      mlsGeneration: Int64(1),
      mlsEpoch: Int64(0),
    ),
  );

  Future<StoredMessage?> row(int n) => rig.device.vault.message(_c1, _mid(n));

  Future<ConversationSync> sync() async =>
      (await rig.device.vault.conversation(_c1))!.sync;

  Future<ReceiveRecord> record() =>
      ReceiveRecords().read(rig.device.vault, _c1);

  Future<ReconcileEntry?> rec() async => (await record()).rec;

  Future<void> putRec(ReconcileEntry? entry) async {
    final r = await record();
    await rig.device.vault.transaction(
      (tx) => ReceiveRecords().putIn(tx, _c1, r.copyWith(rec: entry)),
    );
  }

  Future<List<String>> deferredIds() async => [
    for (final i in (await DeferredRecords().read(
      rig.device.vault,
      _c1,
    )).record.items)
      i.id,
  ];

  int processedCount(List<int> wire) =>
      rig.device.engine.processed.where((w) => rigEq(w, wire)).length;

  Future<ReceiveOutcome> pull() => rig.receiver.pullLive(_c1);

  List<String> requests() => rig.server.tombstoneRequests;

  /// A takedown the since listings never show (only the by-id tombstone
  /// listing does): the state changes on the server and every ListMessages
  /// and ListEpochMessages answer leaves the message out.
  final hidden = <String>{};
  void takeDownUnseen(int n, [MessageState state = _removed]) {
    rig.server.tombstone(_c1, _mid(n), state);
    hidden.add(_mid(n));
    rig.server
      ..rewriteLive = ((r) =>
          r..messages.removeWhere((m) => hidden.contains(m.id)))
      ..rewriteEpoch = ((r) =>
          r..messages.removeWhere((m) => hidden.contains(m.id)));
  }

  setUp(hidden.clear);

  /// The stored since token is retired, and the pass that meets the
  /// refusal has run: the token is empty and the entry is reset, unarmed.
  Future<String> retire() async {
    final token = (await sync()).sinceToken;
    expect(token, isNotEmpty);
    rig.server.retiredSince.add(token);
    expect((await pull()).kind, ReceiveOutcomeKind.more);
    expect((await sync()).sinceToken, '');
    expect((await rec())!.armed, isFalse);
    if ((await record()).anchor == token) {
      // The anchor is the same retired token: the next probe sends it, is
      // refused too and clears it.
      expect((await pull()).kind, ReceiveOutcomeKind.more);
      expect((await record()).anchor, '');
    }
    // The tombstone requests counted from here are the reconcile's.
    rig.server.tombstoneRequests.clear();
    return token;
  }

  /// Passes until the entry is disarmed (at most [max]).
  Future<void> untilDisarmed({int max = 6}) async {
    for (var i = 0; i < max && await rec() != null; i++) {
      await pull();
    }
    expect(await rec(), isNull);
  }

  group('the reconcile walk (§8.2)', () {
    test('the first pass of a conversation lists the tombstones and disarms '
        'the entry once its since token is saved', () async {
      await setUpJoined();
      await say(1);

      final out = await pull();

      expect(out.kind, ReceiveOutcomeKind.complete);
      expect((await sync()).sinceToken, isNotEmpty);
      expect(await rec(), isNull);
      // One listing while the token was still empty (it could not disarm),
      // one from the top after the token was saved.
      expect(requests(), ['', '']);
      expect((await row(1))!.state, StoredMessageState.visible);
      // Nothing armed: a later pass lists no tombstones.
      await pull();
      expect(requests(), hasLength(2));
    });

    test('a retired since token keeps every stored message and reconciles '
        'tombstones by id', () async {
      await setUpJoined();
      await say(1);
      await say(2, at: _seconds(1));
      await pull();
      // A row the server no longer lists.
      await rig.device.vault.transaction(
        (tx) => tx.putMessage(
          StoredMessage(
            conversationId: _c1,
            messageId: _mid(9),
            createdAtMicros: t0.microsecondsSinceEpoch,
            mine: true,
            state: StoredMessageState.visible,
            generation: 1,
            epoch: 1,
            content: _content('kept'),
          ),
        ),
      );
      takeDownUnseen(1);
      final token = await retire();
      expect((await row(1))!.state, StoredMessageState.visible);

      await untilDisarmed();

      final r1 = (await row(1))!;
      expect(r1.state, StoredMessageState.removed);
      expect(r1.content, isNull);
      expect((await row(2))!.state, StoredMessageState.visible);
      expect((await row(2))!.content, isNotNull);
      expect((await row(9))!.state, StoredMessageState.visible);
      final next = (await sync()).sinceToken;
      expect(next, isNotEmpty);
      expect(next, isNot(token));
    });

    test('the reconcile walk marks stored rows removed or deleted-account '
        'from tombstone pages', () async {
      await setUpJoined();
      await say(1);
      await say(2, at: _seconds(1));
      await say(3, at: _seconds(2));
      await pull();
      takeDownUnseen(1);
      takeDownUnseen(3, _deleted);
      await retire();
      rig.changed.clear();

      // The pass that arms the entry lists at once, before its walks.
      await pull();

      final r1 = (await row(1))!;
      final r3 = (await row(3))!;
      expect((r1.state, r1.content), (StoredMessageState.removed, null));
      expect((r3.state, r3.content), (StoredMessageState.deletedAccount, null));
      expect((await row(2))!.state, StoredMessageState.visible);
      expect(rig.changed, contains(_c1));
      expect(rig.contexts.of(_c1).tombstoned, {
        _mid(1): StoredMessageState.removed,
        _mid(3): StoredMessageState.deletedAccount,
      });
      await untilDisarmed();
    });

    test('every message of a deleted account is cleared', () async {
      await setUpJoined();
      for (var n = 1; n <= 5; n++) {
        await say(n, at: _seconds(n));
      }
      await pull();
      for (var n = 1; n <= 5; n++) {
        takeDownUnseen(n, _deleted);
      }
      rig.server.tombstonePageMax = 2;
      await retire();

      await untilDisarmed();

      for (var n = 1; n <= 5; n++) {
        final r = (await row(n))!;
        expect(r.state, StoredMessageState.deletedAccount);
        expect(r.content, isNull);
      }
      // Paged by the last id of each page.
      expect(requests(), contains('x:$_c1:${_mid(2)}'));
      expect(requests(), contains('x:$_c1:${_mid(4)}'));
    });

    test('a retirement during the reconcile walk restarts it from the '
        'top', () async {
      await setUpJoined();
      await say(1);
      await say(2, at: _seconds(1));
      await pull();
      takeDownUnseen(1);
      takeDownUnseen(2);
      // A listing in progress, past the first tombstone.
      await putRec(
        ReconcileEntry(armed: true, t: 'x:$_c1:${_mid(1)}', n: 1, l: _mid(1)),
      );
      rig.server.tombstonePageMax = 1;
      requests().clear();

      await retire();

      final reset = (await rec())!;
      expect((reset.armed, reset.t, reset.n, reset.l), (false, '', 0, ''));
      // An interrupted listing is counted (the bound on a server that
      // retires without end).
      expect(reset.f, 1);
      expect(requests(), isEmpty);

      await pull();

      expect(requests().first, '');
      expect((await row(1))!.state, StoredMessageState.removed);
      expect((await row(2))!.state, StoredMessageState.removed);
      await untilDisarmed();
    });

    test('the reconcile walk never ends early and continues one allowance '
        'per pass across a restart', () async {
      await setUpJoined();
      await say(40);
      await pull();
      expect(await rec(), isNull);
      for (var n = 1; n <= 24; n++) {
        ghost(n);
      }
      takeDownUnseen(40);
      rig.server.tombstonePageMax = 1;
      await retire();
      requests().clear();

      // The arming pass: one allowance; the since token is saved by its
      // open walk, so the listing that may disarm begins again from the top.
      final armed = await pull();
      expect(armed.kind, ReceiveOutcomeKind.more);
      expect(requests(), hasLength(kReconcilePagesPerPass));
      expect((await sync()).sinceToken, isNotEmpty);
      expect((await rec())!.n, 0);

      final second = await pull();
      expect(second.kind, ReceiveOutcomeKind.more);
      expect(requests(), hasLength(2 * kReconcilePagesPerPass));
      final cursor = (await rec())!;
      expect(cursor.n, kReconcilePagesPerPass);
      expect(cursor.t, 'x:$_c1:${_mid(10)}');
      expect(cursor.l, _mid(10));
      expect((await row(40))!.state, StoredMessageState.visible);

      // The cursor is in the sealed record: a restart continues from it.
      await rig.restart();
      final third = await pull();
      expect(third.kind, ReceiveOutcomeKind.more);
      expect(requests()[2 * kReconcilePagesPerPass], cursor.t);
      expect(requests(), hasLength(3 * kReconcilePagesPerPass));
      expect((await rec())!.n, 2 * kReconcilePagesPerPass);
      expect((await row(40))!.state, StoredMessageState.visible);

      final last = await pull();
      expect(last.kind, ReceiveOutcomeKind.complete);
      expect(await rec(), isNull);
      expect((await row(40))!.state, StoredMessageState.removed);
      expect(requests(), hasLength(3 * kReconcilePagesPerPass + 5));
    });

    test('a since token saved while the listing is past a stored row begins '
        'it again, so a takedown seen only on an unprocessed probe page is '
        'cleared before the entry is disarmed', () async {
      await setUpJoined();
      await say(5);
      await pull();
      for (var n = 10; n <= 21; n++) {
        ghost(n);
      }
      rig.server.tombstonePageMax = 1;
      await retire();
      // The arming pass lists past the stored row's id; its open walk
      // cannot end, so no since token is saved.
      rig.server.epochOrderFallback = true;
      final stalled = await pull();
      expect(stalled.kind, ReceiveOutcomeKind.stopped);
      expect((await sync()).sinceToken, '');
      expect((await rec())!.n, kReconcilePagesPerPass);
      rig.server.epochOrderFallback = false;

      // The takedown: the next probe's page carries it, but that page is
      // not processed (no since token), and the listing is past its id.
      rig.server.tombstone(_c1, _mid(5), _removed);
      rig.server.rewriteEpoch = (r) =>
          r..messages.removeWhere((m) => m.id == _mid(5));
      rig.clock.advance(kWalkBackoff);

      for (var i = 0; i < 6 && await rec() != null; i++) {
        await pull();
        if (await rec() == null) break;
        // Never disarmed with the row still readable.
      }
      expect(await rec(), isNull);
      final r = (await row(5))!;
      expect((r.state, r.content), (StoredMessageState.removed, null));
    });

    test(
      'the entry is never disarmed while the since token is empty, and '
      'removed text is cleared even while the open walk is stalled',
      () async {
        await setUpJoined();
        await say(1);
        await pull();
        takeDownUnseen(1);
        await retire();
        rig.server.epochOrderFallback = true;

        for (var i = 0; i < 3; i++) {
          await pull();
          rig.clock.advance(kWalkBackoffMax);
        }

        expect((await sync()).sinceToken, '');
        expect((await row(1))!.state, StoredMessageState.removed);
        final held = (await rec())!;
        expect(held.armed, isTrue);
        // Its last page is listed again each pass; nothing is counted.
        expect((held.t, held.n, held.f), ('', 0, 0));

        rig.server.epochOrderFallback = false;
        await untilDisarmed();
        expect((await sync()).sinceToken, isNotEmpty);
      },
    );

    test('a page listed before a reconcile step is discarded, so a message '
        'taken down meanwhile is never stored visible', () async {
      await setUpJoined();
      await pull();
      for (var n = 1; n <= 11; n++) {
        ghost(n);
      }
      // A listing in progress with a stored since token.
      await putRec(const ReconcileEntry(armed: true));
      rig.server.tombstonePageMax = 1;
      final m = await say(50, at: _seconds(1));
      // The probe's page is never processed as a batch: the open walk lists
      // the new message. While that page is in flight the message is taken
      // down and a reconcile step passes its id.
      rig.server.rewriteLive = (r) => r..gapPageToken = 'gap';
      var raced = false;
      rig.server.afterEpochAnswer = () async {
        if (raced) return;
        raced = true;
        rig.server.tombstone(_c1, _mid(50), _removed);
        final out = await rig.receiver.reconcile(_c1);
        expect(out.kind, ReceiveOutcomeKind.complete);
      };

      await pull();

      expect(raced, isTrue);
      expect(await rec(), isNull);
      expect(rig.contexts.of(_c1).discardedPages, 1);
      expect(await row(50), isNull);
      expect(processedCount(m.ciphertext), 0);
    });

    test('a tombstone page whose ids do not ascend is discarded and backs '
        'off', () async {
      await setUpJoined();
      await say(1);
      await say(2, at: _seconds(1));
      await pull();
      takeDownUnseen(1);
      takeDownUnseen(2);
      await retire();
      rig.server.rewriteTombstones = (r) {
        final reversed = r.tombstones.reversed.toList();
        return r
          ..tombstones.clear()
          ..tombstones.addAll(reversed);
      };
      final context = rig.contexts.of(_c1);

      final out = await pull();

      // Nothing of the page is applied; the walks still ran and the pass
      // waits for the listing's own backoff.
      expect((await row(1))!.state, StoredMessageState.visible);
      expect((await row(2))!.state, StoredMessageState.visible);
      expect(context.reconcileViolation, 1);
      final until = rig.clock.now().add(kWalkBackoff);
      expect(context.reconcileNotBefore, until);
      expect((await sync()).sinceToken, isNotEmpty);
      expect((out.kind, out.until), (ReceiveOutcomeKind.stopped, until));
      final kept = (await rec())!;
      expect((kept.armed, kept.t, kept.n, kept.f), (true, '', 0, 1));
      expect(requests().where((t) => t.isEmpty), hasLength(1));

      // Not listed again before the backoff ends.
      await pull();
      expect(requests(), hasLength(1));

      rig.server.rewriteTombstones = null;
      rig.clock.advance(kWalkBackoff);
      await untilDisarmed();
      expect((await row(1))!.state, StoredMessageState.removed);
      expect((await row(2))!.state, StoredMessageState.removed);
      expect(context.reconcileNotBefore, isNull);
    });

    for (final (name, forge)
        in <(String, void Function(pb.ListMessageTombstonesResponse))>[
          (
            'an id that is not 32 lower-case hex',
            (r) => r.tombstones.first.id = 'A' * 32,
          ),
          (
            'a state that is not a tombstone state',
            (r) =>
                r.tombstones.first.state = MessageState.MESSAGE_STATE_VISIBLE,
          ),
          (
            'a next token outside the token shape',
            (r) => r.nextPageToken = 'a\u0001b',
          ),
          (
            'no tombstone and a next token',
            (r) => r
              ..tombstones.clear()
              ..nextPageToken = 'x:$_c1:${_mid(1)}',
          ),
          (
            'more tombstones than a page holds',
            (r) => r.tombstones.addAll([
              for (var n = 100; n < 100 + kTombstonePageSize; n++)
                pb.MessageTombstone(id: _mid(n), state: _removed),
            ]),
          ),
        ]) {
      test('a tombstone page with $name is discarded and counted', () async {
        await setUpJoined();
        await say(1);
        await pull();
        takeDownUnseen(1);
        await retire();
        rig.server.rewriteTombstones = (r) => r.deepCopy()..also(forge);

        await pull();

        expect((await row(1))!.state, StoredMessageState.visible);
        expect(rig.contexts.of(_c1).reconcileViolation, 1);
        final kept = (await rec())!;
        expect((kept.armed, kept.t, kept.n, kept.f), (true, '', 0, 1));
      });
    }

    test('a listing longer than the page bound is counted and begun again '
        'from the top', () async {
      await setUpJoined();
      await say(1);
      await pull();
      takeDownUnseen(1);
      ghost(2);
      rig.server.tombstonePageMax = 1;
      await putRec(
        ReconcileEntry(
          armed: true,
          t: 'x:$_c1:${_mid(0)}',
          n: kReconcilePagesMax,
          l: _mid(0),
        ),
      );

      final out = await pull();

      expect(out.kind, ReceiveOutcomeKind.stopped);
      final again = (await rec())!;
      expect((again.armed, again.t, again.n, again.l), (true, '', 0, ''));
      expect(again.f, 1);
      expect((await row(1))!.state, StoredMessageState.visible);
    });

    test('a refused tombstone page token begins the listing again from the '
        'top and is counted', () async {
      await setUpJoined();
      await say(1);
      await say(2, at: _seconds(1));
      await pull();
      takeDownUnseen(1);
      takeDownUnseen(2);
      rig.server.tombstonePageMax = 1;
      await putRec(
        ReconcileEntry(armed: true, t: 'x:$_c1:${_mid(1)}', n: 1, l: _mid(1)),
      );
      rig.server.refuseTombstoneTokens = 1;
      requests().clear();

      final out = await pull();

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(requests(), ['x:$_c1:${_mid(1)}']);
      final again = (await rec())!;
      expect((again.armed, again.t, again.n, again.l), (true, '', 0, ''));
      expect(again.f, 1);

      rig.clock.advance(kWalkBackoff);
      await untilDisarmed();
      expect(requests()[1], '');
      expect((await row(1))!.state, StoredMessageState.removed);
      expect((await row(2))!.state, StoredMessageState.removed);
    });

    test('a FEATURE_DISABLED or UNIMPLEMENTED tombstone answer keeps the '
        'entry armed', () async {
      await setUpJoined();
      await say(1);
      await pull();
      takeDownUnseen(1);
      await retire();
      Object? error = const FeatureDisabledException('off', feature: 'e2ee_dm');
      rig.server.tombstoneError = () => error;
      final context = rig.contexts.of(_c1);

      // FEATURE_DISABLED: the walks still run (the since token is saved),
      // nothing is lost, the entry stays armed.
      final first = await pull();
      final until = rig.clock.now().add(kWalkBackoff);
      expect((first.kind, first.until), (ReceiveOutcomeKind.stopped, until));
      expect((await sync()).sinceToken, isNotEmpty);
      var kept = (await rec())!;
      expect((kept.armed, kept.f), (true, 1));
      expect(kept.fa, rig.clock.now().microsecondsSinceEpoch);
      expect((await row(1))!.state, StoredMessageState.visible);
      expect(requests(), hasLength(1));

      // UNIMPLEMENTED (an older server), a minute later.
      error = const UnknownApiException('unimplemented');
      rig.clock.advance(kWalkBackoff);
      final second = await pull();
      expect(second.kind, ReceiveOutcomeKind.stopped);
      expect(second.until, rig.clock.now().add(kWalkBackoff * 2));
      kept = (await rec())!;
      expect((kept.armed, kept.f), (true, 2));
      expect(requests(), hasLength(2));
      expect(context.reconcileBackoff, kWalkBackoff * 2);

      // The server answers again: the listing runs and disarms.
      error = null;
      rig.clock.advance(kWalkBackoff * 2);
      await untilDisarmed();
      expect((await row(1))!.state, StoredMessageState.removed);
    });

    test('a failed tombstone call is counted in a pass whose probe was '
        'answered, and not without that witness', () async {
      await setUpJoined();
      await say(1);
      await pull();
      takeDownUnseen(1);
      await putRec(const ReconcileEntry(armed: true));
      rig.server.tombstoneError = () => const NetworkException('rig');

      // Alone (no probe answered just before): this may be the device
      // being offline. A wait, nothing counted, nothing written.
      final before = await rig.dump();
      final alone = await rig.receiver.reconcile(_c1);
      expect(alone.kind, ReceiveOutcomeKind.stopped);
      expect(alone.until, rig.clock.now().add(kWalkBackoff));
      expect(await rig.dump(), before);

      // In a pass, right after the server answered its probe.
      rig.clock.advance(kWalkBackoff);
      final out = await pull();
      expect(out.kind, ReceiveOutcomeKind.stopped);
      final kept = (await rec())!;
      expect((kept.armed, kept.f), (true, 1));
    });

    test('a rate-limited tombstone call holds the pass and counts '
        'nothing', () async {
      await setUpJoined();
      await say(1);
      await pull();
      await putRec(const ReconcileEntry(armed: true));
      rig.server.tombstoneError = () =>
          const RateLimitedException('slow', retryAfter: Duration(seconds: 30));
      final before = await rig.dump();

      final out = await rig.receiver.reconcile(_c1);

      expect(out.kind, ReceiveOutcomeKind.held);
      expect(out.until, rig.clock.now().add(const Duration(seconds: 30)));
      expect(rig.syncBudget.paused, isTrue);
      expect(await rig.dump(), before);
    });

    test('reconcile failures are counted at most once per doubling minute, '
        'whatever the app run, and the fifth is reported once', () async {
      await setUpJoined();
      await say(1);
      await pull();
      takeDownUnseen(1);
      await putRec(const ReconcileEntry(armed: true));
      rig.server.tombstoneError = () => const UnknownApiException('x');
      requests().clear();

      await pull();
      expect((await rec())!.f, 1);
      final t1 = rig.clock.now();
      // A new run forgets the listing's own wait: the call is made again at
      // once, but a second failure within the minute is not counted and
      // nothing is written.
      await rig.restart();
      final before = await rig.dump();
      await pull();
      expect(requests(), hasLength(2));
      expect(await rig.dump(), before);
      expect((await rec())!.fa, t1.microsecondsSinceEpoch);

      // 1, 2, 4, 8 minutes after the last counted one.
      var wait = kEngineBackoff;
      for (var f = 2; f <= kReconcileGiveUpAfter; f++) {
        await rig.restart();
        rig.clock.advance(wait - const Duration(seconds: 1));
        await pull();
        expect((await rec())!.f, f - 1);
        await rig.restart();
        rig.clock.advance(const Duration(seconds: 1));
        expect(rig.unexpected, isEmpty);
        await pull();
        expect((await rec())!.f, f);
        wait *= 2;
      }
      expect(rig.unexpected, hasLength(1));
      expect(
        (rig.unexpected.single as E2eePipelineError).step,
        'receive.reconcile.gaveUp',
      );
      // Never past its bound, and not reported again.
      await rig.restart();
      rig.clock.advance(kWalkBackoffMax);
      await pull();
      final capped = (await rec())!;
      expect((capped.armed, capped.f), (true, kReconcileGiveUpAfter));
      expect(rig.unexpected, hasLength(1));
      rig.unexpected.clear();
      // The stored row was never touched, and a listing that completes
      // still clears everything.
      expect((await row(1))!.state, StoredMessageState.visible);
      rig.server.tombstoneError = null;
      await rig.restart();
      await untilDisarmed();
      expect((await row(1))!.state, StoredMessageState.removed);
    });
  });

  group('reconciliation and deferred messages (§8.1, carry-overs 12, 15 to '
      '18)', () {
    const internal = MlsException(MlsErrorCode.internal, 'x');

    /// Message [n] is deferred by a pull.
    Future<pb.Message> deferOne(int n) async {
      final m = await say(n);
      rig.device.engine.failWire[RigEngine.key(m.ciphertext)] = [internal];
      await pull();
      expect(await deferredIds(), [_mid(n)]);
      return m;
    }

    void nextRun() {
      rig.device.engine.onAppResumed();
      rig.receiver.onAppResumed();
      rig.clock.advance(kDeferredRetrySpacing);
    }

    test('the reconcile walk writes no visible row and makes no engine '
        'call', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      await say(2, at: _seconds(1));
      await pull();
      expect((await row(2))!.state, StoredMessageState.visible);
      expect(await rec(), isNull);
      takeDownUnseen(1);
      takeDownUnseen(2);
      await retire();
      nextRun();
      // Decryption is held (a group-level failure's own hold): the
      // reconcile walk needs no engine and still runs.
      final until = rig.clock.now().add(const Duration(hours: 1));
      rig.contexts.of(_c1).engineHoldUntil = until;
      final calls = [...rig.device.engine.calls];
      rig.changed.clear();
      // One transaction: when the removed row cannot be written, the
      // deferred item stays and the stored row keeps its state.
      rig.device.cipher.failSeal = (label) =>
          label.startsWith('vault_messages.');
      await pull();
      expect(await deferredIds(), [_mid(1)]);
      expect(await row(1), isNull);
      rig.device.cipher.failSeal = null;

      final out = await pull();

      expect((out.kind, out.until), (ReceiveOutcomeKind.stopped, until));
      // The deferred message ends as its removed row, its item purged.
      final r1 = (await row(1))!;
      expect((r1.state, r1.content), (StoredMessageState.removed, null));
      expect(await deferredIds(), isEmpty);
      final r2 = (await row(2))!;
      expect((r2.state, r2.content), (StoredMessageState.removed, null));
      expect(rig.changed, contains(_c1));
      expect(rig.device.engine.calls, calls);
      expect(processedCount(m1.ciphertext), 1);
    });

    test('a deferred message is retried only after the reconcile walk has '
        'disarmed the entry', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      expect(await rec(), isNull);
      await retire();
      // Something changed on the server, so its next since token is a new
      // one (the rig's tokens are its change count).
      await say(2, at: _seconds(1));
      nextRun();
      // The listing cannot run: every pass leaves the entry armed, and
      // the due item never reaches the engine, whatever token is stored.
      rig.server.tombstoneError = () => const UnknownApiException('x');
      for (var i = 0; i < 3; i++) {
        await pull();
        rig.clock.advance(kWalkBackoffMax);
      }
      expect((await sync()).sinceToken, isNotEmpty);
      expect((await rec())!.armed, isTrue);
      expect(processedCount(m1.ciphertext), 1);
      expect(await deferredIds(), [_mid(1)]);

      // The listing completes: the entry is disarmed by its last page.
      rig.server.tombstoneError = null;
      await untilDisarmed();
      nextRun();

      await pull();

      expect(processedCount(m1.ciphertext), 2);
      expect((await row(1))!.state, StoredMessageState.visible);
      expect(await deferredIds(), isEmpty);
    });
  });
}

extension<T> on T {
  T also(void Function(T value) change) {
    change(this);
    return this;
  }
}
