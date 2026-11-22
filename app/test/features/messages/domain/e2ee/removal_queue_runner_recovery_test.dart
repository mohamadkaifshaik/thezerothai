import 'package:dzeroth/core/network/app_exception.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/removal_queue_harness.dart';

// The removal queue's fix-round tests (Task 11 review): the hooks under a
// held lock, the intent record, the own-list refresh, the durable
// "removed by the user" record, the pending record and a stored hold. The
// first file is removal_queue_runner_test.dart.

const _c1 = '11111111111111111111111111111111';

void main() {
  tearDown(removalQueueTearDown);

  group('the hooks (review I3)', () {
    test('noteConversation and onAccepted return at once inside a held '
        'conversation lock', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      rig.server.commitScript.add((
        error: const CannotMessageException(),
        stored: false,
      ));
      await removeAndSettle(sibling);
      expect((await stored())!.entries.single.parked, isTrue);
      rig.contexts.note(headerRow(_c1));

      await rig.locks.run(_c1, () async {
        await runner.noteConversation(_c1).timeout(const Duration(seconds: 5));
        await runner.onAccepted(_c1).timeout(const Duration(seconds: 5));
      });
      await runner.idle();

      expect(await pin(sibling), isNull);
      expect(runner.pending.value, 0);
    });
  });
}
