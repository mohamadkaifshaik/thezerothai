import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/domain/beacon_labels.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/beacon_detail_cubit.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/beacon_detail_state.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockBeacons extends Mock implements BeaconsRepository {}

/// The plan page's "Riya and 2 others are going" with a face stack, for a
/// viewer who may list participants. Not in the design mocks.
void main() {
  late FakeBeaconsServer server;
  final start = DateTime.now().add(const Duration(hours: 2));

  setUp(() => server = FakeBeaconsServer());

  pb.BeaconView plan({required bool lister, int accepted = 4}) {
    final v = beaconView(
      startAt: start,
      canManage: lister,
      accepted: accepted,
      openSpots: 6,
    );
    v.viewer = pb.ViewerState(
      role: lister
          ? pb.ViewerRole.VIEWER_ROLE_ORGANISER
          : pb.ViewerRole.VIEWER_ROLE_NONE,
      canManage: lister,
      canRequest: !lister,
    );
    return v;
  }

  void goers() {
    server.going[kBeaconIdA] = [
      for (final n in ['Riya', 'Sam', 'Lee', 'Max'])
        participant(userId: n, name: n),
    ];
  }

  Future<void> open(WidgetTester tester, MatrixEnv env) => pumpPlansRouter(
    tester,
    beacons: server,
    env: env,
    initialLocation: '/plans/$kBeaconIdA',
    routes: [
      GoRoute(
        path: '/plans/:id',
        builder: (_, s) => BeaconScreen(beaconId: s.pathParameters['id']!),
      ),
    ],
  );

  forEachThemeAndWidth(
    'a lister sees 3 faces and the going sentence',
    (tester, env) async {
      server.public.add(plan(lister: true));
      goers();
      await open(tester, env);
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      expect(find.byKey(const ValueKey('plan-going-faces')), findsOneWidget);
      expect(find.text('Riya and 3 others are going'), findsOneWidget);
      expect(find.text('People · 4 going'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('plan-going-faces')),
          matching: find.byType(AppAvatar),
        ),
        findsNWidgets(3), // the +1 bubble is not an avatar
      );
    },
    heights: kRedesignHeights,
    widths: const [360, 834, 1440],
  );

  testWidgets('a visitor makes no ListParticipants call and sees the count', (
    tester,
  ) async {
    server.public.add(plan(lister: false));
    goers();
    await open(
      tester,
      MatrixEnv(
        brightness: Brightness.light,
        size: const Size(360, 800),
        textScale: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(server.calls, isNot(contains('people:accepted')));
    expect(find.byKey(const ValueKey('plan-going-faces')), findsNothing);
    expect(find.text('People · 4 going'), findsOneWidget);
  });

  group('cubit', () {
    late _MockBeacons repo;
    setUp(() => repo = _MockBeacons());

    Future<void> stubFaces(Object? answer) async {
      when(
        () => repo.listParticipants(
          beaconId: kBeaconIdA,
          filter: pb.ParticipantFilter.PARTICIPANT_FILTER_ACCEPTED,
          limit: 3,
        ),
      ).thenAnswer((_) async {
        if (answer is Exception) throw answer;
        return answer! as ParticipantsPage;
      });
    }

    test('a lister loads the first 3 people going', () async {
      when(() => repo.getBeacon(kBeaconIdA))
          .thenAnswer((_) async => plan(lister: true));
      await stubFaces(
        ParticipantsPage(
          participants: [
            for (final n in ['a', 'b', 'c']) participant(userId: n),
          ],
          nextPageToken: '',
        ),
      );
      final cubit = BeaconDetailCubit(repository: repo, beaconId: kBeaconIdA);
      await cubit.load();
      expect(cubit.state.faces.map((p) => p.user.userId), ['a', 'b', 'c']);
      await cubit.close();
    });

    for (final refusal in [const NotFoundException('x')]) {
      test(
        '${refusal.runtimeType} on the faces read leaves the count',
        () async {
          when(() => repo.getBeacon(kBeaconIdA))
              .thenAnswer((_) async => plan(lister: true));
          await stubFaces(refusal);
          final cubit = BeaconDetailCubit(
            repository: repo,
            beaconId: kBeaconIdA,
          );
          await cubit.load();
          expect(cubit.state.status, BeaconDetailStatus.ready);
          expect(cubit.state.faces, isEmpty);
          await cubit.close();
        },
      );
    }

    test('a visitor never reads the people', () async {
      when(() => repo.getBeacon(kBeaconIdA))
          .thenAnswer((_) async => plan(lister: false));
      final cubit = BeaconDetailCubit(repository: repo, beaconId: kBeaconIdA);
      await cubit.load();
      verifyNever(
        () => repo.listParticipants(
          beaconId: kBeaconIdA,
          filter: pb.ParticipantFilter.PARTICIPANT_FILTER_ACCEPTED,
          limit: 3,
        ),
      );
      expect(cubit.state.faces, isEmpty);
      await cubit.close();
    });
  });

  group('goingSentence', () {
    test('forms', () {
      expect(
        goingSentence(['Riya', 'Sam', 'Lee'], 3),
        'Riya and 2 others are going',
      );
      expect(goingSentence(['Riya', 'Sam'], 2), 'Riya and 1 other are going');
      expect(goingSentence(['Riya'], 1), 'Riya is going');
      expect(goingSentence([], 5), '5 are going');
      expect(goingSentence([], 1), '1 is going');
    });
  });
}
