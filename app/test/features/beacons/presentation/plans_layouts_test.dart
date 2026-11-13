import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/beacon_row.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_preview.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_tips.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/beacons_fixtures.dart';
import '../../../support/plans_tablet_rig.dart';

// Plans from the dzeroth-mobile, tablet and desktop mocks (Home, PlanDetail,
// PlanPeople, PlanCreate, PlanEdit, MyPlans): one feature, the same actions
// at every width. The phone is the full-bleed hero and the label-above forms;
// from 600 dp the page's actions are pills beside the headline; the tablet
// keeps the list beside a plan from 840 dp; the desktop adds "Your plans"
// on top of the list.

const _screenshots = bool.fromEnvironment('PLANS_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/plans/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

const _planTitle = 'Flat white before work';

/// A rig whose first plan has people: two going and one request. With
/// [organiser] the caller manages it (People and Edit need that).
PlansTabletRig _rig({bool organiser = false}) {
  final rig = PlansTabletRig();
  final first = rig.server.public.first.beacon;
  rig.server.public[0] = beaconView(
    startAt: first.startAt.toDateTime(),
    id: kBeaconIdA,
    title: _planTitle,
    details: 'A slow coffee and a chat before work. Introverts welcome.',
    venue: 'Third Wave Coffee, 12th Main',
    accepted: 2,
    canManage: organiser,
  );
  rig.server.going[kBeaconIdA] = [
    participant(userId: 'u1', handle: 'sana.n', name: 'Sana'),
    participant(userId: 'u2', handle: 'riya.s', name: 'Riya'),
  ];
  rig.server.requests[kBeaconIdA] = [
    participant(
      userId: 'u3',
      handle: 'kabir.m',
      name: 'Kabir',
      state: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
      note: 'New to the area, would love a coffee buddy.',
    ),
  ];
  return rig;
}

Future<PlansTabletRig> _open(
  WidgetTester tester,
  Size size,
  String location, {
  bool organiser = false,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final rig = _rig(organiser: organiser);
  await rig.pump(
    tester,
    location: location,
    width: size.width,
    height: size.height,
    textScale: textScale,
    brightness: brightness,
    realForms: true,
  );
  return rig;
}

final _planPath = AppRouter.planPath(kBeaconIdA);
final _previewAction = find.widgetWithText(TextButton, kPlanPreviewTitle);
final _tipsToggle = find.byKey(const ValueKey('plan-tips-toggle'));
Finder _field(String label) => find.byKey(ValueKey('field-$label'));
Finder get _pillMyPlans => find.widgetWithText(AppPillButton, 'My plans');
Finder get _pillNewPlan => find.widgetWithText(AppPillButton, 'New plan');

/// The one of [a] and [b] on screen (the header icon or the headline pill).
Finder _either(Finder a, Finder b) =>
    a.evaluate().isNotEmpty ? a.first : b.first;

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final phone = size.width < 600;
    final desktop = size.width >= 1200;

    group('$name (${size.width.toInt()} dp)', () {
      group('Home', () {
        testWidgets('the look', (tester) async {
          await _open(tester, size, AppRouter.plansPath);
          expect(find.text('Flat white before work'), findsWidgets);
          expect(find.textContaining('2 going'), findsWidgets);
          // My plans and New plan: header icons on the phone and in the list
          // pane, pills beside the headline on the page.
          final pills = !phone && size.width < 840 || desktop;
          expect(_pillMyPlans, pills ? findsOneWidget : findsNothing);
          // The tablet's empty detail pane carries a content-sized New plan
          // pill too.
          final placeholderPill = !phone && !desktop && size.width >= 840;
          expect(
            _pillNewPlan,
            pills || placeholderPill ? findsOneWidget : findsNothing,
          );
          expect(
            find.byTooltip('My plans'),
            pills ? findsNothing : findsOneWidget,
          );
          // "Your plans" on the tablet layout and the desktop, not the phone.
          expect(
            find.text('Your plans'),
            phone ? findsNothing : findsOneWidget,
          );
          // The list cards say who is going and carry no seat count.
          expect(find.text('2 of 3 seats taken'), findsNothing);
          expect(tester.takeException(), isNull);
        });

        testWidgets('My plans and New plan open their pages', (tester) async {
          final rig = await _open(tester, size, AppRouter.plansPath);
          await tester.tap(_either(find.byTooltip('My plans'), _pillMyPlans));
          await tester.pumpAndSettle();
          expect(rig.uri.path, AppRouter.plansMinePath);
          rig.router.pop();
          await tester.pumpAndSettle();
          await tester.tap(_either(find.byTooltip('New plan'), _pillNewPlan));
          await tester.pumpAndSettle();
          expect(rig.uri.path, AppRouter.planNewPath);
        });

        testWidgets('a card opens its plan', (tester) async {
          final rig = await _open(tester, size, AppRouter.plansPath);
          await tester.tap(find.byType(BeaconRow).first);
          await tester.pumpAndSettle();
          expect(rig.uri.path, startsWith('/plans/'));
        });
      });

      group('PlanDetail', () {
        testWidgets('the look', (tester) async {
          await _open(tester, size, _planPath);
          // The hero is the page's top: full width of its column, rounded
          // under, with Back in it (the list is beside it from 840 dp).
          final hero = tester.getRect(find.byKey(const ValueKey('plan-hero')));
          expect(hero.top, 0);
          final back = find.byTooltip('Back');
          expect(
            back,
            size.width < 840 || desktop ? findsOneWidget : findsNothing,
          );
          if (back.evaluate().isNotEmpty) {
            expect(hero.contains(tester.getCenter(back)), isTrue);
          }
          expect(find.text('Organiser'), findsOneWidget);
          expect(find.text('Ask to join'), findsOneWidget);
          expect(find.text('Plan'), findsNothing);
          expect(tester.takeException(), isNull);
        });

        testWidgets('Ask to join sends the request', (tester) async {
          final rig = await _open(tester, size, _planPath);
          await tester.tap(find.text('Ask to join'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Send request'));
          await tester.pumpAndSettle();
          expect(rig.count('request'), 1);
        });
      });

      group('PlanPeople', () {
        testWidgets('the look', (tester) async {
          await _open(
            tester,
            size,
            AppRouter.planPeoplePath(kBeaconIdA),
            organiser: true,
          );
          // The header names the plan; the tabs carry the counts.
          expect(find.text(_planTitle), findsOneWidget);
          expect(find.text('Going · 2'), findsOneWidget);
          expect(find.text('Requests · 1'), findsOneWidget);
          expect(find.text('Sana'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('Accept takes the request', (tester) async {
          final rig = await _open(
            tester,
            size,
            AppRouter.planPeoplePath(kBeaconIdA),
            organiser: true,
          );
          await tester.tap(find.text('Requests · 1'));
          await tester.pumpAndSettle();
          expect(find.text('Kabir'), findsOneWidget);
          await tester.tap(find.text('Accept'));
          await tester.pumpAndSettle();
          expect(rig.count('respond:accept'), 1);
        });
      });

      group('PlanCreate', () {
        testWidgets('the look', (tester) async {
          await _open(tester, size, AppRouter.planNewPath);
          // The same header action and tips at every width, labels over the
          // fields.
          expect(_previewAction, findsOneWidget);
          expect(_tipsToggle, findsOneWidget);
          expect(find.text(kPlanTipsTitle), findsOneWidget);
          expect(_field('Title'), findsOneWidget);
          final label = tester.getRect(find.text('Title'));
          expect(
            label.bottom,
            lessThanOrEqualTo(tester.getRect(_field('Title')).top),
          );
          // Cost and Open spots share a row where there is room.
          await tester.ensureVisible(find.text('Open spots'));
          await tester.pumpAndSettle();
          final cost = tester.getRect(find.text('Cost'));
          final spots = tester.getRect(find.text('Open spots'));
          expect((cost.center.dy - spots.center.dy).abs() < 40, !phone);
          expect(tester.takeException(), isNull);
        });

        testWidgets('Preview shows the plan; Create sends it', (tester) async {
          final rig = await _open(tester, size, AppRouter.planNewPath);
          await tester.enterText(_field('Title'), _planTitle);
          await tester.enterText(_field('Meeting point'), 'Third Wave Coffee');
          await tester.pumpAndSettle();
          await tester.tap(_previewAction);
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.text(_planTitle),
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(AppPillButton, 'Create'));
          await tester.pumpAndSettle();
          expect(rig.server.lastCreate?.title, _planTitle);
        });
      });

      group('PlanEdit', () {
        testWidgets('the look and Save', (tester) async {
          final rig = await _open(
            tester,
            size,
            AppRouter.planEditPath(kBeaconIdA),
            organiser: true,
          );
          expect(_previewAction, findsOneWidget);
          expect(_tipsToggle, findsOneWidget);
          expect(
            tester.widget<TextField>(_field('Title')).controller?.text,
            _planTitle,
          );
          await tester.enterText(_field('Title'), '$_planTitle today');
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
          await tester.pumpAndSettle();
          expect(rig.server.lastUpdate?.title, '$_planTitle today');
        });
      });

      group('MyPlans', () {
        testWidgets('the look and a row opens its plan', (tester) async {
          final rig = await _open(tester, size, AppRouter.plansMinePath);
          // The wide layouts put the role pills above the tabs; the phone
          // keeps the tabs first.
          final roles = tester.getRect(find.text('Organising'));
          final tabs = tester.getRect(find.text('Upcoming'));
          expect(roles.top < tabs.top, !phone);
          expect(find.text('0 going'), findsWidgets);
          await tester.tap(find.text('My run'));
          await tester.pumpAndSettle();
          expect(rig.uri.path, startsWith('/plans/'));
        });
      });
    });
  }

  group('text scale 2.0 on a phone: nothing overflows', () {
    final screens = <String, (String, bool)>{
      'Home': (AppRouter.plansPath, false),
      'PlanDetail': (_planPath, false),
      'PlanPeople': (AppRouter.planPeoplePath(kBeaconIdA), true),
      'PlanCreate': (AppRouter.planNewPath, false),
      'PlanEdit': (AppRouter.planEditPath(kBeaconIdA), true),
      'MyPlans': (AppRouter.plansMinePath, false),
    };
    for (final MapEntry(key: name, value: (path, organiser))
        in screens.entries) {
      testWidgets(name, (tester) async {
        await _open(
          tester,
          _sizes['phone']!,
          path,
          organiser: organiser,
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('screenshots', () {
    final screens = <String, (String, bool)>{
      'Home': (AppRouter.plansPath, false),
      'PlanDetail': (_planPath, false),
      'PlanPeople': (AppRouter.planPeoplePath(kBeaconIdA), true),
      'PlanCreate': (AppRouter.planNewPath, false),
      'PlanEdit': (AppRouter.planEditPath(kBeaconIdA), true),
      'MyPlans': (AppRouter.plansMinePath, false),
    };
    for (final MapEntry(key: screen, value: (path, organiser))
        in screens.entries) {
      for (final brightness in Brightness.values) {
        for (final MapEntry(key: name, value: size) in _sizes.entries) {
          testWidgets('$screen $name ${brightness.name}', (tester) async {
            await _open(
              tester,
              size,
              path,
              organiser: organiser,
              brightness: brightness,
            );
            await _capture(tester, '$screen-$name-${brightness.name}');
          }, skip: !_screenshots);
        }
      }
    }
  });
}
