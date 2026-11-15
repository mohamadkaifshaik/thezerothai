import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/settings/domain/data_usage.dart';
import 'package:dzeroth/features/settings/domain/settings_categories.dart';
import 'package:dzeroth/features/settings/presentation/bloc/data_usage_cubit.dart';
import 'package:dzeroth/features/settings/presentation/data_usage_messages.dart';
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_network_type_service.dart';
import '../../../support/settings_tablet_rig.dart';

/// Settings > Data usage on the three devices: one page model (three rows),
/// opened from Display (tablet / desktop) or the App group (phone).

class _Store implements DataUsageStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

DataUsageCubit _cubit({
  FakeNetworkTypeService? network,
  _Store? store,
  bool load = true,
}) {
  final cubit = DataUsageCubit(
    store ?? _Store(),
    network ?? FakeNetworkTypeService(),
  );
  addTearDown(cubit.close);
  if (load) cubit.load();
  return cubit;
}

Finder _switch() => find.descendant(
  of: find.widgetWithText(SettingsRow, kDataSaverTitle),
  matching: find.byType(Switch),
);

void main() {
  test('Data usage belongs to the Display category', () {
    expect(
      settingsCategoryOfLeaf(AppRouter.dataUsagePath),
      SettingsCategory.display,
    );
  });

  testWidgets('no cubit, no row (a harness without it)', (tester) async {
    final rig = SettingsTabletRig();
    await rig.pump(tester, width: 390, height: 2600);
    expect(find.text(kDataUsageTitle), findsNothing);
  });

  group('phone (390dp)', () {
    testWidgets('the App group opens the page; three rows, saved choices', (
      tester,
    ) async {
      final cubit = _cubit();
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 390, height: 2600, dataUsage: cubit);
      await tester.tap(find.widgetWithText(SettingsRow, kDataUsageTitle));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.dataUsagePath);

      expect(settingsRowTitles(tester, find.byType(ListView)), [
        kDataSaverTitle,
        kHighQualityImagesTitle,
        kHighQualityUploadsTitle,
      ]);

      await tester.tap(_switch());
      await tester.pumpAndSettle();
      expect(cubit.state.dataSaver, isTrue);

      await tester.tap(find.text('Never'));
      await tester.pumpAndSettle();
      expect(cubit.state.images, HighQualityImages.never);

      // Two "Wi-Fi only" choices (images, uploads): the uploads one is last.
      await tester.tap(find.text('Wi-Fi only').last);
      await tester.pumpAndSettle();
      expect(cubit.state.uploads, HighQualityUploads.wifiOnly);
      expect(cubit.state.images, HighQualityImages.never);
    });

    testWidgets('data saver says why High-quality images does not apply', (
      tester,
    ) async {
      final cubit = _cubit(load: false);
      await cubit.load();
      await cubit.setDataSaver(true);
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.dataUsagePath,
        width: 390,
        height: 2600,
        dataUsage: cubit,
      );
      expect(find.text(kHighQualityImagesOffByDataSaver), findsOneWidget);
    });
  });

  group('the web note', () {
    testWidgets('shown where the connection type is unknown', (tester) async {
      final cubit = _cubit(
        network: FakeNetworkTypeService(canDistinguish: false),
      );
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.dataUsagePath,
        width: 390,
        height: 2600,
        dataUsage: cubit,
      );
      expect(find.text(kDataUsageWebNote), findsOneWidget);
      expect(
        kDataUsageWebNote,
        "On the web we can't always tell Wi-Fi from mobile data.",
      );
    });

    testWidgets('not shown where Wi-Fi and mobile data are told apart', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.dataUsagePath,
        width: 390,
        height: 2600,
        dataUsage: _cubit(),
      );
      expect(find.text(kDataUsageWebNote), findsNothing);
    });
  });

  group('tablet (800dp) and desktop (1440dp)', () {
    for (final (name, width) in [('tablet', 800.0), ('desktop', 1440.0)]) {
      testWidgets('$name: Display lists Data usage and the same three rows '
          'open on its page', (tester) async {
        final cubit = _cubit();
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          location: settingsCategoryLocation(SettingsCategory.display),
          width: width,
          dataUsage: cubit,
        );
        expect(
          settingsRowTitles(tester, find.byType(Scaffold).last),
          contains(kDataUsageTitle),
        );
        await tester.tap(find.widgetWithText(SettingsRow, kDataUsageTitle));
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.dataUsagePath);
        expect(find.text(kDataSaverTitle), findsOneWidget);
        expect(find.text(kHighQualityImagesTitle), findsOneWidget);
        expect(find.text(kHighQualityUploadsTitle), findsOneWidget);
        expect(
          find.text('Mobile data & Wi-Fi'),
          findsNWidgets(4),
        ); // the current line and the pill, twice
        expect(find.text('Never'), findsOneWidget);
      });
    }
  });
}
