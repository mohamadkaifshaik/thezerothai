import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/message_outbox.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockModeration extends Mock implements ModerationRepository {}

class _MockMessaging extends Mock implements MessagingRepository {
  @override
  final MessageOutbox outbox = MessageOutbox();
}

/// The viewer's actions on `/plans/:id` (R35, R37): the buttons follow the
/// server's ViewerState, every write reloads, and the menu offers Message
/// organiser and Report plan by flag and role.
void main() {
  late FakeBeaconsServer server;
  late _MockMessaging messaging;
  final now = DateTime.now();
  final start = now.add(const Duration(hours: 2));

  setUp(() {
    server = FakeBeaconsServer();
    messaging = _MockMessaging();
    when(() => messaging.cachedConversationWith(any()))
        .thenAnswer((_) async => null);
  });

  pb.BeaconView view({
    bool canRequest = false,
    bool canWithdraw = false,
    bool canLeave = false,
    bool canManage = false,
    pb.ParticipantState state =
        pb.ParticipantState.PARTICIPANT_STATE_UNSPECIFIED,
    pb.BeaconStatus status = pb.BeaconStatus.BEACON_STATUS_OPEN,
    int accepted = 2,
  }) {
    final v = beaconView(
      startAt: start,
      status: status,
      canManage: canManage,
      accepted: accepted,
    );
    v.viewer = pb.ViewerState(
      role: canManage
          ? pb.ViewerRole.VIEWER_ROLE_ORGANISER
          : pb.ViewerRole.VIEWER_ROLE_NONE,
      participantState: state,
      canRequest: canRequest,
      canWithdraw: canWithdraw,
      canLeave: canLeave,
      canManage: canManage,
    );
    return v;
  }

  Future<GoRouter> open(
    WidgetTester tester, {
    Set<String> features = const {},
    ModerationRepository? moderation,
  }) => pumpPlansRouter(
    tester,
    beacons: server,
    messaging: messaging,
    moderation: moderation,
    graph: _MockGraph(),
    features: features,
    initialLocation: '/plans/$kBeaconIdA',
    routes: [
      GoRoute(path: '/plans', builder: (_, _) => stubPage('plans')),
      GoRoute(
        path: '/plans/:id',
        builder: (_, state) =>
            BeaconScreen(beaconId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/plans/:id/people',
        builder: (_, state) => stubPage('people ${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/plans/:id/edit',
        builder: (_, state) => stubPage('edit ${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: AppRouter.messageDraftPath,
        builder: (_, _) => stubPage('draft message'),
      ),
    ],
  );

  group('buttons follow ViewerState (R37)', () {
    testWidgets('can_request: Ask to join and no pill', (tester) async {
      server.public.add(view(canRequest: true));
      await open(tester);
      expectNoOverflow(tester);
      expect(find.text('Ask to join'), findsOneWidget);
      expect(find.text('Requested'), findsNothing);
      expect(find.text("You're going"), findsNothing);
      expect(find.text('Withdraw request'), findsNothing);
      expect(find.text('Leave plan'), findsNothing);
      expect(find.text('Cancel plan'), findsNothing);
      expect(find.text('Edit'), findsNothing);
    });

    testWidgets('can_withdraw: Requested pill and Withdraw', (tester) async {
      server.public.add(
        view(
          canWithdraw: true,
          state: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
        ),
      );
      await open(tester);
      expect(find.text('Requested'), findsOneWidget);
      expect(find.text('Withdraw request'), findsOneWidget);
      expect(find.text('Ask to join'), findsNothing);
    });

    testWidgets("can_leave: You're going pill and Leave", (tester) async {
      server.public.add(
        view(
          canLeave: true,
          state: pb.ParticipantState.PARTICIPANT_STATE_ACCEPTED,
        ),
      );
      final router = await open(tester);
      expect(find.text("You're going"), findsOneWidget);
      expect(find.text('Leave plan'), findsOneWidget);
      // Going participants may see who else is going (ListParticipants).
      expect(find.text('People · 2 going'), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Cancel plan'), findsNothing);
      await tester.tap(find.text('People · 2 going'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/plans/$kBeaconIdA/people');
    });

    testWidgets('can_manage: People, Edit and Cancel, and they navigate', (
      tester,
    ) async {
      server.public.add(view(canManage: true));
      final router = await open(tester);
      expect(find.text('People · 2 going'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Cancel plan'), findsOneWidget);
      expect(find.text('Ask to join'), findsNothing);
      await tester.tap(find.text('People · 2 going'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/plans/$kBeaconIdA/people');
      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/plans/$kBeaconIdA/edit');
    });

    testWidgets('nothing allowed: the status only', (tester) async {
      server.public.add(view(status: pb.BeaconStatus.BEACON_STATUS_ENDED));
      await open(tester);
      expect(find.text('Ended'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  testWidgets('Ask to join opens the note sheet, caps the note, sends it and '
      'reloads to Requested', (tester) async {
    server.public.add(view(canRequest: true));
    await open(tester);

    await tester.tap(find.text('Ask to join'));
    await tester.pumpAndSettle();
    expect(find.text('Send request'), findsOneWidget);
    final note = find.widgetWithText(TextField, 'Note (optional)');
    await tester.enterText(note, 'x' * 141);
    await tester.pump();
    expect(find.text('At most 140 characters.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Send request'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(note, 'see you');
    await tester.pump();
    await tester.tap(find.text('Send request'));
    await tester.pumpAndSettle();

    expect(server.lastNote, 'see you');
    expect(server.calls.where((c) => c == 'request'), hasLength(1));
    expect(find.text('Requested'), findsOneWidget);
    expect(find.text('Withdraw request'), findsOneWidget);
    expect(find.text('Ask to join'), findsNothing);
  });

  testWidgets('a plan that filled meanwhile: the refusal is said and the '
      'reload shows Full with no Ask (Review Focus 1)', (tester) async {
    final v = view(canRequest: true);
    server.public.add(v);
    await open(tester);
    await tester.tap(find.text('Ask to join'));
    await tester.pumpAndSettle();
    // Between the open and the tap the plan filled on the server.
    server.refusals.add(StateConflictException('full'));
    v.beacon.status = pb.BeaconStatus.BEACON_STATUS_FULL;
    v.viewer.canRequest = false;

    await tester.tap(find.text('Send request'));
    await tester.pumpAndSettle();

    expect(find.text('This plan is full.'), findsOneWidget);
    expect(find.text('Full'), findsOneWidget);
    expect(find.text('Ask to join'), findsNothing);
  });

  testWidgets('Withdraw sends once and reloads to Ask to join', (tester) async {
    server.public.add(
      view(
        canWithdraw: true,
        state: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
      ),
    );
    await open(tester);

    await tester.tap(find.text('Withdraw request'));
    await tester.pumpAndSettle();

    expect(server.calls.where((c) => c == 'withdraw'), hasLength(1));
    expect(server.receivedKeys, hasLength(1));
    expect(find.text('Ask to join'), findsOneWidget);
  });

  testWidgets('Leave asks first, then sends once and reloads', (tester) async {
    server.public.add(
      view(
        canLeave: true,
        state: pb.ParticipantState.PARTICIPANT_STATE_ACCEPTED,
        accepted: 1,
      ),
    );
    await open(tester);

    await tester.tap(find.text('Leave plan'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this plan?'), findsOneWidget);
    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(server.calls.where((c) => c == 'leave'), isEmpty);

    await tester.tap(find.text('Leave plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Leave'));
    await tester.pumpAndSettle();

    expect(server.calls.where((c) => c == 'leave'), hasLength(1));
    expect(find.text("You're going"), findsNothing);
    expect(find.text('0 of 3 seats taken'), findsOneWidget);
  });

  group('the menu', () {
    testWidgets('Message organiser needs messaging on and not the organiser; '
        'it opens the draft thread', (tester) async {
      server.public.add(view(canRequest: true));
      await open(tester, features: const {'messaging'});
      await tester.tap(find.byTooltip('Plan options'));
      await tester.pumpAndSettle();
      expect(find.text('Message organiser'), findsOneWidget);
      expect(find.text('Report plan'), findsNothing);
      await tester.tap(find.text('Message organiser'));
      await tester.pumpAndSettle();
      expect(find.text('draft message'), findsOneWidget);
    });

    testWidgets('Report plan needs reports on; the sheet names the plan', (
      tester,
    ) async {
      server.public.add(view(canRequest: true));
      await open(
        tester,
        features: const {'reports'},
        moderation: _MockModeration(),
      );
      await tester.tap(find.byTooltip('Plan options'));
      await tester.pumpAndSettle();
      expect(find.text('Report plan'), findsOneWidget);
      expect(find.text('Message organiser'), findsNothing);
      await tester.tap(find.text('Report plan'));
      await tester.pumpAndSettle();
      expect(find.text('Report Coffee'), findsOneWidget);
    });

    testWidgets('no entries: no menu (flags off, or the organiser)', (
      tester,
    ) async {
      server.public.add(view(canRequest: true));
      await open(tester);
      expect(find.byTooltip('Plan options'), findsNothing);

      server.public
        ..clear()
        ..add(view(canManage: true));
      await open(tester, features: const {'messaging', 'reports'});
      expect(find.byTooltip('Plan options'), findsNothing);
    });
  });
}
