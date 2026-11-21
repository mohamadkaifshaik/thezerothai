import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/deferred_record.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart';
import 'package:dzeroth/features/messages/domain/e2ee/receive_record.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
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

  Future<void> setUpJoined({int pageSize = kEpochPageSize}) async {
    rig = await RigCrypto.create(epochPageSize: pageSize);
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
      int listings() =>
          rig.server.calls.where((c) => c == 'listMessageTombstones').length;
      final before = listings();

      await retire();

      final reset = (await rec())!;
      expect((reset.armed, reset.t, reset.n, reset.l), (false, '', 0, ''));
      // An interrupted listing is counted (the bound on a server that
      // retires without end).
      expect(reset.f, 1);
      // The retiring passes listed no tombstones (the server's own call
      // log: `retire()` clears the request list).
      expect(listings(), before);

      await pull();

      expect(requests().first, '');
      expect((await row(1))!.state, StoredMessageState.removed);
      expect((await row(2))!.state, StoredMessageState.removed);
      await untilDisarmed();
    });

    test('an anchor retirement while a multi-page listing waits for a since '
        'token restarts the listing, and a row taken down behind its cursor '
        'becomes removed', () async {
      await setUpJoined();
      await say(5);
      await pull();
      await retire();
      for (var n = 10; n <= 21; n++) {
        ghost(n);
      }
      rig.server.tombstonePageMax = 1;
      // The arming pass lists past the stored row's id; its open walk
      // cannot end, so no since token is saved and the listing spans passes.
      rig.server.epochOrderFallback = true;
      await pull();
      expect((await sync()).sinceToken, '');
      final anchor = (await record()).anchor;
      expect(anchor, isNotEmpty);
      final begun = (await rec())!;
      expect(
        (begun.armed, begun.n, begun.l),
        (true, kReconcilePagesPerPass, _mid(19)),
      );

      // The takedown retires every older since token (the server's rule),
      // the anchor among them; its id is behind the listing's cursor and
      // the since listings never show it.
      rig.server.takedownRetiresSince = true;
      takeDownUnseen(5);
      rig.clock.advance(kWalkBackoffMax);
      expect((await pull()).kind, ReceiveOutcomeKind.more);

      expect((await record()).anchor, '');
      final reset = (await rec())!;
      expect((reset.armed, reset.t, reset.n, reset.l), (false, '', 0, ''));
      // The interrupted listing is counted, as for a retired since token.
      expect(reset.f, 1);
      expect((await row(5))!.state, StoredMessageState.visible);

      rig.clock.advance(kWalkBackoffMax);
      await pull();

      // Still no since token: the listing from the top cleared the row.
      expect((await sync()).sinceToken, '');
      final r = (await row(5))!;
      expect((r.state, r.content), (StoredMessageState.removed, null));

      rig.server.epochOrderFallback = false;
      rig.clock.advance(kWalkBackoffMax);
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

    test('a listing that reaches its end clears the failure count while the '
        'entry still waits for a since token', () async {
      await setUpJoined();
      await say(1);
      await pull();
      await retire();
      // Three counted failures from a flaky hour, and no since token can
      // be saved yet (the open walk cannot end).
      final at = rig.clock.now().microsecondsSinceEpoch;
      await putRec(ReconcileEntry(armed: false, f: 3, fa: at));
      rig.server.epochOrderFallback = true;

      await pull();

      expect(requests(), ['']);
      expect((await sync()).sinceToken, '');
      final kept = (await rec())!;
      expect((kept.armed, kept.t, kept.n), (true, '', 0));
      expect((kept.f, kept.fa), (0, 0));

      rig.server.epochOrderFallback = false;
      rig.clock.advance(kWalkBackoffMax);
      await untilDisarmed();
    });

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
      // Read in the hook, asserted after the pass (the listing swallows
      // whatever its hook throws).
      ReceiveOutcome? alone;
      rig.server.afterEpochAnswer = () async {
        if (raced) return;
        raced = true;
        rig.server.tombstone(_c1, _mid(50), _removed);
        alone = await rig.receiver.reconcile(_c1);
      };

      await pull();

      expect(raced, isTrue);
      expect(alone?.kind, ReceiveOutcomeKind.complete);
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

    test('an empty tombstone page with a new next token advances the '
        'listing', () async {
      await setUpJoined();
      await say(3);
      await pull();
      // A full page of rows the server skips for their state, then the
      // stored message's tombstone.
      ghost(1);
      ghost(2);
      rig.server.tombstoneSkipped.addAll([_mid(1), _mid(2)]);
      takeDownUnseen(3);
      rig.server.tombstonePageMax = 2;
      await retire();

      await pull();

      expect(requests().take(2), ['', 'x:$_c1:${_mid(2)}']);
      expect(rig.contexts.of(_c1).reconcileViolation, 0);
      final r = (await row(3))!;
      expect((r.state, r.content), (StoredMessageState.removed, null));
      await untilDisarmed();
    });

    test('an empty tombstone page between passes advances the cursor and '
        'keeps the last id', () async {
      await setUpJoined();
      await pull();
      ghost(1);
      ghost(2);
      ghost(3);
      rig.server.tombstoneSkipped.addAll([_mid(2)]);
      rig.server.tombstonePageMax = 1;
      // A listing in progress with a stored since token, past the first id.
      await putRec(
        ReconcileEntry(armed: true, t: 'x:$_c1:${_mid(1)}', n: 1, l: _mid(1)),
      );
      requests().clear();
      // One page only: the cursor after the empty page is read back.
      final until = rig.clock.now().add(const Duration(minutes: 5));
      rig.server.afterTombstoneAnswer = () async =>
          rig.syncBudget.pauseUntil(until);

      await pull();

      expect(requests(), ['x:$_c1:${_mid(1)}']);
      final moved = (await rec())!;
      expect(
        (moved.armed, moved.t, moved.n, moved.l),
        (true, 'x:$_c1:${_mid(2)}', 2, _mid(1)),
      );
      rig.server.afterTombstoneAnswer = null;
      rig.clock.advance(const Duration(minutes: 5));
      await untilDisarmed();
    });

    test('an empty tombstone page whose next token is the one it was listed '
        'with is discarded and counted', () async {
      await setUpJoined();
      await say(1);
      await pull();
      takeDownUnseen(1);
      final token = 'x:$_c1:${_mid(0)}';
      await putRec(ReconcileEntry(armed: true, t: token, n: 1, l: _mid(0)));
      rig.server.rewriteTombstones = (r) => r.deepCopy()
        ..tombstones.clear()
        ..nextPageToken = token;

      await pull();

      expect((await row(1))!.state, StoredMessageState.visible);
      expect(rig.contexts.of(_c1).reconcileViolation, 1);
      final kept = (await rec())!;
      expect((kept.armed, kept.t, kept.n, kept.f), (true, token, 1, 1));
    });

    test('a stored row at time 0 is marked removed by the reconcile '
        'listing', () async {
      await setUpJoined();
      await pull();
      // A server time this client cannot hold: the live path stores the
      // message at time 0, and the epoch walk skips it by id.
      final g = bobGroup();
      final content = _content('at time 0');
      final e = await g.owner.engine.encrypt(g.owner.state, g.state, content);
      g.state = e.groupState;
      rig.server.addMessage(
        pb.Message(
          id: _mid(7),
          conversationId: _c1,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          // Out of range, not a date: 2^53 microseconds is about 9.0e9 s.
          createdAt: ts.Timestamp()..seconds = Int64(10) * Int64(1000000000000),
          ciphertext: e.ciphertext,
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(e.epoch),
          reportCommitment: reportCommitment(content),
        ),
      );
      await pull();
      final stored = (await row(7))!;
      expect(
        (stored.state, stored.createdAtMicros),
        (StoredMessageState.visible, 0),
      );
      takeDownUnseen(7);
      await retire();

      await untilDisarmed();

      final r = (await row(7))!;
      expect((r.state, r.content), (StoredMessageState.removed, null));
    });

    test('a takedown of a stored message seen only on a probe page that is '
        'not processed removes the row', () async {
      await setUpJoined();
      await say(1);
      await pull();
      expect((await row(1))!.state, StoredMessageState.visible);
      expect(await rec(), isNull);
      // The since listing carries the takedown, but its page is not
      // processed as a batch (a gap), and the open walk lists by creation
      // time: it does not show the message again.
      rig.server.tombstone(_c1, _mid(1), _removed);
      rig.server
        ..rewriteLive = ((r) => r..gapPageToken = 'gap')
        ..rewriteEpoch = ((r) =>
            r..messages.removeWhere((m) => m.id == _mid(1)));
      final calls = [...rig.device.engine.calls];
      rig.changed.clear();
      requests().clear();

      await pull();

      final r = (await row(1))!;
      expect((r.state, r.content), (StoredMessageState.removed, null));
      expect(rig.changed, contains(_c1));
      // By the probe page alone: no tombstone listing, no engine call.
      expect(requests(), isEmpty);
      expect(rig.device.engine.calls, calls);
    });

    test('a last tombstone page applied with no since token discards an '
        'epoch page listed before it, so a message taken down meanwhile is '
        'never stored visible', () async {
      await setUpJoined();
      await pull();
      await retire();
      final m = await say(50, at: _seconds(1));
      // While the open walk's page (the new message, still readable) is in
      // flight, the message is taken down and a reconcile step lists it on
      // a last page that cannot disarm: no since token is stored.
      var raced = false;
      // Read in the hook, asserted after the pass (the listing swallows
      // whatever its hook throws).
      String? tokenThen;
      bool? armedThen;
      rig.server.afterEpochAnswer = () async {
        if (raced) return;
        raced = true;
        rig.server.tombstone(_c1, _mid(50), _removed);
        await rig.receiver.reconcile(_c1);
        tokenThen = (await sync()).sinceToken;
        armedThen = (await rec())?.armed;
      };

      await pull();

      expect(raced, isTrue);
      expect((tokenThen, armedThen), ('', true));
      expect(rig.contexts.of(_c1).discardedPages, 1);
      expect(await row(50), isNull);
      expect(processedCount(m.ciphertext), 0);
      await untilDisarmed();
      expect(await row(50), isNull);
    });

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

    test('a receive record that no longer reads does not drop an armed '
        'reconcile: the listing runs from the top and clears the '
        'row', () async {
      await setUpJoined();
      await say(1);
      await pull();
      expect((await sync()).sinceToken, isNotEmpty);
      takeDownUnseen(1);
      // A listing is owed (armed after a retirement), and the sealed record
      // that says so stops reading.
      await putRec(const ReconcileEntry(armed: true));
      await rig.replaySealedSetting(
        ReceiveRecords.keyOf(_c1),
        Uint8List.fromList([1, 2, 3]),
      );
      requests().clear();

      await pull();

      expect(requests(), isNotEmpty);
      expect(requests().first, '');
      final r = (await row(1))!;
      expect((r.state, r.content), (StoredMessageState.removed, null));
      await untilDisarmed();
      expect(rig.unexpected.whereType<E2eePipelineError>().map((e) => e.step), [
        'receive.read',
      ]);
      rig.unexpected.clear();
    });
  });

  group('a conversation with no final group (a ruling after the design)', () {
    /// No final group is left (a reset, or this device was removed).
    Future<void> loseGroup() =>
        rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));

    int probes() =>
        rig.server.calls.where((c) => c == 'listMlsMessages').length;

    test('a retirement with no final group arms the entry and lists the '
        'tombstones by id', () async {
      await setUpJoined();
      await say(1);
      await say(2, at: _seconds(1));
      await pull();
      expect(await rec(), isNull);
      await loseGroup();
      takeDownUnseen(1);
      final token = (await sync()).sinceToken;
      rig.server.retiredSince.add(token);

      // The detector probe meets the refusal: the token is retired.
      expect((await pull()).kind, ReceiveOutcomeKind.more);
      expect((await sync()).sinceToken, '');
      expect((await rec())!.armed, isFalse);
      // The anchor is that same token: refused and cleared too.
      expect((await pull()).kind, ReceiveOutcomeKind.more);
      expect((await record()).anchor, '');
      requests().clear();
      final engineCalls = [...rig.device.engine.calls];

      // The probe with no token arms the entry; the listing runs at once.
      final armed = await pull();

      expect(requests(), ['']);
      final r1 = (await row(1))!;
      expect((r1.state, r1.content), (StoredMessageState.removed, null));
      expect((await row(2))!.state, StoredMessageState.visible);
      expect(rig.device.engine.calls, engineCalls);
      // The resting state: no walk will save a since token, so the entry
      // stays armed at its last page and the pass waits; never `complete`,
      // never an immediate next pass.
      expect((await sync()).sinceToken, '');
      final kept = (await rec())!;
      expect((kept.armed, kept.t, kept.n, kept.f), (true, '', 0, 0));
      expect(
        (armed.kind, armed.until),
        (ReceiveOutcomeKind.stopped, rig.clock.now().add(kWalkBackoff)),
      );

      // Each later pass costs one probe and one tombstone page.
      rig.clock.advance(kWalkBackoff);
      final before = probes();
      final rest = await pull();
      expect(rest.kind, ReceiveOutcomeKind.stopped);
      expect(probes(), before + 1);
      expect(requests(), ['', '']);

      // A takedown in that state is still cleared by id: it retires the
      // anchor (the server's rule), and the pass after that lists from the
      // top.
      rig.server.takedownRetiresSince = true;
      takeDownUnseen(2);
      rig.clock.advance(kWalkBackoff);
      expect((await pull()).kind, ReceiveOutcomeKind.more);
      expect((await record()).anchor, '');
      expect((await row(2))!.state, StoredMessageState.visible);
      await pull();
      final r2 = (await row(2))!;
      expect((r2.state, r2.content), (StoredMessageState.removed, null));
      expect(rig.device.engine.calls, engineCalls);
    });

    test('a pass with no final group is not complete while the reconcile '
        'listing has pages left', () async {
      await setUpJoined();
      await say(40);
      await pull();
      expect(await rec(), isNull);
      for (var n = 1; n <= 24; n++) {
        ghost(n);
      }
      takeDownUnseen(40);
      rig.server.tombstonePageMax = 1;
      await loseGroup();
      final token = (await sync()).sinceToken;
      rig.server.retiredSince.add(token);
      expect((await pull()).kind, ReceiveOutcomeKind.more);
      expect((await pull()).kind, ReceiveOutcomeKind.more);
      expect((await record()).anchor, '');
      requests().clear();

      // One allowance a pass, and `more` while pages are left.
      final first = await pull();
      expect(first.kind, ReceiveOutcomeKind.more);
      expect(requests(), hasLength(kReconcilePagesPerPass));
      expect((await rec())!.n, kReconcilePagesPerPass);
      final second = await pull();
      expect(second.kind, ReceiveOutcomeKind.more);
      expect((await rec())!.n, 2 * kReconcilePagesPerPass);
      expect((await row(40))!.state, StoredMessageState.visible);

      // The listing reaches its end: the row is cleared, the entry waits
      // for a since token, and the pass waits (not `complete`).
      final last = await pull();
      expect(last.kind, ReceiveOutcomeKind.stopped);
      expect(requests(), hasLength(2 * kReconcilePagesPerPass + 5));
      expect((await row(40))!.state, StoredMessageState.removed);
      expect((await rec())!.armed, isTrue);
    });
  });

  group('the budgets (§9)', () {
    test('every call of a pass takes its unit in the conversation\'s lane: '
        'the probe on the read budget, tombstone and walk pages on the sync '
        'budget', () async {
      await setUpJoined();
      await say(1);
      final syncTakes = <(BudgetPriority, Object?)>[];
      final readTakes = <(BudgetPriority, Object?)>[];
      rig
        ..syncBudget = _SpyBudget(rig.clock.now, syncTakes)
        ..readBudget = _SpyBudget(rig.clock.now, readTakes);
      await rig.restart();
      final before = rig.server.calls.length;

      final out = await rig.receiver.pullLive(
        _c1,
        priority: BudgetPriority.live,
      );

      expect(out.kind, ReceiveOutcomeKind.complete);
      expect(readTakes, [(BudgetPriority.live, _c1)]);
      // Two tombstone pages (before and after the since token is saved)
      // and the open walk's page.
      expect(syncTakes, List.filled(3, (BudgetPriority.live, _c1)));
      expect(rig.server.calls.skip(before), [
        'listMlsMessages',
        'listMessageTombstones',
        'listEpochMessages',
        'listMessageTombstones',
      ]);
    });

    test('a pass whose budget is paused is held and makes no call', () async {
      await setUpJoined();
      await say(1);
      await pull();
      takeDownUnseen(1);
      await putRec(const ReconcileEntry(armed: true));
      final until = rig.clock.now().add(const Duration(minutes: 3));
      rig.syncBudget.pauseUntil(until);
      requests().clear();

      // The probe draws on the read budget and still runs; the tombstone
      // listing draws on the paused sync budget.
      final out = await pull();

      expect(out.kind, ReceiveOutcomeKind.held);
      expect(requests(), isEmpty);
      final kept = (await rec())!;
      expect((kept.armed, kept.f), (true, 0));
      expect((await row(1))!.state, StoredMessageState.visible);

      rig.clock.advance(const Duration(minutes: 3));
      await untilDisarmed();
      expect((await row(1))!.state, StoredMessageState.removed);
    });

    test('a rate-limited cleared_at read pauses the sync budget, and its '
        'priority can be given', () async {
      await setUpJoined();
      final takes = <(BudgetPriority, Object?)>[];
      rig.syncBudget = _SpyBudget(rig.clock.now, takes);
      await rig.restart();
      const wait = Duration(seconds: 30);
      RateLimitedException? limited = const RateLimitedException(
        'slow',
        retryAfter: wait,
      );
      rig.server.onCall = (call) async {
        final e = limited;
        if (call == 'listEpochMessages' && e != null) throw e;
      };

      await rig.receiver.applyClearedAtOnce(_c1);

      // As every other listing: the budget is paused until the server's
      // time, so no walk or tombstone page is asked for meanwhile.
      expect(rig.syncBudget.paused, isTrue);
      expect(takes, [(BudgetPriority.user, _c1)]);
      expect(rig.contexts.of(_c1).clearedAtReadThisRun, isFalse);
      final calls = rig.server.calls.length;
      await rig.receiver.applyClearedAtOnce(_c1);
      expect(rig.server.calls, hasLength(calls));

      // Not read yet: it runs again once the pause is over, at the priority
      // the caller gives.
      limited = null;
      rig.clock.advance(wait);
      expect(rig.syncBudget.paused, isFalse);
      await rig.receiver.applyClearedAtOnce(
        _c1,
        priority: BudgetPriority.background,
      );
      expect(takes.last, (BudgetPriority.background, _c1));
      expect(rig.contexts.of(_c1).clearedAtReadThisRun, isTrue);
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

    /// Bob commits a self-update on the server's current pair.
    Future<void> bobSelfUpdate() async {
      final g = bobGroup();
      final at = rig.server.current(_c1);
      final c = await bob.engine.selfUpdate(bob.state, g.state);
      g.state = await bob.engine.confirmCommit(bob.state, c.groupState);
      rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
    }

    Future<int> epoch() async => (await rig.device.vault.group(_c1, 1))!.epoch;

    test('a final attempt makes no engine call while the reconcile entry '
        'stands: the walk does not end and the commit waits', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      expect(await rec(), isNull);
      // The entry stands and its listing is not available.
      await putRec(const ReconcileEntry(armed: true));
      rig.server.tombstoneError = () => const UnknownApiException('x');
      await bobSelfUpdate();

      // The sink (catch-up, with the lock held) reaches the close walk's
      // end: the stored ciphertext is not given to the engine.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(processedCount(m1.ciphertext), 1);
      expect(await deferredIds(), [_mid(1)]);
      expect(await row(1), isNull);
      expect((await record()).close!.end, isFalse);
      expect(await epoch(), 1);

      // A pass: the same, and it stops for a wait.
      final out = await pull();
      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(processedCount(m1.ciphertext), 1);
      expect(await deferredIds(), [_mid(1)]);
      expect((await record()).close!.end, isFalse);
      expect((await rec())!.f, 1);

      // The listing completes and disarms: the final attempt runs, the
      // walk ends and the commit applies.
      rig.server.tombstoneError = null;
      rig.clock.advance(kWalkBackoff);
      for (var i = 0; i < 4 && await epoch() == 1; i++) {
        await pull();
        rig.clock.advance(kWalkBackoff);
      }
      expect(await rec(), isNull);
      expect(await epoch(), 2);
      expect(processedCount(m1.ciphertext), 2);
      expect((await row(1))!.state, StoredMessageState.visible);
      expect(await deferredIds(), isEmpty);
    });

    test('at the fifth counted reconcile failure a deferred message waiting '
        'for its final attempt becomes an undecryptable row with no engine '
        'call, and the walk ends', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      rig.server.tombstoneError = () => const UnknownApiException('x');
      await bobSelfUpdate();
      // One below the bound: the end still waits.
      await putRec(
        const ReconcileEntry(armed: true, f: kReconcileGiveUpAfter - 1),
      );
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(await deferredIds(), [_mid(1)]);

      await putRec(const ReconcileEntry(armed: true, f: kReconcileGiveUpAfter));
      final calls = [...rig.device.engine.calls];

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      final r = (await row(1))!;
      expect((r.state, r.content), (StoredMessageState.undecryptable, null));
      expect(r.mine, isFalse);
      expect(await deferredIds(), isEmpty);
      expect(processedCount(m1.ciphertext), 1);
      // The commit's own application is the only engine work (one
      // `process`: the commit, never the stored ciphertext).
      expect(
        rig.device.engine.calls.skip(calls.length).where((c) => c == 'process'),
        hasLength(1),
      );
      expect(await epoch(), 2);
      // The entry still stands: only a complete listing clears it.
      expect((await rec())!.f, kReconcileGiveUpAfter);
    });

    /// A conversation that catches up before its first pass: no since token
    /// (the entry reads as armed), message 1 deferred by the sink's close
    /// walk (it failed once, the engine works), and a commit waiting behind
    /// that walk's final attempt.
    Future<pb.Message> caughtUpBeforeFirstPass() async {
      await setUpJoined();
      final m1 = await say(1);
      rig.device.engine.failWire[RigEngine.key(m1.ciphertext)] = [internal];
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(await deferredIds(), [_mid(1)]);
      expect(processedCount(m1.ciphertext), 1);
      expect((await record()).close!.end, isFalse);
      return m1;
    }

    /// The message was decrypted and is readable, the commit applied, a
    /// since token is saved and the entry is disarmed.
    Future<void> expectDelivered(pb.Message m, int n) async {
      expect(processedCount(m.ciphertext), 2);
      final r = (await row(n))!;
      expect(r.state, StoredMessageState.visible);
      expect(r.content, isNotNull);
      expect(await deferredIds(), isEmpty);
      expect(await epoch(), 2);
      expect((await sync()).sinceToken, isNotEmpty);
      expect(await rec(), isNull);
    }

    test('after a retirement a final attempt behind a close walk of the '
        'current pair is delivered by the pass whose listing reached its '
        'end, and the next pass saves a since token and disarms', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      await bobSelfUpdate();
      await retire();
      // Something changed on the server, so its next since token is a new
      // one (the rig's tokens are its change count).
      ghost(90);
      // The post-retirement entry (unarmed, nothing listed yet): the sink
      // makes no engine call.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(processedCount(m1.ciphertext), 1);
      expect((await record()).close!.end, isFalse);

      // The pass: its probe arms the entry, its listing reaches the end
      // (no since token: the entry stays armed), and its close walk's final
      // attempt runs the engine; the commit applies at its end.
      final first = await pull();
      expect(first.kind, ReceiveOutcomeKind.more);
      expect(processedCount(m1.ciphertext), 2);
      expect((await row(1))!.state, StoredMessageState.visible);
      expect(await epoch(), 2);
      expect((await rec())!.armed, isTrue);

      // The next pass: the open walk saves the token, the last page disarms.
      await pull();
      await expectDelivered(m1, 1);
    });

    test('a conversation that catches up before its first since token is '
        'saved delivers the waiting final attempt in its first pass and '
        'disarms in its second', () async {
      final m1 = await caughtUpBeforeFirstPass();

      final first = await pull();
      expect(first.kind, ReceiveOutcomeKind.more);
      expect(processedCount(m1.ciphertext), 2);
      expect((await row(1))!.state, StoredMessageState.visible);
      expect(await epoch(), 2);

      await pull();
      await expectDelivered(m1, 1);
    });

    test('a final attempt behind an orphan walk with no since token is '
        'delivered once this pass\'s listing reaches its end', () async {
      await setUpJoined();
      final m1 = await say(1, at: _seconds(-1));
      rig.device.engine.failWire[RigEngine.key(m1.ciphertext)] = [internal];
      await pull();
      expect(await deferredIds(), [_mid(1)]);
      await retire();
      ghost(90);
      // The device moved on to generation 2 and kept generation 1's group:
      // its last epoch is the orphan walk's.
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      await rig.device.vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        ),
      );

      await pull();

      expect(processedCount(m1.ciphertext), 2);
      expect((await row(1))!.state, StoredMessageState.visible);
      expect(await deferredIds(), isEmpty);
      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect((await record()).orphan, isNull);
      await untilDisarmed(max: 3);
      expect((await sync()).sinceToken, isNotEmpty);
    });

    test('a message taken down between the listing\'s end and the final '
        'attempt is cleared by id at the next listing', () async {
      final m1 = await caughtUpBeforeFirstPass();
      // The server's rule: the takedown retires every older since token.
      rig.server.takedownRetiresSince = true;
      var taken = false;
      rig.server.afterTombstoneAnswer = () async {
        if (taken) return;
        taken = true;
        // After the listing's last page was computed, before the walk.
        takeDownUnseen(1);
      };

      await pull();

      // The stated window of the ruling: the listing had ended, so the
      // final attempt ran and the message is readable for now.
      expect(taken, isTrue);
      expect(processedCount(m1.ciphertext), 2);
      expect((await row(1))!.state, StoredMessageState.visible);
      // The entry still stands, so the next listing is owed.
      expect(await rec(), isNotNull);

      // The anchor is retired by the takedown; the pass after that arms
      // the entry and lists by id from the top.
      for (var i = 0; i < 3; i++) {
        await pull();
        if ((await row(1))!.state != StoredMessageState.visible) break;
      }
      final r = (await row(1))!;
      expect((r.state, r.content), (StoredMessageState.removed, null));
      await untilDisarmed();
      expect((await row(1))!.state, StoredMessageState.removed);
    });

    test('a catch-up outside a pass makes no final attempt while the entry '
        'stands, and the next pass delivers it', () async {
      final m1 = await caughtUpBeforeFirstPass();
      final context = rig.contexts.of(_c1);
      expect(context.catchUpDueAt, isNotNull);

      // A pass whose listing reaches its end, but whose close walk is kept
      // from the engine: nothing is delivered, and the fact that this pass
      // listed to the end goes with the pass.
      context.engineHoldUntil = rig.clock.now().add(kEngineBackoff);
      final held = await pull();
      expect(held.kind, ReceiveOutcomeKind.stopped);
      expect(requests(), isNotEmpty);
      expect(processedCount(m1.ciphertext), 1);
      context.engineHoldUntil = null;

      // The bare sink, right after that pass: still no engine call.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(processedCount(m1.ciphertext), 1);
      expect(await deferredIds(), [_mid(1)]);
      expect(await row(1), isNull);
      expect((await record()).close!.end, isFalse);
      expect(await epoch(), 1);
      expect(context.catchUpDueAt, isNotNull);
      // Nor does the public reconcile step open the gate for it.
      await rig.receiver.reconcile(_c1);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(processedCount(m1.ciphertext), 1);

      await pull();
      expect(processedCount(m1.ciphertext), 2);
      expect((await row(1))!.state, StoredMessageState.visible);
      expect(await epoch(), 2);
      await pull();
      await expectDelivered(m1, 1);
    });

    test('after the kill switch is lifted a waiting final attempt is '
        'delivered, not rowed', () async {
      final m1 = await caughtUpBeforeFirstPass();
      // The kill switch: both new surfaces answer FEATURE_DISABLED, so the
      // tombstone listing is counted and no walk can list its epoch.
      const off = FeatureDisabledException('off', feature: 'e2ee_dm');
      rig.server
        ..tombstoneError = (() => off)
        ..onCall = (call) async {
          if (call == 'listEpochMessages') throw off;
        };
      for (var i = 0; i < kReconcileGiveUpAfter; i++) {
        await pull();
        rig.clock.advance(kWalkBackoffMax);
      }
      expect((await rec())!.f, kReconcileGiveUpAfter);
      expect(
        (rig.unexpected.single as E2eePipelineError).step,
        'receive.reconcile.gaveUp',
      );
      rig.unexpected.clear();
      // Nothing was lost while it was on.
      expect(await deferredIds(), [_mid(1)]);
      expect(await row(1), isNull);

      rig.server
        ..tombstoneError = null
        ..onCall = null;
      await pull();

      expect(processedCount(m1.ciphertext), 2);
      expect((await row(1))!.state, StoredMessageState.visible);
      await pull();
      await expectDelivered(m1, 1);
    });

    test('a listing that is rate limited or held in this pass does not open '
        'the final-attempt gate', () async {
      await setUpJoined();
      await say(1, at: const Duration(minutes: -10));
      await pull();
      expect(await rec(), isNull);
      await rig.locks.run(
        _c1,
        () => rig.receiver.completeEpoch(
          _c1,
          const MlsPair(1, 1),
          priority: BudgetPriority.user,
        ),
      );
      expect((await record()).close!.end, isTrue);
      // A message of the pair deferred after the walk ended, and the device
      // moved on to generation 2: the ended close walk owes a final attempt
      // before generation 1's group goes, and reaching it needs no listing.
      final late = await say(2, at: _seconds(-5));
      rig.server
        ..rewriteEpoch = ((r) =>
            r..messages.removeWhere((m) => m.id == _mid(2)))
        ..rewriteLive = ((r) =>
            r..messages.removeWhere((m) => m.id == _mid(2)));
      final now = rig.clock.now().microsecondsSinceEpoch;
      await rig.device.vault.transaction(
        (tx) => DeferredRecords().putIn(
          tx,
          _c1,
          DeferredRecord([
            DeferredItem(
              id: _mid(2),
              pair: const MlsPair(1, 1),
              at: late.createdAt.toDateTime().microsecondsSinceEpoch,
              da: now,
              ct: Uint8List.fromList(late.ciphertext),
              rc: Uint8List.fromList(late.reportCommitment),
              fs: false,
              k: 1,
              la: now,
              ru: 'bbbbbbbbbbbbbbbb',
            ),
          ]),
        ),
      );
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      await rig.device.vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        ),
      );
      // The entry stands, and its listing is rate limited.
      await putRec(const ReconcileEntry(armed: true));
      RateLimitedException? limited = const RateLimitedException(
        'slow',
        retryAfter: Duration(seconds: 30),
      );
      rig.server.tombstoneError = () => limited;
      requests().clear();

      final first = await pull();
      expect(first.kind, ReceiveOutcomeKind.held);
      expect(requests(), hasLength(1));
      expect(processedCount(late.ciphertext), 0);
      expect(await rig.device.vault.group(_c1, 1), isNotNull);
      expect(await deferredIds(), [_mid(2)]);

      // The server would answer now, but the budget is still paused: the
      // listing is held, no call is made, and the gate stays closed.
      limited = null;
      final second = await pull();
      expect(second.kind, ReceiveOutcomeKind.held);
      expect(requests(), hasLength(1));
      expect(processedCount(late.ciphertext), 0);
      expect(await rig.device.vault.group(_c1, 1), isNotNull);
      expect((await rec())!.f, 0);

      rig.clock.advance(const Duration(seconds: 30));
      await pull();
      expect(processedCount(late.ciphertext), 1);
      expect((await row(2))!.state, StoredMessageState.visible);
      expect(await rig.device.vault.group(_c1, 1), isNull);
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

    test('a final attempt behind a two-page close walk with no since token '
        'is delivered by the next pass', () async {
      // Pages of two: the close walk of (1, 1) has two pages.
      await setUpJoined(pageSize: 2);
      final m1 = await say(1);
      await say(2, at: _seconds(1));
      await say(3, at: _seconds(2));
      rig.device.engine.failWire[RigEngine.key(m1.ciphertext)] = [internal];
      await bobSelfUpdate();
      // The close walk of the current pair, not begun (as the sink creates
      // it), and no since token: the entry reads as armed.
      await rig.device.vault.transaction(
        (tx) => ReceiveRecords().putIn(
          tx,
          _c1,
          const ReceiveRecord(
            close: WalkEntry(pair: MlsPair(1, 1), mode: WalkMode.decrypt),
          ),
        ),
      );

      // The pass lists the tombstones to the end, then applies the walk's
      // first page: that write of the record closes the gate this pass had
      // opened for itself, so the last page's end waits.
      final first = await pull();
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect(await deferredIds(), [_mid(1)]);
      expect(processedCount(m1.ciphertext), 1);
      expect(await row(1), isNull);
      expect((await row(2))!.state, StoredMessageState.visible);
      expect((await row(3))!.state, StoredMessageState.visible);
      final close = (await record()).close!;
      expect(close.end, isFalse);
      expect(close.t, isNotEmpty);
      expect(await epoch(), 1);

      // The next pass has only the last page left: nothing writes the
      // record between its listing's end and the walk's end.
      await pull();
      expect(processedCount(m1.ciphertext), 2);
      expect((await row(1))!.state, StoredMessageState.visible);
      expect(await epoch(), 2);
      await pull();
      await expectDelivered(m1, 1);
    });

    test('a catch-up outside a pass makes no final attempt on a null entry, '
        'and the next pass delivers it', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      // No reconcile entry, a since token stored, a commit waiting.
      expect(await rec(), isNull);
      expect((await sync()).sinceToken, isNotEmpty);
      await bobSelfUpdate();
      final context = rig.contexts.of(_c1);

      // The sink reaches the close walk's end outside a pass: no probe
      // has shown what changed since the stored token, so the stored
      // ciphertext is not given to the engine and the commit waits.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(processedCount(m1.ciphertext), 1);
      expect(await deferredIds(), [_mid(1)]);
      expect(await row(1), isNull);
      expect((await record()).close!.end, isFalse);
      expect(await epoch(), 1);
      expect(context.catchUpDueAt, isNotNull);
      // Nor does a second one, nor an unheld welcome poll.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      await rig.crypto.processWelcomes();
      expect(processedCount(m1.ciphertext), 1);
      expect(await row(1), isNull);

      // The next pass: its probe is answered for the stored token, its
      // close walk ends with the final attempt, and the commit applies.
      await pull();
      expect(processedCount(m1.ciphertext), 2);
      expect((await row(1))!.state, StoredMessageState.visible);
      expect(await epoch(), 2);
      await pull();
      await expectDelivered(m1, 1);
    });

    test('a deferred message taken down while no pass ran is rowed as '
        'removed, never decrypted, when its epoch closes', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      expect(await rec(), isNull);
      await bobSelfUpdate();
      // The app is closed. The message is taken down (the server's rule:
      // that retires every since token issued before it), and only the
      // by-id tombstone listing shows it.
      rig.server.takedownRetiresSince = true;
      takeDownUnseen(1);
      await rig.restart();

      // The next start: a catch-up closes the epoch before any probe.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(processedCount(m1.ciphertext), 1);
      expect(await row(1), isNull);
      expect(await deferredIds(), [_mid(1)]);
      expect(await epoch(), 1);

      // The passes: the token and the anchor are refused, the entry is
      // armed, the by-id listing ends the item as its removed row, and
      // the epoch closes.
      for (
        var i = 0;
        i < 6 && (await epoch() == 1 || await rec() != null);
        i++
      ) {
        await pull();
      }

      expect(processedCount(m1.ciphertext), 1);
      final r = (await row(1))!;
      expect((r.state, r.content), (StoredMessageState.removed, null));
      expect(await deferredIds(), isEmpty);
      expect(await epoch(), 2);
      expect(await rec(), isNull);
      expect((await sync()).sinceToken, isNotEmpty);
    });

    test('a final attempt with a null entry runs in a pass whose probe was '
        'answered for the stored since token', () async {
      await setUpJoined();
      await say(1, at: const Duration(minutes: -10));
      await pull();
      // The device moved on to generation 2 (generation 1's last epoch is
      // walked and its group let go), and the fast path is open.
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      await rig.device.vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        ),
      );
      await pull();
      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect(await rec(), isNull);
      final token = (await sync()).sinceToken;
      expect(token, isNotEmpty);
      // Generation 1's group is kept after all, its close walk at its end,
      // with a message of the pair deferred after that walk ended: the
      // ended walk owes a final attempt before the group goes.
      final late = await say(2, at: _seconds(-5));
      rig.server
        ..rewriteEpoch = ((r) =>
            r..messages.removeWhere((m) => m.id == _mid(2)))
        ..rewriteLive = ((r) =>
            r..messages.removeWhere((m) => m.id == _mid(2)));
      final now = rig.clock.now().microsecondsSinceEpoch;
      final stored = await record();
      await rig.device.vault.transaction((tx) async {
        await tx.putGroup(g1);
        await ReceiveRecords().putIn(
          tx,
          _c1,
          stored.copyWith(
            close: const WalkEntry(
              pair: MlsPair(1, 1),
              end: true,
              mode: WalkMode.decrypt,
            ),
          ),
        );
        await DeferredRecords().putIn(
          tx,
          _c1,
          DeferredRecord([
            DeferredItem(
              id: _mid(2),
              pair: const MlsPair(1, 1),
              at: late.createdAt.toDateTime().microsecondsSinceEpoch,
              da: now,
              ct: Uint8List.fromList(late.ciphertext),
              rc: Uint8List.fromList(late.reportCommitment),
              fs: false,
              k: 1,
              la: now,
              ru: 'bbbbbbbbbbbbbbbb',
            ),
          ]),
        );
      });
      // Something changed on the server: this pass's probe is answered for
      // the stored token, and its fast path saves the answer's NEW token
      // before the walks reach the final attempt.
      ghost(90);

      await pull();

      expect((await sync()).sinceToken, isNot(token));
      expect(await rec(), isNull);
      expect(processedCount(late.ciphertext), 1);
      expect((await row(2))!.state, StoredMessageState.visible);
      expect(await deferredIds(), isEmpty);
      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect((await record()).close, isNull);
    });
  });
}

/// A real budget (a limit no test reaches) that records each unit taken.
class _SpyBudget extends SyncBudget {
  _SpyBudget(DateTime Function() now, this.takes)
    : super(perMinute: 100000, ownDeviceCount: () => 1, now: now);

  final List<(BudgetPriority, Object?)> takes;

  @override
  Future<void> take(BudgetPriority priority, {Object? lane}) {
    takes.add((priority, lane));
    return super.take(priority, lane: lane);
  }
}

extension<T> on T {
  T also(void Function(T value) change) {
    change(this);
    return this;
  }
}
