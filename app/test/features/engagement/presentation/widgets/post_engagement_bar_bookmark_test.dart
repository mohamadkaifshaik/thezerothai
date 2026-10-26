import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:bloc_test/bloc_test.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/widgets/post_engagement_bar.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:dzeroth/shared/widgets/post_card.dart';

import '../../../../support/fake_transport.dart';
import '../../../../support/posts_fixtures.dart';

class MockEngagementRepository extends Mock implements EngagementRepository {}

class MockPostsRepository extends Mock implements PostsRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

pb.PostView _view() => pb.PostView(
  post: pb.Post(
    postId: postId(1),
    text: 'hello',
    author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
    likeCount: Int64(4),
    repostCount: Int64(2),
    replyCount: Int64(1),
  ),
);

pb.PostView _repostView() => pb.PostView(
  post: pb.Post(
    postId: postId(50),
    kind: PostKind.POST_KIND_REPOST,
    author: common.AuthorSnapshot(userId: 'u2', handle: 'bob'),
    embedded: pb.EmbeddedPost(
      postId: postId(1),
      text: 'original',
      author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
    ),
  ),
);

class _Call {
  _Call(this.procedure, this.input);

  final String procedure;
  final Object input;
  final Completer<Object> answer = Completer<Object>();

  String get sentPostId => switch (input) {
    eng.AddBookmarkRequest(:final postId) => postId,
    eng.RemoveBookmarkRequest(:final postId) => postId,
    _ => '',
  };

  void ok({required bool bookmarked}) => answer.complete(
    bookmarked
        ? eng.AddBookmarkResponse(
            state: eng.BookmarkState(postId: postId(1), bookmarked: true),
          )
        : eng.RemoveBookmarkResponse(
            state: eng.BookmarkState(postId: postId(1), bookmarked: false),
          ),
  );
}

void main() {
  late MockEngagementRepository engagementRepo;
  late MockPostsRepository posts;
  late MockOnboardingBloc onboarding;
  late EngagementCubit engagement;
  late BookmarksRepository bookmarksRepo;
  late BookmarksCubit cubit;
  late SessionEpoch epoch;
  late List<_Call> calls;
  String? pushed;

  setUp(() {
    engagementRepo = MockEngagementRepository();
    posts = MockPostsRepository();
    onboarding = MockOnboardingBloc();
    engagement = EngagementCubit(repository: engagementRepo);
    calls = [];
    pushed = null;
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    bookmarksRepo = BookmarksRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) {
          final call = _Call(procedure, input);
          calls.add(call);
          return call.answer.future;
        }),
      ),
      gate: ServiceFeatureGate(isEnabled: () => true),
      epoch: epoch = SessionEpoch(),
    );
  });

  tearDown(() async {
    await engagement.close();
    await cubit.close();
    await bookmarksRepo.dispose();
  });

  Future<void> pump(
    WidgetTester tester,
    pb.PostView view, {
    Set<String> features = const {'engagement', 'replies', 'bookmarks'},
    bool? serverState,
    String? viewRoute,
    double width = 400,
    double textScale = 1,
    int bars = 1,
    ThemeData? theme,
    bool? bookmarkEnabled,
    String initialLocation = '/',
    bool barOnBookmarksRoute = false,
    List<pb.PostView>? views,
    Stream<OnboardingState>? onboardingStream,
  }) async {
    whenListen(
      onboarding,
      onboardingStream ?? const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: features,
      ),
    );
    cubit = BookmarksCubit(
      repository: bookmarksRepo,
      viewRoute: viewRoute,
      serverStateOf: (_) => serverState,
    );
    Widget page() => Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (views != null)
                for (final v in views)
                  PostEngagementBar(view: v, bookmarkEnabled: bookmarkEnabled)
              else
                for (var i = 0; i < bars; i++)
                  PostEngagementBar(view: view, bookmarkEnabled: bookmarkEnabled),
            ],
          ),
        ),
      ),
    );
    final router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(path: '/', builder: (context, state) => page()),
        GoRoute(
          path: '/bookmarks',
          builder: (context, state) {
            pushed = state.uri.toString();
            return barOnBookmarksRoute
                ? page()
                : const Scaffold(body: Text('bookmarks page'));
          },
        ),
      ],
    );
    await tester.pumpWidget(
      RepositoryProvider<PostsRepository>.value(
        value: posts,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<EngagementCubit>.value(value: engagement),
            BlocProvider<BookmarksCubit>.value(value: cubit),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: theme ?? appDarkTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder outline() => find.byIcon(Icons.bookmark_border);
  Finder filled() => find.byIcon(Icons.bookmark);

  testWidgets('flag off: no bookmark icon and the cubit is never read', (
    tester,
  ) async {
    await pump(tester, _view(), features: const {'engagement', 'replies'});
    expect(outline(), findsNothing);
    expect(filled(), findsNothing);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets('flag on: an outline icon at the right of the row, no Share', (
    tester,
  ) async {
    await pump(tester, _view());
    expect(outline(), findsOneWidget);
    expect(find.byIcon(Icons.ios_share), findsNothing);

    final like = tester.getTopLeft(find.byIcon(Icons.favorite_border)).dx;
    final bookmark = tester.getTopLeft(outline()).dx;
    final rowRight = tester.getBottomRight(find.byType(PostEngagementBar)).dx;
    expect(bookmark, greaterThan(like));
    // Flush with the right edge of the row (48dp box, icon at its end).
    expect(rowRight - tester.getBottomRight(outline()).dx, lessThan(1));
    expect(tester.getSize(outline()), const Size(16, 16));
  });

  testWidgets('semantics: "Bookmark", a 48dp button; "Bookmarked" is selected '
      'and accent', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, _view());

    final off = tester.getSemantics(find.bySemanticsLabel('Bookmark'));
    expect(off.flagsCollection.isButton, isTrue);
    expect(off.flagsCollection.isSelected, Tristate.isFalse);
    expect(off.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(off.rect.size.shortestSide, greaterThanOrEqualTo(48));
    expect(
      tester.widget<Icon>(outline()).color,
      isNot(appDarkTheme.colorScheme.primary),
    );

    await tester.pumpWidget(const SizedBox());
    await pump(tester, _view(), serverState: true);
    final on = tester.getSemantics(find.bySemanticsLabel('Bookmarked'));
    expect(on.flagsCollection.isSelected, Tristate.isTrue);
    expect(on.rect.size.shortestSide, greaterThanOrEqualTo(48));
    expect(tester.widget<Icon>(filled()).color, const Color(0xFF1D9BF0));
    handle.dispose();
  });

  testWidgets('tap is optimistic, sends one AddBookmark, then toasts '
      '"Added to Bookmarks" with no View action while /bookmarks does '
      'not exist', (tester) async {
    await pump(tester, _view());

    await tester.tap(outline());
    await tester.pump();

    expect(filled(), findsOneWidget);
    expect(outline(), findsNothing);
    expect(calls, hasLength(1));
    expect(calls.single.sentPostId, postId(1));
    expect(find.text('Added to Bookmarks'), findsNothing);

    calls.single.ok(bookmarked: true);
    await tester.pumpAndSettle();

    expect(filled(), findsOneWidget);
    expect(find.text('Added to Bookmarks'), findsOneWidget);
    expect(find.text('View'), findsNothing);
    expect(cubit.state.notice, isNull, reason: 'cleared once shown');
  });

  testWidgets('bookmarkEnabled: true shows the icon with the flag off '
      '(a caller dropped from the allowlist can still remove)', (tester) async {
    await pump(
      tester,
      _view(),
      features: const {'engagement', 'replies'},
      serverState: true,
      bookmarkEnabled: true,
    );
    expect(filled(), findsOneWidget);

    await tester.tap(filled());
    await tester.pump();
    expect(calls.single.input, isA<eng.RemoveBookmarkRequest>());
    calls.single.ok(bookmarked: false);
    await tester.pumpAndSettle();
    expect(outline(), findsOneWidget);
  });

  testWidgets('bookmarkEnabled: false hides the icon even with the flag on', (
    tester,
  ) async {
    await pump(tester, _view(), bookmarkEnabled: false);
    expect(outline(), findsNothing);
    expect(filled(), findsNothing);
  });

  testWidgets('no View action on the page View points to', (tester) async {
    await pump(
      tester,
      _view(),
      viewRoute: '/bookmarks',
      initialLocation: '/bookmarks',
      barOnBookmarksRoute: true,
    );

    await tester.tap(outline());
    await tester.pump();
    calls.single.ok(bookmarked: true);
    await tester.pumpAndSettle();

    expect(find.text('Added to Bookmarks'), findsOneWidget);
    expect(find.text('View'), findsNothing);
  });

  testWidgets('a card under another page stays quiet: only the page on top '
      'toasts', (tester) async {
    await pump(tester, _view(), viewRoute: '/bookmarks');
    final router = GoRouter.of(tester.element(find.byType(PostEngagementBar)));
    unawaited(router.push('/bookmarks'));
    await tester.pumpAndSettle();
    expect(find.text('bookmarks page'), findsOneWidget);

    // The bookmark lands while the other page is on top.
    unawaited(cubit.setBookmarked(postId(1), _view(), saved: true));
    await tester.pump();
    calls.single.ok(bookmarked: true);
    await tester.pumpAndSettle();

    expect(find.text('Added to Bookmarks'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('with a view route the toast has a View action that opens it', (
    tester,
  ) async {
    await pump(tester, _view(), viewRoute: '/bookmarks');

    await tester.tap(outline());
    await tester.pump();
    calls.single.ok(bookmarked: true);
    await tester.pumpAndSettle();

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(pushed, '/bookmarks');
    expect(find.text('bookmarks page'), findsOneWidget);
  });

  testWidgets('removing: outline at once, RemoveBookmark, "Removed from '
      'Bookmarks" without an action', (tester) async {
    await pump(tester, _view(), serverState: true, viewRoute: '/bookmarks');
    expect(filled(), findsOneWidget);

    await tester.tap(filled());
    await tester.pump();

    expect(outline(), findsOneWidget);
    expect(calls.single.procedure, endsWith('RemoveBookmark'));
    calls.single.ok(bookmarked: false);
    await tester.pumpAndSettle();

    expect(find.text('Removed from Bookmarks'), findsOneWidget);
    expect(find.text('View'), findsNothing);
  });

  testWidgets('a REPOST row bookmarks the original post', (tester) async {
    await pump(tester, _repostView());

    await tester.tap(outline());
    await tester.pump();

    expect(calls.single.sentPostId, postId(1));
  });

  testWidgets('a REPOST row of an unavailable original has no action row', (
    tester,
  ) async {
    final view = _repostView()..post.embedded.unavailable = true;
    await pump(tester, view);
    expect(outline(), findsNothing);
  });

  group('failures roll back with friendly text', () {
    Future<void> failWith(WidgetTester tester, Object error) async {
      await pump(tester, _view());
      await tester.tap(outline());
      await tester.pump();
      calls.single.answer.completeError(error);
      await tester.pumpAndSettle();
      // Rolled back.
      expect(outline(), findsOneWidget);
      expect(filled(), findsNothing);
      expect(cubit.state.failure, isNull, reason: 'cleared once shown');
    }

    testWidgets('LIMIT_REACHED limit=bookmarks', (tester) async {
      await failWith(
        tester,
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
          metadata: {'limit': 'bookmarks'},
        ),
      );
      expect(find.text('You can save up to 1,000 posts.'), findsOneWidget);
    });

    testWidgets('QUOTA_EXCEEDED quota=bookmarks', (tester) async {
      await failWith(
        tester,
        serverError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_QUOTA_EXCEEDED,
          metadata: {'quota': 'bookmarks'},
        ),
      );
      expect(
        find.text(
          "You've reached today's limit for saving posts. It resets tomorrow.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('FEATURE_DISABLED feature=bookmarks', (tester) async {
      await failWith(
        tester,
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          metadata: {'feature': 'bookmarks'},
        ),
      );
      expect(find.text("Bookmarks aren't available yet."), findsOneWidget);
    });

    testWidgets('rate limited', (tester) async {
      await failWith(
        tester,
        serverError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        ),
      );
      expect(
        find.text(
          "You're doing that a bit too fast. Give it a moment and try again.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('network', (tester) async {
      await failWith(
        tester,
        connect.ConnectException(connect.Code.unavailable, 'offline'),
      );
      expect(find.textContaining('No connection'), findsOneWidget);
    });
  });

  testWidgets('a failed remove rolls back to filled', (tester) async {
    await pump(tester, _view(), serverState: true);
    await tester.tap(filled());
    await tester.pump();
    expect(outline(), findsOneWidget);
    calls.single.answer.completeError(
      serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      ),
    );
    await tester.pumpAndSettle();
    expect(filled(), findsOneWidget);
    expect(find.textContaining('a bit too fast'), findsOneWidget);
  });

  testWidgets('two cards of the same post show the same state', (tester) async {
    // Both bars are mounted at once (a card in the feed and the same post
    // elsewhere): the session overlay is shared, so one tap flips both, and
    // only one toast shows.
    await pump(tester, _view(), bars: 2);
    expect(outline(), findsNWidgets(2));

    await tester.tap(outline().first);
    await tester.pump();
    expect(filled(), findsNWidgets(2));
    expect(outline(), findsNothing);
    expect(calls, hasLength(1));

    calls.single.ok(bookmarked: true);
    await tester.pumpAndSettle();
    expect(filled(), findsNWidgets(2));
    expect(find.text('Added to Bookmarks'), findsOneWidget);
  });

  testWidgets('bookmarks on but engagement off: the card has no action row, '
      'so no bookmark icon', (tester) async {
    // No providers at all: with engagement off the card must not even look
    // up the bookmark flag or cubit.
    await tester.pumpWidget(
      MaterialApp(
        theme: appDarkTheme,
        home: Scaffold(body: PostCard(view: _view())),
      ),
    );
    expect(outline(), findsNothing);
    expect(filled(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final width in [360.0, 320.0]) {
    testWidgets('five-slot row fits at ${width.toInt()}dp and text scale 2.0', (
      tester,
    ) async {
      await pump(tester, _view(), width: width, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(outline(), findsOneWidget);
    });
  }

  testWidgets('light theme: the filled icon is the accent', (tester) async {
    await pump(tester, _view(), serverState: true, theme: appLightTheme);
    expect(tester.widget<Icon>(filled()).color, const Color(0xFF1D9BF0));
  });

  // ---------------------------------------------------------------------
  // W2-13 (tester): responsive matrix, rapid taps, sign-out and flag drop on
  // the bookmark icon of the action row.
  // ---------------------------------------------------------------------

  group('W2-13 responsive matrix: action row with the bookmark icon', () {
    for (final dark in [false, true]) {
      for (final width in const [360.0, 600.0, 1200.0]) {
        for (final scale in const [1.0, 1.3, 2.0]) {
          testWidgets(
            '${dark ? 'dark' : 'light'} ${width.toInt()}dp x$scale: five slots '
            'inside the row, no overflow, 48dp target',
            (tester) async {
              tester.view.physicalSize = Size(width, 900);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
              final handle = tester.ensureSemantics();
              await pump(
                tester,
                _view(),
                serverState: true,
                width: width,
                textScale: scale,
                theme: dark ? appDarkTheme : appLightTheme,
              );

              expect(tester.takeException(), isNull);
              final row = tester.getRect(find.byType(PostEngagementBar));
              for (final icon in [
                Icons.chat_bubble_outline,
                Icons.repeat,
                Icons.favorite_border,
                Icons.bookmark,
              ]) {
                expect(find.byIcon(icon), findsOneWidget, reason: '$icon');
                final r = tester.getRect(find.byIcon(icon));
                expect(
                  row.inflate(0.5).contains(r.topLeft) &&
                      row.inflate(0.5).contains(r.bottomRight),
                  isTrue,
                  reason: '$icon at $r is outside the row $row',
                );
              }
              final target = tester.getSemantics(
                find.bySemanticsLabel('Bookmarked'),
              );
              expect(target.rect.size.shortestSide, greaterThanOrEqualTo(48));
              expect(
                tester.widget<Icon>(filled()).color,
                const Color(0xFF1D9BF0),
              );
              handle.dispose();
            },
          );
        }
      }
    }
  });

  testWidgets('W2-13: three rapid taps while the first request runs: the '
      'latest intent wins, one RPC, one toast', (tester) async {
    await pump(tester, _view());

    await tester.tap(outline()); // on: AddBookmark in flight
    await tester.pump();
    expect(calls, hasLength(1));
    await tester.tap(filled()); // off: only recorded
    await tester.pump();
    expect(outline(), findsOneWidget);
    await tester.tap(outline()); // on again: the same as in flight
    await tester.pump();
    expect(filled(), findsOneWidget);
    expect(calls, hasLength(1), reason: 'one request at a time per post');

    calls.single.ok(bookmarked: true);
    await tester.pumpAndSettle();

    expect(calls, hasLength(1), reason: 'the final intent equals the answer');
    expect(filled(), findsOneWidget);
    expect(find.text('Added to Bookmarks'), findsOneWidget);
  });

  testWidgets('W2-13: on then off while the first request runs: two RPCs with '
      'two keys, back where it started, no toast', (tester) async {
    await pump(tester, _view());

    await tester.tap(outline());
    await tester.pump();
    await tester.tap(filled());
    await tester.pump();
    expect(outline(), findsOneWidget);
    expect(calls, hasLength(1));

    calls[0].ok(bookmarked: true);
    await tester.pump();
    await tester.pump();
    expect(calls, hasLength(2), reason: 'the follow-up Remove');
    expect(calls[0].input, isA<eng.AddBookmarkRequest>());
    expect(calls[1].input, isA<eng.RemoveBookmarkRequest>());
    expect(
      (calls[0].input as eng.AddBookmarkRequest).idempotencyKey,
      isNot((calls[1].input as eng.RemoveBookmarkRequest).idempotencyKey),
    );
    expect(outline(), findsOneWidget, reason: 'no flash of the filled icon');

    calls[1].ok(bookmarked: false);
    await tester.pumpAndSettle();

    expect(outline(), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Added to Bookmarks'), findsNothing);
    expect(find.text('Removed from Bookmarks'), findsNothing);
  });

  testWidgets('W2-13: sign-out while the request runs: the late answer '
      'changes nothing and toasts nothing', (tester) async {
    await pump(tester, _view());
    await tester.tap(outline());
    await tester.pump();
    expect(calls, hasLength(1));

    // What AppWidget does on sign-out.
    cubit.reset();
    epoch.end();
    await tester.pump();
    expect(outline(), findsOneWidget);

    calls.single.ok(bookmarked: true);
    await tester.pumpAndSettle();

    expect(outline(), findsOneWidget, reason: "not the next user's state");
    expect(find.byType(SnackBar), findsNothing);
    expect(bookmarksRepo.snapshot(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('W2-13: sign-out while the request runs, then it fails: no '
      'error toast for the next user', (tester) async {
    await pump(tester, _view());
    await tester.tap(outline());
    await tester.pump();

    cubit.reset();
    epoch.end();
    await tester.pump();
    calls.single.answer.completeError(
      serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
    expect(cubit.state.failure, isNull);
    expect(outline(), findsOneWidget);
  });

  testWidgets('W2-13: a REPOST row and its original on screen share one '
      'entry: one tap flips both, one RPC for the original id, one toast', (
    tester,
  ) async {
    await pump(tester, _view(), views: [_repostView(), _view()]);
    expect(outline(), findsNWidgets(2));

    await tester.tap(outline().first); // the REPOST row's icon
    await tester.pump();
    expect(filled(), findsNWidgets(2));
    expect(calls, hasLength(1));
    expect(calls.single.sentPostId, postId(1));

    calls.single.ok(bookmarked: true);
    await tester.pumpAndSettle();
    expect(filled(), findsNWidgets(2));
    expect(find.text('Added to Bookmarks'), findsOneWidget);

    // Removing from the original's own card flips the REPOST row back.
    await tester.tap(filled().last);
    await tester.pump();
    expect(outline(), findsNWidgets(2));
    expect(calls, hasLength(2));
    expect(calls[1].input, isA<eng.RemoveBookmarkRequest>());
    expect(calls[1].sentPostId, postId(1));
    calls[1].ok(bookmarked: false);
    await tester.pumpAndSettle();
    expect(find.text('Removed from Bookmarks'), findsOneWidget);
  });

  testWidgets('W2-13: GetMe drops "bookmarks" while the Add is in flight: the '
      'icon goes with the flag, the late answer is harmless, it is back '
      'filled when the flag returns', (tester) async {
    final states = StreamController<OnboardingState>.broadcast();
    addTearDown(states.close);
    await pump(tester, _view(), onboardingStream: states.stream);
    await tester.tap(outline());
    await tester.pump();
    expect(calls, hasLength(1));

    states.add(
      const OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {'engagement', 'replies'},
      ),
    );
    await tester.pump();
    expect(outline(), findsNothing);
    expect(filled(), findsNothing);

    calls.single.ok(bookmarked: true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    states.add(
      const OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {'engagement', 'replies', 'bookmarks'},
      ),
    );
    await tester.pumpAndSettle();
    expect(filled(), findsOneWidget, reason: 'the add landed');
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'no stale toast replayed when the flag returns',
    );
  });
}
