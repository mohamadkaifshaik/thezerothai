import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/removal_queue_harness.dart';

// Plan 5a Task 12 with lane D PR 2 (removal design section 4, "Task 11
// queue"): the queue's RemoveKeyDevice is a removal of ANOTHER device, sent
// with REMOVE_REASON_REMOTE.

const _c1 = '11111111111111111111111111111111';

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
  });
}
