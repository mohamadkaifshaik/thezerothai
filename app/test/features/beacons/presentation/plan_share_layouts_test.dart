import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/share/share_links.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_share.dart';
import 'package:dzeroth/shared/widgets/post/post_share_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/plans_tablet_rig.dart';

// The plan's Share entry through the real shell (phone, tablet with the list
// pane, desktop): the same button and the same options at every width.
const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

void main() {
  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('$name, ${brightness.name}: Share opens the same options', (
        tester,
      ) async {
        final rig = PlansTabletRig();
        rig.server.public[0] = beaconView(
          startAt: DateTime.now().add(const Duration(hours: 2)),
          id: kBeaconIdA,
          title: 'Flat white before work',
          canManage: true,
        );
        await rig.pump(
          tester,
          location: AppRouter.planPath(kBeaconIdA),
          width: size.width,
          height: size.height,
          brightness: brightness,
          flags: {...kPlansTabletFlags, kFeaturePostBeaconEmbed},
          shareLinks: const ShareLinks(origin: 'https://dzeroth.com'),
        );

        await tester.tap(find.byTooltip(kSharePlanTitle));
        await tester.pumpAndSettle();

        expect(find.text(kPostAboutPlanLabel), findsOneWidget);
        expect(find.text('Copy link'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('no ShareLinks: no entry through the shell', (tester) async {
    final rig = PlansTabletRig();
    await rig.pump(tester, location: AppRouter.planPath(kBeaconIdA));
    expect(find.byTooltip(kSharePlanTitle), findsNothing);
  });
}
