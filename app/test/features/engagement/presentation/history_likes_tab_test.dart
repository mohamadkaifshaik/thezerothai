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
import 'package:dzeroth/features/engagement/data/likes_repository.dart';
import 'package:dzeroth/features/engagement/domain/likes_list_feature_flag.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_state.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/likes_list_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bookmarks_screen.dart';
import 'package:dzeroth/features/engagement/presentation/engagement_error_messages.dart';
import 'package:dzeroth/features/engagement/presentation/likes_tab.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/core/widgets/app_error_view.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_back_header.dart';
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/bookmarks_fixtures.dart';
import '../../../support/fake_transport.dart';
import '../../../support/likes_fixtures.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockPostsRepository extends Mock implements PostsRepository {}

const _allFlags = {'posts', 'engagement', 'replies', 'bookmarks', 'likes_list'};
const _flagOff = {'posts', 'engagement', 'replies', 'bookmarks'};

/// The History screen's Likes tab (W3-18, ADR-0024 D6) over the real cubits
/// and repositories, with `ListLikedPosts` / `ListBookmarks` / `LikePost` /
/// `UnlikePost` scripted: flag off and on, the deep link, lazy loading, the
/// copy, un-liking, short-page paging, errors, sign-out and the layout matrix.
void main() {
  late FakeBookmarksServer bookmarks;
  late FakeLikesServer server;
  late SessionEpoch epoch;
  late BookmarksRepository bookmarksRepo;
  late LikesRepository likesRepo;
  late ApiClient client;
  late BookmarksCubit overlay;
  late EngagementCubit engagement;
  late _MockOnboardingBloc onboarding;
  late _MockPostsRepository posts;
  late GoRouter router;
  late Set<String> features;
  late StreamController<OnboardingState> onboardingStates;
  var reported = 0;

  setUp(() {
    bookmarks = FakeBookmarksServer();
    server = FakeLikesServer(bookmarks: bookmarks);
    epoch = SessionEpoch();
    reported = 0;
    features = {..._allFlags};
    client = ApiClient.withTransport(FakeTransport(server.handle));
    bookmarksRepo = BookmarksRepository(
      apiClient: client,
      gate: ServiceFeatureGate(isEnabled: () => true),
      epoch: epoch,
    );
    likesRepo = LikesRepository(
      apiClient: client,
      gate: ServiceFeatureGate(
        isEnabled: () => features.contains(kFeatureLikesList),
      ),
      epoch: epoch,
      onUnexpectedError: (_, _) => reported++,
    );
    onboarding = _MockOnboardingBloc();
    onboardingStates = StreamController<OnboardingState>.broadcast();
    posts = _MockPostsRepository();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
  });

  // Not awaited: when a test fails the fake-async zone is not pumped again,
  // and awaiting a close would hold the failure back for the test timeout.
  tearDown(() {
    unawaited(onboardingStates.close());
    unawaited(engagement.close());
    unawaited(overlay.close());
    unawaited(bookmarksRepo.dispose());
    unawaited(likesRepo.dispose());
  });

  /// Opens [location] over a "came from" page, on the real route shape: the
  /// tab comes from the query, as in `AppRouter`.
  Future<void> open(
    WidgetTester tester, {
    Set<String>? flags,
    String location = '/bookmarks',
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool settle = true,
  }) async {
    if (flags != null) features = {...flags};
    // Built here, in the test body's zone, so that what they emit reaches the
    // widgets within the same pumps (a cubit made in setUp delivers to its
    // listeners outside the fake-async clock).
    overlay = BookmarksCubit(repository: bookmarksRepo);
    engagement = EngagementCubit(
      repository: EngagementRepository(
        apiClient: client,
        gate: ServiceFeatureGate(isEnabled: () => true),
      ),
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      onboardingStates.stream,
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: features,
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('came from')),
        ),
        GoRoute(
          path: '/bookmarks',
          builder: (context, state) => BookmarksScreen(
            initialTab: HistoryTab.fromQuery(state.uri.queryParameters['tab']),
          ),
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
          RepositoryProvider<BookmarksRepository>.value(value: bookmarksRepo),
          RepositoryProvider<LikesRepository>.value(value: likesRepo),
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
    unawaited(router.push(location));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Finder rows() => find.byType(PostCard);
  Finder tabBar() => find.byType(AppTabBar);
  Finder tab(String label) =>
      find.descendant(of: tabBar(), matching: find.text(label));
  Finder likedHearts() => find.byIcon(Icons.favorite);

  Future<void> selectLikes(WidgetTester tester) async {
    await tester.tap(tab('Likes'));
    await tester.pumpAndSettle();
  }

  group('flag off', () {
    testWidgets('Bookmarks only: "History", no tab bar, no Likes call', (
      tester,
    ) async {
      bookmarks.pages[''] = () => bookmarksPage([2, 1]);
      await open(tester, flags: _flagOff);

      expect(
        find.descendant(
          of: find.byType(AppBackHeader),
          matching: find.text('History'),
        ),
        findsOneWidget,
      );
      expect(tabBar(), findsNothing);
      expect(rows(), findsNWidgets(2));
      expect(server.listCalls, 0);
    });

    testWidgets('?tab=likes is ignored: the saved posts show, nothing asks '
        'for likes', (tester) async {
      bookmarks.pages[''] = () => bookmarksPage([2, 1]);
      await open(tester, flags: _flagOff, location: '/bookmarks?tab=likes');

      expect(tabBar(), findsNothing);
      expect(rows(), findsNWidgets(2));
      expect(find.text(kLikesEmptyTitle), findsNothing);
      expect(server.listCalls, 0);
      expect(bookmarks.listTokens, ['']);
    });

    testWidgets('the flag on in GetMe but the server having said FEATURE_'
        'DISABLED once: no tab (the repository remembers)', (tester) async {
      server.pages[''] = () => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureLikesList},
      );
      // Learn it the way the app does: one refused call.
      await expectLater(
        likesRepo.fetchPage(),
        throwsA(isA<FeatureDisabledException>()),
      );
      server.listTokens.clear();

      await open(tester);

      expect(tabBar(), findsNothing);
      expect(server.listCalls, 0);
    });
  });

  group('flag on', () {
    testWidgets('two tabs, Bookmarks first; Likes is not asked for until it '
        'is selected', (tester) async {
      bookmarks.pages[''] = () => bookmarksPage([2, 1]);
      await open(tester);

      expect(tabBar(), findsOneWidget);
      expect(tab('Bookmarks'), findsOneWidget);
      expect(tab('Likes'), findsOneWidget);
      expect(rows(), findsNWidgets(2));
      expect(server.listCalls, 0, reason: 'lazy: 24 reads saved');

      server.pages[''] = () => likesPage([5, 4, 3]);
      await selectLikes(tester);

      expect(server.listTokens, ['']);
      expect(rows(), findsNWidgets(3));
      expect(find.text('Liked post number 5'), findsOneWidget);
      // Live counts of the page, and the heart showing liked.
      expect(find.text('15'), findsOneWidget);
      expect(likedHearts(), findsNWidgets(3));
    });

    testWidgets('both tabs keep their rows: switching back and forth asks '
        'nothing more', (tester) async {
      bookmarks.pages[''] = () => bookmarksPage([2, 1]);
      server.pages[''] = () => likesPage([5, 4]);
      await open(tester);
      await selectLikes(tester);

      await tester.tap(tab('Bookmarks'));
      await tester.pumpAndSettle();
      expect(find.text('Liked post number 5'), findsNothing);
      expect(find.text('post 2'), findsOneWidget);

      await selectLikes(tester);
      expect(find.text('Liked post number 5'), findsOneWidget);
      expect(server.listTokens, ['']);
      expect(bookmarks.listTokens, ['']);
    });

    testWidgets('the Bookmarks tab out of sight stays quiet: removing a '
        'bookmark on a Likes card shows the card toast, not a second '
        'Undo from the hidden list', (tester) async {
      bookmarks.pages[''] = () => bookmarksPage([2, 1]);
      server.pages[''] = () => likesPageOf([likedView(2, bookmarked: true)]);
      await open(tester);
      await selectLikes(tester);

      await tester.tap(find.byIcon(Icons.bookmark));
      await tester.pumpAndSettle();

      expect(bookmarks.toggles.single, isA<eng.RemoveBookmarkRequest>());
      expect(find.text('Removed from Bookmarks'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);

      // Back on Bookmarks the row is gone, and nothing is pending.
      await tester.tap(tab('Bookmarks'));
      await tester.pumpAndSettle();
      expect(find.text('post 2'), findsNothing);
      expect(find.text('post 1'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('?tab=likes lands on Likes, and Bookmarks is not asked for', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      server.pages[''] = () => likesPage([5, 4]);
      await open(tester, location: '/bookmarks?tab=likes');

      expect(rows(), findsNWidgets(2));
      expect(find.text('Liked post number 4'), findsOneWidget);
      expect(bookmarks.listTokens, isEmpty);
      expect(
        tester.getSemantics(tab('Likes')),
        isSemantics(
          label: 'Likes',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );

      // Bookmarks loads when it is first selected.
      bookmarks.pages[''] = () => bookmarksPage([2, 1]);
      await tester.tap(tab('Bookmarks'));
      await tester.pumpAndSettle();
      expect(bookmarks.listTokens, ['']);
      expect(find.text('post 2'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('any other ?tab= value is Bookmarks', (tester) async {
      bookmarks.pages[''] = () => bookmarksPage([2]);
      await open(tester, location: '/bookmarks?tab=nonsense');

      expect(find.text('post 2'), findsOneWidget);
      expect(server.listCalls, 0);
    });

    testWidgets('tapping a liked row opens the post', (tester) async {
      server.pages[''] = () => likesPage([5]);
      await open(tester, location: '/bookmarks?tab=likes');

      await tester.tap(find.text('Liked post number 5'));
      await tester.pumpAndSettle();

      expect(find.text('post page ${postId(5)}'), findsOneWidget);
    });

    testWidgets('pull down asks again and replaces page 1', (tester) async {
      server.pages[''] = () => likesPage([5, 4]);
      await open(tester, location: '/bookmarks?tab=likes');
      server.pages[''] = () => likesPage([9]);

      await tester.fling(
        find.byType(PostCard).first,
        const Offset(0, 400),
        800,
      );
      await tester.pumpAndSettle();

      expect(server.listTokens, ['', '']);
      expect(rows(), findsOneWidget);
      expect(find.text('Liked post number 9'), findsOneWidget);
    });

    testWidgets('with engagement off the rows list with no action row, '
        'whatever liked_by_viewer says', (tester) async {
      server.pages[''] = () =>
          likesPageOf([likedView(5, liked: false), likedView(4, liked: false)]);
      await open(
        tester,
        flags: const {'posts', 'likes_list'},
        location: '/bookmarks?tab=likes',
      );

      expect(rows(), findsNWidgets(2));
      expect(likedHearts(), findsNothing);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
    });
  });

  group('copy', () {
    testWidgets('empty: says the 1,000 most recent are kept', (tester) async {
      await open(tester, location: '/bookmarks?tab=likes');

      expect(find.text(kLikesEmptyTitle), findsOneWidget);
      expect(find.text(kLikesEmptyBody), findsOneWidget);
      expect(kLikesEmptyBody, contains('1,000 most recent'));
      expect(rows(), findsNothing);
      expect(find.text(kLikesEndNote), findsNothing);
    });

    testWidgets('end: the note under the last row states the limit, and only '
        'once there is no next page', (tester) async {
      server.pages[''] = () => likesPage([5, 4], 't1');
      server.pages['t1'] = () => likesPage([3]);
      await open(
        tester,
        location: '/bookmarks?tab=likes',
        size: const Size(390, 2000),
      );

      expect(server.listTokens, ['', 't1']);
      expect(rows(), findsNWidgets(3));
      expect(find.text(kLikesEndNote), findsOneWidget);
      expect(kLikesEndNote, contains('1,000 most recent'));
    });

    testWidgets('no end note while more pages exist', (tester) async {
      final gate = Completer<void>();
      server.pages[''] = () => likesPage([5, 4], 't1');
      server.pages['t1'] = () async {
        await gate.future;
        return likesPage([3]);
      };
      await open(
        tester,
        location: '/bookmarks?tab=likes',
        size: const Size(390, 2000),
        settle: false,
      );
      await tester.pump();
      await tester.pump();

      expect(find.text(kLikesEndNote), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text(kLikesEndNote), findsOneWidget);
    });

    testWidgets('the loading skeleton is announced', (tester) async {
      final handle = tester.ensureSemantics();
      final gate = Completer<void>();
      server.pages[''] = () async {
        await gate.future;
        return likesPage([5]);
      };
      await open(tester, location: '/bookmarks?tab=likes', settle: false);

      expect(find.bySemanticsLabel('Loading likes'), findsOneWidget);
      expect(find.text(kLikesEmptyTitle), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Loading likes'), findsNothing);
      handle.dispose();
    });
  });

  group('paging', () {
    testWidgets('a short page with a token fills the screen by asking again, '
        'through empty pages, until the token is empty', (tester) async {
      server.pages[''] = () => likesPage([4], 't1');
      server.pages['t1'] = () => likesPage(const [], 't2');
      server.pages['t2'] = () => likesPage([3, 2], 't3');
      server.pages['t3'] = () => likesPage([1]);
      await open(tester, location: '/bookmarks?tab=likes');

      expect(server.listTokens, ['', 't1', 't2', 't3']);
      expect(rows(), findsNWidgets(4));
      expect(find.text(kLikesEmptyTitle), findsNothing);
    });

    testWidgets('a first page with no row but a token never claims empty', (
      tester,
    ) async {
      server.pages[''] = () => likesPage(const [], 't1');
      server.pages['t1'] = () => likesPage([1]);
      await open(tester, location: '/bookmarks?tab=likes');

      expect(rows(), findsOneWidget);
      expect(find.text(kLikesEmptyTitle), findsNothing);
    });

    testWidgets('pages that end empty show the empty state only then', (
      tester,
    ) async {
      server.pages[''] = () => likesPage(const [], 't1');
      server.pages['t1'] = () => likesPage(const []);
      await open(tester, location: '/bookmarks?tab=likes');

      expect(find.text(kLikesEmptyTitle), findsOneWidget);
    });

    testWidgets('a long list prefetches the next page near the end only, and '
        'drops a row it already has', (tester) async {
      server.pages[''] = () =>
          likesPage([for (var n = 30; n > 10; n--) n], 't1');
      server.pages['t1'] = () => likesPage([11, 10, 9, 8, 7, 6]);
      await open(tester, location: '/bookmarks?tab=likes');
      expect(server.listTokens, ['']);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
      await tester.pumpAndSettle();

      expect(server.listTokens, ['', 't1']);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -9000));
      await tester.pumpAndSettle();
      expect(server.listTokens, ['', 't1'], reason: 'the token ended it');
      expect(find.text('Liked post number 6'), findsOneWidget);
      final cubit = BlocProvider.of<LikesListCubit>(
        tester.element(find.byType(CustomScrollView)),
      );
      expect(cubit.state.items, hasLength(25), reason: '30..6, 11 once');
    });

    testWidgets('a failed next page keeps the rows, with a Retry', (
      tester,
    ) async {
      server.pages[''] = () =>
          likesPage([for (var n = 30; n > 10; n--) n], 't1');
      server.pages['t1'] = () => throw serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );
      await open(tester, location: '/bookmarks?tab=likes');

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
      await tester.pumpAndSettle();

      expect(
        find.text("You're offline. Showing the likes already loaded."),
        findsOneWidget,
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(server.listTokens, ['', 't1']);

      server.pages['t1'] = () => likesPage([5]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(server.listTokens, ['', 't1', 't1']);
    });
  });

  group('un-liking', () {
    testWidgets('the heart removes the row at once and asks UnlikePost', (
      tester,
    ) async {
      server.pages[''] = () => likesPage([3, 2, 1]);
      await open(tester, location: '/bookmarks?tab=likes');

      await tester.tap(likedHearts().at(1));
      await tester.pump();

      expect(rows(), findsNWidgets(2));
      expect(find.text('Liked post number 2'), findsNothing);
      await tester.pumpAndSettle();
      final request = server.toggles.single as eng.UnlikePostRequest;
      expect(request.postId, postId(2));
      expect(rows(), findsNWidgets(2));
    });

    testWidgets('the last row going shows the empty state', (tester) async {
      server.pages[''] = () => likesPage([1]);
      await open(tester, location: '/bookmarks?tab=likes');

      await tester.tap(likedHearts());
      await tester.pumpAndSettle();

      expect(rows(), findsNothing);
      expect(find.text(kLikesEmptyTitle), findsOneWidget);
    });

    testWidgets('a failed unlike puts the row back and says why, once', (
      tester,
    ) async {
      server.pages[''] = () => likesPage([2, 1]);
      await open(tester, location: '/bookmarks?tab=likes');
      server.toggleError = serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await tester.tap(likedHearts().first);
      await tester.pumpAndSettle();

      expect(rows(), findsNWidgets(2));
      expect(
        find.text(
          engagementErrorMessage(
            const NetworkException('x'),
            action: EngagementAction.unlike,
          ),
        ),
        findsOneWidget,
      );
      expect(engagement.state.failure, isNull, reason: 'shown, then cleared');
    });

    testWidgets('re-opening the tab within a minute does not bring the row '
        'back, even if the server still lists it', (tester) async {
      server.pages[''] = () => likesPage([3, 2, 1]);
      await open(tester, location: '/bookmarks?tab=likes');
      await tester.tap(likedHearts().at(1));
      await tester.pumpAndSettle();

      // A fresh visit: page 1 again, with the stale row still in it.
      router.pop();
      await tester.pumpAndSettle();
      unawaited(router.push('/bookmarks?tab=likes'));
      await tester.pumpAndSettle();

      expect(server.listTokens, ['', '']);
      expect(find.text('Liked post number 3'), findsOneWidget);
      expect(find.text('Liked post number 2'), findsNothing);
    });
  });

  group('errors', () {
    testWidgets('a failed first page: the error view, Retry loads again', (
      tester,
    ) async {
      server.pages[''] = () => throw serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );
      await open(tester, location: '/bookmarks?tab=likes');
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      server.pages[''] = () => likesPage([1]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(rows(), findsOneWidget);
      expect(server.listTokens, ['', '']);
    });

    testWidgets('a failed refresh keeps the rows under a banner', (
      tester,
    ) async {
      server.pages[''] = () => likesPage([2, 1]);
      await open(tester, location: '/bookmarks?tab=likes');
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
        find.text("You're offline. Showing the likes already loaded."),
        findsOneWidget,
      );
    });

    testWidgets('the 10/min bucket answers with friendly words and no Retry '
        'loop; Bookmarks is not held with it', (tester) async {
      server.pages[''] = () => throw serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      );
      bookmarks.pages[''] = () => bookmarksPage([2, 1]);
      await open(tester, location: '/bookmarks?tab=likes');

      expect(
        find.text(rateLimitedMessage(const RateLimitedException('slow down'))),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsNothing);

      await tester.tap(tab('Bookmarks'));
      await tester.pumpAndSettle();
      expect(rows(), findsNWidgets(2));
    });

    testWidgets('FEATURE_DISABLED hides the tab: Bookmarks shows, no error '
        'text', (tester) async {
      bookmarks.pages[''] = () => bookmarksPage([2, 1]);
      server.pages[''] = () => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureLikesList},
      );
      await open(tester);
      await selectLikes(tester);

      expect(tabBar(), findsNothing);
      expect(find.byType(AppErrorView), findsNothing);
      expect(find.text(kLikesUnavailableTitle), findsNothing);
      expect(find.text('post 2'), findsOneWidget);
      expect(rows(), findsNWidgets(2));
    });

    testWidgets('UNIMPLEMENTED (dev before the server ships) hides the tab '
        'quietly: one call, nothing reported', (tester) async {
      bookmarks.pages[''] = () => bookmarksPage([2, 1]);
      server.pages[''] = () => throw connect.ConnectException(
        connect.Code.unimplemented,
        'ListLikedPosts is not implemented yet',
      );
      await open(tester, location: '/bookmarks?tab=likes');

      expect(tabBar(), findsNothing);
      expect(find.text('post 2'), findsOneWidget);
      expect(server.listCalls, 1);
      expect(reported, 0);
      expect(likesRepo.available, isFalse);
    });
  });

  group('flags mid-visit', () {
    testWidgets('likes_list turning off while Likes is showing falls back to '
        'Bookmarks', (tester) async {
      bookmarks.pages[''] = () => bookmarksPage([2, 1]);
      server.pages[''] = () => likesPage([5]);
      await open(tester, location: '/bookmarks?tab=likes');
      expect(find.text('Liked post number 5'), findsOneWidget);

      features = {..._flagOff};
      onboardingStates.add(
        OnboardingState(
          status: OnboardingStatus.ready,
          enabledFeatures: features,
          profile: identity.Profile(userId: 'me', handle: 'me'),
        ),
      );
      await tester.pumpAndSettle();

      expect(tabBar(), findsNothing);
      expect(find.text('Liked post number 5'), findsNothing);
      expect(find.text('post 2'), findsOneWidget);
    });
  });

  group('sign-out', () {
    testWidgets('the rows are cleared, and a page landing after is dropped', (
      tester,
    ) async {
      final gate = Completer<void>();
      server.pages[''] = () => likesPage([4, 3], 't1');
      server.pages['t1'] = () async {
        await gate.future;
        return likesPage([0]);
      };
      await open(
        tester,
        location: '/bookmarks?tab=likes',
        size: const Size(390, 300),
      );
      expect(rows(), findsWidgets);

      // What AppWidget does on sign-out.
      engagement.reset();
      likesRepo.clearSession();
      epoch.end();
      await tester.pumpAndSettle();

      expect(rows(), findsNothing);
      expect(find.text(kLikesEmptyTitle), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(rows(), findsNothing);
    });
  });

  group('layout', () {
    forEachThemeAndWidth(
      'Likes tab, tab bar and header fit',
      (tester, env) async {
        server.pages[''] = () => likesPageOf([
          likedView(
            3,
            text:
                'A long liked post that wraps over several lines so the row '
                'grows with the text size and must never overflow the column '
                'it sits in, at any width.',
          ),
          likedView(2),
          likedView(1),
        ]);
        await open(
          tester,
          location: '/bookmarks?tab=likes',
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        expect(rows(), findsWidgets);
        expect(tab('Bookmarks'), findsOneWidget);
        expect(tab('Likes'), findsOneWidget);
        expect(find.text('History'), findsWidgets);
        final header = tester.getSize(find.byType(AppBackHeader)).width;
        expect(header, lessThanOrEqualTo(AppLayout.mainColumnMaxWidth));
        // A target of at least 48dp: the tab row is the 53dp header row.
        expect(tester.getSize(tab('Likes')).height, greaterThan(0));
        expect(
          tester.getSize(find.byType(AppTabBar)).height,
          greaterThanOrEqualTo(48),
        );
      },
      textScales: const [1.0, 1.3, 2.0],
      height: 900,
    );

    forEachThemeAndWidth('empty Likes state fits', (tester, env) async {
      await open(
        tester,
        location: '/bookmarks?tab=likes',
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );

      expect(tester.takeException(), isNull);
      expect(find.text(kLikesEmptyTitle), findsOneWidget);
    }, textScales: const [1.0, 2.0]);
  });
}
