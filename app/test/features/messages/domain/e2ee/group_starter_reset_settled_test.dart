import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_reset_harness.dart';

// Plan 5a Task 13, gate item 20 (Task 11 follow-up SA L6): the starter
// tells the pipeline when it settled this device's own reset, so a removal
// queued while the reset was provisional gets a removal pass then. The
// pipeline's wiring of the hook is tested in e2ee_pipeline_test.dart.

const _c1 = '11111111111111111111111111111111';

void main() {
  registerResetHarness();

  test('item 20: onResetSettled fires once when the server stored the '
      "device's own reset", () async {
    await setUpJoined();
    await makeStuck();
    final settled = <String>[];
    starter.onResetSettled = settled.add;

    await reset();

    expect((await groupAt(2))!.provisional, isFalse);
    expect(settled, [_c1]);
  });

  test('item 20: a reset whose outcome is unknown does not fire it', () async {
    await setUpJoined();
    await makeStuck();
    final settled = <String>[];
    starter.onResetSettled = settled.add;
    rig.server.commitScript
      ..add(unknown)
      ..add(unknown);

    await reset();

    expect((await groupAt(2))!.provisional, isTrue);
    expect(settled, isEmpty);
  });
}
