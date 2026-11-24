import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';

// The acceptance sighting of a restarted app. Acceptance is stored only from
// the server's word that a conversation is ACCEPTED, and the app already reads
// that word: the rows of its inbox and requests answers and the header of a
// thread's first page. The repository reports those rows (its own tests); the
// pipeline takes each as a full sight (`ConversationContexts.note(row,
// keepPeer: true)`). No dedicated read is made: a since-poll has no header,
// and a read per conversation would wait for the read budget under the
// conversation lock and be capped (review M1, M2).

String _id(int n) => n.toRadixString(16).padLeft(32, '0');
final String _c1 = _id(1);
final String _c2 = _id(2);

pb.Conversation _row(
  String id, {
  String peer = 'ref-bob',
  Folder folder = Folder.FOLDER_INBOX,
  ConversationState state = ConversationState.CONVERSATION_STATE_ACCEPTED,
  bool canReply = true,
}) => pb.Conversation(
  id: id,
  peer: common.AuthorSnapshot(userId: peer),
  folder: folder,
  state: state,
  canReply: canReply,
);

pb.Conversation _request(String id, {String peer = 'ref-bob'}) => _row(
  id,
  peer: peer,
  folder: Folder.FOLDER_REQUESTS,
  state: ConversationState.CONVERSATION_STATE_REQUEST,
);

void main() {
  late RigCrypto rig;
  late RigPeer bob;

  Future<RigCrypto> newRig() async {
    final r = await RigCrypto.create();
    r.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    r.watchAcceptanceNow();
    return r;
  }

  setUp(() async {
    bob = await RigPeer.create('bob');
    rig = await newRig();
  });

  tearDown(() => rig.dispose());

  int listMls(RigCrypto r) =>
      r.server.calls.where((c) => c == 'listMlsMessages').length;

  Future<bool> accepted(RigCrypto r, String id) async =>
      (await r.device.vault.conversation(id))?.sync.requestAccepted ?? false;

  /// [ids] joined from bob's welcomes (the server sends no header meanwhile,
  /// as a since-poll sends none); then "a restart": no memory.
  Future<void> joinedThenRestarted(RigCrypto r, List<String> ids) async {
    for (final id in ids) {
      await r.offer(id, bob);
    }
    expect(await r.crypto.processWelcomes(), unorderedEquals(ids));
    for (final id in ids) {
      expect(
        await r.device.vault.conversation(id),
        isNotNull,
        reason: 'an unaccepted record is here',
      );
      expect(await accepted(r, id), isFalse);
    }
    r.contexts.clear();
    r.server.calls.clear();
  }

  /// A started pipeline that joined [_c1] as an unaccepted incoming request,
  /// then "a restart": no memory of any sighting, the server's header gone
  /// (a since-poll sends none).
  Future<void> restarted(PipelineHarness h) async {
    final owner = await RigPeer.create('bob');
    h.rig.keys.peers['ref-bob'] = [rigKeyDevice(owner.idString, owner.key)];
    await h.offer(_c1, owner, accepted: false);
    await h.ready();
    expect(await accepted(h.rig, _c1), isFalse);
    expect(await h.rig.device.vault.groups(_c1), isNotEmpty);
    h.rig.server.rows.remove(_c1);
    h.pipeline.contexts.clear();
    h.rig.server.calls.clear();
  }

  group('a restart, a group and an unaccepted record', () {
    test('(a) the next server inbox sync that lists it ACCEPTED settles it '
        'with no extra RPC', () async {
      await joinedThenRestarted(rig, [_c1]);

      // The inbox row, as the repository reports it from a server answer.
      rig.contexts.note(_row(_c1), keepPeer: true);
      await rig.upkeep.idle();

      expect(await accepted(rig, _c1), isTrue);
      expect(rig.contexts.of(_c1).acceptanceSettled, isTrue);
      expect(rig.server.calls.where((c) => c == 'listMlsMessages'), isEmpty);
    });

    test('(b) a thread open settles it: the first page header is a sight, '
        'through the pipeline entry the repository feeds', () async {
      final h = await PipelineHarness.create();
      try {
        await restarted(h);

        h.pipeline.noteServerRow(_row(_c1));
        await h.settle();

        expect(await accepted(h.rig, _c1), isTrue);
        expect(
          h.rig.server.calls.where((c) => c == 'listMlsMessages'),
          isEmpty,
        );
      } finally {
        await h.dispose();
      }
    });

    test('(c) a REQUEST row never accepts, in either folder', () async {
      await joinedThenRestarted(rig, [_c1, _c2]);

      rig.contexts.note(_request(_c1), keepPeer: true);
      // The user's own outgoing request: INBOX folder, REQUEST state.
      rig.contexts.note(
        _row(_c2, state: ConversationState.CONVERSATION_STATE_REQUEST),
        keepPeer: true,
      );
      await rig.upkeep.idle();
      await rig.crypto.catchUp(_c1);
      await rig.crypto.catchUp(_c2);
      await rig.upkeep.idle();

      expect(await accepted(rig, _c1), isFalse);
      expect(await accepted(rig, _c2), isFalse);
      expect(rig.contexts.of(_c1).acceptanceSettled, isFalse);
      expect(rig.contexts.of(_c1).acceptedSightingHeld, isFalse);
      expect(rig.contexts.of(_c1).requestSeenInHeader, isTrue);
    });

    test('(d) a row for a conversation with no record or group is held and '
        'applied after the join', () async {
      // Nothing is kept for _c1 yet.
      rig.contexts.note(_row(_c1), keepPeer: true);
      await rig.upkeep.idle();
      expect(rig.contexts.of(_c1).acceptedSightingHeld, isTrue);
      expect(await accepted(rig, _c1), isFalse);

      await rig.offer(_c1, bob);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await rig.upkeep.idle();

      expect(await accepted(rig, _c1), isTrue);
      expect(rig.contexts.of(_c1).acceptedSightingHeld, isFalse);
      expect(rig.contexts.of(_c1).acceptanceSettled, isTrue);
    });

    test('(e) a cached row and a send answer never count', () async {
      await joinedThenRestarted(rig, [_c1]);

      // Both reach the contexts as `peerOnly` (the pipeline's re-read of
      // the cached inbox; the sender's send answer).
      rig.contexts.note(_row(_c1), peerOnly: true);
      await rig.upkeep.idle();
      await rig.crypto.catchUp(_c1);
      await rig.upkeep.idle();

      expect(await accepted(rig, _c1), isFalse);
      expect(rig.contexts.of(_c1).acceptedSightingHeld, isFalse);
      expect(rig.contexts.of(_c1).peerUserId, 'ref-bob');
      expect(rig.server.calls.where((c) => c == 'listMlsMessages'), isEmpty);
    });

    test(
      '(e) the pipeline\'s own re-read of the cached inbox is no sight',
      () async {
        final h = await PipelineHarness.create();
        try {
          await restarted(h);

          h.messaging.inbox = [_row(_c1)];
          h.messaging.changed.add(null);
          await h.settle();

          expect(await accepted(h.rig, _c1), isFalse);
          expect(h.pipeline.contexts.of(_c1).acceptedSightingHeld, isFalse);
        } finally {
          await h.dispose();
        }
      },
    );
  });

  test('(f) 40 unanswered incoming requests and one accepted conversation: '
      'the accepted one settles, and no ListMessages call is added', () async {
    final ids = [for (var i = 1; i <= 41; i++) _id(i)];
    final acceptedId = ids.last;

    /// A run of the same scenario: join all, restart, then (when [feed]) the
    /// server's inbox rows reach the pipeline; then a catch-up of each.
    Future<({int reads, bool settled, int others})> run({
      required bool feed,
    }) async {
      final r = await newRig();
      try {
        await joinedThenRestarted(r, ids);
        if (feed) {
          for (final id in ids) {
            r.contexts.note(
              id == acceptedId ? _row(id) : _request(id),
              keepPeer: true,
            );
          }
          await r.upkeep.idle();
        }
        for (final id in ids) {
          await r.crypto.catchUp(id);
        }
        await r.upkeep.idle();
        var others = 0;
        for (final id in ids) {
          if (id != acceptedId && await accepted(r, id)) others++;
        }
        return (
          reads: listMls(r),
          settled: await accepted(r, acceptedId),
          others: others,
        );
      } finally {
        await r.dispose();
      }
    }

    final baseline = await run(feed: false);
    final fed = await run(feed: true);

    expect(baseline.settled, isFalse, reason: 'nothing settles it unfed');
    expect(fed.settled, isTrue);
    expect(fed.others, 0, reason: 'a request never accepts');
    // The same scenario unfed is origin/main's: the pipeline makes no
    // ListMessages call of its own to settle (the attribution's first-page
    // reads, which the rows even spare, are all there is).
    expect(fed.reads, lessThanOrEqualTo(baseline.reads));
  });

  group('(g) the pipeline entry with no parts', () {
    test('does nothing: no parts, no vault read, no call', () async {
      final h = await PipelineHarness.create();
      try {
        expect(h.pipeline.hasParts, isFalse);
        final reads = h.rig.device.groupsReads;

        h.pipeline.noteServerRow(_row(_c1));
        h.pipeline.noteBlocked(_c1);
        await h.settle();

        expect(h.pipeline.hasParts, isFalse);
        expect(h.rig.device.groupsReads, reads);
        expect(h.rig.server.calls, isEmpty);
        expect(h.reported, isEmpty);
      } finally {
        await h.dispose();
      }
    });
  });

  group('a held sighting is forgotten', () {
    test('by a full header that is not ACCEPTED', () {
      rig.contexts.of(_c1).acceptedSightingHeld = true;

      rig.contexts.note(_request(_c1));

      expect(rig.contexts.of(_c1).acceptedSightingHeld, isFalse);
    });

    test('by a full row that says the thread cannot be answered', () {
      rig.contexts.of(_c1).acceptedSightingHeld = true;

      rig.contexts.note(_row(_c1, canReply: false));

      expect(rig.contexts.of(_c1).acceptedSightingHeld, isFalse);
      expect(rig.contexts.of(_c1).canReply, isFalse);
    });

    test('not by a peer-only row, nor by an ACCEPTED row that can be '
        'answered', () {
      rig.contexts.of(_c1).acceptedSightingHeld = true;

      rig.contexts.note(_row(_c1, canReply: false), peerOnly: true);
      expect(rig.contexts.of(_c1).acceptedSightingHeld, isTrue);

      rig.contexts.note(_row(_c1));
      expect(rig.contexts.of(_c1).acceptedSightingHeld, isTrue);
    });

    test('an ACCEPTED row that cannot be answered is not held in the first '
        'place (no record or group yet)', () async {
      rig.contexts.note(_row(_c1, canReply: false), keepPeer: true);
      await rig.upkeep.idle();

      expect(rig.contexts.of(_c1).acceptedSightingHeld, isFalse);
      expect(await accepted(rig, _c1), isFalse);
    });

    test('by a delete-for-me of the conversation', () async {
      final h = await PipelineHarness.create();
      try {
        await h.ready();
        h.pipeline.contexts.of(_c1).acceptedSightingHeld = true;

        h.pipeline.noteDeleted(_c1);
        await h.settle();

        expect(h.pipeline.contexts.of(_c1).acceptedSightingHeld, isFalse);
      } finally {
        await h.dispose();
      }
    });

    test('by the user blocking the peer from the thread', () async {
      final h = await PipelineHarness.create();
      try {
        await h.ready();
        h.pipeline.contexts.of(_c1).acceptedSightingHeld = true;

        h.pipeline.noteBlocked(_c1);
        await h.settle();

        expect(h.pipeline.contexts.of(_c1).acceptedSightingHeld, isFalse);
      } finally {
        await h.dispose();
      }
    });

    test('by CANNOT_MESSAGE', () {
      rig.contexts.of(_c1).acceptedSightingHeld = true;

      rig.contexts.of(_c1).noteCannotMessage();

      expect(rig.contexts.of(_c1).acceptedSightingHeld, isFalse);
      expect(rig.contexts.of(_c1).canReply, isFalse);
    });
  });

  group('a stored accepted record settles the conversation', () {
    test('later passes read the vault less', () async {
      await joinedThenRestarted(rig, [_c1]);
      await rig.accept(_c1);

      final g0 = rig.device.groupsReads;
      await rig.crypto.catchUp(_c1);
      final first = rig.device.groupsReads - g0;
      expect(rig.contexts.of(_c1).acceptanceSettled, isTrue);
      final g1 = rig.device.groupsReads;
      await rig.crypto.catchUp(_c1);
      final second = rig.device.groupsReads - g1;

      expect(second, lessThan(first));
    });
  });

  group('a header is bound to the conversation asked for', () {
    pb.Conversation other() => _row(_c2, peer: 'ref-intruder');

    /// Every first page, whatever the conversation asked for, carries the
    /// header of [_c2]; the cache and the server's row of [_c1] are empty.
    void foreignHeaders() {
      rig.server.rows.clear();
      rig.server.rewriteLive = (real) =>
          real.deepCopy()..conversation = other();
    }

    test('the attribution first-page read ignores a header for another '
        'id', () async {
      await rig.offer(_c1, bob);
      await rig.crypto.processWelcomes();
      rig.contexts.clear();
      foreignHeaders();

      await rig.crypto.attributeMembers(_c1);

      expect(rig.contexts.of(_c1).peerUserId, isNull);
      expect(rig.contexts.of(_c2).peerUserId, isNull);
    });

    test('the receiver probe ignores a header for another id', () async {
      await rig.offer(_c1, bob);
      await rig.crypto.processWelcomes();
      rig.contexts.clear();
      foreignHeaders();

      await rig.receiver.pullLive(_c1);

      expect(rig.contexts.of(_c1).peerUserId, isNull);
      expect(rig.contexts.of(_c2).peerUserId, isNull);
      expect(rig.contexts.of(_c2).canReply, isTrue);
      expect(rig.contexts.of(_c2).incomingRequest, isNull);
    });
  });

  group('the peer reference of a sight', () {
    test('keepPeer keeps one the context already has, and takes the rest '
        'from the row', () {
      rig.contexts.of(_c1).peerUserId = 'ref-one';

      rig.contexts.note(_request(_c1, peer: 'ref-two'), keepPeer: true);

      final c = rig.contexts.of(_c1);
      expect(c.peerUserId, 'ref-one');
      expect(c.incomingRequest, isTrue);
      expect(c.requestSeenInHeader, isTrue);
    });

    test('keepPeer sets the peer when the context has none', () {
      rig.contexts.note(_request(_c1, peer: 'ref-two'), keepPeer: true);

      expect(rig.contexts.of(_c1).peerUserId, 'ref-two');
    });
  });
}
