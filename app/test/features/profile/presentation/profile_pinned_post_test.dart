import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockIdentityRepository extends Mock implements IdentityRepository {}

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// W3-17: the Pinned row on the profile's Posts tab and the Pin / Unpin rows
/// of an own post's menu.
void main() {
  late _MockIdentityRepository identityRepository;
  late _MockGraphRepository graphRepository;
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockOnboardingBloc onboardingBloc;
  late PendingPostsCubit pending;
  late StreamController<String> removed;
  late bool refused;

  const viewer = 'viewer-uid';
  const target = 'target-uid';

  const base = {'posts', 'replies', 'graph'};
  const withExtras = {'posts', 'replies', 'graph', 'profile_extras'};

  setUpAll(() {
    registerFallbackValue(const FeedKey.home());
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  setUp(() {
    identityRepository = _MockIdentityRepository();
    graphRepository = _MockGraphRepository();
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    onboardingBloc = _MockOnboardingBloc();
    pending = PendingPostsCubit();
    removed = StreamController<String>.broadcast();
    refused = false;
    when(() => graphRepository.cached(any())).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.sinceRefresh(any())).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
    when(() => identityRepository.profileExtrasRefused)
        .thenAnswer((_) => refused);
  });

  tearDown(() async {
    await pending.close();
    await removed.close();
  });

  /// A post as the server sends it: with its kind (the fixture leaves it
  /// unspecified, which is never pinnable).
  pb.PostView postOfKind(
    int n,
    String author, {
    PostKind kind = PostKind.POST_KIND_POST,
  }) {
    final view = postView(n, authorId: author);
    view.post.kind = kind;
    return view;
  }

  TimelineSnapshot snapshotWithKind(List<int> ids, String author) =>
      TimelineSnapshot(
        entries: [
          for (final id in ids)
            TimelineEntry.post(postId(id), postId(id), postOfKind(id, author)),
        ],
        sinceToken: 's',
        olderPageToken: '',
      );

  identity.Profile profileOf(
    String uid, {
    String pin = '',
    int postsCount = 0,
  }) => identity.Profile(
    userId: uid,
    handle: 'kaif',
    displayName: 'Kaif',
    postsCount: Int64(postsCount),
    pinnedPostId: pin,
  );

  /// A profile of [own] (the viewer) or [target] whose Posts tab holds the
  /// posts [rows] (newest first, authored by the profile's user) and whose
  /// pin is [pin] (a post number, 0 for none). `GetPost` answers any id with
  /// that post, unless [getPost] says otherwise.
  void arrange({
    bool own = true,
    Set<String> features = base,
    List<int> rows = const [3, 2, 1],
    int pin = 0,
    int postsCount = 3,
    Future<dynamic> Function(String id)? getPost,
    bool blocking = false,
  }) {
    final uid = own ? viewer : target;
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: viewer, handle: 'viewer'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => profileOf(
        uid,
        pin: pin == 0 ? '' : postId(pin),
        postsCount: postsCount,
      ),
    );
    when(() => graphRepository.profileRelationshipFor(uid)).thenAnswer(
      (_) async => ProfileRelationship(
        relationship: graph.Relationship(userId: uid, blocking: blocking),
      ),
    );
    final snapshot = snapshotWithKind(rows, uid);
    final feed = FeedKey.user(uid);
    when(() => timeline.cached(feed)).thenAnswer((_) async => snapshot);
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshot);
    final replies = FeedKey.user(uid, includeReplies: true);
    final repliesSnapshot = snapshotWithKind([101], uid);
    when(() => timeline.cached(replies))
        .thenAnswer((_) async => repliesSnapshot);
    when(() => timeline.refresh(replies))
        .thenAnswer((_) async => repliesSnapshot);
    when(() => posts.getPost(any())).thenAnswer((invocation) async {
      final id = invocation.positionalArguments.first as String;
      if (getPost != null) return await getPost(id);
      return postOfKind(int.parse(id), uid);
    });
  }

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<IdentityRepository>.value(
            value: identityRepository,
          ),
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp(
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const ProfileScreen(handle: 'kaif'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, Finder finder) =>
      tester.getTopLeft(finder).dy;

  /// The "more options" button of the card that shows [text].
  Finder menuOf(String text) => find.descendant(
    of: find.ancestor(of: find.text(text), matching: find.byType(PostCard)),
    matching: find.byTooltip('More options'),
  );

  Future<void> openMenuOf(WidgetTester tester, String text) async {
    await tester.tap(menuOf(text));
    await tester.pumpAndSettle();
  }

  /// Stubs the pin call to answer with a profile pinning [pin] (0: none).
  void answerPin(int pin, {String uid = viewer}) {
    when(
      () => identityRepository.updatePinnedPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        postId: any(named: 'postId'),
      ),
    ).thenAnswer((_) async => profileOf(uid, pin: pin == 0 ? '' : postId(pin)));
  }

  group('the Pinned row', () {
    testWidgets('sits above the posts and is not repeated below', (
      tester,
    ) async {
      arrange(pin: 2);
      await open(tester);

      expect(find.text('Pinned'), findsOneWidget);
      // Once, in the Pinned row: the feed below leaves it out.
      expect(find.text('post 2'), findsOneWidget);
      expect(find.text('post 3'), findsOneWidget);
      expect(find.text('post 1'), findsOneWidget);
      final pinned = top(tester, find.text('post 2'));
      expect(top(tester, find.text('Pinned')), lessThan(pinned));
      expect(pinned, lessThan(top(tester, find.text('post 3'))));
      verify(() => posts.getPost(postId(2))).called(1);
    });

    testWidgets('is absent without a pin and costs no GetPost', (tester) async {
      arrange();
      await open(tester);

      expect(find.text('Pinned'), findsNothing);
      expect(find.text('post 2'), findsOneWidget);
      verifyNever(() => posts.getPost(any()));
    });

    testWidgets('hides silently on NOT_FOUND and the feed stays whole', (
      tester,
    ) async {
      arrange(
        pin: 2,
        getPost: (_) async => throw const NotFoundException('gone'),
      );
      await open(tester);

      expect(find.text('Pinned'), findsNothing);
      expect(find.textContaining("Couldn't load"), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('post 3'), findsOneWidget);
      expect(find.text('post 1'), findsOneWidget);
      verify(() => posts.getPost(postId(2))).called(1);
    });

    testWidgets('a failed load says so with Retry and keeps the post below', (
      tester,
    ) async {
      var calls = 0;
      arrange(
        pin: 2,
        getPost: (id) async {
          calls++;
          if (calls == 1) throw const NetworkException('offline');
          return postOfKind(2, viewer);
        },
      );
      await open(tester);

      expect(find.text('Pinned'), findsOneWidget);
      expect(
        find.text(
          "You're offline. The pinned post will load when you're back.",
        ),
        findsOneWidget,
      );
      // Not lost: still listed with the others while the row failed.
      expect(find.text('post 2'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('post 2'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(
        top(tester, find.text('post 2')),
        lessThan(top(tester, find.text('post 3'))),
      );
      expect(calls, 2);
    });

    testWidgets('is only on the Posts tab', (tester) async {
      arrange(pin: 2);
      await open(tester);
      expect(find.text('Pinned'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(AppTabBar),
          matching: find.text('Replies'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pinned'), findsNothing);
      expect(find.text('post 101'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(AppTabBar),
          matching: find.text('Posts'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pinned'), findsOneWidget);
      // Back on Posts it is still one GetPost for the profile.
      verify(() => posts.getPost(postId(2))).called(1);
    });

    testWidgets('renders for another profile whatever the viewer flags are', (
      tester,
    ) async {
      arrange(own: false, pin: 2);
      await open(tester);

      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('post 2'), findsOneWidget);
      // Rows to pin or unpin are for your own posts only.
      await openMenuOf(tester, 'post 2');
      expect(find.text('Unpin from profile'), findsNothing);
      expect(find.text('Pin to your profile'), findsNothing);
    });

    testWidgets('is not asked for while the viewer blocks the author', (
      tester,
    ) async {
      arrange(own: false, pin: 2, blocking: true);
      await open(tester);

      expect(find.text('Pinned'), findsNothing);
      expect(find.text('Show posts'), findsOneWidget);
      verifyNever(() => posts.getPost(any()));

      await tester.tap(find.text('Show posts'));
      await tester.pumpAndSettle();
      expect(find.text('Pinned'), findsOneWidget);
      verify(() => posts.getPost(postId(2))).called(1);
    });

    testWidgets('the only post being pinned shows no empty state', (
      tester,
    ) async {
      arrange(rows: [2], pin: 2, postsCount: 1);
      await open(tester);

      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('post 2'), findsOneWidget);
      expect(find.text("You haven't posted yet"), findsNothing);
    });

    testWidgets('a profile without posts still shows its empty state', (
      tester,
    ) async {
      arrange(rows: const [], postsCount: 0);
      await open(tester);

      expect(find.text('Pinned'), findsNothing);
      expect(find.text("You haven't posted yet"), findsOneWidget);
    });

    testWidgets('deleting the pinned post removes the row and the count', (
      tester,
    ) async {
      arrange(features: withExtras, pin: 2, postsCount: 3);
      answerPin(3);
      when(
        () => posts.deletePost(
          postId: any(named: 'postId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((invocation) async {
        // What the repository does once the server confirmed.
        removed.add(invocation.namedArguments[#postId] as String);
      });
      await open(tester);
      expect(find.text('3 posts'), findsOneWidget);

      await openMenuOf(tester, 'post 2');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      verify(
        () => posts.deletePost(
          postId: postId(2),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(find.text('Pinned'), findsNothing);
      expect(find.text('post 2'), findsNothing);
      expect(find.text('2 posts'), findsOneWidget);
      // The pin is gone locally: pinning another post is no replacement.
      await openMenuOf(tester, 'post 3');
      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();
      expect(find.text('Replace your pinned post?'), findsNothing);
      verify(
        () => identityRepository.updatePinnedPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          postId: postId(3),
        ),
      ).called(1);
    });
  });

  group('Pin and Unpin rows', () {
    testWidgets('need profile_extras', (tester) async {
      arrange();
      await open(tester);

      await openMenuOf(tester, 'post 3');
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Pin to your profile'), findsNothing);
    });

    testWidgets('are on your own posts with the flag', (tester) async {
      arrange(features: withExtras);
      await open(tester);

      await openMenuOf(tester, 'post 3');
      expect(find.text('Pin to your profile'), findsOneWidget);
    });

    testWidgets("are not on someone else's profile", (tester) async {
      arrange(own: false, features: withExtras);
      await open(tester);

      await openMenuOf(tester, 'post 3');
      expect(find.text('Pin to your profile'), findsNothing);
      expect(find.text('Unpin from profile'), findsNothing);
    });

    testWidgets('pin a post: the row appears and the post leaves the feed', (
      tester,
    ) async {
      arrange(features: withExtras);
      answerPin(2);
      await open(tester);
      expect(find.text('post 2'), findsOneWidget);
      expect(find.text('Pinned'), findsNothing);

      await openMenuOf(tester, 'post 2');
      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();

      verify(
        () => identityRepository.updatePinnedPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          postId: postId(2),
        ),
      ).called(1);
      expect(find.text('Pinned to your profile.'), findsOneWidget);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('post 2'), findsOneWidget);
      expect(
        top(tester, find.text('post 2')),
        lessThan(top(tester, find.text('post 3'))),
      );
      verify(() => posts.getPost(postId(2))).called(1);
      // The session's own profile hears about it.
      verify(
        () => onboardingBloc.add(any(that: isA<OnboardingProfileUpdated>())),
      ).called(1);
    });

    testWidgets('replacing a pin asks first; Replace swaps the posts', (
      tester,
    ) async {
      arrange(features: withExtras, pin: 2);
      answerPin(3);
      await open(tester);
      expect(find.text('post 3'), findsOneWidget);

      await openMenuOf(tester, 'post 3');
      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();
      expect(find.text('Replace your pinned post?'), findsOneWidget);
      verifyNever(
        () => identityRepository.updatePinnedPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          postId: any(named: 'postId'),
        ),
      );

      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();

      verify(
        () => identityRepository.updatePinnedPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          postId: postId(3),
        ),
      ).called(1);
      expect(find.text('Pinned'), findsOneWidget);
      // 3 is in the Pinned row now and 2 is back in the feed.
      expect(find.text('post 3'), findsOneWidget);
      expect(find.text('post 2'), findsOneWidget);
      expect(
        top(tester, find.text('post 3')),
        lessThan(top(tester, find.text('post 2'))),
      );
    });

    testWidgets('Cancel on the replace confirm sends nothing', (tester) async {
      arrange(features: withExtras, pin: 2);
      await open(tester);

      await openMenuOf(tester, 'post 3');
      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(
        () => identityRepository.updatePinnedPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          postId: any(named: 'postId'),
        ),
      );
      expect(find.text('post 2'), findsOneWidget);
    });

    testWidgets('Unpin from the Pinned row sends "" and the post returns', (
      tester,
    ) async {
      arrange(features: withExtras, pin: 2);
      answerPin(0);
      await open(tester);
      expect(find.text('Pinned'), findsOneWidget);

      await openMenuOf(tester, 'post 2');
      expect(find.text('Pin to your profile'), findsNothing);
      await tester.tap(find.text('Unpin from profile'));
      await tester.pumpAndSettle();

      verify(
        () => identityRepository.updatePinnedPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          postId: '',
        ),
      ).called(1);
      expect(find.text('Unpinned from your profile.'), findsOneWidget);
      expect(find.text('Pinned'), findsNothing);
      // Back in the feed, in its place.
      expect(find.text('post 2'), findsOneWidget);
      expect(
        top(tester, find.text('post 3')),
        lessThan(top(tester, find.text('post 2'))),
      );
    });

    testWidgets('a refusal says so and hides the rows for the session', (
      tester,
    ) async {
      arrange(features: withExtras);
      when(
        () => identityRepository.updatePinnedPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          postId: any(named: 'postId'),
        ),
      ).thenAnswer((_) async {
        refused = true;
        throw const FeatureDisabledException('off', feature: 'profile_extras');
      });
      await open(tester);

      await openMenuOf(tester, 'post 3');
      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();

      expect(find.text("Pinning isn't available right now."), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Pinned'), findsNothing);

      await openMenuOf(tester, 'post 3');
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Pin to your profile'), findsNothing);
    });

    testWidgets("a VALIDATION answer reads \"This post can't be pinned.\"", (
      tester,
    ) async {
      arrange(features: withExtras);
      when(
        () => identityRepository.updatePinnedPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          postId: any(named: 'postId'),
        ),
      ).thenAnswer(
        (_) async =>
            throw const ValidationException('x', field: 'pinned_post_id'),
      );
      await open(tester);

      await openMenuOf(tester, 'post 3');
      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();

      expect(find.text("This post can't be pinned."), findsOneWidget);
      expect(find.text('Pinned'), findsNothing);
      // The post is still in the feed, and the rows are still on offer.
      expect(find.text('post 3'), findsOneWidget);
      await openMenuOf(tester, 'post 3');
      expect(find.text('Pin to your profile'), findsOneWidget);
    });

    testWidgets('a retry after a failure sends the same idempotency key', (
      tester,
    ) async {
      arrange(features: withExtras);
      final keys = <String>[];
      var fail = true;
      when(
        () => identityRepository.updatePinnedPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          postId: any(named: 'postId'),
        ),
      ).thenAnswer((invocation) async {
        keys.add(invocation.namedArguments[#idempotencyKey] as String);
        if (fail) throw const NetworkException('offline');
        return profileOf(viewer, pin: postId(3));
      });
      await open(tester);

      await openMenuOf(tester, 'post 3');
      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No connection'), findsOneWidget);

      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
      expect(find.text('Pinned'), findsOneWidget);
    });
  });

  group('layout', () {
    forEachThemeAndWidth('the Pinned row fits', (tester, env) async {
      arrange(features: withExtras, pin: 2);
      await open(
        tester,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );

      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('post 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits at 320dp and text scale 2', (tester) async {
      arrange(features: withExtras, pin: 2);
      await open(tester, size: const Size(320, 800), textScale: 2);

      expect(find.text('Pinned'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is announced as a pinned post, then the post', (tester) async {
      arrange(pin: 2);
      await open(tester);

      expect(find.bySemanticsLabel('Pinned post'), findsOneWidget);
    });
  });
}
