import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/share/share_links.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/domain/graph_list_extra.dart';
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/features/graph/presentation/graph_list_screen.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/profile/presentation/edit_profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_cubit.dart';
import 'package:dzeroth/features/settings/domain/settings_categories.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import 'failing_image_cache.dart';
import 'fake_search_repository.dart';
import 'search_field_rig.dart';
import 'suggestions_fixtures.dart';
import 'timeline_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// The profile surfaces' flags (the tabs, the extras, Edit profile), the
/// context pane's global-set flags and the tablet shell's two.
const kProfileTabletFlags = <String>{
  'posts',
  'replies',
  'graph',
  'profile_tabs',
  'profile_extras',
  'profile_snapshot',
  'search',
  'trends',
  'follow_suggestions',
  kFeatureUiShell,
  kFeatureUiTablet,
};

/// The flag modes the tablet shell distinguishes (tablet plan section 2.3),
/// each with the profile surfaces' own flags on.
final kProfileFlagModes = <String, Set<String>>{
  'neither': {
    for (final f in kProfileTabletFlags)
      if (f != kFeatureUiShell && f != kFeatureUiTablet) f,
  },
  'ui_shell only': {
    for (final f in kProfileTabletFlags)
      if (f != kFeatureUiTablet) f,
  },
  'ui_tablet only': {
    for (final f in kProfileTabletFlags)
      if (f != kFeatureUiShell) f,
  },
  'ui_shell + ui_tablet': kProfileTabletFlags,
};

/// The signed-in user (own profile `/profile/alice`).
const kRigOwnId = 'u-alice';
const kRigOwnHandle = 'alice';

/// Another person (`/profile/kaif`, `/u/u-kaif`).
const kRigOtherId = 'u-kaif';
const kRigOtherHandle = 'kaif';

/// The thumbnail and full URLs of image [i] of media post [n].
String rigThumbUrl(int n, int i) => 'https://m.test/p$n-$i-thumb.webp';
String rigFullUrl(int n, int i) => 'https://m.test/p$n-$i-full.webp';

/// A post of [author] with [images] images (alt text on the first).
pb.PostView rigMediaPost(int n, String author, {int images = 1}) => pb.PostView(
  post: pb.Post(
    postId: 'm$n',
    text: 'media post $n',
    kind: PostKind.POST_KIND_POST,
    author: common.AuthorSnapshot(userId: author, handle: 'h$author'),
    media: [
      for (var i = 0; i < images; i++)
        common.MediaRef(
          mediaId: 'm$n-$i',
          url: rigFullUrl(n, i),
          thumbUrl: rigThumbUrl(n, i),
          width: 800,
          height: 600,
          altText: i == 0 ? 'Photo $n' : '',
        ),
    ],
  ),
);

GraphListExtra? _graphExtra(GoRouterState state) =>
    state.extra is GraphListExtra ? state.extra as GraphListExtra : null;

/// A populated profile (bio, location, website, counts).
identity.Profile rigProfile(String uid, String handle, String name) =>
    identity.Profile(
      userId: uid,
      handle: handle,
      displayName: name,
      bio: 'Bio of $name.',
      avatarUrl: 'https://m.test/$handle-avatar.webp',
      avatarThumbUrl: 'https://m.test/$handle-avatar-thumb.webp',
      location: 'Mumbai, India',
      website: 'https://example.com/$handle',
      postsCount: Int64(6),
      followersCount: Int64(12),
      followingCount: Int64(34),
      createdAt: ts.Timestamp.fromDateTime(
        DateTime.now().toUtc().subtract(const Duration(days: 90)),
      ),
    );

/// The real `MainShell` in a real `ShellRoute` around the real profile
/// surfaces: `ProfileScreen` (`/profile/:handle` and `/u/:userId`),
/// `GraphListScreen` (Followers / Following), `SettingsScreen` and the real
/// `EditProfileScreen` (`/settings/profile`), over mocked repositories with a
/// call log, and the context pane's shared cubits over fakes. `/home` is a
/// stub; the photo viewer is a root stub.
class ProfileTabletRig {
  ProfileTabletRig();

  final identityRepository = _MockIdentity();
  final graphRepository = _MockGraph();
  final timeline = MockTimelineRepository();
  final posts = MockPostsRepository();
  final search = FakeSearchRepository()
    ..trendsResult = TrendsResult(
      trends: [for (var i = 1; i <= 3; i++) searchTrend('tag$i', 100 * i, i)],
      computedAt: DateTime.now().subtract(const Duration(hours: 2)),
    );
  final suggestionsRepository = FakeSuggestionsRepository([
    for (var i = 1; i <= 3; i++) suggestedUser(i),
  ]);
  late GoRouter router;

  /// Every image URL asked for (no image loads in a widget test: each
  /// download fails, as a missing object does).
  late FailingImageCacheManager images;

  /// Every server call, in order: `profile:<handle|id>`, `feed:<uid>:<tab>`,
  /// `followers:<uid>`, `following:<uid>`.
  final calls = <String>[];

  int count(String prefix) => calls.where((c) => c.startsWith(prefix)).length;

  /// Media posts (one image each unless [mediaImages] says otherwise) in
  /// each profile's Media tab.
  int mediaPosts = 4;

  /// Images per media post.
  int mediaImages = 1;

  /// Non-null: GetProfile waits for it.
  Completer<void>? holdProfile;

  /// Non-null: the Media feed's refresh waits for it.
  Completer<void>? holdMedia;

  /// Non-null: GetProfile fails with it.
  AppException? profileError;

  /// Non-null: the Media feed's refresh fails with it.
  AppException? mediaError;

  /// The other person's posts are protected from the viewer.
  bool otherProtected = false;

  /// The viewer blocks the other person.
  bool blocking = false;

  /// The other person follows the viewer.
  bool followedBy = false;

  /// The location of the top page (a pushed one too).
  Uri get uri => router.state.uri;

  /// The own profile's display name and follower count, when a test wants
  /// extremes (a long name, seven digits).
  String ownName = 'Alice A';
  int? ownFollowers;

  identity.Profile get ownProfile {
    final profile = rigProfile(kRigOwnId, kRigOwnHandle, ownName);
    final followers = ownFollowers;
    if (followers != null) profile.followersCount = Int64(followers);
    return profile;
  }

  identity.Profile get otherProfile =>
      rigProfile(kRigOtherId, kRigOtherHandle, 'Kaif Shaik');

  identity.Profile _profileFor({String? handle, String? userId}) =>
      handle == kRigOwnHandle || userId == kRigOwnId
      ? ownProfile
      : otherProfile;

  void _arrange() {
    registerFallbackValue(const FeedKey.home());
    registerFallbackValue(const OnboardingRefreshRequested());
    when(() => identityRepository.profileExtrasRefused).thenReturn(false);
    when(
      () => identityRepository.getProfile(
        handle: any(named: 'handle'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer((invocation) async {
      final handle = invocation.namedArguments[#handle] as String?;
      final userId = invocation.namedArguments[#userId] as String?;
      calls.add('profile:${handle ?? userId}');
      await holdProfile?.future;
      final error = profileError;
      if (error != null) throw error;
      return _profileFor(handle: handle, userId: userId);
    });
    when(() => graphRepository.cached(any())).thenReturn(null);
    when(() => graphRepository.followRequestsUnavailable).thenReturn(false);
    when(() => graphRepository.profileRelationshipFor(any()))
        .thenAnswer((invocation) async {
          final uid = invocation.positionalArguments.first as String;
          return ProfileRelationship(
            relationship: graph.Relationship(userId: uid, blocking: blocking),
            followedBy: followedBy,
          );
        });
    for (final (name, list) in [
      ('followers', graphRepository.listFollowers),
      ('following', graphRepository.listFollowing),
    ]) {
      when(
        () => list(
          userId: any(named: 'userId'),
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((invocation) async {
        calls.add('$name:${invocation.namedArguments[#userId]}');
        return GraphPage(
          items: [
            for (var i = 1; i <= 3; i++)
              graph.UserListItem(
                user: common.AuthorSnapshot(
                  userId: 'f$i',
                  handle: 'friend$i',
                  displayName: 'Friend $i',
                ),
              ),
          ],
          nextPageToken: '',
        );
      });
    }
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.sinceRefresh(any())).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
    when(() => timeline.cached(any()))
        .thenAnswer((_) async => const TimelineSnapshot());
    when(() => timeline.refresh(any())).thenAnswer((invocation) async {
      final key = invocation.positionalArguments.first as FeedKey;
      final (uid, tab) = _feedOf(key);
      calls.add('feed:$uid:$tab');
      if (uid == kRigOtherId && otherProtected) {
        return const TimelineSnapshot(authorProtected: true);
      }
      if (tab == 'media') {
        await holdMedia?.future;
        final error = mediaError;
        if (error != null) throw error;
        return TimelineSnapshot(
          entries: [
            for (var n = mediaPosts; n >= 1; n--)
              TimelineEntry.post(
                'm$n',
                'm$n',
                rigMediaPost(n, uid, images: mediaImages),
              ),
          ],
          sinceToken: 's',
        );
      }
      return TimelineSnapshot(
        entries: [
          for (var n = 3; n >= 1; n--)
            TimelineEntry.post('$tab$n', '$tab$n', _post('$tab$n', uid)),
        ],
        sinceToken: 's',
      );
    });
  }

  static pb.PostView _post(String id, String uid) => pb.PostView(
    post: pb.Post(
      postId: id,
      text: 'post $id',
      kind: PostKind.POST_KIND_POST,
      author: common.AuthorSnapshot(userId: uid, handle: 'h$uid'),
    ),
  );

  /// The user and tab of a profile feed, read through the key's own
  /// equality (the key's fields are not part of this rig's contract).
  static (String, String) _feedOf(FeedKey key) {
    for (final uid in [kRigOwnId, kRigOtherId]) {
      for (final (tab, candidate) in [
        ('posts', FeedKey.user(uid)),
        ('reposts', FeedKey.user(uid, tab: UserFeedTab.reposts)),
        ('media', FeedKey.user(uid, tab: UserFeedTab.media)),
        ('articles', FeedKey.user(uid, tab: UserFeedTab.articles)),
      ]) {
        if (candidate == key) return (uid, tab);
      }
    }
    return ('?', '$key');
  }

  Future<void> pump(
    WidgetTester tester, {
    String location = '/profile/$kRigOwnHandle',
    double width = 1024,
    double height = 900,
    Set<String> flags = kProfileTabletFlags,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    TextDirection textDirection = TextDirection.ltr,
    bool settle = true,
    ShareLinks? shareLinks,
  }) async {
    images = useFailingImageCache();
    _arrange();
    final onboarding = _MockOnboardingBloc();
    when(() => onboarding.add(any())).thenReturn(null);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: ownProfile,
      ),
    );
    final auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    final unread = UnreadBadgeCubit(0);
    addTearDown(unread.close);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    final trends = TrendsCubit(repository: search);
    addTearDown(trends.close);
    final suggestions = SuggestionsCubit(repository: suggestionsRepository);
    addTearDown(suggestions.close);
    final pending = PendingPostsCubit();
    addTearDown(pending.close);

    Widget stub(String text) => Scaffold(
      appBar: AppBar(title: Text(text)),
      body: Text('$text body'),
    );

    router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/post/:id/photo/:index',
          builder: (context, state) => stub(
            'Photo ${state.pathParameters['id']} '
            '${state.pathParameters['index']}',
          ),
        ),
        ShellRoute(
          builder: (context, state, child) => MainShell(
            location: state.matchedLocation,
            uri: state.uri,
            child: child,
          ),
          routes: [
            GoRoute(
              path: AppRouter.homePath,
              builder: (context, state) => stub('Home stub'),
            ),
            GoRoute(
              path: '/profile/:handle',
              builder: (context, state) =>
                  ProfileScreen(handle: state.pathParameters['handle']!),
            ),
            GoRoute(
              path: '/u/:userId',
              builder: (context, state) =>
                  ProfileScreen(userId: state.pathParameters['userId']!),
            ),
            GoRoute(
              path: '/profile/:handle/followers',
              builder: (context, state) => GraphListScreen(
                handle: state.pathParameters['handle']!,
                userId: _graphExtra(state)?.userId,
                displayName: _graphExtra(state)?.displayName,
              ),
            ),
            GoRoute(
              path: '/profile/:handle/following',
              builder: (context, state) => GraphListScreen(
                handle: state.pathParameters['handle']!,
                userId: _graphExtra(state)?.userId,
                displayName: _graphExtra(state)?.displayName,
                initialTab: GraphListTab.following,
              ),
            ),
            GoRoute(
              path: AppRouter.settingsPath,
              builder: (context, state) => SettingsScreen(
                categoryId: state.uri.queryParameters[kSettingsCategoryParam],
              ),
            ),
            GoRoute(
              path: AppRouter.editProfilePath,
              builder: (context, state) => const EditProfileScreen(),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
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
          RepositoryProvider<SearchRepository>.value(value: search),
          RepositoryProvider<RecentSearchesStore>.value(
            value: FakeRecentSearchesStore(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<UnreadBadgeCubit>.value(value: unread),
            BlocProvider<MessagesBadgeCubit>.value(value: messages),
            BlocProvider<TrendsCubit>.value(value: trends),
            BlocProvider<SuggestionsCubit>.value(value: suggestions),
            BlocProvider<PendingPostsCubit>.value(value: pending),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_MemoryThemeStore()),
            ),
          ],
          child: ShareLinksScope(
            links: shareLinks,
            child: MaterialApp.router(
              theme: buildAppTheme(brightness: brightness),
              routerConfig: router,
              builder: (context, child) => Directionality(
                textDirection: textDirection,
                child: MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  /// Resizes the window and settles.
  Future<void> resize(
    WidgetTester tester,
    double width, [
    double? height,
  ]) async {
    tester.view.physicalSize = Size(
      width,
      height ?? tester.view.physicalSize.height,
    );
    await tester.pumpAndSettle();
  }
}

/// The route child (the primary pane on the tablet layout, the whole body
/// elsewhere): one of the profile surfaces.
Finder findProfilePage() => find.byWidgetPredicate(
  (w) =>
      w is ProfileScreen ||
      w is GraphListScreen ||
      w is EditProfileScreen ||
      w is SettingsScreen,
);

/// [finder] inside the route child.
Finder inProfilePage(Finder finder) =>
    find.descendant(of: findProfilePage(), matching: finder);
