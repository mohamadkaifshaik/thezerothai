import 'dart:typed_data';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/session/session_end.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_pipeline.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_queue_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';

// Plan 5a Task 13 (step 13-i): the pipeline's lifecycle gate items: the
// late-bound wasRemovedByUser (17-19), the stopsPipeline/removedDefinitely
// split (16), the reset-settled pass (20), set up again (34), pause (40),
// sign-out (41, 42). Each test names the mutation it catches in the report.

const _c1 = '11111111111111111111111111111111';

/// Waits (real time, bounded) until [done] holds.
Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 200; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('the condition never held');
}

void main() {
  group('wasRemovedByUserOf (items 17-19, SA L5)', () {
    test('no runner yet: a StateError, never a false answer', () async {
      final ask = wasRemovedByUserOf(() => null);
      await expectLater(ask(Uint8List(4)), throwsStateError);
    });
  });

  group('the real pipeline', () {
    late PipelineHarness h;
    late RigPeer bob;

    setUp(() async {
      h = await PipelineHarness.create();
      bob = await RigPeer.create('bob');
      h.rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    });

    tearDown(() => h.dispose());

    test(
      'items 17-19: once built, the late-bound seam asks the runner',
      () async {
        await h.ready();
        final RemovalQueueRunner runner = h.pipeline.runner;
        final ask = wasRemovedByUserOf(() => runner);
        final sibling = await RigPeer.create('sibling');
        expect(await ask(sibling.id), isFalse);
      },
    );

    test(
      'item 16: an unknown removed-elsewhere fact stops the pipeline but '
      'still lets the user remove a lost device; a definite one does not',
      () async {
        final sibling = await RigPeer.create('sibling');
        // The rig lists this device already.
        h.rig.keys.own.add(rigKeyDevice(sibling.idString, sibling.key));
        await h.ready();

        h.deviceKeys.state = RemovedElsewhere.unknown;
        expect(h.deviceKeys.stopsPipeline, isTrue);
        await h.pipeline.runner.removeDevice(sibling.idString);
        await h.settle();
        expect(
          [for (final c in h.rig.keys.removeCalls) c.deviceId],
          [sibling.idString],
        );

        h.deviceKeys.state = RemovedElsewhere.removed;
        final other = await RigPeer.create('other');
        await expectLater(
          h.pipeline.runner.removeDevice(other.idString),
          throwsStateError,
        );
        expect(h.rig.keys.removeCalls, hasLength(1));
      },
    );

    test('vault-ready order (items 15, 21): a removed-elsewhere marker not '
        'read as clear when the pipeline hook runs keeps everything idle; '
        'the read answer starts it', () async {
      await h.offer(_c1, bob);
      h.deviceKeys.state = RemovedElsewhere.unknown;
      await h.ready();
      expect(h.welcomePolls, 0);
      expect(h.rig.server.calls, isEmpty);
      expect(h.pipeline.started, isFalse);
      h.deviceKeys.clearRemoved();
      await _until(() async => h.welcomePolls >= 1);
      expect(h.pipeline.started, isTrue);
    });

    test('item 20: a reset that settles starts a removal pass', () async {
      await h.ready();
      final runner = h.pipeline.runner;
      final before = runner.passesAsked;
      h.pipeline.starter.onResetSettled!(_c1);
      await h.settle();
      expect(runner.passesAsked, before + 1, reason: 'the starter settle');
      // The join path's settle (crypto.onOwnResetEnded) too.
      h.pipeline.crypto.onOwnResetEnded!(_c1);
      await h.settle();
      expect(runner.passesAsked, before + 2, reason: 'the join settle');
    });

    test('item 40: a timer that fires while paused runs at resume', () async {
      await h.ready();
      var ran = 0;
      h.pipeline.onAppPaused();
      h.pipeline.scheduleForTest(Duration.zero, () => ran++);
      h.scheduled.last.run();
      expect(ran, 0);
      h.pipeline.onAppResumed();
      expect(ran, 1);
      // Not paused: at once.
      h.pipeline.scheduleForTest(Duration.zero, () => ran++);
      h.scheduled.last.run();
      expect(ran, 2);
    });

    test('item 34: set up again recreates the device, forgets the run and '
        'polls welcomes for the new device', () async {
      await h.offer(_c1, bob);
      await h.ready();
      h.deviceKeys.markRemoved();
      final commits = h.pipeline.commits;
      final starterResets = h.pipeline.starter.resets;
      final upkeepResets = h.pipeline.upkeep.resets;
      commits.lastRateLimit = const RateLimitedException('rig');
      h.rig.keys.peerError = const CannotMessageException();
      await h.pipeline.directory.peer('ref-bob', fresh: true);
      h.rig.keys.peerError = null;
      expect(h.pipeline.directory.isParked('ref-bob'), isTrue);

      await h.pipeline.setUpAgain();
      await h.settle();

      expect(h.deviceKeys.newId, isNotNull);
      expect(commits.lastRateLimit, isNull, reason: 'commits.reset');
      expect(h.pipeline.starter.resets, greaterThan(starterResets));
      expect(h.pipeline.upkeep.resets, greaterThan(upkeepResets));
      expect(h.pipeline.directory.isParked('ref-bob'), isFalse);
      expect(h.pipeline.started, isTrue);
      expect(
        h.rig.server.listedFor.last,
        h.deviceKeys.newId,
        reason: 'the new device polls welcomes',
      );
    });

    test('items 41, 42: sign-out resets every part and drops the remembered '
        'hints', () async {
      await h.offer(_c1, bob);
      await h.ready();
      final p = h.pipeline;
      final starter = p.starter;
      final runner = p.runner;
      final upkeep = p.upkeep;
      final commits = p.commits;
      final sender = p.sender;
      final contexts = p.contexts;
      final directory = p.directory;
      final known = p.known;
      final sync = p.coordinator!;
      final syncBudget = p.syncBudget;
      final readBudget = p.readBudget;
      final vault = h.rig.device.vault;
      final starterResets = starter.resets;
      final runnerResets = runner.resets;
      final upkeepResets = upkeep.resets;
      commits.lastRateLimit = const RateLimitedException('rig');
      sender.rememberRefusal('local-1', const CannotMessageException());
      contexts.note(
        pb.Conversation(
          id: _c1,
          peer: common.AuthorSnapshot(userId: 'ref-bob'),
        ),
      );
      h.rig.keys.peerError = const CannotMessageException();
      await directory.peer('ref-bob', fresh: true);
      h.rig.keys.peerError = null;
      final later = h.rig.clock.now().add(const Duration(minutes: 5));
      syncBudget.pauseUntil(later);
      readBudget.pauseUntil(later);
      expect(sender.memoryEntries, 1);
      expect(directory.isParked('ref-bob'), isTrue);
      expect(known.isLoadedFor(vault), isTrue);

      await h.rig.device.session.onSessionEnded(
        'user-a',
        SessionEnd.sessionLost,
      );
      await h.settle();

      final reset = <String, bool>{
        'coordinator': !sync.running,
        'starter': starter.resets > starterResets,
        'runner': runner.resets > runnerResets,
        'upkeep': upkeep.resets > upkeepResets,
        'commits': commits.lastRateLimit == null,
        'sender': sender.memoryEntries == 0,
        'contexts': contexts.of(_c1).peerUserId == null,
        'directory': !directory.isParked('ref-bob'),
        'known': !known.isLoadedFor(vault),
        'syncBudget': syncBudget.tryTake(BudgetPriority.user),
        'readBudget': readBudget.tryTake(BudgetPriority.user),
        'parts dropped': !p.hasParts,
      };
      expect(reset.entries.where((e) => !e.value).map((e) => e.key), isEmpty);
    });

    test('item 42: hints remembered while the vault is ready but the '
        'pipeline has not started are dropped at sign-out', () async {
      h.deviceKeys.phase = DeviceKeysStatus.idle;
      await h.ready();
      expect(h.pipeline.started, isFalse);
      h.pipeline
        ..noteEncrypted(_c1)
        ..noteAccepted(_c1)
        ..onPush(_c1);
      expect(h.pipeline.notedCount, 3);

      await h.rig.device.session.onSessionEnded(
        'user-a',
        SessionEnd.sessionLost,
      );
      await h.settle();
      expect(h.pipeline.notedCount, 0);
      expect(h.pipeline.hasParts, isFalse);
    });
  });
}
