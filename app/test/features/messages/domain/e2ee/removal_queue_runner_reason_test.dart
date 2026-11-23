import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/removal_queue_harness.dart';

// Plan 5a Task 12 with lane D PR 2 (removal design section 4, "Task 11
// queue"): the queue's RemoveKeyDevice is a removal of ANOTHER device, sent
// with REMOVE_REASON_REMOTE; a first call answered REAUTH_REQUIRED parks
// its intent and asks the UI for a re-sign-in (brief amendment 3).

const _c1 = '11111111111111111111111111111111';

/// The runner's stored record (opened); null when absent.
Future<RemovalRecord?> storedRecord() async {
  final raw = await rig.device.vault.setting(kVaultSettingRemovalRecord);
  return raw == null ? null : RemovalRecord.decode(raw);
}

void main() {
  tearDown(removalQueueTearDown);

  test('the queue sends REMOTE', () async {
    final sibling = await RigPeer.create('sibling');
    await setUpRig(ownListed: [sibling]);
    await join(_c1, others: [sibling]);
    await synced();

    await removeAndSettle(sibling);

    final call = rig.keys.removeCalls.single;
    expect(call.deviceId, sibling.idString);
    expect(call.reason, kpb.RemoveReason.REMOVE_REASON_REMOTE);
    expect(await pin(sibling), isNull);
    expect(runner.needsReauth.value, isFalse);
  });

  group('REAUTH_REQUIRED (brief amendment 3)', () {
    test('a new removal answered REAUTH_REQUIRED parks its intent, never '
        'drops it, and asks for a re-sign-in; after it the same call '
        'finishes', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      rig.keys.removeError = const ReauthRequiredException('rig: sign in');

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<ReauthRequiredException>()),
      );
      await runner.idle();

      expect(runner.needsReauth.value, isTrue);
      // Parked, not dropped: the stored intent still answers.
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      expect((await storedRecord())!.intents.map((i) => i.deviceId), [
        sibling.idString,
      ]);
      expect(requests(), isEmpty);

      // A pass does not send it again while it waits for the sign-in.
      await runner.runPass();
      await runner.idle();
      expect(rig.keys.removeCalls, hasLength(1));

      // The user signed in again and confirms: the call goes, and queues.
      rig.keys.removeError = null;
      await removeAndSettle(sibling);

      expect(rig.keys.removeCalls, hasLength(2));
      expect(
        rig.keys.removeCalls.last.reason,
        kpb.RemoveReason.REMOVE_REASON_REMOTE,
      );
      expect(runner.needsReauth.value, isFalse);
      expect(await pin(sibling), isNull);
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    });

    test("a stored intent's retry answered REAUTH_REQUIRED keeps the "
        'intent and asks for a re-sign-in', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      // The first call's outcome is unknown: an intent is left.
      rig.keys.removeError = const NetworkException('rig: offline');
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );
      await runner.idle();

      rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      await runner.runPass();
      await runner.idle();

      expect(rig.keys.removeCalls, hasLength(2));
      expect(runner.needsReauth.value, isTrue);
      expect((await storedRecord())!.intents.map((i) => i.deviceId), [
        sibling.idString,
      ]);
      // The own list still names it, but a REAUTH answer settles nothing.
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);

      await runner.runPass();
      await runner.idle();
      expect(rig.keys.removeCalls, hasLength(2));

      // A reset (sign-out) forgets the ask; the intent stays stored.
      runner.reset();
      expect(runner.needsReauth.value, isFalse);
    });
  });
}
