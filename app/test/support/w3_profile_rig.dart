import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
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
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as pbts;

import 'fake_transport.dart';
import 'posts_fixtures.dart';
import 'timeline_fixtures.dart';

class W3MockIdentityRepository extends Mock implements IdentityRepository {}

class W3MockGraphRepository extends Mock implements GraphRepository {}

class W3MockAppDatabase extends Mock implements AppDatabase {}

class W3MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The flag sets of the W3 client matrix (`GetMe.enabled_features`).
const w3Base = {'posts', 'replies', 'graph'};
const w3Tabs = {'posts', 'replies', 'graph', 'profile_tabs'};
const w3Extras = {'posts', 'replies', 'graph', 'profile_extras'};

/// The flags of an own profile that can open Edit profile and pin: the tabs, the
/// extras and the snapshot (`engagement`, `media` and `reports` are left out:
/// they put cubits and repositories in the cards that this rig does not
/// provide, and no W3 widget reads them on the profile screen).
const w3Own = {
  'posts',
  'replies',
  'graph',
  'profile_tabs',
  'profile_extras',
  'profile_snapshot',
};

/// A fully populated profile of [uid]: banner (both sizes), location,
/// website, a bio, counts and a join date relative to the real clock (never a
/// fixed date, see `test/guards/fixed_date_guard_test.dart`).
identity.Profile w3Profile(
  String uid, {
  String handle = 'kaif',
  String displayName = 'Kaif Shaik',
  String bio = 'Builds things on the free tier.',
  String banner = 'https://m.test/banner-full.webp',
  String bannerThumb = 'https://m.test/banner-thumb.webp',
  String location = 'Mumbai, India',
  String website = 'https://example.com/me',
  String pin = '',
  int postsCount = 6,
}) => identity.Profile(
  userId: uid,
  handle: handle,
  displayName: displayName,
  bio: bio,
  bannerUrl: banner,
  bannerThumbUrl: bannerThumb,
  location: location,
  website: website,
  pinnedPostId: pin,
  postsCount: Int64(postsCount),
  followersCount: Int64(12),
  followingCount: Int64(34),
  createdAt: pbts.Timestamp.fromDateTime(
    DateTime.now().toUtc().subtract(const Duration(days: 90)),
  ),
);

/// A post by [author] of a pinnable kind (the shared fixture leaves the kind
/// unspecified, which is never pinnable).
pb.PostView w3Post(
  int n,
  String author, {
  PostKind kind = PostKind.POST_KIND_POST,
  String text = '',
}) {
  final view = postView(n, authorId: author, text: text);
  view.post.kind = kind;
  return view;
}

TimelineSnapshot w3Snapshot(
  List<int> ids,
  String author, {
  PostKind kind = PostKind.POST_KIND_POST,
  String older = '',
}) => TimelineSnapshot(
  entries: [
    for (final id in ids)
      TimelineEntry.post(
        postId(id),
        postId(id),
        w3Post(id, author, kind: kind),
      ),
  ],
  sinceToken: 's',
  olderPageToken: older,
);

/// The profile screen over mocked repositories: the viewer's own profile or
/// another user's, every tab with a few rows, the relationship and the pinned
/// post scripted. Mirrors the rigs of `profile_tabs_test` and
/// `profile_pinned_post_test`, in one place for the W3-21 files.
class W3ProfileRig {
  W3ProfileRig()
    : identityRepository = W3MockIdentityRepository(),
      graphRepository = W3MockGraphRepository(),
      timeline = MockTimelineRepository(),
      posts = MockPostsRepository(),
      onboarding = W3MockOnboardingBloc(),
      pending = PendingPostsCubit(),
      removed = StreamController<String>.broadcast() {
    when(() => graphRepository.cached(any())).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.sinceRefresh(any())).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
    when(() => identityRepository.profileExtrasRefused)
        .thenAnswer((_) => extrasRefused);
  }

  static const viewer = 'viewer-uid';
  static const target = 'target-uid';

  final W3MockIdentityRepository identityRepository;
  final W3MockGraphRepository graphRepository;
  final MockTimelineRepository timeline;
  final MockPostsRepository posts;
  final W3MockOnboardingBloc onboarding;
  final PendingPostsCubit pending;
  final StreamController<String> removed;
  bool extrasRefused = false;

  /// A real [GraphRepository] for [open] to provide instead of the mock (see
  /// [realGraph]).
  GraphRepository? graphOverride;

  static void registerFallbacks() {
    registerFallbackValue(const FeedKey.home());
    registerFallbackValue(const OnboardingRefreshRequested());
  }

  FeedKey feed(String uid, [String tab = 'posts']) => switch (tab) {
    'replies' => FeedKey.user(uid, includeReplies: true),
    'reposts' => FeedKey.user(uid, tab: UserFeedTab.reposts),
    'media' => FeedKey.user(uid, tab: UserFeedTab.media),
    _ => FeedKey.user(uid),
  };

  /// Scripts the screen. [own] opens the viewer's own profile, else
  /// [target]'s. [profile] overrides the default populated profile (its
  /// `userId` is forced). Each tab shows [rowsPerTab] posts.
  void arrange({
    bool own = false,
    Set<String> features = w3Tabs,
    identity.Profile? profile,
    // `followed_by`: null is "unknown" (what the UNIMPLEMENTED fallback of
    // `GraphRepository.profileRelationshipFor` produces).
    bool? followedBy = false,
    bool blocking = false,
    int rowsPerTab = 4,
    Future<pb.PostView> Function(String id)? getPost,
    Object? relationshipError,
    Stream<OnboardingState>? onboardingStates,
  }) {
    final uid = own ? viewer : target;
    whenListen(
      onboarding,
      onboardingStates ?? const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: viewer, handle: 'viewer'),
      ),
    );
    final shown = (profile ?? w3Profile(uid))..userId = uid;
    when(() => identityRepository.getProfile(handle: 'kaif'))
        .thenAnswer((_) async => shown);
    if (relationshipError != null) {
      when(() => graphRepository.profileRelationshipFor(uid))
          .thenAnswer((_) async => throw relationshipError);
    } else {
      when(() => graphRepository.profileRelationshipFor(uid)).thenAnswer(
        (_) async => ProfileRelationship(
          relationship: graph.Relationship(userId: uid, blocking: blocking),
          followedBy: followedBy,
        ),
      );
    }
    final byTab = {
      'posts': [for (var i = rowsPerTab; i >= 1; i--) i],
      'replies': [for (var i = 100 + rowsPerTab; i >= 101; i--) i],
      'reposts': [for (var i = 200 + rowsPerTab; i >= 201; i--) i],
      'media': [for (var i = 300 + rowsPerTab; i >= 301; i--) i],
    };
    for (final entry in byTab.entries) {
      final snapshot = w3Snapshot(entry.value, uid);
      final key = feed(uid, entry.key);
      when(() => timeline.cached(key)).thenAnswer((_) async => snapshot);
      when(() => timeline.refresh(key)).thenAnswer((_) async => snapshot);
    }
    when(() => posts.getPost(any())).thenAnswer((invocation) async {
      final id = invocation.positionalArguments.first as String;
      if (getPost != null) return getPost(id);
      return w3Post(int.parse(id), uid);
    });
  }

  /// Pumps the profile screen (opened by handle `kaif`). [rtl] puts a
  /// right-to-left `Directionality` inside the `MaterialApp` builder (above
  /// it, `Localizations` would override it).
  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool rtl = false,
    bool settle = true,
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
          RepositoryProvider<GraphRepository>.value(
            value: graphOverride ?? graphRepository,
          ),
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp(
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => Directionality(
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
            ),
            home: const ProfileScreen(handle: 'kaif'),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  /// A real [GraphRepository] over a fake transport that answers each RPC
  /// through [handler] (by procedure name), to follow `GetProfileRelationship`
  /// and its UNIMPLEMENTED / FEATURE_DISABLED fallback all the way to the
  /// header. Set it as [graphOverride] before [open].
  static GraphRepository realGraph(
    Future<Object> Function(String procedure, Object input) handler, {
    DateTime Function()? now,
  }) {
    final database = W3MockAppDatabase();
    when(() => database.sessionEpoch).thenReturn(SessionEpoch());
    when(() => database.cachedFollowingIds()).thenAnswer((_) async => []);
    when(() => database.upsertFollowing(any(), epoch: any(named: 'epoch')))
        .thenAnswer((_) async {});
    when(() => database.removeFollowing(any(), epoch: any(named: 'epoch')))
        .thenAnswer((_) async {});
    return GraphRepository(
      apiClient: ApiClient.withTransport(FakeTransport(handler)),
      database: database,
      now: now,
    );
  }

  /// The bottom edge of the app bar: where the pinned tab bar parks.
  double appBarBottom(WidgetTester tester) =>
      tester.getBottomLeft(find.byType(AppBar)).dy;

  /// Scrolls the header away until the tab bar is built and pinned under the
  /// app bar. At large text the header is taller than the screen and the tab
  /// bar sliver is not built before then, so a test that wants the tabs must
  /// scroll to them, as a user does. The drag starts on the whole nested
  /// scroll view (on screen at any header height), never on a list below the
  /// fold.
  Future<void> pinTabBar(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      final bar = find.byType(AppTabBar);
      if (bar.evaluate().isNotEmpty &&
          tester.getTopLeft(bar).dy <= appBarBottom(tester) + 0.5) {
        return;
      }
      await tester.drag(
        find.byType(NestedScrollView),
        const Offset(0, -500),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
    }
    fail('the tab bar never pinned under the app bar');
  }

  Future<void> dispose() async {
    await pending.close();
    await removed.close();
  }
}
