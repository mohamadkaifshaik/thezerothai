import 'dart:convert';

import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/conversation_id.dart';
import 'package:dzeroth/features/messages/domain/e2ee/commit_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart'
    show kDeviceListReuse;
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/presentation/report_conversation.dart'
    show encryptedReportTargetId;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import 'smoke_world.dart';

// Plan 5a Task 16 (spec 7.12): two users, three devices, the encrypted
// messaging pipeline against the REAL API on the Firebase emulators, the fake
// MLS engine on each device. Run by `make e2ee-smoke` (scripts/e2ee-smoke.sh),
// which starts the API with the flags this scenario needs and passes the
// defines below. With E2EE_SMOKE_API empty every test is skipped, so
// `make flutter-test` and CI never run it.
//
// One test per scenario step; the steps share one world and run in order. A
// step whose earlier step failed fails at once naming it (the world is not in
// the state it needs). Every assertion is on vault contents or port values,
// never on logs. A failure here is a contract mismatch between the pipeline
// and the server: report it, do not bend the test.

const _api = String.fromEnvironment('E2EE_SMOKE_API');
const _authHost = String.fromEnvironment(
  'E2EE_SMOKE_AUTH',
  defaultValue: '127.0.0.1:9099',
);
const _project = String.fromEnvironment(
  'E2EE_SMOKE_PROJECT',
  defaultValue: 'demo-dzeroth-local',
);
const _run = String.fromEnvironment('E2EE_SMOKE_RUN');

void main() {
  group(
    'E2EE smoke: two users, three devices, the real API',
    skip: _api.isEmpty
        ? 'E2EE_SMOKE_API is empty: run through `make e2ee-smoke`'
        : null,
    _scenario,
  );
}

void _scenario() {
  late SmokeWorld w;
  late SmokeUser a, b, c, d;
  late SmokeDevice a1, a2, b1, c1, d1;
  late String conv; // A and B's conversation
  final passed = <String>{};
  final launched = <SmokeDevice>[];

  // Every text is unique to this run, so a cache scan cannot match by chance.
  String text(String word) => '$word $_run';
  final one = text('one');
  final two = text('two');
  final three = text('three');
  final four = text('four');
  final fiveA = text('five-a');
  final fiveB = text('five-b');
  final six = text('six');
  final seven = text('seven');
  final eightA = text('eight-a');
  final eightB = text('eight-b');
  final shareAb = text('share-ab');
  final firstCd = text('first-cd');
  final shareCd = text('share-cd');
  final all = [
    one,
    two,
    three,
    four,
    fiveA,
    fiveB,
    six,
    seven,
    eightA,
    eightB,
    shareAb,
    firstCd,
    shareCd,
  ];

  void step(
    String id,
    String title,
    List<String> needs,
    Future<void> Function() body,
  ) {
    test('step $id: $title', () async {
      for (final n in needs) {
        if (!passed.contains(n)) fail('not run: step $n did not pass');
      }
      await body();
      passed.add(id);
    }, timeout: const Timeout(Duration(minutes: 8)));
  }

  Future<SmokeDevice> start(String name, SmokeUser user) async {
    final device = await w.newDevice(name, user);
    await device.launch();
    launched.add(device);
    return device;
  }

  Future<SecurityCode> codeOf(SmokeDevice dev, String id) =>
      dev.port.securityCode(id);

  bool counts(SecurityCode s, int mine, int theirs) =>
      s.digits != null && s.myDevices == mine && s.theirDevices == theirs;

  setUpAll(() async {
    if (_api.isEmpty) return;
    if (_run.isEmpty) {
      fail('E2EE_SMOKE_RUN is empty: scripts/e2ee-smoke.sh passes it');
    }
    w = SmokeWorld(
      apiBase: _api,
      auth: SmokeAuth(host: _authHost, project: _project),
      run: _run,
    );
    a = await w.newUser('a');
    b = await w.newUser('b');
    c = await w.newUser('c');
    d = await w.newUser('d');
    await w.follow(a, b);
    await w.follow(b, a);
    await w.follow(c, d);
    await w.follow(d, c);
  });

  tearDownAll(() async {
    if (_api.isEmpty) return;
    await w.close();
  });

  step(
    '1',
    'A1 and B1 register; A1 starts the conversation; B1 joins',
    [],
    () async {
      b1 = await start('B1', b);
      a1 = await start('A1', a);
      for (final dev in [a1, b1]) {
        final own = await dev.port.ownDevices();
        expect(own.directoryKnown, isTrue, reason: '${dev.name} directory');
        expect(
          own.devices.where((x) => x.thisDevice && x.inDirectory).length,
          1,
          reason: '${dev.name}: this device is in the key directory',
        );
      }

      final out = await a1.port.send(
        to: ThreadRef.recipientOf(await a1.pickerSnapshotOf(b)),
        localId: SmokeWorld.newKey(),
        text: one,
      );
      expect(out.kind, SendOutcomeKind.queued);
      expect(isConversationId(out.conversationId ?? ''), isTrue);
      conv = out.conversationId!;
      final ta1 = a1.watch(conv);
      final tb1 = b1.watch(conv);

      await w.eventually(
        'A1 delivered "one" and B1 decrypted it',
        () async =>
            ta1.showsOnce(one, mine: true) && tb1.showsOnce(one, mine: false),
        nudge: () async {
          await b1.nudgeInbox();
          b1.push(conv);
        },
      );

      // The conversation is MLS at (1, 1): the server's header, and the pair
      // both vaults stored the message at.
      final row = (await a1.inbox()).where((r) => r.id == conv).toList();
      expect(row, hasLength(1));
      expect(
        row.single.encryption,
        ConversationEncryption.CONVERSATION_ENCRYPTION_MLS,
      );
      for (final dev in [a1, b1]) {
        final stored = await dev.storedWithText(conv, one);
        expect(stored, hasLength(1), reason: '${dev.name} stores "one" once');
        expect(
          (stored.single.generation, stored.single.epoch),
          (1, 1),
          reason: '${dev.name}: the pair of "one"',
        );
      }
      expect((await a1.storedWithText(conv, one)).single.mine, isTrue);
      expect((await b1.storedWithText(conv, one)).single.mine, isFalse);
    },
  );

  step('2', 'B1 replies; equal codes, 1 and 1 devices', ['1'], () async {
    final out = await b1.port.send(
      to: ThreadRef.conversation(conv),
      localId: SmokeWorld.newKey(),
      text: two,
    );
    expect(out.kind, SendOutcomeKind.queued);
    await w.eventually('A1 decrypted "two"; both codes 1/1', () async {
      if (!a1.thread(conv).showsOnce(two, mine: false)) return false;
      if (!b1.thread(conv).showsOnce(two, mine: true)) return false;
      final ca = await codeOf(a1, conv);
      final cb = await codeOf(b1, conv);
      return counts(ca, 1, 1) && counts(cb, 1, 1);
    }, nudge: () async => a1.push(conv));
    final ca = await codeOf(a1, conv);
    final cb = await codeOf(b1, conv);
    expect(ca.digits, hasLength(60));
    expect(ca.digits, cb.digits, reason: 'both sides show one code');
  });

  step(
    '3',
    'A2 starts and is added; codes equal again, 2 and 1',
    ['2'],
    () async {
      a2 = await start('A2', a);
      // The device lists the others hold are reused for kDeviceListReuse; the
      // clients' time moves past it, so A2 shows up in the next lookups.
      w.clock.advance(kDeviceListReuse + const Duration(minutes: 1));
      final ta2 = a2.watch(conv);

      await w.eventually(
        'A2 added and joined; codes 2/1 on A, 1/2 on B',
        () async {
          if (!a2.port.hasLocal(conv)) return false;
          final c1 = await codeOf(a1, conv);
          final c2 = await codeOf(a2, conv);
          final cb = await codeOf(b1, conv);
          return counts(c1, 2, 1) && counts(c2, 2, 1) && counts(cb, 1, 2);
        },
        nudge: () async {
          await a1.resume();
          a1.push(conv);
          b1.push(conv);
          await a2.nudgeInbox();
          a2.push(conv);
        },
      );

      final out = await b1.port.send(
        to: ThreadRef.conversation(conv),
        localId: SmokeWorld.newKey(),
        text: three,
      );
      expect(out.kind, SendOutcomeKind.queued);
      await w.eventually(
        'A2 and A1 decrypted "three"',
        () async =>
            ta2.showsOnce(three, mine: false) &&
            a1.thread(conv).showsOnce(three, mine: false),
        nudge: () async {
          a1.push(conv);
          a2.push(conv);
        },
      );
      expect(
        ta2.messages.where(
          (m) => m.state == EncryptedMessageState.undecryptable,
        ),
        isEmpty,
        reason: 'A2 shows no message from before its join as a failure',
      );
      expect(
        a1
            .thread(conv)
            .lines
            .where(
              (l) =>
                  l.kind == SystemLineKind.deviceAdded &&
                  l.side == LineSide.mine,
            ),
        hasLength(1),
        reason: 'A1 holds one deviceAdded row for its own side',
      );
      expect(
        b1
            .thread(conv)
            .lines
            .where(
              (l) =>
                  l.kind == SystemLineKind.deviceAdded &&
                  l.side == LineSide.theirs,
            ),
        hasLength(1),
        reason: 'B1 holds one deviceAdded row for the other side',
      );
      final codes = [
        for (final dev in [a1, a2, b1]) (await codeOf(dev, conv)).digits,
      ];
      expect(codes.toSet(), hasLength(1), reason: 'one code on three devices');
    },
  );

  step('4', 'A2 sends; A1 and B1 decrypt; mine on A1', ['3'], () async {
    final out = await a2.port.send(
      to: ThreadRef.conversation(conv),
      localId: SmokeWorld.newKey(),
      text: four,
    );
    expect(out.kind, SendOutcomeKind.queued);
    await w.eventually(
      'A1 (mine) and B1 (theirs) decrypted "four"',
      () async =>
          a2.thread(conv).showsOnce(four, mine: true) &&
          b1.thread(conv).showsOnce(four, mine: false) &&
          a1.thread(conv).withText(four).length == 1,
      nudge: () async {
        a1.push(conv);
        b1.push(conv);
      },
    );
    final onA1 = a1.thread(conv).withText(four).single;
    expect(onA1.mine, isTrue, reason: 'A2 is A\'s device: mine on A1');
    expect(onA1.state, EncryptedMessageState.visible);
    expect(onA1.check, MessageCheck.ok);
  });

  step(
    '5',
    'a commit lands between two sends: STALE_EPOCH, caught up, once',
    ['4'],
    () async {
      final before = b1.wire.sends.length;
      // A1's commit lands; B1 has not seen it (no push reaches B1 here).
      final committed = await a1.pipeline.commits.selfUpdate(conv);
      expect(committed, CommitOutcome.applied);
      final outs = await Future.wait([
        a1.port.send(
          to: ThreadRef.conversation(conv),
          localId: SmokeWorld.newKey(),
          text: fiveA,
        ),
        b1.port.send(
          to: ThreadRef.conversation(conv),
          localId: SmokeWorld.newKey(),
          text: fiveB,
        ),
      ]);
      expect(
        [for (final o in outs) o.kind],
        [SendOutcomeKind.queued, SendOutcomeKind.queued],
      );
      await w.eventually(
        'both messages delivered and decrypted on every device',
        () async =>
            a1.thread(conv).showsOnce(fiveA, mine: true) &&
            b1.thread(conv).showsOnce(fiveB, mine: true) &&
            a1.thread(conv).showsOnce(fiveB, mine: false) &&
            a2.thread(conv).showsOnce(fiveB, mine: false) &&
            b1.thread(conv).showsOnce(fiveA, mine: false),
        nudge: () async {
          a1.push(conv);
          a2.push(conv);
          b1.push(conv);
        },
      );
      final b1Sends = b1.wire.sends.skip(before).toList();
      expect(
        b1Sends.where((s) => s.reason == ErrorReason.ERROR_REASON_STALE_EPOCH),
        isNotEmpty,
        reason:
            'B1 sent at the epoch before A1\'s commit, so the server refused it '
            'with STALE_EPOCH (if B1 caught up first, the precondition was not '
            'met: ${[for (final s in b1Sends) '${s.status}/${s.reason}']})',
      );
      expect(
        (await a1.storedWithText(conv, fiveB)).length,
        1,
        reason: 'the loser\'s message arrives once',
      );
    },
  );

  step(
    '6',
    'B1 restarts with an encrypted row unsent: same bytes, stored once',
    ['4'],
    () async {
      b1.wire.sendsOffline = true;
      final out = await b1.port.send(
        to: ThreadRef.conversation(conv),
        localId: SmokeWorld.newKey(),
        text: six,
      );
      expect(out.kind, SendOutcomeKind.queued);
      late OutboxItem held;
      await w.eventually('B1 holds "six" encrypted and unsent', () async {
        final read = await b1.vault.outbox(conversationId: conv);
        for (final item in read.items) {
          if (item.stage != OutboxStage.encrypted) continue;
          if (decodeMessageContentLenient(item.content).text != six) continue;
          final tried = b1.wire.sends.any(
            (s) => s.offline && s.request.idempotencyKey == item.idempotencyKey,
          );
          if (!tried) continue;
          held = item;
          return true;
        }
        return false;
      });
      await b1.shutdown();
      b1.wire.sendsOffline = false;
      await b1.launch();

      await w.eventually(
        'A1 and A2 decrypted "six" once; B1 shows it delivered',
        () async =>
            b1.thread(conv).showsOnce(six, mine: true) &&
            a1.thread(conv).showsOnce(six, mine: false) &&
            a2.thread(conv).showsOnce(six, mine: false),
        nudge: () async {
          a1.push(conv);
          a2.push(conv);
        },
      );
      final calls = [
        for (final s in b1.wire.sends)
          if (s.request.idempotencyKey == held.idempotencyKey) s,
      ];
      expect(calls.where((s) => s.stored), isNotEmpty);
      for (final s in calls) {
        expect(
          s.request.ciphertext,
          held.ciphertext,
          reason: 'every attempt sends the stored bytes',
        );
      }
      expect((await b1.storedWithText(conv, six)).length, 1);
      expect((await a1.storedWithText(conv, six)).length, 1);
      final left = await b1.vault.outbox(conversationId: conv);
      expect(
        left.items.where((i) => i.idempotencyKey == held.idempotencyKey),
        isEmpty,
      );
    },
  );

  step(
    '7',
    'A1 removes A2; A2 finds out and sends nothing more',
    ['4'],
    () async {
      // REMOTE removal needs a recent sign-in: A1 signs in again (the Auth
      // emulator's own sign-in, no server bypass).
      await a1.tokens.signIn();
      final own = await a1.port.ownDevices();
      final others = [
        for (final x in own.devices)
          if (!x.thisDevice && x.inDirectory) x,
      ];
      expect(others, hasLength(1), reason: 'A1 lists A2');
      final a2SendsBefore = a2.wire.sends.length;
      await a1.port.removeDevice(others.single.ref);

      await w.eventually(
        'A2 removed from the group: codes 1/1, a deviceRemoved row on B1',
        () async {
          final ca = await codeOf(a1, conv);
          final cb = await codeOf(b1, conv);
          return counts(ca, 1, 1) &&
              counts(cb, 1, 1) &&
              a1.port.removalsPending.value == 0 &&
              b1
                  .thread(conv)
                  .lines
                  .any(
                    (l) =>
                        l.kind == SystemLineKind.deviceRemoved &&
                        l.side == LineSide.theirs,
                  );
        },
        nudge: () async {
          await a1.resume();
          a1.push(conv);
          b1.push(conv);
        },
      );
      expect((await codeOf(a1, conv)).digits, (await codeOf(b1, conv)).digits);

      await w.eventually(
        'A2 reports removedElsewhere',
        () async => a2.port.removedElsewhere.value,
        nudge: () => a2.port.retryDeviceSetup(),
      );
      try {
        await a2.port.send(
          to: ThreadRef.conversation(conv),
          localId: SmokeWorld.newKey(),
          text: seven,
        );
      } on Object {
        // Any answer: what counts is that nothing goes out.
      }
      // A few rounds of every trigger A2 has.
      for (var i = 0; i < 4; i++) {
        a2.push(conv);
        await a2.resume();
        await a2.settle();
        b1.push(conv);
        await b1.settle();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      expect(
        a2.wire.sends.length,
        a2SendsBefore,
        reason: 'A2 sends nothing after its removal',
      );
      expect(b1.thread(conv).withText(seven), isEmpty);
      expect(a1.thread(conv).withText(seven), isEmpty);
      expect(a2.tokens.sessionEnded, 0, reason: 'device_sign_out is off');
    },
  );

  step(
    '8',
    'B1 resets: generation 2 on both, one reset row each',
    ['7'],
    () async {
      await b1.port.resetConversation(conv);
      bool hasGen2(List<GroupRecord> groups) =>
          groups.any((g) => g.generation == 2);
      int resets(SmokeDevice dev) => dev
          .thread(conv)
          .lines
          .where((l) => l.kind == SystemLineKind.encryptionReset)
          .length;
      await w.eventually(
        'A1 joined generation 2; one reset row on A1 and B1',
        () async =>
            hasGen2(await a1.vault.groups(conv)) &&
            hasGen2(await b1.vault.groups(conv)) &&
            resets(a1) == 1 &&
            resets(b1) == 1,
        nudge: () async {
          a1.push(conv);
          b1.push(conv);
        },
      );
      final outs = await Future.wait([
        b1.port.send(
          to: ThreadRef.conversation(conv),
          localId: SmokeWorld.newKey(),
          text: eightB,
        ),
        a1.port.send(
          to: ThreadRef.conversation(conv),
          localId: SmokeWorld.newKey(),
          text: eightA,
        ),
      ]);
      expect(
        [for (final o in outs) o.kind],
        [SendOutcomeKind.queued, SendOutcomeKind.queued],
      );
      await w.eventually(
        'messages after the reset decrypted by both',
        () async =>
            a1.thread(conv).showsOnce(eightB, mine: false) &&
            b1.thread(conv).showsOnce(eightA, mine: false),
        nudge: () async {
          a1.push(conv);
          b1.push(conv);
        },
      );
      expect((await a1.storedWithText(conv, eightB)).single.generation, 2);
      expect(a1.thread(conv).showsOnce(one, mine: true), isTrue);
      expect(b1.thread(conv).showsOnce(one, mine: false), isTrue);
      expect(resets(a1), 1);
      expect(resets(b1), 1);
    },
  );

  step('9', 'B1 reports A1\'s first message', ['1'], () async {
    final m = b1.thread(conv).withText(one).single;
    expect(m.canReport, isTrue);
    final payload = await b1.port.reportPayload(conv, m.id);
    expect(payload, isNotNull);
    expect(payload, isNotEmpty);
    final receipt = await b1.moderation.report(
      idempotencyKey: SmokeWorld.newKey(),
      targetType: ReportTargetType.REPORT_TARGET_TYPE_MESSAGE,
      targetId: encryptedReportTargetId(conv, m),
      reason: ReportReason.REPORT_REASON_SPAM,
      messagePayload: payload,
    );
    expect(receipt.reportId, isNotEmpty);
  });

  // Re-read N3: the picker's ref for the peer equals the header's
  // peer.userId byte for byte, and a share by recipient after a restart goes
  // into the known conversation; with public_ids off (A, B) and on (C, D).
  Future<void> sameRefAndShare({
    required SmokeDevice from,
    required SmokeDevice to,
    required SmokeUser peer,
    required String conversationId,
    required String share,
  }) async {
    final snapshot = await from.pickerSnapshotOf(peer);
    final ref = ThreadRef.recipientOf(snapshot);
    final rows = [
      for (final r in await from.inbox())
        if (r.id == conversationId) r,
    ];
    expect(rows, hasLength(1));
    expect(
      utf8.encode(ref.recipientUserId!),
      utf8.encode(rows.single.peer.userId),
      reason: 'picker ref == peer.userId, byte for byte',
    );
    await from.restart();
    final again = ThreadRef.recipientOf(await from.pickerSnapshotOf(peer));
    expect(again, ref);
    final out = await from.port.send(
      to: again,
      localId: SmokeWorld.newKey(),
      text: share,
    );
    expect(out.kind, SendOutcomeKind.queued);
    expect(out.conversationId, conversationId);
    await w.eventually(
      '${to.name} decrypted the share in the same conversation',
      () async => to.thread(conversationId).showsOnce(share, mine: false),
      nudge: () async => to.push(conversationId),
    );
  }

  step(
    '9a',
    'recipient ref == peer.userId, public_ids off and on',
    ['1'],
    () async {
      expect(a.has('public_ids'), isFalse);
      expect(a.userId, a.uid, reason: 'public_ids off: the uid on the wire');
      await sameRefAndShare(
        from: a1,
        to: b1,
        peer: b,
        conversationId: conv,
        share: shareAb,
      );

      expect(c.has('public_ids'), isTrue);
      expect(c.userId, isNot(c.uid), reason: 'public_ids on: a public id');
      d1 = await start('D1', d);
      c1 = await start('C1', c);
      final out = await c1.port.send(
        to: ThreadRef.recipientOf(await c1.pickerSnapshotOf(d)),
        localId: SmokeWorld.newKey(),
        text: firstCd,
      );
      expect(out.kind, SendOutcomeKind.queued);
      final convCd = out.conversationId!;
      c1.watch(convCd);
      d1.watch(convCd);
      await w.eventually(
        'D1 joined and decrypted the first message',
        () async => d1.thread(convCd).showsOnce(firstCd, mine: false),
        nudge: () async {
          await d1.nudgeInbox();
          d1.push(convCd);
        },
      );
      await sameRefAndShare(
        from: c1,
        to: d1,
        peer: d,
        conversationId: convCd,
        share: shareCd,
      );
    },
  );

  step('10', 'nothing of any message is in a MessagingStore', ['1'], () async {
    final hits = <String>[];
    for (final dev in launched) {
      await dev.nudgeInbox();
      for (final id in dev.threads.keys) {
        try {
          await dev.messaging.refreshThread(id);
        } on Object {
          // A refused read stores nothing.
        }
      }
      hits.addAll(await dev.cacheHits(all));
    }
    expect(hits, isEmpty, reason: 'plaintext in the cache database');
  });
}
