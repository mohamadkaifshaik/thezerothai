import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/domain/engagement_feature_flag.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/widgets/post_engagement_bar.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/home/presentation/widgets/home_composer_entry.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/features/posts/presentation/reply_composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_drafts_repository.dart';
import 'posts_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockEngagement extends Mock implements EngagementRepository {}

class MockComposerPosts extends Mock implements PostsRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// Posts with replies and quotes, and the tablet shell's two flags.
const kComposerTabletFlags = <String>{
  kFeaturePosts,
  kPostsSubFeatureReplies,
  kFeatureEngagement,
  kPostsSubFeatureQuotes,
  kFeatureUiShell,
  kFeatureUiTablet,
};

/// The flag modes the tablet layout distinguishes (tablet plan section 2.3):
/// only `ui_shell` + `ui_tablet` draws the tablet layout.
const kComposerFlagModes = <String, Set<String>>{
  'neither': {kFeaturePosts, kPostsSubFeatureReplies, kFeatureEngagement},
  'ui_shell only': {
    kFeaturePosts,
    kPostsSubFeatureReplies,
    kFeatureEngagement,
    kFeatureUiShell,
  },
  'ui_tablet only': {
    kFeaturePosts,
    kPostsSubFeatureReplies,
    kFeatureEngagement,
    kFeatureUiTablet,
  },
  'ui_shell + ui_tablet': kComposerTabletFlags,
};

/// A full-screen root page with no rail (like Drafts or the photo viewer).
const kRigRootPagePath = '/root-page';

/// The id of the saved draft the rig seeds when `drafts` is on.
const kRigDraftId = '0123456789abcdef';

/// The real `MainShell` in a real `ShellRoute` (Home: the real
/// [HomeComposerEntry] and a real [PostEngagementBar] for the parent post),
/// the app's own composer routes ([AppRouter.composeRoute],
/// [AppRouter.composeReplyRoute]) and a full-screen root page with a Reply
/// and a draft button. Only the server is faked ([MockComposerPosts]).
class ComposerTabletRig {
  ComposerTabletRig() {
    parent = postView(1, text: 'A conversation worth continuing.');
    parent.post.author = common.AuthorSnapshot(userId: 'u2', handle: 'bob');
    parent.post.replyCount = Int64(1);
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(() => posts.getPost(any())).thenAnswer((_) async {
      getPostCalls++;
      return parent;
    });
  }

  /// How many times the reply's parent post was fetched (`LoadedPost`).
  int getPostCalls = 0;

  final posts = MockComposerPosts();
  late final pb.PostView parent;
  late GoRouter router;
  FakeDraftsRepository? drafts;
  final pending = PendingPostsCubit();

  /// The location of the top page.
  Uri get uri => router.state.uri;

  /// Opens the app at [location] (default Home) and settles.
  Future<void> pump(
    WidgetTester tester, {
    String location = AppRouter.homePath,
    double width = 1024,
    double height = 768,
    Set<String> flags = kComposerTabletFlags,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    TextDirection textDirection = TextDirection.ltr,
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    addTearDown(pending.close);
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: identity.Profile(userId: 'uid-1', handle: 'me'),
      ),
    );
    final auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: 'uid-1',
          email: 'me@example.com',
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    final unread = UnreadBadgeCubit(0);
    addTearDown(unread.close);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    final graph = _MockGraph();
    when(() => graph.followRequestsUnavailable).thenReturn(false);
    final engagement = EngagementCubit(repository: _MockEngagement());
    addTearDown(engagement.close);
    if (flags.contains(kFeatureDrafts)) {
      final now = DateTime.now();
      drafts = FakeDraftsRepository(
        drafts: [
          ComposerDraft(
            id: kRigDraftId,
            uid: 'uid-1',
            text: 'A saved thought',
            createdAt: now.subtract(const Duration(minutes: 10)),
            updatedAt: now.subtract(const Duration(minutes: 5)),
          ),
        ],
      );
    }

    router = GoRouter(
      initialLocation: location,
      routes: [
        AppRouter.composeReplyRoute(),
        AppRouter.composeRoute(),
        GoRoute(
          path: kRigRootPagePath,
          builder: (context, state) => Scaffold(
            appBar: AppBar(title: const Text('Root page')),
            body: Column(
              children: [
                TextButton(
                  onPressed: () => context.push(
                    AppRouter.composeReplyPath(parent.post.postId),
                  ),
                  child: const Text('Reply from root'),
                ),
                TextButton(
                  onPressed: () =>
                      context.push(AppRouter.composeDraftPath(kRigDraftId)),
                  child: const Text('Open draft'),
                ),
              ],
            ),
          ),
        ),
        GoRoute(
          path: AppRouter.draftsPath,
          builder: (context, state) => Scaffold(
            appBar: AppBar(title: const Text('Drafts stub')),
            body: TextButton(
              onPressed: () => context.pop(kRigDraftId),
              child: const Text('Pick the saved draft'),
            ),
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
              builder: (context, state) => Scaffold(
                body: ListView(
                  children: [
                    const HomeComposerEntry(),
                    const Text('home body'),
                    PostEngagementBar(view: parent),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    tester.view.padding = FakeViewPadding(
      left: padding.left,
      top: padding.top,
      right: padding.right,
      bottom: padding.bottom,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<GraphRepository>.value(value: graph),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
          if (drafts case final d?)
            RepositoryProvider<DraftsRepository>.value(value: d),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<UnreadBadgeCubit>.value(value: unread),
            BlocProvider<MessagesBadgeCubit>.value(value: messages),
            BlocProvider<PendingPostsCubit>.value(value: pending),
            BlocProvider<EngagementCubit>.value(value: engagement),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_MemoryThemeStore()),
            ),
          ],
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
    );
    await tester.pumpAndSettle();
  }

  /// Pushes [location] unawaited (the future completes only on pop) and
  /// settles.
  Future<void> push(WidgetTester tester, String location) async {
    unawaited(router.push(location));
    await tester.pumpAndSettle();
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

/// The post composer's editor.
Finder findComposer() => find.byType(ComposerScreen);

/// The reply composer's editor.
Finder findReplyComposer() => find.byType(ReplyComposerScreen);

/// The `Dialog` around [editor], or nothing when it is full screen.
Finder dialogAround(Finder editor) =>
    find.ancestor(of: editor, matching: find.byType(Dialog));

/// The composer's cubit (the one its text field writes to).
ComposerCubit composerCubitOf(WidgetTester tester) =>
    BlocProvider.of<ComposerCubit>(
      tester.element(find.byType(EditableText).first),
    );

/// The composer's text field state.
EditableTextState editorStateOf(WidgetTester tester) =>
    tester.state<EditableTextState>(find.byType(EditableText).first);
