import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';

// The restart header read of the catch-up (acceptance sighting fix round):
// its budget, priority, caps, binding to the conversation asked for, and the
// held sighting's invalidation.

String _id(int n) => n.toRadixString(16).padLeft(32, '0');
final String _c1 = _id(1);
final String _c2 = _id(2);

/// A budget that counts the units taken from it.
class _CountingBudget extends SyncBudget {
  _CountingBudget(DateTime Function() now)
    : super(perMinute: 100000, ownDeviceCount: () => 1, now: now);

  int takes = 0;

  @override
  Future<void> take(BudgetPriority priority, {Object? lane}) {
    takes++;
    return super.take(priority, lane: lane);
  }
}

pb.Conversation _row(
  String id, {
  String peer = 'ref-bob',
  Folder folder = Folder.FOLDER_REQUESTS,
  ConversationState state = ConversationState.CONVERSATION_STATE_REQUEST,
}) => pb.Conversation(
  id: id,
  peer: common.AuthorSnapshot(userId: peer),
  folder: folder,
  state: state,
  canReply: true,
);

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late _CountingBudget syncBudget;
  late _CountingBudget readBudget;

  setUp(() async {
    rig = await RigCrypto.create(
      syncBudget: (c) => syncBudget = _CountingBudget(c.now),
      readBudget: (c) => readBudget = _CountingBudget(c.now),
    );
    bob = await RigPeer.create('bob');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
  });

  tearDown(() => rig.dispose());

  int listMls() => rig.server.calls.where((c) => c == 'listMlsMessages').length;

  /// [ids] joined from bob's welcomes, the server's first page carrying no
  /// header meanwhile; then "a restart": no memory, and [row] answers.
  Future<void> joinedThenRestarted(
    List<String> ids, {
    pb.Conversation Function(String id)? row,
  }) async {
    for (final id in ids) {
      await rig.offer(id, bob);
    }
    expect(await rig.crypto.processWelcomes(), unorderedEquals(ids));
    rig.contexts.clear();
    for (final id in ids) {
      rig.server.rows[id] = (row ?? _row)(id);
    }
    rig.server.calls.clear();
    readBudget.takes = 0;
    syncBudget.takes = 0;
  }

  group('the restart header read: budget, priority and caps', () {
    test('40 joined unaccepted conversations make at most the per-run cap of '
        'reads, on the read budget, none on the sync budget', () async {
      final ids = [for (var i = 1; i <= 40; i++) _id(i)];
      await joinedThenRestarted(ids);
      int commitLists() =>
          rig.server.calls.where((c) => c == 'listConversationCommits').length;

      for (final id in ids) {
        await rig.crypto.catchUp(id);
      }

      expect(listMls(), kAcceptanceHeaderReadsPerRun);
      expect(readBudget.takes, kAcceptanceHeaderReadsPerRun);
      // The sync budget paid for the commit listings only.
      expect(syncBudget.takes, commitLists());
      expect(rig.server.readHold, isNull);
    });

    test('a rate-limit answer pauses the read budget and no further read '
        'is made', () async {
      await joinedThenRestarted([_c1, _c2]);
      rig.server.onCall = (call) async {
        if (call == 'listMlsMessages') {
          throw const RateLimitedException(
            'slow down',
            retryAfter: Duration(minutes: 2),
          );
        }
      };

      await rig.crypto.catchUp(_c1);
      expect(readBudget.paused, isTrue);
      await rig.crypto.catchUp(_c2);

      expect(listMls(), 1);
    });

    test('a user-priority pass makes no read', () async {
      await joinedThenRestarted([_c1]);

      await rig.crypto.catchUp(_c1, priority: BudgetPriority.user);

      expect(listMls(), 0);
      expect(readBudget.takes, 0);
      // A later background pass does.
      await rig.crypto.catchUp(_c1);
      expect(listMls(), 1);
    });

    test('no second read after a first page the probe took', () async {
      await joinedThenRestarted([_c1]);
      // The receiver's probe (a first page: no stored token) notes the
      // header.
      await rig.receiver.pullLive(_c1);
      final reads = listMls();
      expect(reads, greaterThan(0));

      await rig.crypto.catchUp(_c1);

      expect(listMls(), reads);
    });

    test('a failing read stops after the failure cap for that run', () async {
      await joinedThenRestarted([_c1]);
      rig.server.onCall = (call) async {
        if (call == 'listMlsMessages') throw const NetworkException('down');
      };

      for (var i = 0; i < 5; i++) {
        await rig.crypto.catchUp(_c1);
      }

      expect(listMls(), kAcceptanceHeaderFailuresPerRun);
    });

    test('a held sighting applied in the same call makes no read', () async {
      await joinedThenRestarted([_c1]);
      rig.contexts.of(_c1).acceptedSightingHeld = true;

      await rig.crypto.catchUp(_c1);

      expect(listMls(), 0);
      expect(rig.contexts.of(_c1).acceptedSightingHeld, isFalse);
    });

    test('a stored accepted record settles the conversation: later passes '
        'read the vault less', () async {
      await joinedThenRestarted([_c1]);
      await rig.accept(_c1);

      final g0 = rig.device.groupsReads;
      await rig.crypto.catchUp(_c1);
      final first = rig.device.groupsReads - g0;
      expect(rig.contexts.of(_c1).acceptanceSettled, isTrue);
      final g1 = rig.device.groupsReads;
      await rig.crypto.catchUp(_c1);
      final second = rig.device.groupsReads - g1;

      expect(second, lessThan(first));
      expect(listMls(), 0);
    });
  });

  group('the header is bound to the conversation asked for', () {
    pb.Conversation other(String asked) => _row(
      _c2,
      peer: 'ref-intruder',
      folder: Folder.FOLDER_INBOX,
      state: ConversationState.CONVERSATION_STATE_ACCEPTED,
    );

    /// Every first page, whatever the conversation asked for, carries the
    /// header of [_c2]; the cache and the server's row of [_c1] are empty.
    void foreignHeaders() {
      rig.server.rows.clear();
      rig.server.rewriteLive = (real) =>
          real.deepCopy()..conversation = other(_c1);
    }

    test('the restart read ignores a header for another id', () async {
      await joinedThenRestarted([_c1]);
      foreignHeaders();

      await rig.crypto.catchUp(_c1);
      await rig.upkeep.idle();

      expect(listMls(), greaterThanOrEqualTo(1));
      expect(rig.contexts.of(_c1).peerUserId, isNull);
      expect(rig.contexts.of(_c2).peerUserId, isNull);
      expect(rig.contexts.of(_c2).acceptanceSettled, isFalse);
      expect(
        (await rig.device.vault.conversation(_c1))?.sync.requestAccepted ??
            false,
        isFalse,
      );
    });

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

  group('the restart read and the context', () {
    test('keeps a peer ref the context already has, and takes the rest from '
        'the header', () async {
      await joinedThenRestarted([_c1], row: (id) => _row(id, peer: 'ref-two'));
      rig.contexts.of(_c1).peerUserId = 'ref-one';

      await rig.crypto.catchUp(_c1);

      final c = rig.contexts.of(_c1);
      expect(c.peerUserId, 'ref-one');
      expect(c.incomingRequest, isTrue);
      expect(c.requestSeenInHeader, isTrue);
    });

    test('sets the peer when the context has none', () async {
      await joinedThenRestarted([_c1], row: (id) => _row(id, peer: 'ref-two'));

      await rig.crypto.catchUp(_c1);

      expect(rig.contexts.of(_c1).peerUserId, 'ref-two');
    });
  });

  group('a held sighting is invalidated', () {
    test('by a full header that is not ACCEPTED', () {
      rig.contexts.of(_c1).acceptedSightingHeld = true;

      rig.contexts.note(_row(_c1));

      expect(rig.contexts.of(_c1).acceptedSightingHeld, isFalse);
    });

    test('not by a peer-only row, nor by an ACCEPTED header', () {
      rig.contexts.of(_c1).acceptedSightingHeld = true;

      rig.contexts.note(_row(_c1), peerOnly: true);
      expect(rig.contexts.of(_c1).acceptedSightingHeld, isTrue);

      rig.contexts.note(
        _row(
          _c1,
          folder: Folder.FOLDER_INBOX,
          state: ConversationState.CONVERSATION_STATE_ACCEPTED,
        ),
      );
      expect(rig.contexts.of(_c1).acceptedSightingHeld, isTrue);
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

    test('by a CANNOT_MESSAGE answer', () {
      rig.contexts.of(_c1).acceptedSightingHeld = true;

      rig.contexts.of(_c1).noteCannotMessage();

      expect(rig.contexts.of(_c1).acceptedSightingHeld, isFalse);
      expect(rig.contexts.of(_c1).canReply, isFalse);
    });
  });
}
