import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bookmarks_screen.dart';
import 'package:dzeroth/features/engagement/presentation/engagement_error_messages.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/app_back_header.dart';
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/bookmarks_fixtures.dart';
import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockEngagementRepository extends Mock implements EngagementRepository {}

class _MockPostsRepository extends Mock implements PostsRepository {}

const _allFlags = {'posts', 'engagement', 'replies', 'bookmarks'};

/// A live post: counts the card shows (not a snapshot taken at bookmark time).
pb.PostView _view(int n, {String? text}) => pb.PostView(
  post: pb.Post(
    postId: postId(n),
    text: text ?? 'Saved post number $n',
    author: common.AuthorSnapshot(
      userId: 'u$n',
      handle: 'user$n',
      displayName: 'User $n',
    ),
    likeCount: Int64(10 + n),
    repostCount: Int64(2),
    replyCount: Int64(3),
  ),
  // Listed rows come hydrated (ADR-0023 D3).
  bookmarkedByViewer: true,
);

eng.ListBookmarksResponse _rows(List<int> posts, [String next = '']) =>
    bookmarksPageOf([for (final n in posts) _view(n)], next);

/// `/bookmarks` (W2-7): states, live rows, short-page paging, un-bookmark with
/// Undo, flag handling and sign-out, over the real cubits and repository.
void main() {
  late FakeBookmarksServer server;
  late SessionEpoch epoch;
  late BookmarksRepository repo;
  late BookmarksCubit overlay;
  late EngagementCubit engagement;
  late _MockOnboardingBloc onboarding;
  late _MockPostsRepository posts;
  late GoRouter router;
  var gateOn = true;

  setUp(() {
    server = FakeBookmarksServer();
    epoch = SessionEpoch();
    gateOn = true;
    repo = BookmarksRepository(
      apiClient: ApiClient.withTransport(FakeTransport(server.handle)),
      gate: ServiceFeatureGate(isEnabled: () => gateOn),
      epoch: epoch,
    );
    overlay = BookmarksCubit(repository: repo, viewRoute: '/bookmarks');
    engagement = EngagementCubit(repository: _MockEngagementRepository());
    onboarding = _MockOnboardingBloc();
    posts = _MockPostsRepository();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() async {
    await engagement.close();
    await overlay.close();
    await repo.dispose();
  });

  /// Opens `/bookmarks` over a "came from" page (or as the first page with
  /// [deepLink]).
  Future<void> open(
    WidgetTester tester, {
    Set<String> features = _allFlags,
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool deepLink = false,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: features,
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
    router = GoRouter(
      initialLocation: deepLink ? '/bookmarks' : '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('came from')),
        ),
        GoRoute(
          path: '/home',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/bookmarks',
          builder: (context, state) => const BookmarksScreen(),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) =>
              Scaffold(body: Text('post page ${state.pathParameters['id']}')),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<BookmarksRepository>.value(value: repo),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<EngagementCubit>.value(value: engagement),
            BlocProvider<BookmarksCubit>.value(value: overlay),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    if (!deepLink) unawaited(router.push('/bookmarks'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Finder filledBookmark() => find.byIcon(Icons.bookmark);
  Finder rows() => find.byType(PostCard);
  Finder removedSnack() => find.text('Removed from Bookmarks');

  group('states', () {
    testWidgets('loading: a skeleton, announced', (tester) async {
      final handle = tester.ensureSemantics();
      final gate = Completer<void>();
      server.pages[''] = () async {
        await gate.future;
        return _rows([1]);
      };
      await open(tester, settle: false);

      expect(find.bySemanticsLabel('Loading bookmarks'), findsOneWidget);
      expect(rows(), findsNothing);
      expect(find.text('Save posts for later'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Loading bookmarks'), findsNothing);
      expect(rows(), findsOneWidget);
      handle.dispose();
    });

    testWidgets('empty: "Save posts for later" with our own guidance', (
      tester,
    ) async {
      await open(tester);

      expect(find.text(kBookmarksEmptyTitle), findsOneWidget);
      expect(find.text('Save posts for later'), findsOneWidget);
      expect(find.text(kBookmarksEmptyBody), findsOneWidget);
      expect(rows(), findsNothing);
      expect(server.listTokens, ['']);
    });

    testWidgets('FEATURE_DISABLED: the not-available state, no Retry', (
      tester,
    ) async {
      server.pages[''] = () => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'bookmarks'},
      );
      await open(tester);

      expect(find.text(kBookmarksUnavailableTitle), findsOneWidget);
      expect(find.text(kBookmarksUnavailableBody), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(rows(), findsNothing);
      expect(find.text(kBookmarksEmptyTitle), findsNothing);
    });

    testWidgets('a failed first page: the error view, Retry loads again', (
      tester,
    ) async {
      server.pages[''] = () => throw serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );
      await open(tester);
      expect(find.text('Retry'), findsOneWidget);

      server.pages[''] = () => _rows([1]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(rows(), findsOneWidget);
      expect(server.listTokens, ['', '']);
    });

    testWidgets('a failed refresh keeps the rows under a banner', (
      tester,
    ) async {
      server.pages[''] = () => _rows([2, 1]);
      await open(tester);
      server.pages[''] = () => throw serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await tester.fling(
        find.byType(PostCard).first,
        const Offset(0, 400),
        800,
      );
      await tester.pumpAndSettle();

      expect(rows(), findsNWidgets(2));
      expect(
        find.text("You're offline. Showing the bookmarks already loaded."),
        findsOneWidget,
      );
    });
  });

  group('rows', () {
    testWidgets('live post cards, newest first, each with the engagement row '
        'and the bookmark icon showing bookmarked', (tester) async {
      final handle = tester.ensureSemantics();
      server.pages[''] = () => _rows([3, 2, 1]);
      await open(tester);

      expect(rows(), findsNWidgets(3));
      expect(find.text('Saved post number 3'), findsOneWidget);
      // Current counts from the page, not a snapshot: likes 13 / 12 / 11.
      expect(find.text('13'), findsOneWidget);
      expect(find.text('11'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Saved post number 3')).dy,
        lessThan(tester.getTopLeft(find.text('Saved post number 1')).dy),
      );
      expect(filledBookmark(), findsNWidgets(3));
      expect(find.byIcon(Icons.bookmark_border), findsOneWidget, reason: 'tab');
      expect(find.bySemanticsLabel('Bookmarked'), findsNWidgets(3));
      // Every row is in the local set (no flag on the row yet).
      for (final n in [1, 2, 3]) {
        expect(repo.isBookmarked(postId(n)), isTrue);
      }
      handle.dispose();
    });

    testWidgets(
      'header "Bookmarks" and a one-tab bar (bookmark icon + label)',
      (tester) async {
        final handle = tester.ensureSemantics();
        server.pages[''] = () => _rows([1]);
        await open(tester);

        expect(find.byType(AppBackHeader), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AppBackHeader),
            matching: find.text('Bookmarks'),
          ),
          findsOneWidget,
        );
        final tabs = find.byType(AppTabBar);
        expect(tabs, findsOneWidget);
        expect(
          find.descendant(of: tabs, matching: find.text('Bookmarks')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: tabs,
            matching: find.byIcon(Icons.bookmark_border),
          ),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(find.byType(AppBackHeader).first),
          isNotNull,
        );
        handle.dispose();
      },
    );

    testWidgets('tapping a row opens the post', (tester) async {
      server.pages[''] = () => _rows([2]);
      await open(tester);

      await tester.tap(find.text('Saved post number 2'));
      await tester.pumpAndSettle();

      expect(find.text('post page ${postId(2)}'), findsOneWidget);
    });

    testWidgets('back pops to where the user came from', (tester) async {
      await open(tester);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.text('came from'), findsOneWidget);
    });

    testWidgets('back from a deep link goes Home', (tester) async {
      await open(tester, deepLink: true);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.text('home page'), findsOneWidget);
    });

    testWidgets('pull down asks again and replaces page 1', (tester) async {
      server.pages[''] = () => _rows([2, 1]);
      await open(tester);
      server.pages[''] = () => _rows([9]);

      await tester.fling(
        find.byType(PostCard).first,
        const Offset(0, 400),
        800,
      );
      await tester.pumpAndSettle();

      expect(server.listTokens, ['', '']);
      expect(rows(), findsOneWidget);
      expect(find.text('Saved post number 9'), findsOneWidget);
    });
  });

  group('paging', () {
    testWidgets('a short page with a token fills the screen by asking again, '
        'through empty pages, until the token is empty', (tester) async {
      server.pages[''] = () => _rows([4], 't1');
      server.pages['t1'] = () => _rows(const [], 't2');
      server.pages['t2'] = () => _rows([3, 2], 't3');
      server.pages['t3'] = () => _rows([1]);
      await open(tester);

      expect(server.listTokens, ['', 't1', 't2', 't3']);
      expect(rows(), findsNWidgets(4));
      expect(find.text(kBookmarksEmptyTitle), findsNothing);
    });

    testWidgets('a first page with no row but a token never claims empty', (
      tester,
    ) async {
      server.pages[''] = () => _rows(const [], 't1');
      server.pages['t1'] = () => _rows(const [], 't2');
      server.pages['t2'] = () => _rows([1]);
      await open(tester);

      expect(rows(), findsOneWidget);
      expect(find.text(kBookmarksEmptyTitle), findsNothing);
    });

    testWidgets('pages that end empty show the empty state only then', (
      tester,
    ) async {
      server.pages[''] = () => _rows(const [], 't1');
      server.pages['t1'] = () => _rows(const []);
      await open(tester);

      expect(server.listTokens, ['', 't1']);
      expect(find.text(kBookmarksEmptyTitle), findsOneWidget);
    });

    testWidgets('a long list prefetches the next page near the end only', (
      tester,
    ) async {
      server.pages[''] = () => _rows([for (var n = 30; n > 10; n--) n], 't1');
      server.pages['t1'] = () => _rows([for (var n = 10; n > 5; n--) n]);
      await open(tester);
      expect(server.listTokens, [
        '',
      ], reason: 'the viewport is not near the end');

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
      await tester.pumpAndSettle();

      expect(server.listTokens, ['', 't1']);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -9000));
      await tester.pumpAndSettle();
      expect(server.listTokens, ['', 't1'], reason: 'the token ended it');
      expect(find.text('Saved post number 6'), findsOneWidget);
    });

    testWidgets('a failed next page keeps the rows, with a Retry', (
      tester,
    ) async {
      server.pages[''] = () => _rows([for (var n = 30; n > 10; n--) n], 't1');
      server.pages['t1'] = () => throw serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );
      await open(tester);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
      await tester.pumpAndSettle();

      expect(
        find.text("You're offline. Showing the bookmarks already loaded."),
        findsOneWidget,
      );
      // Halted: more scrolling sends nothing.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(server.listTokens, ['', 't1']);

      server.pages['t1'] = () => _rows([5]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(server.listTokens, ['', 't1', 't1']);
    });
  });

  group('un-bookmark', () {
    testWidgets('a failed next page with every row removed shows one banner', (
      tester,
    ) async {
      final gate = Completer<void>();
      server.pages[''] = () => _rows([1], 't1');
      server.pages['t1'] = () async {
        await gate.future;
        throw serverError(
          connect.Code.unavailable,
          common.ErrorReason.ERROR_REASON_UNSPECIFIED,
        );
      };
      await open(tester, settle: false);
      await tester.pump();
      await tester.pump();

      await tester.tap(filledBookmark());
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();

      expect(rows(), findsNothing);
      expect(
        find.text("You're offline. Showing the bookmarks already loaded."),
        findsOneWidget,
      );
    });

    testWidgets('removes the row at once with an Undo snackbar; Undo '
        'brings it back through the repository', (tester) async {
      server.pages[''] = () => _rows([3, 2, 1]);
      await open(tester);

      // The icon of the second row.
      await tester.tap(filledBookmark().at(1));
      await tester.pump();

      expect(rows(), findsNWidgets(2));
      expect(find.text('Saved post number 2'), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(removedSnack(), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      expect(server.toggles.single, isA<eng.RemoveBookmarkRequest>());
      expect(
        (server.toggles.single as eng.RemoveBookmarkRequest).postId,
        postId(2),
      );

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(server.toggles.last, isA<eng.AddBookmarkRequest>());
      expect(rows(), findsNWidgets(3));
      // Back at its place.
      final dy = [
        for (final n in [3, 2, 1])
          tester.getTopLeft(find.text('Saved post number $n')).dy,
      ];
      expect(dy[0], lessThan(dy[1]));
      expect(dy[1], lessThan(dy[2]));
    });

    testWidgets('the last row going shows the empty state', (tester) async {
      server.pages[''] = () => _rows([1]);
      await open(tester);

      await tester.tap(filledBookmark());
      await tester.pumpAndSettle();

      expect(rows(), findsNothing);
      expect(find.text(kBookmarksEmptyTitle), findsOneWidget);
    });

    testWidgets('a failed removal puts the row back and says why', (
      tester,
    ) async {
      server.pages[''] = () => _rows([2, 1]);
      await open(tester);
      server.toggleError = serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await tester.tap(filledBookmark().first);
      await tester.pumpAndSettle();

      expect(rows(), findsNWidgets(2));
      expect(
        find.text(
          engagementErrorMessage(
            const NetworkException('x'),
            action: EngagementAction.unbookmark,
          ),
        ),
        findsOneWidget,
      );
      expect(removedSnack(), findsNothing, reason: 'the failure replaced it');
    });

    testWidgets('a failed Undo says why and the row stays out', (tester) async {
      server.pages[''] = () => _rows([2, 1]);
      await open(tester);
      await tester.tap(filledBookmark().first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      server.toggleError = serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(rows(), findsOneWidget);
      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
    });

    testWidgets('the Undo snackbar leaves by itself', (tester) async {
      server.pages[''] = () => _rows([2, 1]);
      await open(tester);
      await tester.tap(filledBookmark().first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(removedSnack(), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      expect(removedSnack(), findsNothing);
    });
  });

  group('flags', () {
    testWidgets('bookmarks off for the caller (dropped from the allowlist): '
        'the list shows and a row can still be removed', (tester) async {
      gateOn = false;
      server.pages[''] = () => _rows([2, 1]);
      await open(tester, features: const {'posts', 'engagement', 'replies'});

      expect(rows(), findsNWidgets(2));
      expect(filledBookmark(), findsNWidgets(2));

      await tester.tap(filledBookmark().first);
      await tester.pumpAndSettle();

      expect(server.toggles.single, isA<eng.RemoveBookmarkRequest>());
      expect(rows(), findsOneWidget);
    });

    testWidgets('engagement off: the rows show with no action row', (
      tester,
    ) async {
      server.pages[''] = () => _rows([2, 1]);
      await open(tester, features: const {'posts', 'bookmarks'});

      expect(rows(), findsNWidgets(2));
      expect(filledBookmark(), findsNothing);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
    });
  });

  group('sign-out', () {
    testWidgets('the list is cleared, and a page landing after is dropped', (
      tester,
    ) async {
      server.pages[''] = () => _rows([2, 1], 't1');
      final gate = Completer<void>();
      server.pages['t1'] = () async {
        await gate.future;
        return _rows([0]);
      };
      await open(tester, size: const Size(390, 300));
      expect(rows(), findsWidgets);

      // What AppWidget does on sign-out.
      overlay.reset();
      epoch.end();
      await tester.pumpAndSettle();

      expect(rows(), findsNothing);
      expect(find.text(kBookmarksEmptyTitle), findsNothing);
      expect(repo.snapshot(), isEmpty);

      gate.complete();
      await tester.pumpAndSettle();
      expect(rows(), findsNothing);
      expect(repo.snapshot(), isEmpty);
    });
  });

  group('layout', () {
    for (final brightness in Brightness.values) {
      for (final width in const [360.0, 600.0, 1200.0]) {
        for (final scale in const [1.0, 1.3, 2.0]) {
          testWidgets(
            'rows, header and tab fit: ${brightness.name} ${width.toInt()}dp '
            'x$scale',
            (tester) async {
              server.pages[''] = () => bookmarksPageOf([
                _view(
                  3,
                  text:
                      'A long saved post that wraps over several lines so the '
                      'row grows with the text size and must never overflow '
                      'the column it sits in, at any width.',
                ),
                _view(2),
                _view(1),
              ]);
              await open(
                tester,
                size: Size(width, 900),
                brightness: brightness,
                textScale: scale,
              );

              expect(tester.takeException(), isNull);
              expect(rows(), findsWidgets);
              expect(find.text('Bookmarks'), findsWidgets);
              expect(filledBookmark(), findsWidgets);
              // The column is capped on wide screens.
              final header = tester.getSize(find.byType(AppBackHeader)).width;
              expect(header, lessThanOrEqualTo(AppLayout.mainColumnMaxWidth));
            },
          );
        }
      }
    }
  });
}
