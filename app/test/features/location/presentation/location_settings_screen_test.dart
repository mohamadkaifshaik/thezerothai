import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/location/domain/location_copy.dart';
import 'package:dzeroth/features/location/domain/location_feature_flag.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_location_repository.dart';
import '../../../support/settings_tablet_rig.dart';

const _phone = 390.0;

final _flagsOn = {...kSettingsRowFlags, kFeatureLocation};

final _agreed = DateTime.now();

LocationSettingsData _stored({bool consent = true}) => LocationSettingsData(
  area: fakeAreaOne,
  consent: ConsentInfo(granted: consent, copyVersion: 1, at: _agreed),
);

void main() {
  late SettingsTabletRig rig;
  setUp(() => rig = SettingsTabletRig());

  Future<void> open(
    WidgetTester tester,
    FakeLocationRepository repo, {
    Set<String>? flags,
    String location = AppRouter.locationSettingsPath,
    double width = _phone,
  }) => rig.pump(
    tester,
    location: location,
    width: width,
    height: 1100,
    flags: flags ?? _flagsOn,
    locationRepo: repo,
  );

  group('flag on, no area', () {
    testWidgets('explainer and Choose your area; no clear', (tester) async {
      await open(tester, FakeLocationRepository());
      expect(find.text(kLocationExplainer), findsOneWidget);
      expect(find.text(kLocationChooseArea), findsOneWidget);
      expect(find.text(kLocationClearArea), findsNothing);
    });

    testWidgets('no consent: rationale first, Continue needs the tick, then '
        'the picker, then SetArea with the consent', (tester) async {
      final repo = FakeLocationRepository();
      await open(tester, repo);
      await tester.tap(find.text(kLocationChooseArea));
      await tester.pumpAndSettle();
      expect(find.text(kLocationRationaleTitle), findsWidgets);
      expect(
        find.text('Notice version $kLocationConsentCopyVersion'),
        findsOne,
      );

      FilledButton continueButton() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, kLocationContinue),
      );
      expect(continueButton().onPressed, isNull);
      await tester.tap(find.text(kLocationAdultTick));
      await tester.pump();
      expect(continueButton().onPressed, isNotNull);
      await tester.tap(find.text(kLocationContinue));
      await tester.pumpAndSettle();

      expect(find.text(kLocationSearchHint), findsOneWidget);
      await tester.tap(find.text(fakeAreaTwo.name));
      await tester.pumpAndSettle();

      expect(repo.calls, contains('set:${fakeAreaTwo.id}'));
      expect(repo.lastConsent?.adultConfirmed, isTrue);
      expect(repo.lastConsent?.copyVersion, kLocationConsentCopyVersion);
      expect(find.text(fakeAreaTwo.label), findsOneWidget);
      expect(find.text(kLocationClearArea), findsOneWidget);
    });

    testWidgets('a stored consent skips the rationale', (tester) async {
      final repo = FakeLocationRepository(
        settings: const LocationSettingsData(
          consent: ConsentInfo(granted: true, copyVersion: 1),
        ),
      );
      await open(tester, repo);
      await tester.tap(find.text(kLocationChooseArea));
      await tester.pumpAndSettle();
      expect(find.text(kLocationAdultTick), findsNothing);
      await tester.tap(find.text(locationAllOf(fakeCityBlr.name)));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('set:${fakeCityBlr.id}'));
      expect(repo.lastConsent, isNull);
    });

    testWidgets('consent_required from the server runs the rationale again', (
      tester,
    ) async {
      final repo = FakeLocationRepository(
        settings: const LocationSettingsData(
          consent: ConsentInfo(granted: true, copyVersion: 1),
        ),
      )..setError = const StateConflictException('consent_required');
      await open(tester, repo);
      await tester.tap(find.text(kLocationChooseArea));
      await tester.pumpAndSettle();
      await tester.tap(find.text(fakeAreaOne.name));
      await tester.pumpAndSettle();
      expect(find.text(kLocationAdultTick), findsOneWidget);
      repo.setError = null;
      await tester.tap(find.text(kLocationAdultTick));
      await tester.pump();
      await tester.tap(find.text(kLocationContinue));
      await tester.pumpAndSettle();
      expect(repo.lastConsent?.adultConfirmed, isTrue);
      expect(find.text(kLocationClearArea), findsOneWidget);
    });
  });

  group('picker', () {
    testWidgets('search filters, groups by city, and shows the empty state', (
      tester,
    ) async {
      final repo = FakeLocationRepository(
        settings: const LocationSettingsData(
          consent: ConsentInfo(granted: true, copyVersion: 1),
        ),
      );
      await open(tester, repo);
      await tester.tap(find.text(kLocationChooseArea));
      await tester.pumpAndSettle();

      expect(find.text(fakeAreaOne.name), findsOneWidget);
      expect(find.text(fakeOtherArea.name), findsOneWidget);
      expect(find.text(locationAllOf('Testville')), findsOneWidget);
      expect(find.text(locationAllOf('Otherton')), findsOneWidget);

      await tester.enterText(find.byType(TextField), "gam'ma");
      await tester.pumpAndSettle();
      expect(
        find.text(fakeOtherArea.name),
        findsOneWidget,
        reason: 'apostrophe',
      );

      await tester.enterText(find.byType(TextField), 'GAMMA!');
      await tester.pumpAndSettle();
      expect(find.text(fakeOtherArea.name), findsOneWidget);
      expect(find.text(fakeAreaOne.name), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text(kLocationPickerEmptyTitle), findsOneWidget);
      // Retired areas never show.
      await tester.enterText(find.byType(TextField), 'retired');
      await tester.pumpAndSettle();
      expect(find.text(kLocationPickerEmptyTitle), findsOneWidget);
    });
  });

  group('clear', () {
    testWidgets('one tap clears with the snackbar, no dialog', (tester) async {
      final repo = FakeLocationRepository(settings: _stored());
      await open(tester, repo);
      expect(find.text(fakeAreaOne.label), findsOneWidget);
      expect(
        find.textContaining('You agreed on ${_agreed.day} '),
        findsOneWidget,
      );
      await tester.tap(find.text(kLocationClearArea));
      await tester.pump();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(kLocationCleared), findsOneWidget);
      expect(repo.calls, ['get', 'clear']);
      await tester.pumpAndSettle();
      expect(find.text(kLocationChooseArea), findsOneWidget);
    });

    testWidgets('a failed clear keeps the area and says why', (tester) async {
      final repo = FakeLocationRepository(settings: _stored())
        ..clearError = const NetworkException('down');
      await open(tester, repo);
      await tester.tap(find.text(kLocationClearArea));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining("Couldn't reach Dzeroth"), findsOneWidget);
      expect(find.text(fakeAreaOne.label), findsOneWidget);
    });
  });

  group('flag off', () {
    testWidgets('area stored: only the clear action, no picker entry', (
      tester,
    ) async {
      final repo = FakeLocationRepository(settings: _stored());
      await open(tester, repo, flags: kSettingsRowFlags);
      expect(find.text(kLocationOffStoredNote), findsOneWidget);
      expect(find.text(kLocationClearArea), findsOneWidget);
      expect(find.text(kLocationChangeArea), findsNothing);
      expect(find.text(kLocationChooseArea), findsNothing);
      await tester.tap(find.text(kLocationClearArea));
      await tester.pumpAndSettle();
      expect(repo.calls, ['get', 'clear']);
      expect(find.text(kLocationOffTitle), findsOneWidget);
    });

    testWidgets('no area: nothing to show', (tester) async {
      await open(tester, FakeLocationRepository(), flags: kSettingsRowFlags);
      expect(find.text(kLocationOffTitle), findsOneWidget);
      expect(find.text(kLocationClearArea), findsNothing);
      expect(find.text(kLocationChooseArea), findsNothing);
    });
  });

  group('Settings row', () {
    testWidgets('flag on: shows with the area, opens the page', (tester) async {
      final repo = FakeLocationRepository(settings: _stored());
      await open(tester, repo, location: AppRouter.settingsPath);
      expect(find.text(kLocationSettingsTitle), findsOneWidget);
      expect(find.text(fakeAreaOne.label), findsOneWidget);
      await tester.tap(find.text(kLocationSettingsTitle));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.locationSettingsPath);
    });

    testWidgets('flag on, no area: row says Not set', (tester) async {
      await open(
        tester,
        FakeLocationRepository(),
        location: AppRouter.settingsPath,
      );
      expect(find.text(kLocationSettingsTitle), findsOneWidget);
      expect(find.text(kLocationNotSet), findsOneWidget);
    });

    testWidgets('flag off: row only while an area is stored', (tester) async {
      await open(
        tester,
        FakeLocationRepository(settings: _stored()),
        flags: kSettingsRowFlags,
        location: AppRouter.settingsPath,
      );
      expect(find.text(kLocationSettingsTitle), findsOneWidget);
      await open(
        tester,
        FakeLocationRepository(),
        flags: kSettingsRowFlags,
        location: AppRouter.settingsPath,
      );
      expect(find.text(kLocationSettingsTitle), findsNothing);
    });

    testWidgets('no repository in the tree: no row', (tester) async {
      await rig.pump(
        tester,
        location: AppRouter.settingsPath,
        width: _phone,
        height: 1100,
        flags: _flagsOn,
      );
      expect(find.text(kLocationSettingsTitle), findsNothing);
    });
  });

  group('Explore settings (F8)', () {
    testWidgets('one Nearby group, one Your area row, opens Location', (
      tester,
    ) async {
      await open(
        tester,
        FakeLocationRepository(settings: _stored()),
        location: AppRouter.exploreSettingsPath,
      );
      expect(find.text(kExploreSettingsAreaRow), findsOneWidget);
      expect(find.text(fakeAreaOne.label), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
      await tester.tap(find.text(kExploreSettingsAreaRow));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.locationSettingsPath);
    });

    testWidgets('Not set without an area', (tester) async {
      await open(
        tester,
        FakeLocationRepository(),
        location: AppRouter.exploreSettingsPath,
      );
      expect(find.text(kLocationNotSet), findsOneWidget);
    });
  });
}
