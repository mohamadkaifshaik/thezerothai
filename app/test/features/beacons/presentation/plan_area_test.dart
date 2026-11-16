import 'package:dzeroth/features/beacons/presentation/create_beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/edit_beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/area_label.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_form_fields.dart';
import 'package:dzeroth/gen/dzeroth/location/v1/location.pb.dart' as loc;
import 'package:dzeroth/gen/dzeroth/location/v1/location.pbenum.dart'
    as locenum;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/fake_location_repository.dart';

loc.AreaSummary _summary() => loc.AreaSummary(
  areaId: 'in.tcity.alpha',
  name: 'Alpha Nagar',
  kind: locenum.AreaKind.AREA_KIND_AREA,
  cityId: 'in.tcity',
  cityName: 'Testville',
);

/// Area labels on plan cards and the plan page, and the "Area (optional)"
/// field of the create and edit forms.
void main() {
  late FakeBeaconsServer server;
  final start = DateTime.now().add(const Duration(hours: 2));
  final today = DateTime.now();
  final now = DateTime(today.year, today.month, today.day, 12, 0);

  setUp(() => server = FakeBeaconsServer());

  group('AreaLabel', () {
    Future<void> pump(
      WidgetTester tester,
      loc.AreaSummary? area,
      Set<String>? features,
    ) async {
      await pumpPlansRouter(
        tester,
        beacons: server,
        features: features,
        initialLocation: '/x',
        routes: [
          GoRoute(
            path: '/x',
            builder: (_, _) => Scaffold(
              body: Column(
                children: [
                  const Text('before'),
                  AreaLabel(area: area),
                  const Text('after'),
                ],
              ),
            ),
          ),
        ],
      );
    }

    testWidgets('shows the icon and the name with location on', (tester) async {
      await pump(tester, _summary(), const {'location'});
      expect(find.text('Alpha Nagar, Testville'), findsOneWidget);
      expect(find.byIcon(Icons.place_outlined), findsOneWidget);
    });

    testWidgets('nothing when the area is unset', (tester) async {
      await pump(tester, null, const {'location'});
      expect(find.byIcon(Icons.place_outlined), findsNothing);
      expect(tester.getSize(find.byType(AreaLabel)), Size.zero);
    });

    testWidgets('nothing when location is off or there is no session', (
      tester,
    ) async {
      await pump(tester, _summary(), const {'beacons'});
      expect(find.byIcon(Icons.place_outlined), findsNothing);
      await pump(tester, _summary(), null);
      expect(find.byIcon(Icons.place_outlined), findsNothing);
    });
  });

  group('create', () {
    Future<GoRouter> open(WidgetTester tester, Set<String> features) =>
        pumpPlansRouter(
          tester,
          beacons: server,
          features: features,
          initialLocation: '/plans/new',
          routes: [
            GoRoute(path: '/plans', builder: (_, _) => stubPage('plans')),
            GoRoute(
              path: '/plans/new',
              builder: (_, _) => CreateBeaconScreen(
                now: () => now,
                pickDate: (
                  context, {
                  required initial,
                  required first,
                  required last,
                }) async => initial,
                pickTime: (context, {required initial}) async => initial,
              ),
            ),
            GoRoute(
              path: '/area-picker',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () => context.pop(fakeAreaOne),
                  child: const Text('pick alpha'),
                ),
              ),
            ),
            GoRoute(
              path: '/plans/:id',
              builder: (_, state) =>
                  stubPage('plan ${state.pathParameters['id']}'),
            ),
          ],
        );

    Finder field(String label) => find.byKey(ValueKey('field-$label'));

    Future<void> tapVisible(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Future<void> fill(WidgetTester tester) async {
      await tester.enterText(field('Title'), 'Coffee at the hall');
      await tester.enterText(field('Meeting point'), 'Food court');
      await tester.pump();
    }

    testWidgets('the field is hidden with location off', (tester) async {
      await open(tester, const {'beacons'});
      expect(find.text(kPlanAreaTitle), findsNothing);
    });

    testWidgets('picking an area sends area_id; the user needs no own area', (
      tester,
    ) async {
      await open(tester, const {'beacons', 'location'});
      await tester.ensureVisible(find.text(kPlanAreaTitle));
      expect(find.text(kPlanAreaHint), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('plan-area-field')));
      await tester.tap(find.text('pick alpha'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha Nagar, Testville'), findsOneWidget);

      await fill(tester);
      await tapVisible(tester, find.widgetWithText(AppPillButton, 'Create'));

      expect(server.lastCreate?.areaId, 'in.tcity.alpha');
    });

    testWidgets('no area sends none; clearing a pick sends none', (
      tester,
    ) async {
      await open(tester, const {'beacons', 'location'});
      await tapVisible(tester, find.byKey(const ValueKey('plan-area-field')));
      await tester.tap(find.text('pick alpha'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('plan-area-clear')));
      expect(find.text(kPlanAreaChoose), findsOneWidget);

      await fill(tester);
      await tapVisible(tester, find.widgetWithText(AppPillButton, 'Create'));

      expect(server.lastCreate?.areaId, isEmpty);
    });
  });

  group('edit', () {
    Future<GoRouter> open(WidgetTester tester, {bool withArea = true}) async {
      final view = beaconView(
        startAt: start,
        title: 'Coffee',
        venue: 'Hall',
        canManage: true,
      );
      if (withArea) view.beacon.area = _summary();
      server.public.add(view);
      return pumpPlansRouter(
        tester,
        beacons: server,
        features: const {'beacons', 'location'},
        initialLocation: '/plans/$kBeaconIdA/edit',
        routes: [
          GoRoute(
            path: '/plans/:id',
            builder: (_, state) =>
                stubPage('plan ${state.pathParameters['id']}'),
          ),
          GoRoute(
            path: '/plans/:id/edit',
            builder: (_, state) =>
                EditBeaconScreen(beaconId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/area-picker',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => context.pop(fakeAreaTwo),
                child: const Text('pick beta'),
              ),
            ),
          ),
        ],
      );
    }

    Future<void> tapVisible(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    bool saveEnabled(WidgetTester tester) =>
        tester
            .widget<AppPillButton>(find.widgetWithText(AppPillButton, 'Save'))
            .onPressed !=
        null;

    testWidgets('shows the stored area; nothing changed sends nothing', (
      tester,
    ) async {
      await open(tester);
      await tester.ensureVisible(find.text(kPlanAreaTitle));
      expect(find.text('Alpha Nagar, Testville'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
    });

    testWidgets('a new area is the only field sent', (tester) async {
      await open(tester);
      await tapVisible(tester, find.byKey(const ValueKey('plan-area-field')));
      await tester.tap(find.text('pick beta'));
      await tester.pumpAndSettle();
      expect(saveEnabled(tester), isTrue);

      await tapVisible(tester, find.widgetWithText(AppPillButton, 'Save'));

      final sent = server.lastUpdate!;
      expect(sent.areaId, 'in.tcity.beta');
      expect(sent.hasTitle(), isFalse);
      expect(sent.hasVenue(), isFalse);
    });

    testWidgets('clearing sends an empty area_id', (tester) async {
      await open(tester);
      await tapVisible(tester, find.byKey(const ValueKey('plan-area-clear')));
      expect(saveEnabled(tester), isTrue);

      await tapVisible(tester, find.widgetWithText(AppPillButton, 'Save'));

      final sent = server.lastUpdate!;
      expect(sent.hasAreaId(), isTrue);
      expect(sent.areaId, '');
    });

    testWidgets('editing another field leaves area_id unset', (tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('field-Title')), 'Tea');
      await tester.pump();

      await tapVisible(tester, find.widgetWithText(AppPillButton, 'Save'));

      expect(server.lastUpdate!.hasAreaId(), isFalse);
    });

    testWidgets('a plan without an area offers the picker', (tester) async {
      await open(tester, withArea: false);
      await tester.ensureVisible(find.text(kPlanAreaTitle));
      expect(find.text(kPlanAreaChoose), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-area-clear')), findsNothing);
    });
  });
}
