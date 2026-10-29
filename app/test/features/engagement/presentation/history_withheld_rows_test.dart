import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
import 'package:dzeroth/features/engagement/presentation/bookmarks_screen.dart';
import 'package:dzeroth/features/engagement/presentation/engagement_error_messages.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:dzeroth/shared/widgets/post_media.dart';
import 'package:dzeroth/shared/widgets/protected_post_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/bookmarks_fixtures.dart';
import '../../../support/fake_transport.dart';
import '../../../support/geometry.dart';
import '../../../support/likes_fixtures.dart';
import '../../../support/owner_placeholder_fixtures.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockPostsRepository extends Mock implements PostsRepository {}

// `private_accounts` is deliberately absent from every set: an undo is never
// gated on it (ADR-0025).
const _allFlags = {'posts', 'engagement', 'replies', 'bookmarks', 'likes_list'};
const _message = 'This post is from an account that protects its posts.';

/// W3-41b: the History screen's rows the server withheld (`PostView.withheld`,
/// the caller's own Likes and Bookmarks of a protected author they can no
/// longer see): the protected box with Unlike or Remove bookmark, no card, no
/// thread entry, an optimistic removal that rolls back with the existing copy.
/// Real cubits and repositories over scripted `ListLikedPosts`,
/// `ListBookmarks`, `UnlikePost` and `RemoveBookmark`.
void main() {
  late FakeBookmarksServer bookmarks;
  late FakeLikesServer likes;
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

  /// The ids the Unlike / Remove requests carried, in order.
  late List<String> unliked;

  setUp(() {
    bookmarks = FakeBookmarksServer();
    likes = FakeLikesServer(bookmarks: bookmarks);
    epoch = SessionEpoch();
    unliked = [];
    features = {..._allFlags};
    // Unlike answers the missing-post shape W3-40a returns for a post the
    // caller may no longer see: the post id and zero counts, not liked.
    client = ApiClient.withTransport(
      FakeTransport((procedure, input) async {
        final answer = await likes.handle(procedure, input);
        if (procedure == likesUnlikeProcedure) {
          final id = (input as eng.UnlikePostRequest).postId;
          unliked.add(id);
          return eng.UnlikePostResponse(
            engagement: eng.PostEngagement(postId: id),
          );
        }
        return answer;
      }),
    );
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
    );
    onboarding = _MockOnboardingBloc();
    onboardingStates = StreamController<OnboardingState>.broadcast();
    posts = _MockPostsRepository();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() {
    unawaited(onboardingStates.close());
    unawaited(engagement.close());
    unawaited(overlay.close());
    unawaited(bookmarksRepo.dispose());
    unawaited(likesRepo.dispose());
  });

  Future<void> open(
    WidgetTester tester, {
    Set<String>? flags,
    String location = '/bookmarks',
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    if (flags != null) features = {...flags};
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
    await tester.pumpAndSettle();
  }

  Finder cards() => find.byType(PostCard);
  Finder boxes() => find.byType(ProtectedPostBox);
  Finder button(String label) => find.widgetWithText(OutlinedButton, label);

  /// The withheld row of [withheldView]`(leak: true)` shows its author and
  /// nothing else: no text, hashtag, count or photo.
  void expectNothingLeaked(WidgetTester tester) {
    expect(find.text('secret words that must not show'), findsNothing);
    expect(find.textContaining('secrettag'), findsNothing);
    expect(find.text('4242'), findsNothing);
    expect(find.byType(PostMedia), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is CachedNetworkImage &&
            (w.imageUrl.contains('full.jpg') ||
                w.imageUrl.contains('thumb.jpg')),
      ),
      findsNothing,
    );
    expect(find.text('Locked Author 2'), findsOneWidget);
  }

  /// The Likes page of the tests: a live post, a withheld one and a live one.
  void scriptLikes() {
    likes.pages[''] = () =>
        likesPageOf([likedView(3), withheldView(2), likedView(1)]);
  }

  /// The Bookmarks page: a live post, a withheld one and a live one.
  void scriptBookmarks() {
    bookmarks.pages[''] = () => bookmarksPageOf([
      postView(3)..bookmarkedByViewer = true,
      withheldView(2, liked: false, bookmarked: true),
      postView(1)..bookmarkedByViewer = true,
    ]);
  }

  group('Likes tab', () {
    forEachThemeAndWidth(
      'a withheld like: the box and one 48dp Unlike, no card',
      (tester, env) async {
        scriptLikes();
        await open(
          tester,
          location: '/bookmarks?tab=likes',
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull);
        // The two live posts are cards; the withheld one is only a box.
        expect(cards(), findsNWidgets(2));
        expect(boxes(), findsOneWidget);
        expect(find.text('Locked Author 2'), findsOneWidget);
        expect(find.text('@locked2'), findsOneWidget);
        expect(find.text(_message), findsOneWidget);
        expect(button('Unlike'), findsOneWidget);
        expectMinTarget(tester, button('Unlike'));
        expectInsideHorizontally(tester, button('Unlike'), env.size.width);
        expectInsideHorizontally(tester, boxes(), env.size.width);
        // No action row inside the placeholder.
        expect(
          find.descendant(of: boxes(), matching: find.byType(PostActionBar)),
          findsNothing,
        );
      },
      textScales: kMatrixTextScalesLarge,
      height: 900,
    );

    testWidgets('tapping the box opens no thread (it would answer NOT_FOUND)', (
      tester,
    ) async {
      scriptLikes();
      await open(tester, location: '/bookmarks?tab=likes');

      await tester.tap(find.text('Locked Author 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_message));
      await tester.pumpAndSettle();

      expect(find.textContaining('post page'), findsNothing);
      expect(boxes(), findsOneWidget);
    });

    testWidgets('Unlike removes the row at once, asks UnlikePost with the '
        'withheld id, and the missing-post answer is a success', (
      tester,
    ) async {
      scriptLikes();
      final gate = likes.toggleGate = Completer<void>();
      await open(tester, location: '/bookmarks?tab=likes');

      await tester.tap(button('Unlike'));
      await tester.pump();

      expect(boxes(), findsNothing);
      expect(cards(), findsNWidgets(2));

      gate.complete();
      await tester.pumpAndSettle();

      expect(unliked, [postId(2)]);
      expect(boxes(), findsNothing);
      expect(cards(), findsNWidgets(2));
      expect(find.byType(SnackBar), findsNothing);
      expect(engagement.state.failure, isNull);
    });

    testWidgets('a failed Unlike puts the box back and says why, once', (
      tester,
    ) async {
      scriptLikes();
      await open(tester, location: '/bookmarks?tab=likes');
      likes.toggleError = serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await tester.tap(button('Unlike'));
      await tester.pumpAndSettle();

      expect(boxes(), findsOneWidget);
      expect(button('Unlike'), findsOneWidget);
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

    testWidgets('the last row going shows the empty state', (tester) async {
      likes.pages[''] = () => likesPageOf([withheldView(2)]);
      await open(tester, location: '/bookmarks?tab=likes');

      await tester.tap(button('Unlike'));
      await tester.pumpAndSettle();

      expect(boxes(), findsNothing);
      expect(find.text('No likes yet'), findsOneWidget);
    });

    testWidgets('`engagement` off: the box shows, with no Unlike (the heart is '
        'not offered either)', (tester) async {
      scriptLikes();
      await open(
        tester,
        location: '/bookmarks?tab=likes',
        flags: {'posts', 'bookmarks', 'likes_list'},
      );

      expect(boxes(), findsOneWidget);
      expect(button('Unlike'), findsNothing);
      expect(likes.toggles, isEmpty);
    });

    testWidgets('a withheld row keeps a stable key, so a refresh keeps '
        'its place', (tester) async {
      scriptLikes();
      await open(tester, location: '/bookmarks?tab=likes');

      expect(find.byKey(ValueKey('like-${postId(2)}')), findsOneWidget);
    });
    testWidgets('the Unlike button is one labelled node naming the author', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      scriptLikes();
      await open(tester, location: '/bookmarks?tab=likes');

      expect(
        tester.getSemantics(button('Unlike')),
        matchesSemantics(
          label: "Unlike, @locked2's post",
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();
    });

    testWidgets('two quick taps on Unlike send ONE request', (tester) async {
      scriptLikes();
      final gate = likes.toggleGate = Completer<void>();
      await open(tester, location: '/bookmarks?tab=likes');

      // No frame between the taps: the second lands on the same button.
      await tester.tap(button('Unlike'));
      await tester.tap(button('Unlike'));
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();

      expect(likes.toggles, hasLength(1));
      expect(unliked, [postId(2)]);
      expect(boxes(), findsNothing);
    });

    testWidgets('a withheld row shows none of what a hostile or older server '
        'could still send', (tester) async {
      likes.pages[''] = () =>
          likesPageOf([withheldView(2, leak: true), likedView(1)]);
      await open(tester, location: '/bookmarks?tab=likes');

      expect(boxes(), findsOneWidget);
      expectNothingLeaked(tester);
    });
  });

  group('Bookmarks tab', () {
    forEachThemeAndWidth(
      'a withheld bookmark: the box and one 48dp Remove bookmark, no card',
      (tester, env) async {
        scriptBookmarks();
        await open(
          tester,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull);
        expect(cards(), findsNWidgets(2));
        expect(boxes(), findsOneWidget);
        expect(find.text('Locked Author 2'), findsOneWidget);
        expect(find.text(_message), findsOneWidget);
        expect(button('Remove bookmark'), findsOneWidget);
        expectMinTarget(tester, button('Remove bookmark'));
        expectInsideHorizontally(
          tester,
          button('Remove bookmark'),
          env.size.width,
        );
        expectInsideHorizontally(tester, boxes(), env.size.width);
      },
      textScales: kMatrixTextScalesLarge,
      height: 900,
    );

    testWidgets('tapping the box opens no thread', (tester) async {
      scriptBookmarks();
      await open(tester);

      await tester.tap(find.text('Locked Author 2'));
      await tester.pumpAndSettle();

      expect(find.textContaining('post page'), findsNothing);
      expect(boxes(), findsOneWidget);
    });

    testWidgets('Remove bookmark removes the row at once and asks '
        'RemoveBookmark; the toast has no Undo (AddBookmark would answer '
        'NOT_FOUND)', (tester) async {
      scriptBookmarks();
      final gate = bookmarks.toggleGate = Completer<void>();
      await open(tester);

      await tester.tap(button('Remove bookmark'));
      await tester.pump();
      expect(boxes(), findsNothing);
      expect(cards(), findsNWidgets(2));

      gate.complete();
      await tester.pumpAndSettle();

      final request = bookmarks.toggles.single as eng.RemoveBookmarkRequest;
      expect(request.postId, postId(2));
      expect(boxes(), findsNothing);
      expect(find.text('Removed from Bookmarks'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets(
      'removing a live bookmark still offers Undo (the contrast with a withheld one)',
      (tester) async {
        scriptBookmarks();
        // The answer comes after the frame that removed the card, as it does
        // over a real network: the card's own toast (no Undo) is then gone.
        final gate = bookmarks.toggleGate = Completer<void>();
        await open(tester);

        await tester.tap(find.byIcon(Icons.bookmark).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        gate.complete();
        await tester.pump();

        expect(find.text('Removed from Bookmarks'), findsOneWidget);
        expect(find.text('Undo'), findsOneWidget);
      },
    );

    testWidgets('a failed removal puts the box back and says why', (
      tester,
    ) async {
      scriptBookmarks();
      await open(tester);
      bookmarks.toggleError = serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await tester.tap(button('Remove bookmark'));
      await tester.pumpAndSettle();

      expect(boxes(), findsOneWidget);
      expect(
        find.text(
          engagementErrorMessage(
            const NetworkException('x'),
            action: EngagementAction.unbookmark,
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('`engagement` off: Remove bookmark is still offered (a '
        'removal needs only the bookmarks flag)', (tester) async {
      scriptBookmarks();
      await open(tester, flags: {'posts', 'bookmarks'});

      expect(button('Remove bookmark'), findsOneWidget);
      await tester.tap(button('Remove bookmark'));
      await tester.pumpAndSettle();
      expect(bookmarks.toggles.single, isA<eng.RemoveBookmarkRequest>());
      expect(boxes(), findsNothing);
    });

    testWidgets('the Remove bookmark button is one labelled node naming the '
        'author', (tester) async {
      final semantics = tester.ensureSemantics();
      scriptBookmarks();
      await open(tester);

      expect(
        tester.getSemantics(button('Remove bookmark')),
        matchesSemantics(
          label: "Remove bookmark, @locked2's post",
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();
    });

    testWidgets('two quick taps on Remove bookmark send ONE request', (
      tester,
    ) async {
      scriptBookmarks();
      final gate = bookmarks.toggleGate = Completer<void>();
      await open(tester);

      // No frame between the taps: the second lands on the same button.
      await tester.tap(button('Remove bookmark'));
      await tester.tap(button('Remove bookmark'));
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();

      expect(bookmarks.toggles, hasLength(1));
      expect(boxes(), findsNothing);
    });

    testWidgets('a withheld row shows none of what a hostile or older server '
        'could still send', (tester) async {
      bookmarks.pages[''] = () => bookmarksPageOf([
        withheldView(2, liked: false, bookmarked: true, leak: true),
        postView(1)..bookmarkedByViewer = true,
      ]);
      await open(tester);

      expect(boxes(), findsOneWidget);
      expectNothingLeaked(tester);
    });
  });
}
