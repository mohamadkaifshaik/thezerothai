import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
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
import 'package:dzeroth/shared/widgets/app_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/suggestions_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _on = {'graph', 'follow_suggestions'};

void main() {
  late FakeSuggestionsRepository repo;
  late SuggestionsCubit cubit;
  late _MockGraph graphRepo;
  late _MockOnboarding onboarding;
  late List<String> followed;
  Object? followError;

  List<graph.UserListItem> five() => [
    for (var i = 1; i <= 5; i++) suggestedUser(i),
  ];

  setUp(() {
    repo = FakeSuggestionsRepository(five());
    cubit = SuggestionsCubit(repository: repo);
    graphRepo = _MockGraph();
    onboarding = _MockOnboarding();
    followed = [];
    followError = null;
    when(
      () => graphRepo.follow(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((invocation) async {
      final id = invocation.namedArguments[#userId] as String;
      final error = followError;
      if (error != null) throw error;
      followed.add(id);
      return graph.Relationship(
        userId: id,
        followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
      );
    });
  });

  tearDown(() => cubit.close());

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = _on,
    String? uid = 'me',
    Size size = const Size(360, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    double? width,
    EdgeInsets? margin,
    String? title,
    Stream<OnboardingState> states = const Stream<OnboardingState>.empty(),
  }) async {
    whenListen(
      onboarding,
      states,
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: uid == null
            ? null
            : identity.Profile(userId: uid, handle: 'me'),
      ),
    );
    await pumpThemed(
      tester,
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<SuggestionsCubit>.value(value: cubit),
          ],
          child: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width ?? size.width,
                child: WhoToFollowCard(
                  title: title ?? 'Who to follow',
                  margin: margin ?? const EdgeInsets.all(AppSpacing.md),
                ),
              ),
            ),
          ),
        ),
      ),
      size: size,
      brightness: brightness,
      textScale: textScale,
    );
  }

  Finder followButtons() => find.widgetWithText(FilledButton, 'Follow');

  group('flag gating: nothing is drawn and nothing is asked', () {
    for (final entry in {
      'no flags': <String>{},
      'graph only': {'graph'},
      'follow_suggestions without graph': {'follow_suggestions'},
      'ui_shell and posts only': {'ui_shell', 'posts'},
    }.entries) {
      testWidgets(entry.key, (tester) async {
        await open(tester, features: entry.value);

        expect(find.text('Who to follow'), findsNothing);
        expect(find.byType(UserListRow), findsNothing);
        expect(repo.calls, 0);
      });
    }

    testWidgets('no known viewer: nothing', (tester) async {
      await open(tester, uid: null);

      expect(find.text('Who to follow'), findsNothing);
      expect(repo.calls, 0);
    });
  });

  group('flag on', () {
    testWidgets('three rows, then Show more opens the full five', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('Who to follow'), findsOneWidget);
      expect(find.byType(UserListRow), findsNWidgets(3));
      expect(find.text('User 3'), findsOneWidget);
      expect(find.text('User 4'), findsNothing);
      expect(find.text('Show more'), findsOneWidget);
      expect(repo.calls, 1);

      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();

      expect(find.byType(UserListRow), findsNWidgets(5));
      expect(find.text('User 5'), findsOneWidget);
      expect(find.text('Show more'), findsNothing);
      expect(repo.calls, 1);
    });

    testWidgets('up to three suggestions: no Show more', (tester) async {
      repo.rows = five().take(3).toList();

      await open(tester);

      expect(find.byType(UserListRow), findsNWidgets(3));
      expect(find.text('Show more'), findsNothing);
    });

    testWidgets('an empty result hides the whole card', (tester) async {
      repo.rows = const [];

      await open(tester);

      expect(find.text('Who to follow'), findsNothing);
      expect(find.byType(AppSurface), findsNothing);
      expect(repo.calls, 1);
    });

    testWidgets('the title is a parameter ("You might like")', (tester) async {
      await open(tester, title: 'You might like');

      expect(find.text('You might like'), findsOneWidget);
      expect(find.text('Who to follow'), findsNothing);
    });

    testWidgets('each row shows name, handle and a Follow button', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('User 1'), findsOneWidget);
      expect(find.text('@user1'), findsOneWidget);
      expect(followButtons(), findsNWidgets(3));
    });

    testWidgets('a followed row disappears once the server confirms and the '
        'next suggestion moves up', (tester) async {
      await open(tester);

      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();

      expect(followed, ['u1']);
      expect(find.text('User 1'), findsNothing);
      expect(find.byType(UserListRow), findsNWidgets(3));
      expect(find.text('User 4'), findsOneWidget);
      expect(find.text('Show more'), findsOneWidget);
      expect(repo.hidden, {'u1'});
    });

    testWidgets('after a removal the next Follow acts on its own account '
        '(rows are keyed by user)', (tester) async {
      await open(tester);

      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();
      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();

      expect(followed, ['u1', 'u2']);
      expect(find.text('User 2'), findsNothing);
      expect(find.text('User 3'), findsOneWidget);
    });

    testWidgets('a follow refused with NOT_FOUND drops the row silently and '
        'the next suggestion moves up (blocked-by, suspended, gone: L-1)', (
      tester,
    ) async {
      followError = const NotFoundException('not found');
      await open(tester);

      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();

      // No error, no snackbar: the row simply is not there any more.
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text("This account doesn't exist anymore."), findsNothing);
      expect(find.text('User 1'), findsNothing);
      expect(find.byType(UserListRow), findsNWidgets(3));
      expect(find.text('User 4'), findsOneWidget);
      expect(find.text('Show more'), findsOneWidget);
      // Dropped for good (not just hidden for the session), and nothing was
      // reported as followed.
      expect(repo.dropped, {'u1'});
      expect(followed, isEmpty);
    });

    testWidgets('after a dropped row the next Follow still acts on its own '
        'account, and any other refusal still keeps the row', (tester) async {
      followError = const NotFoundException('not found');
      await open(tester);
      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();

      followError = const QuotaExceededException('limit');
      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();

      expect(find.text('User 2'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(repo.dropped, {'u1'});
    });

    testWidgets('following the last visible row asks for the list again and '
        'shows the new rows (once)', (tester) async {
      repo.rows = five().take(2).toList();
      repo.refillRows = [suggestedUser(7), suggestedUser(8)];
      await open(tester);

      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();
      expect(find.text('User 2'), findsOneWidget);
      expect(repo.calls, 1);

      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();

      expect(followed, ['u1', 'u2']);
      expect(repo.calls, 2);
      expect(find.byType(UserListRow), findsNWidgets(2));
      expect(find.text('User 7'), findsOneWidget);
      expect(find.text('User 8'), findsOneWidget);

      // The new rows are the last ones of the session: following them empties
      // the card for good and sends nothing more.
      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();
      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();

      expect(find.byType(UserListRow), findsNothing);
      expect(find.text('Who to follow'), findsNothing);
      expect(repo.calls, 2);
      expect(repo.followedIds, ['u1', 'u2', 'u7', 'u8']);
    });

    testWidgets('a follow that leaves rows does not ask again', (tester) async {
      repo.refillRows = [suggestedUser(7)];
      await open(tester);

      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();

      expect(repo.calls, 1);
      expect(find.text('User 7'), findsNothing);
      expect(find.byType(UserListRow), findsNWidgets(3));
    });

    testWidgets('resume: free while the entry is fresh, one call past the '
        'lifetime (a card left mounted never shows stale rows)', (
      tester,
    ) async {
      final rig = SuggestionsRig();
      addTearDown(rig.database.close);
      await cubit.close();
      cubit = SuggestionsCubit(repository: rig.repository);
      await tester.runAsync(() async {
        await open(tester);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(rig.suggestionCalls, 1);
      expect(find.text('User 1'), findsOneWidget);

      Future<void> resume() async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }

      rig.clock = kSuggestionsTtl - const Duration(minutes: 1);
      await resume();
      expect(rig.suggestionCalls, 1);
      expect(find.text('User 1'), findsOneWidget);

      rig.clock = kSuggestionsTtl + const Duration(minutes: 1);
      rig.users = [suggestedUser(9)];
      await resume();
      expect(rig.suggestionCalls, 2);
      expect(find.text('User 9'), findsOneWidget);
      expect(find.text('User 1'), findsNothing);

      await resume();
      expect(rig.suggestionCalls, 2);
    });

    testWidgets('a rejected follow keeps the row and says why', (tester) async {
      followError = const QuotaExceededException('limit');
      await open(tester);

      await tester.tap(followButtons().first);
      await tester.pumpAndSettle();

      expect(find.text('User 1'), findsOneWidget);
      expect(followButtons(), findsNWidgets(3));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(repo.hidden, isEmpty);
    });

    testWidgets('the x hides a row for the session and sends nothing', (
      tester,
    ) async {
      await open(tester);

      await tester.tap(find.byTooltip('Dismiss @user2'));
      await tester.pumpAndSettle();

      expect(find.text('User 2'), findsNothing);
      expect(find.byType(UserListRow), findsNWidgets(3));
      expect(find.text('User 4'), findsOneWidget);
      expect(followed, isEmpty);
      verifyNever(
        () => graphRepo.follow(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    testWidgets('a dismissal outlives the card: opening it again keeps the '
        'row hidden without another call', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Dismiss @user2'));
      await tester.pumpAndSettle();

      // The same session: the card is mounted again (Home reopened).
      await open(tester);

      expect(find.text('User 2'), findsNothing);
      expect(find.byType(UserListRow), findsNWidgets(3));
    });

    testWidgets('dismissing everything removes the card and never asks '
        'again', (tester) async {
      repo.rows = five().take(2).toList();
      repo.refillRows = [suggestedUser(7)];
      await open(tester);

      await tester.tap(find.byTooltip('Dismiss @user1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Dismiss @user2'));
      await tester.pumpAndSettle();

      expect(find.text('Who to follow'), findsNothing);
      expect(repo.calls, 1);
      expect(repo.followedIds, isEmpty);
    });

    testWidgets('the flag turning off removes the card', (tester) async {
      final states = StreamController<OnboardingState>.broadcast();
      addTearDown(states.close);
      await open(tester, states: states.stream);
      expect(find.text('Who to follow'), findsOneWidget);

      final off = OnboardingState(
        enabledFeatures: const {'graph'},
        profile: identity.Profile(userId: 'me', handle: 'me'),
      );
      when(() => onboarding.state).thenReturn(off);
      states.add(off);
      await tester.pump();
      await tester.pump();

      expect(find.text('Who to follow'), findsNothing);
    });
  });

  group('accessibility', () {
    testWidgets('title is a header; x and Follow are 48dp targets', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);

      expect(
        tester.getSemantics(find.text('Who to follow')),
        isSemantics(label: 'Who to follow', isHeader: true),
      );
      for (final tooltip in ['Dismiss @user1', 'Dismiss @user3']) {
        final size = tester.getSize(find.byTooltip(tooltip));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      for (final button in followButtons().evaluate()) {
        expect(
          tester.getSize(find.byWidget(button.widget)).height,
          greaterThanOrEqualTo(48),
        );
      }
      expect(
        tester
            .getSemantics(find.byTooltip('Dismiss @user1'))
            .getSemanticsData()
            .tooltip,
        'Dismiss @user1',
      );
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Show more')).height,
        greaterThanOrEqualTo(48),
      );
      handle.dispose();
    });
  });

  group('responsive matrix', () {
    forEachThemeAndWidth('three rows fit without overflow', (
      tester,
      env,
    ) async {
      // At 1200dp the card lives in the 350dp right column.
      await open(
        tester,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
        width: env.size.width >= AppBreakpoints.tablet
            ? AppSize.sideColumn
            : env.size.width,
        // The shell gives the column card only a bottom margin (`MainShell`).
        margin: env.size.width >= AppBreakpoints.tablet
            ? const EdgeInsets.only(bottom: AppSpacing.md)
            : null,
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(UserListRow), findsNWidgets(3));
      final card = tester.getRect(find.byType(WhoToFollowCard));
      expect(card.right, lessThanOrEqualTo(env.size.width));
      final row = tester.getRect(find.byType(UserListRow).first);
      expect(row.left, greaterThanOrEqualTo(card.left));
      expect(row.right, lessThanOrEqualTo(card.right));

      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(UserListRow), findsNWidgets(5));
    }, textScales: kMatrixTextScalesLarge);

    // W3-21: the 2.0 stops of the matrix, and the targets the ui-catalog
    // demands (Follow, the x, Show more) at every cell.
    forEachThemeAndWidth('Follow, x and Show more are 48dp targets', (
      tester,
      env,
    ) async {
      await open(
        tester,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
        width: env.size.width >= AppBreakpoints.tablet
            ? AppSize.sideColumn
            : env.size.width,
        // The shell gives the column card only a bottom margin (`MainShell`).
        margin: env.size.width >= AppBreakpoints.tablet
            ? const EdgeInsets.only(bottom: AppSpacing.md)
            : null,
      );

      expect(tester.takeException(), isNull);
      for (final button in followButtons().evaluate()) {
        expectMinTarget(tester, find.byWidget(button.widget), reason: 'Follow');
      }
      for (var i = 1; i <= 3; i++) {
        expectMinTarget(
          tester,
          find.byTooltip('Dismiss @user$i'),
          reason: 'Dismiss @user$i',
        );
      }
      expectMinTarget(
        tester,
        find.widgetWithText(TextButton, 'Show more'),
        reason: 'Show more',
      );
      expectInsideHorizontally(
        tester,
        find.widgetWithText(TextButton, 'Show more'),
        env.size.width,
      );
    }, textScales: kMatrixTextScalesLarge);

    for (final brightness in Brightness.values) {
      testWidgets('text scale 2.0 on a phone: no overflow, every row stays '
          'reachable (${brightness.name})', (tester) async {
        await open(tester, textScale: 2, brightness: brightness);

        expect(tester.takeException(), isNull);
        expect(find.byType(UserListRow), findsNWidgets(3));

        await tester.tap(followButtons().first);
        await tester.pumpAndSettle();
        // The row went away (a confirmed follow): still no overflow.
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('rows in the card', () {
    testWidgets('the last row has no divider when nothing follows it', (
      tester,
    ) async {
      repo.rows = five().take(2).toList();
      await open(tester);

      expect(find.byType(Divider), findsOneWidget);
    });
  });
}
