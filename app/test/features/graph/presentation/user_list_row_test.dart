import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/suggestions_fixtures.dart' show suggestedUser;
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

void main() {
  late _MockGraph graphRepo;
  late Completer<graph.Relationship> follow;

  setUp(() {
    graphRepo = _MockGraph();
    when(
      () => graphRepo.follow(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) {
      // Built inside the test body, so its callbacks run in the test's fake
      // async zone (one made in setUp would not).
      follow = Completer<graph.Relationship>();
      return follow.future;
    });
  });

  Future<void> open(WidgetTester tester, UserListRow row) => pumpThemed(
    tester,
    RepositoryProvider<GraphRepository>.value(value: graphRepo, child: row),
    size: const Size(360, 400),
  );

  for (final target in ['avatar', 'name', 'handle', 'padding']) {
    testWidgets('the $target opens the stable user-id profile route', (
      tester,
    ) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: UserListRow(
                item: suggestedUser(1),
                onProfileTap: () =>
                    context.push(AppRouter.profileByIdPath('u1')),
              ),
            ),
          ),
          GoRoute(
            path: '/u/:userId',
            builder: (_, state) => Scaffold(
              body: Text('Profile ${state.pathParameters['userId']}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        RepositoryProvider<GraphRepository>.value(
          value: graphRepo,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      switch (target) {
        case 'avatar':
          await tester.tap(find.byType(AppAvatar));
        case 'name':
          await tester.tap(find.text('User 1'));
        case 'handle':
          await tester.tap(find.text('@user1'));
        case 'padding':
          final rect = tester.getRect(find.byType(UserListRow));
          await tester.tapAt(Offset(rect.left + 2, rect.top + 12));
      }
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.last.matchedLocation,
        AppRouter.profileByIdPath('u1'),
      );
      expect(find.text('Profile u1'), findsOneWidget);
      verifyNever(() => graphRepo.relationshipFor(any()));
      verifyNever(
        () => graphRepo.follow(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });
  }

  group('onFollowed', () {
    testWidgets('fires when the server confirmed, not for the optimistic '
        'step', (tester) async {
      var calls = 0;
      await open(
        tester,
        UserListRow(item: suggestedUser(1), onFollowed: () => calls++),
      );

      await tester.tap(find.text('Follow'));
      await tester.pump();
      // Optimistic and in flight: the row is still there.
      expect(calls, 0);

      follow.complete(
        graph.Relationship(
          userId: 'u1',
          followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
      );
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('a REQUESTED answer (a protected account) counts as followed', (
      tester,
    ) async {
      var calls = 0;
      await open(
        tester,
        UserListRow(item: suggestedUser(1), onFollowed: () => calls++),
      );

      await tester.tap(find.text('Follow'));
      await tester.pump();
      follow.complete(
        graph.Relationship(
          userId: 'u1',
          followState: graph.FollowState.FOLLOW_STATE_REQUESTED,
        ),
      );
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('a rejected follow rolls back and never fires', (tester) async {
      var calls = 0;
      await open(
        tester,
        UserListRow(item: suggestedUser(1), onFollowed: () => calls++),
      );

      await tester.tap(find.text('Follow'));
      await tester.pump();
      follow.completeError(const QuotaExceededException('limit'));
      await tester.pumpAndSettle();

      expect(calls, 0);
      expect(find.text('Follow'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('a row that is already followed does not fire on build', (
      tester,
    ) async {
      var calls = 0;
      await open(
        tester,
        UserListRow(
          item: suggestedUser(
            1,
            follow: graph.FollowState.FOLLOW_STATE_FOLLOWING,
          ),
          onFollowed: () => calls++,
        ),
      );

      expect(find.text('Following'), findsOneWidget);
      expect(calls, 0);
    });
  });

  group('onDismiss and showDivider', () {
    testWidgets('no x unless asked for; the x calls back', (tester) async {
      await open(tester, UserListRow(item: suggestedUser(1)));
      expect(find.byTooltip('Dismiss @user1'), findsNothing);

      var dismissed = 0;
      await open(
        tester,
        UserListRow(item: suggestedUser(1), onDismiss: () => dismissed++),
      );
      await tester.tap(find.byTooltip('Dismiss @user1'));

      expect(dismissed, 1);
    });

    testWidgets('the divider is on by default and can be turned off', (
      tester,
    ) async {
      await open(tester, UserListRow(item: suggestedUser(1)));
      expect(find.byType(Divider), findsOneWidget);

      await open(
        tester,
        UserListRow(item: suggestedUser(1), showDivider: false),
      );
      expect(find.byType(Divider), findsNothing);
    });

    testWidgets('a supplied trailing replaces the follow button', (
      tester,
    ) async {
      await open(
        tester,
        UserListRow(item: suggestedUser(1), trailing: const Text('Unblock')),
      );

      expect(find.text('Unblock'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
    });
  });
}
