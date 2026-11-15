import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/location/domain/location_copy.dart';
import 'package:dzeroth/features/location/domain/location_feature_flag.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:dzeroth/features/settings/domain/settings_categories.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_location_repository.dart';
import '../../../support/settings_tablet_rig.dart';

/// The same page, rows and actions on phone, tablet (band A and B) and
/// desktop, in light and dark.
void main() {
  final layouts = <String, (double, Set<String>)>{
    'phone': (390, {...kSettingsRowFlags, kFeatureLocation}),
    'tablet band A': (700, {...kSettingsTabletFlags, kFeatureLocation}),
    'tablet band B': (1000, {...kSettingsTabletFlags, kFeatureLocation}),
    'desktop': (1400, {...kSettingsTabletFlags, kFeatureLocation}),
  };

  for (final MapEntry(key: name, value: (width, flags)) in layouts.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('$name ${brightness.name}: area set, same rows and clear', (
        tester,
      ) async {
        final rig = SettingsTabletRig();
        final repo = FakeLocationRepository(
          settings: LocationSettingsData(
            area: fakeAreaOne,
            consent: ConsentInfo(
              granted: true,
              copyVersion: 1,
              at: DateTime.now(),
            ),
          ),
        );
        await rig.pump(
          tester,
          location: AppRouter.locationSettingsPath,
          width: width,
          height: 900,
          flags: flags,
          brightness: brightness,
          locationRepo: repo,
        );
        expect(tester.takeException(), isNull);
        expect(find.text(fakeAreaOne.label), findsOneWidget);
        expect(find.text(kLocationChangeArea), findsOneWidget);
        expect(find.text(kLocationClearArea), findsOneWidget);
        await tester.tap(find.text(kLocationClearArea));
        await tester.pumpAndSettle();
        expect(repo.calls, contains('clear'));
        expect(find.text(kLocationChooseArea), findsOneWidget);
      });
    }
  }

  testWidgets('tablet: Privacy & safety category lists the Location row', (
    tester,
  ) async {
    final rig = SettingsTabletRig();
    await rig.pump(
      tester,
      location: settingsCategoryLocation(SettingsCategory.privacy),
      width: 700,
      height: 900,
      flags: {...kSettingsTabletFlags, kFeatureLocation},
      locationRepo: FakeLocationRepository(),
    );
    expect(find.text(kLocationSettingsTitle), findsOneWidget);
    await tester.tap(find.text(kLocationSettingsTitle));
    await tester.pumpAndSettle();
    expect(rig.uri.path, AppRouter.locationSettingsPath);
    expect(find.text(kLocationChooseArea), findsOneWidget);
  });

  testWidgets('leaf paths belong to Privacy & safety', (tester) async {
    expect(
      settingsCategoryOfLeaf(AppRouter.locationSettingsPath),
      SettingsCategory.privacy,
    );
    expect(
      settingsCategoryOfLeaf(AppRouter.locationConsentPath),
      SettingsCategory.privacy,
    );
  });
}
