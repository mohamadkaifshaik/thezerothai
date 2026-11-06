import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/create_beacon_screen.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as cpb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';

class _MockCommunities extends Mock implements CommunitiesRepository {}

/// `/plans/new`: defaults, client-side rules (R31), the request sent and the
/// navigation to the created plan.
void main() {
  late FakeBeaconsServer server;
  // The screen's clock, fixed per test; every date is built from it.
  final today = DateTime.now();
  final now = DateTime(today.year, today.month, today.day, 12, 0);
  DateTime? pickedDate;
  TimeOfDay? pickedTime;

  setUp(() {
    server = FakeBeaconsServer();
    pickedDate = null;
    pickedTime = null;
  });

  Future<GoRouter> open(
    WidgetTester tester, {
    CommunitiesRepository? communities,
  }) => pumpPlansRouter(
    tester,
    beacons: server,
    communities: communities,
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
          }) async => pickedDate ?? initial,
          pickTime: (context, {required initial}) async =>
              pickedTime ?? initial,
        ),
      ),
      GoRoute(
        path: '/plans/:id',
        builder: (_, state) => stubPage('plan ${state.pathParameters['id']}'),
      ),
    ],
  );

  Finder field(String label) => find.widgetWithText(TextField, label);

  /// The form is longer than a phone: scroll a control into view, then tap.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  bool createEnabled(WidgetTester tester) {
    final button = tester.widget<AppPillButton>(
      find.widgetWithText(AppPillButton, 'Create'),
    );
    return button.onPressed != null;
  }

  Future<void> fillValid(WidgetTester tester) async {
    await tester.enterText(field('Title'), 'Coffee at the hall');
    await tester.enterText(field('Meeting point'), 'Food court, 2nd floor');
    await tester.pump();
  }

  testWidgets('defaults: Coffee, 60 min, 3 spots, Free, Quiet, Public, and '
      'Create waits for a title and a meeting point', (tester) async {
    await open(tester);

    expectNoOverflow(tester);
    expect(find.text('New plan'), findsOneWidget);
    expect(find.text('60 min'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    for (final label in ['Coffee', 'Free', 'Quiet', 'Public']) {
      final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, label),
      );
      expect(chip.selected, isTrue, reason: label);
    }
    expect(find.widgetWithText(ChoiceChip, 'Gardeners'), findsNothing);
    expect(createEnabled(tester), isFalse);
    await fillValid(tester);
    expect(createEnabled(tester), isTrue);
  });

  testWidgets('an over-long title or venue shows the limit and blocks Create', (
    tester,
  ) async {
    await open(tester);
    await fillValid(tester);
    await tester.enterText(field('Title'), 'x' * (kBeaconTitleMaxLength + 1));
    await tester.pump();
    expect(
      find.text('At most $kBeaconTitleMaxLength characters.'),
      findsOneWidget,
    );
    expect(createEnabled(tester), isFalse);

    await tester.enterText(field('Title'), 'Coffee');
    await tester.enterText(
      field('Meeting point'),
      'x' * (kBeaconVenueMaxLength + 1),
    );
    await tester.pump();
    expect(
      find.text('At most $kBeaconVenueMaxLength characters.'),
      findsOneWidget,
    );
    expect(createEnabled(tester), isFalse);
  });

  testWidgets('a start too soon or too far is refused with its copy', (
    tester,
  ) async {
    await open(tester);
    await fillValid(tester);

    pickedDate = now;
    pickedTime = TimeOfDay.fromDateTime(now.add(const Duration(minutes: 4)));
    await tapVisible(tester, find.byTooltip('Pick a date'));
    await tapVisible(tester, find.byTooltip('Pick a time'));
    expect(
      find.text('Pick a time at least 5 minutes from now.'),
      findsOneWidget,
    );
    expect(createEnabled(tester), isFalse);

    pickedDate = now.add(const Duration(days: 31));
    pickedTime = TimeOfDay.fromDateTime(now);
    await tapVisible(tester, find.byTooltip('Pick a date'));
    await tapVisible(tester, find.byTooltip('Pick a time'));
    expect(find.text('Pick a time within the next 30 days.'), findsOneWidget);
    expect(createEnabled(tester), isFalse);
  });

  testWidgets('a valid submit sends the request and opens the plan', (
    tester,
  ) async {
    final router = await open(tester);
    await fillValid(tester);
    await tester.enterText(field('Details'), ' Bring a book ');
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Study'));
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Split evenly'));
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Open to chat'));
    await tapVisible(tester, find.byTooltip('More spots'));
    pickedDate = now.add(const Duration(days: 2));
    pickedTime = const TimeOfDay(hour: 18, minute: 30);
    await tapVisible(tester, find.byTooltip('Pick a date'));
    await tapVisible(tester, find.byTooltip('Pick a time'));

    await tester.tap(find.widgetWithText(AppPillButton, 'Create'));
    await tester.pumpAndSettle();

    final sent = server.lastCreate!;
    expect(sent.public, isTrue);
    expect(sent.activity, pb.BeaconActivity.BEACON_ACTIVITY_STUDY);
    expect(sent.title, 'Coffee at the hall');
    expect(sent.details, 'Bring a book');
    expect(sent.venue, 'Food court, 2nd floor');
    expect(
      sent.startAt.toDateTime().toLocal(),
      DateTime(now.year, now.month, now.day + 2, 18, 30),
    );
    expect(sent.durationMinutes, 60);
    expect(sent.openSpots, 4);
    expect(sent.cost, pb.BeaconCost.BEACON_COST_SPLIT_EVENLY);
    expect(sent.chatPreference, pb.ChatPreference.CHAT_PREFERENCE_OPEN_TO_CHAT);
    expect(server.receivedKeys, hasLength(1));
    expect(
      router.state.uri.path,
      '/plans/${server.public.single.beacon.beaconId}',
    );
  });

  testWidgets('a community audience sends its id', (tester) async {
    final communities = _MockCommunities();
    when(() => communities.enabled).thenReturn(true);
    when(() => communities.myCommunities(refresh: any(named: 'refresh')))
        .thenAnswer(
          (_) async => MyCommunities(
            communities: [
              cpb.Community(
                communityId: 'c1',
                name: 'Gardeners',
                viewerRole: cpb.CommunityRole.COMMUNITY_ROLE_MEMBER,
              ),
            ],
            canCreate: false,
          ),
        );
    await open(tester, communities: communities);
    await fillValid(tester);

    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Gardeners'));
    await tester.tap(find.widgetWithText(AppPillButton, 'Create'));
    await tester.pumpAndSettle();

    expect(server.lastCreate!.communityId, 'c1');
    expect(server.lastCreate!.hasPublic(), isFalse);
  });

  testWidgets('the open-plans limit keeps the form with its copy', (
    tester,
  ) async {
    server.refusals.add(LimitReachedException('no', quota: kBeaconsOpenLimit));
    final router = await open(tester);
    await fillValid(tester);

    await tester.tap(find.widgetWithText(AppPillButton, 'Create'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'You can have up to $kMaxOpenBeacons open plans. Cancel one to create '
        'another.',
      ),
      findsOneWidget,
    );
    expect(router.state.uri.path, '/plans/new');
    expect(createEnabled(tester), isTrue);
  });
}
