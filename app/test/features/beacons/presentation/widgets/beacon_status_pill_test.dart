import 'package:dzeroth/features/beacons/presentation/widgets/beacon_status_pill.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_status_pill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/theme_harness.dart';

void main() {
  test('only Ended is the danger tone; Full stays info', () {
    expect(
      beaconStatusTone(pb.BeaconStatus.BEACON_STATUS_ENDED),
      AppStatusTone.danger,
    );
    expect(
      beaconStatusTone(pb.BeaconStatus.BEACON_STATUS_FULL),
      AppStatusTone.info,
    );
    expect(
      beaconStatusTone(pb.BeaconStatus.BEACON_STATUS_CANCELLED),
      AppStatusTone.neutral,
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('Ended text uses the theme error colour (${brightness.name})', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const BeaconStatusPill(status: pb.BeaconStatus.BEACON_STATUS_ENDED),
        brightness: brightness,
      );
      final text = tester.widget<Text>(find.text('Ended'));
      final scheme = Theme.of(tester.element(find.byType(BeaconStatusPill)))
          .colorScheme;
      expect(text.style?.color, scheme.error);
    });
  }
}
