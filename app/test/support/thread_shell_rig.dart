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
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/post_detail_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import 'posts_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockEngagement extends Mock implements EngagementRepository {}

class MockThreadPosts extends Mock implements PostsRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// Posts, replies and engagement on the tablet and desktop shell.
const kThreadShellFlags = <String>{
  kFeaturePosts,
  kPostsSubFeatureReplies,
  kFeatureEngagement,
  kFeatureUiShell,
  kFeatureUiTablet,
};

/// The author of [selfThread]: the mocks' "Mohamad".
final kThreadAuthor = common.AuthorSnapshot(
  userId: 'u-mk',
  handle: 'mohamad.k',
  displayName: 'Mohamad',
);

const kSelfThreadTexts = [
  'Why we built DZEROTH, a short thread. 1/4',
  'Feeds made us scroll more and meet less. We wanted the opposite. 2/4',
  'So every plan starts with a simple question: what do you want to do, '
      'nearby? 3/4',
  'Share it. Someone nearby wants that too. 4/4',
];

/// The PostThread mock's thread: post 1 is the root, each of 2-4 answers
/// the one before, all by [kThreadAuthor], two hours ago.
List<pb.PostView> selfThread() {
  final at = DateTime.now().subtract(const Duration(hours: 2));
  return [
    for (var i = 0; i < kSelfThreadTexts.length; i++)
      pb.PostView(
        post: pb.Post(
          postId: postId(i + 1),
          text: kSelfThreadTexts[i],
          author: kThreadAuthor,
          conversationId: postId(1),
          replyToPostId: i == 0 ? '' : postId(i),
          replyToHandle: i == 0 ? '' : kThreadAuthor.handle,
          createdAt: ts.Timestamp.fromDateTime(at),
          replyCount: Int64(i == 3 ? 12 : 1),
          repostCount: Int64(i == 3 ? 8 : 0),
          likeCount: Int64(i == 3 ? 96 : 6),
        ),
      ),
  ];
}

/// The real `MainShell` in a real `ShellRoute` with Home and `/post/:id`
/// (the app's [PostDetailScreen]). Only the server is faked: `GetThread`
/// answers the post at [open] from [posts] (its context and the same
/// author's chain under it).
class ThreadShellRig {
  ThreadShellRig({List<pb.PostView>? thread})
    : thread = thread ?? selfThread() {
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(
      () => posts.getThread(
        any(),
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((call) async {
      final id = call.positionalArguments.first as String;
      return _answer(id);
    });
  }

  final List<pb.PostView> thread;
  final posts = MockThreadPosts();
  late GoRouter router;

  pb.GetThreadResponse _answer(String id) {
    final at = thread.indexWhere((v) => v.post.postId == id);
    final focal = thread[at];
    pb.PostView? byId(String postId) {
      for (final v in thread) {
        if (v.post.postId == postId) return v;
      }
      return null;
    }

    final parent = focal.post.replyToPostId.isEmpty
        ? null
        : byId(focal.post.replyToPostId);
    final root = focal.post.replyToPostId.isEmpty
        ? null
        : byId(focal.post.conversationId);
    final shown = {focal.post.postId, ?parent?.post.postId, ?root?.post.postId};
    return pb.GetThreadResponse(
      focal: focal,
      parent: parent,
      root: root,
      replies: [
        for (final v in thread.skip(at + 1))
          if (!shown.contains(v.post.postId)) v,
      ],
    );
  }

  /// Opens Home, then pushes `/post/<open>` and settles.
  Future<void> pump(
    WidgetTester tester, {
    required String open,
    Size size = const Size(390, 844),
    Set<String> flags = kThreadShellFlags,
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
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
    final pending = PendingPostsCubit();
    addTearDown(pending.close);
    final graph = _MockGraph();
    when(() => graph.followRequestsUnavailable).thenReturn(false);
    when(() => graph.cached(any())).thenReturn(null);
    final engagement = EngagementCubit(repository: _MockEngagement());
    addTearDown(engagement.close);

    router = GoRouter(
      initialLocation: AppRouter.homePath,
      routes: [
        ShellRoute(
          builder: (context, state, child) => MainShell(
            location: state.matchedLocation,
            uri: state.uri,
            child: child,
          ),
          routes: [
            GoRoute(
              path: AppRouter.homePath,
              builder: (context, state) =>
                  const Scaffold(body: Text('home body')),
            ),
            GoRoute(
              path: '/post/:id',
              builder: (context, state) =>
                  PostDetailScreen(postId: state.pathParameters['id']!),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<GraphRepository>.value(value: graph),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
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
    unawaited(router.push(AppRouter.postPath(open)));
    await tester.pumpAndSettle();
  }
}
