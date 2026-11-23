import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../support/device_keys_rig.dart';

// Plan 5a Task 12 (R17, R12) with lane D PR 2: the removal reasons, a
// device removed elsewhere (the server's DEVICE_REMOVED answer), and
// setting the device up again.

const _a = 'user-a';

void main() {
  late DeviceKeysRig rig;

  setUp(() {
    rig = DeviceKeysRig()..launch();
  });

  group('removal reasons (design section 4)', () {
    test('sign-out removal sends SIGN_OUT', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      await rig.signOut();

      final removal = rig.server.removals.single;
      expect(removal.deviceId, id);
      expect(removal.reason, pb.RemoveReason.REMOVE_REASON_SIGN_OUT);
      expect(rig.server.removedMarks, isEmpty);
    });

    test('a failed sign-out re-registers the same id (no mark)', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      await rig.session.beforeExplicitSignOut(_a);
      expect(rig.devices, isEmpty);

      await rig.session.explicitSignOutFailed(_a);
      await rig.service.onSignOutFailed(_a);

      expect(
        rig.server.removals.single.reason,
        pb.RemoveReason.REMOVE_REASON_SIGN_OUT,
      );
      expect(rig.server.removedMarks, isEmpty);
      expect(rig.storedId(), id);
      expect(rig.devices.keys, [id]);
      expect(rig.server.registrations.last.deviceId, id);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });
  });
}
