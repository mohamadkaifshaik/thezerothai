import 'dart:async';

import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart'
    show kResetWaitWithoutWelcome;
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart'
    show kDeferredWithUnattributedLimit;
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';

// An open thread shows what the clock decides (the reset offer after the
// wait without a welcome): one timer per watched thread, on the pipeline's
// injected clock and timer seam, re-armed after every build.

const _c1 = '11111111111111111111111111111111';
const _ref = ThreadRef.conversation(_c1);

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 500; i++) {
    if (done()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('the condition never held');
}

void main() {
  late PipelineHarness h;
  late RigPeer bob;
  late EncryptedMessagingImpl port;
  late DateTime firstSaw;

  setUp(() async {
    h = await PipelineHarness.create();
    bob = await RigPeer.create('bob');
    h.rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    port = EncryptedMessagingImpl(h.pipeline);
  });

  tearDown(() => h.dispose());

  /// Joined and accepted, then a later generation seen at the rig clock's
  /// now (this device waits for a welcome that never comes).
  Future<void> waiting() async {
    await h.offer(_c1, bob);
    await h.ready();
    firstSaw = h.rig.clock.now();
    final vault = h.rig.device.vault;
    final sync = (await vault.conversation(_c1))!.sync;
    await vault.transaction(
      (tx) => tx.putConversationSync(
        _c1,
        sync.copyWith(
          firstSawGeneration: 2,
          firstSawGenerationAtMicros: firstSaw.microsecondsSinceEpoch,
        ),
      ),
    );
  }

  /// The thread-clock timers armed and not cancelled: the only timers of the
  /// harness that wait for the end of the wait without a welcome.
  List<RigScheduled> clocks() => [
    for (final e in h.scheduled)
      if (!e.cancelled && e.delay >= const Duration(hours: 1)) e,
  ];

  group('the thread clock', () {
    test('an open thread re-emits with canReset when the wait ends', () async {
      await waiting();
      final seen = <EncryptedThread>[];
      final sub = port.watchThread(_ref).listen(seen.add);
      await _until(() => seen.isNotEmpty && clocks().isNotEmpty);
      expect(seen.last.security.canReset, isFalse);
      expect(clocks(), hasLength(1));
      expect(clocks().single.delay, kResetWaitWithoutWelcome);

      h.rig.clock.value = firstSaw.add(kResetWaitWithoutWelcome);
      final due = clocks().single;
      h.scheduled.remove(due);
      due.run();
      await _until(() => seen.last.security.canReset);
      expect(seen.last.security.canReset, isTrue);
      // The offer is the last change: nothing more is armed.
      await h.settle();
      expect(clocks(), isEmpty);
      await sub.cancel();
    });

    test('no timer without a listener', () async {
      await waiting();
      await h.settle();
      expect(clocks(), isEmpty);
      // One read of the thread is not watching it either.
      final first = await port.watchThread(_ref).first;
      expect(first.security.canReset, isFalse);
      await h.settle();
      expect(clocks().where((e) => !e.cancelled), isEmpty);
    });

    test('a second listener does not arm a second timer', () async {
      await waiting();
      final a = port.watchThread(_ref).listen((_) {});
      final b = port.watchThread(_ref).listen((_) {});
      await _until(() => clocks().isNotEmpty);
      await h.settle();
      expect(clocks(), hasLength(1));
      await a.cancel();
      expect(clocks(), hasLength(1), reason: 'one listener is left');
      await b.cancel();
      await h.settle();
      expect(clocks(), isEmpty);
    });

    test('the timer is cancelled when the last listener leaves, at pause '
        'and at session end', () async {
      await waiting();
      // The last listener leaving.
      var sub = port.watchThread(_ref).listen((_) {});
      await _until(() => clocks().isNotEmpty);
      final first = clocks().single;
      await sub.cancel();
      expect(first.cancelled, isTrue);

      // Pause.
      sub = port.watchThread(_ref).listen((_) {});
      await _until(() => clocks().isNotEmpty);
      final second = clocks().single;
      h.pipeline.onAppPaused();
      expect(second.cancelled, isTrue);
      expect(clocks(), isEmpty);
      await sub.cancel();
      h.pipeline.onAppResumed();
      await h.settle();

      // Session end: the vault is lost.
      final done = Completer<void>();
      sub = port.watchThread(_ref).listen((_) {}, onDone: done.complete);
      await _until(() => clocks().isNotEmpty);
      final third = clocks().single;
      h.rig.device.owner!.steal();
      await pumpEventQueue();
      await done.future.timeout(const Duration(seconds: 5));
      expect(third.cancelled, isTrue);
      expect(clocks(), isEmpty);
    });

    test('resume reschedules, for what is left of the wait', () async {
      await waiting();
      final sub = port.watchThread(_ref).listen((_) {});
      await _until(() => clocks().isNotEmpty);
      h.pipeline.onAppPaused();
      expect(clocks(), isEmpty);

      h.rig.clock.advance(const Duration(hours: 5));
      h.pipeline.onAppResumed();
      await _until(() => clocks().isNotEmpty);
      await h.settle();
      expect(clocks(), hasLength(1));
      expect(
        clocks().single.delay,
        kResetWaitWithoutWelcome - const Duration(hours: 5),
      );
      await sub.cancel();
    });

    test('a wait that ended while paused is offered at resume', () async {
      await waiting();
      final seen = <EncryptedThread>[];
      final sub = port.watchThread(_ref).listen(seen.add);
      await _until(() => seen.isNotEmpty && clocks().isNotEmpty);
      h.pipeline.onAppPaused();
      h.rig.clock.value = firstSaw.add(kResetWaitWithoutWelcome);
      expect(seen.last.security.canReset, isFalse);
      h.scheduled.clear();
      h.pipeline.onAppResumed();
      await h.settle();
      // The moment is past: the re-armed timer is due at once.
      expect(
        h.scheduled.where((e) => !e.cancelled && e.delay == Duration.zero),
        isNotEmpty,
      );
      await h.runTimers();
      await _until(() => seen.last.security.canReset);
      await sub.cancel();
    });

    test('describeState names every clock moment: the reset wait and the '
        'deferral limit, the earliest first, none once passed', () async {
      await waiting();
      var s = await h.pipeline.crypto.describeState(_c1);
      expect(s.clockChangeAt, firstSaw.add(kResetWaitWithoutWelcome));

      // A deferred list while a member is unattributed: unverifiable after
      // the limit (strictly), which is sooner than the reset wait.
      final vault = h.rig.device.vault;
      final ghost = await RigPeer.create('ghost');
      await vault.transaction(
        (tx) => tx.putMember(
          MemberRecord(
            conversationId: _c1,
            deviceId: ghost.id,
            signatureKey: ghost.key,
            side: MemberSide.unattributed,
            since: const MlsPair(1, 1),
          ),
        ),
      );
      final since = h.rig.clock.now();
      h.pipeline.contexts.of(_c1).deferredSince = since;
      s = await h.pipeline.crypto.describeState(_c1);
      expect(s.deviceListUnverifiable, isFalse);
      expect(
        s.clockChangeAt,
        since
            .add(kDeferredWithUnattributedLimit)
            .add(const Duration(microseconds: 1)),
      );

      h.rig.clock.advance(
        kDeferredWithUnattributedLimit + const Duration(microseconds: 1),
      );
      s = await h.pipeline.crypto.describeState(_c1);
      expect(s.deviceListUnverifiable, isTrue);
      expect(s.clockChangeAt, firstSaw.add(kResetWaitWithoutWelcome));

      h.rig.clock.value = firstSaw.add(kResetWaitWithoutWelcome);
      s = await h.pipeline.crypto.describeState(_c1);
      expect(s.canReset, isTrue);
      expect(s.clockChangeAt, isNull);
    });

    test('with no ready vault nothing is armed', () async {
      // No start: the pipeline holds no parts (the flag-off shape).
      final sub = port.watchThread(_ref).listen((_) {});
      await h.settle();
      expect(h.scheduled, isEmpty);
      await sub.cancel();
    });
  });
}
