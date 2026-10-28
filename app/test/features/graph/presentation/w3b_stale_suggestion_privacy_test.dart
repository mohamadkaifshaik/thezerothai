import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/data/suggestions_repository.dart'
    show kSuggestionsTtl;
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/graph/presentation/widgets/who_to_follow_card.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/protected_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/suggestions_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// W3-35c, owed by W3-35a (report section 2.3) and W3-33c: a "Who to follow"
/// row can sit on the device for up to 48 hours (ADR-0024 Amendment 2), so
/// its `is_private` badge can be older than the account. The badge is a hint
/// from the row's own field and nothing else; a Follow from a stale row is
/// answered by the server (REQUESTED for an account that has since been
/// protected) and the client shows that answer, not the cached row; the next
/// list refreshes the badge.
void main() {
  late SuggestionsRig rig;
  late _MockOnboarding onboarding;
  SuggestionsCubit? cubit;

  graph.UserListItem user(int i, {bool isPrivate = false}) {
    final item = suggestedUser(i);
    item.user.isPrivate = isPrivate;
    return item;
  }

  graph.FollowResponse requested(graph.FollowRequest request) =>
      graph.FollowResponse(
        relationship: graph.Relationship(
          userId: request.userId,
          followState: graph.FollowState.FOLLOW_STATE_REQUESTED,
        ),
      );

  setUp(() {
    onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: const {'graph', 'follow_suggestions'},
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
  });

  tearDown(() async {
    await cubit?.close();
    cubit = null;
    await rig.database.close();
  });

  /// The card over the real repositories and the scripted transport; the
  /// database is real I/O, hence `runAsync`.
  Future<void> openCard(
    WidgetTester tester, {
    MatrixEnv env = const MatrixEnv(
      brightness: Brightness.light,
      size: Size(360, 800),
      textScale: 1,
    ),
  }) async {
    final old = cubit;
    // A restart builds the card again: unmount the old tree first, or the
    // loader (same key) keeps its state and never asks the new cubit.
    if (old != null) await tester.pumpWidget(const SizedBox());
    cubit = SuggestionsCubit(repository: rig.repository);
    await tester.runAsync(() async {
      await old?.close();
      await pumpThemed(
        tester,
        RepositoryProvider<GraphRepository>.value(
          value: rig.graphRepository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<OnboardingBloc>.value(value: onboarding),
              BlocProvider<SuggestionsCubit>.value(value: cubit!),
            ],
            child: const SingleChildScrollView(
              child: WhoToFollowCard(margin: EdgeInsets.all(16)),
            ),
          ),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  Finder badgeOf(String userId) => find.descendant(
    of: find.byKey(ValueKey(userId)),
    matching: find.byType(ProtectedBadge),
  );

  group('the badge follows the row field, cached or fresh', () {
    testWidgets('a cached answer draws the lock from each row, and a restart '
        'from the disk entry asks for nothing', (tester) async {
      rig = SuggestionsRig(users: [user(1, isPrivate: true), user(2)]);
      await openCard(tester);
      expect(rig.suggestionCalls, 1);
      expect(find.byType(UserListRow), findsNWidgets(2));
      expect(badgeOf('u1'), findsOneWidget);
      expect(badgeOf('u2'), findsNothing);

      // An app restart: a new repository over the same database. The row
      // comes off the disk and keeps its own field; no second call.
      rig.repository = rig.newRepository();
      await openCard(tester);
      expect(rig.suggestionCalls, 1);
      expect(badgeOf('u1'), findsOneWidget);
      expect(badgeOf('u2'), findsNothing);
    });

    testWidgets('a cached row is not re-judged: the account protected since '
        'shows no lock until the next list', (tester) async {
      rig = SuggestionsRig(users: [user(1), user(2)]);
      await openCard(tester);
      expect(badgeOf('u1'), findsNothing);

      // The server now says u1 is protected, but the entry is 47 h old and
      // fresh: the card must not ask, and must not invent a lock.
      rig.users = [user(1, isPrivate: true), user(2)];
      rig.clock = kSuggestionsTtl - const Duration(hours: 1);
      rig.repository = rig.newRepository();
      await openCard(tester);
      expect(rig.suggestionCalls, 1);
      expect(badgeOf('u1'), findsNothing);

      // Past the lifetime the next list is one call and the lock appears.
      rig.clock = kSuggestionsTtl + const Duration(minutes: 1);
      rig.repository = rig.newRepository();
      await openCard(tester);
      expect(rig.suggestionCalls, 2);
      expect(badgeOf('u1'), findsOneWidget);
      expect(badgeOf('u2'), findsNothing);
    });

    testWidgets('and the other way: an unprotected account loses the lock '
        'with the next list', (tester) async {
      rig = SuggestionsRig(users: [user(1, isPrivate: true), user(2)]);
      await openCard(tester);
      expect(badgeOf('u1'), findsOneWidget);

      rig.users = [user(1), user(2)];
      rig.clock = kSuggestionsTtl + const Duration(minutes: 1);
      rig.repository = rig.newRepository();
      await openCard(tester);
      expect(rig.suggestionCalls, 2);
      expect(badgeOf('u1'), findsNothing);
    });
  });

  group('a Follow from a stale row', () {
    testWidgets('REQUESTED is rendered as Requested, never as the cached '
        'Follow and never as Following', (tester) async {
      rig = SuggestionsRig(
        users: [user(1)],
        onFollow: (r) async => requested(r),
      );
      final stale = rig.users.single;
      await tester.runAsync(() async {
        await pumpThemed(
          tester,
          RepositoryProvider<GraphRepository>.value(
            value: rig.graphRepository,
            child: UserListRow(item: stale),
          ),
        );
      });
      expect(find.widgetWithText(FilledButton, 'Follow'), findsOneWidget);
      expect(find.byType(ProtectedBadge), findsNothing);

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Follow'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Requested'), findsOneWidget);
      expect(find.text('Following'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Follow'), findsNothing);
      // The badge is the row's field; the answer does not rewrite it.
      expect(find.byType(ProtectedBadge), findsNothing);
      // The shared graph cache holds the answer for every other surface.
      expect(
        rig.graphRepository.cached('u1')?.followState,
        graph.FollowState.FOLLOW_STATE_REQUESTED,
      );
    });

    testWidgets('in the card the requested row leaves like a followed one and '
        'the answer is cached', (tester) async {
      rig = SuggestionsRig(
        users: [user(1), user(2)],
        onFollow: (r) async => requested(r),
      );
      await openCard(tester);

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Follow').first);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('u1')), findsNothing);
      expect(find.byKey(const ValueKey('u2')), findsOneWidget);
      expect(
        rig.graphRepository.cached('u1')?.followState,
        graph.FollowState.FOLLOW_STATE_REQUESTED,
      );
    });

    test('the next list refreshes the badge of a row that was not followed and '
        'does not offer the requested one again', () async {
      rig = SuggestionsRig(
        users: [user(1), user(2)],
        onFollow: (r) async => requested(r),
      );
      await rig.repository.suggestionsFor('me');
      await rig.graphRepository.follow(userId: 'u1', idempotencyKey: 'k1');

      // Both accounts are protected by now.
      rig.users = [user(1, isPrivate: true), user(2, isPrivate: true)];
      rig.clock = kSuggestionsTtl + const Duration(minutes: 1);
      final next = await rig.newRepository().suggestionsFor('me');

      expect(rig.suggestionCalls, 2);
      expect([for (final i in next) i.user.userId], ['u2']);
      expect(next.single.user.isPrivate, isTrue);
    });
  });
}
