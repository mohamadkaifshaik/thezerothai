import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/domain/plan_quick_start.dart';
import 'package:dzeroth/features/beacons/presentation/create_beacon_screen.dart';
import 'package:dzeroth/features/location/data/location_repository.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/fake_location_repository.dart';
import '../../../support/fake_plan_form_store.dart';

const _consent = ConsentInfo(granted: true, copyVersion: 2);

/// The create form's "Use my area", remembered choices across restarts and
/// title suggestions.
void main() {
  late FakeBeaconsServer server;
  final today = DateTime.now();
  final now = DateTime(today.year, today.month, today.day, 12, 0);

  setUp(() => server = FakeBeaconsServer());

  Future<void> open(
    WidgetTester tester, {
    LocationRepository? location,
    PlanFormMemory? memory,
    Set<String> features = const {'beacons', 'location'},
  }) async {
    await pumpPlansRouter(
      tester,
      beacons: server,
      features: features,
      location: location,
      initialLocation: '/plans/new',
      routes: [
        GoRoute(path: '/plans', builder: (_, _) => stubPage('plans')),
        GoRoute(
          path: '/plans/new',
          builder: (_, _) => CreateBeaconScreen(now: () => now, memory: memory),
        ),
        GoRoute(
          path: '/plans/:id',
          builder: (_, s) => stubPage('plan ${s.pathParameters['id']}'),
        ),
      ],
    );
  }

  final useMine = find.byKey(const ValueKey('plan-area-use-mine'));

  group('Use my area', () {
    testWidgets('fills the saved area and Post plan sends its id', (
      tester,
    ) async {
      await open(
        tester,
        location: FakeLocationRepository(
          settings: const LocationSettingsData(
            area: fakeAreaOne,
            consent: _consent,
          ),
        ),
      );
      expect(useMine, findsOneWidget);
      await tester.tap(useMine);
      await tester.pump();
      expect(find.text('Alpha Nagar, Testville'), findsOneWidget);
      expect(useMine, findsNothing);
      await tester.enterText(find.byKey(const ValueKey('field-Title')), 'Tea');
      await tester.enterText(
        find.byKey(const ValueKey('field-Meeting point')),
        'Gate 2',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Post plan'));
      await tester.pumpAndSettle();
      expect(server.lastCreate!.areaId, fakeAreaOne.id);
    });

    testWidgets('is hidden without a valid consent', (tester) async {
      await open(
        tester,
        location: FakeLocationRepository(
          settings: const LocationSettingsData(
            area: fakeAreaOne,
            consent: ConsentInfo(granted: false, copyVersion: 2),
          ),
        ),
      );
      expect(useMine, findsNothing);
      expect(find.byKey(const ValueKey('plan-area-field')), findsOneWidget);
    });

    testWidgets('is hidden without a saved area', (tester) async {
      await open(
        tester,
        location: FakeLocationRepository(
          settings: const LocationSettingsData(consent: _consent),
        ),
      );
      expect(useMine, findsNothing);
    });

    testWidgets('is hidden when the read fails', (tester) async {
      await open(
        tester,
        location: FakeLocationRepository()
          ..loadError = const NetworkException('offline'),
      );
      expect(useMine, findsNothing);
    });

    testWidgets('is hidden with location off, and with no repository', (
      tester,
    ) async {
      await open(
        tester,
        features: const {'beacons'},
        location: FakeLocationRepository(
          settings: const LocationSettingsData(
            area: fakeAreaOne,
            consent: _consent,
          ),
        ),
      );
      expect(useMine, findsNothing);
      expect(find.byKey(const ValueKey('plan-area-field')), findsNothing);
    });
  });

  group('remembered choices across restarts', () {
    testWidgets('the saved choices are the next form defaults', (tester) async {
      final store = FakePlanFormStore(
        '{"v":1,"duration":90,"spots":5,"cost":3,"chat":3,"community":null}',
      );
      final memory = PlanFormMemory(store: store);
      await open(tester, memory: memory);
      expect(find.text('90 min · 5 spots · Split evenly'), findsOneWidget);
    });

    testWidgets('posting saves the choices, not the title', (tester) async {
      final store = FakePlanFormStore(null);
      final memory = PlanFormMemory(store: store);
      await open(tester, memory: memory);
      await tester.enterText(find.byKey(const ValueKey('field-Title')), 'Tea');
      await tester.enterText(
        find.byKey(const ValueKey('field-Meeting point')),
        'Gate 2',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Post plan'));
      await tester.pumpAndSettle();
      expect(store.writes, hasLength(1));
      expect(store.writes.single, isNot(contains('Tea')));
      expect(store.writes.single, contains('"v":1'));
    });
  });

  group('title suggestions', () {
    testWidgets('a chip fills an empty title and then goes away', (
      tester,
    ) async {
      await open(tester);
      final chip = find.byKey(
        const ValueKey('title-suggestion-Coffee and a chat'),
      );
      expect(chip, findsOneWidget);
      await tester.tap(chip);
      await tester.pump();
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('field-Title')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.controller.text, 'Coffee and a chat');
      expect(chip, findsNothing);
    });

    testWidgets('follow the activity', (tester) async {
      await open(tester);
      final walk = find.widgetWithText(ChoiceChip, 'Walk');
      await tester.ensureVisible(walk);
      await tester.pumpAndSettle();
      await tester.tap(walk);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('title-suggestion-Evening walk')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('title-suggestion-Coffee and a chat')),
        findsNothing,
      );
    });
  });
}
