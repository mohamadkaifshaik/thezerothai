import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/post_detail_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPermission;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/timeline_fixtures.dart';

class MockGraphRepository extends Mock implements GraphRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// A reply to [parent] in [conversation].
pb.PostView replyView(
  int n, {
  required int parent,
  required int conversation,
  String text = '',
  String authorId = 'u2',
}) => pb.PostView(
  post: pb.Post(
    postId: postId(n),
    text: text.isEmpty ? 'reply $n' : text,
    replyToPostId: postId(parent),
    replyToHandle: 'h$parent',
    conversationId: postId(conversation),
    author: common.AuthorSnapshot(userId: authorId, handle: 'h$authorId'),
  ),
);

void main() {
  late MockPostsRepository posts;
  late MockGraphRepository graphRepository;
  late MockOnboardingBloc onboardingBloc;
  late StreamController<String> removed;

  setUp(() {
    removed = StreamController<String>.broadcast();
    addTearDown(removed.close);
    posts = MockPostsRepository();
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
    graphRepository = MockGraphRepository();
    onboardingBloc = MockOnboardingBloc();
    when(() => graphRepository.cached(any())).thenReturn(null);
  });

  void stubThread(
    Future<pb.GetThreadResponse> Function(String token) answer, {
    int id = 1,
  }) {
    when(
      () => posts.getThread(
        postId(id),
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((i) => answer(i.namedArguments[#pageToken] as String));
  }

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'posts', 'replies'},
    ThemeData? theme,
    bool settle = true,
    double textScale = 1,
  }) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/home',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) =>
              PostDetailScreen(postId: state.pathParameters['id']!),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboardingBloc,
          child: MaterialApp.router(
            routerConfig: router,
            theme: theme ?? appLightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    unawaited(router.push('/post/${postId(1)}'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  testWidgets('loading shows a skeleton, then the post and its replies', (
    tester,
  ) async {
    final done = Completer<pb.GetThreadResponse>();
    stubThread((_) => done.future);

    await open(tester, settle: false);
    expect(find.bySemanticsLabel('Loading conversation'), findsOneWidget);

    done.complete(
      pb.GetThreadResponse(
        focal: postView(1, text: 'the focal post'),
        replies: [
          replyView(2, parent: 1, conversation: 1, text: 'first reply'),
          replyView(3, parent: 2, conversation: 1, text: 'nested reply'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('the focal post'), findsOneWidget);
    expect(find.text('first reply'), findsOneWidget);
    expect(find.text('nested reply'), findsOneWidget);
    // Only the nested reply says who it answers (focal replies are implied).
    expect(find.text('Replying to @h2'), findsOneWidget);
    expect(find.text('Post your reply'), findsOneWidget);
    verifyNever(() => posts.getPost(any()));
  });

  testWidgets('a reply shows its parent and root, unavailable ones as '
      'tombstones', (tester) async {
    stubThread(
      (_) async => pb.GetThreadResponse(
        focal: replyView(
          1,
          parent: 5,
          conversation: 4,
          text: 'focal reply',
          authorId: 'u1',
        ),
        parent: postView(5, text: 'the parent'),
        rootUnavailable: true,
      ),
    );

    await open(tester);

    expect(find.text('the parent'), findsOneWidget);
    expect(find.text('This post is unavailable'), findsOneWidget);
    expect(find.text('focal reply'), findsOneWidget);
    expect(find.text('Replying to @h5'), findsOneWidget);
    // Root above parent above focal.
    expect(
      tester.getTopLeft(find.text('This post is unavailable')).dy,
      lessThan(tester.getTopLeft(find.text('the parent')).dy),
    );
    expect(
      tester.getTopLeft(find.text('the parent')).dy,
      lessThan(tester.getTopLeft(find.text('focal reply')).dy),
    );
  });

  testWidgets('a first-level reply with a deleted parent shows one tombstone', (
    tester,
  ) async {
    stubThread(
      (_) async => pb.GetThreadResponse(
        focal: replyView(1, parent: 4, conversation: 4, text: 'orphan'),
        parentUnavailable: true,
        rootUnavailable: true,
      ),
    );

    await open(tester);

    expect(find.text('This post is unavailable'), findsOneWidget);
    expect(find.text('orphan'), findsOneWidget);
  });

  testWidgets('empty conversation guides to the composer', (tester) async {
    stubThread((_) async => pb.GetThreadResponse(focal: postView(1)));

    await open(tester);

    expect(find.text('No replies yet'), findsOneWidget);
    expect(find.text('Start the conversation below.'), findsOneWidget);
  });

  testWidgets('"Show more replies" follows the page token', (tester) async {
    stubThread(
      (token) async => token.isEmpty
          ? pb.GetThreadResponse(
              focal: postView(1),
              replies: [replyView(2, parent: 1, conversation: 1)],
              nextPageToken: 'n1',
            )
          : pb.GetThreadResponse(
              focal: postView(1),
              replies: [replyView(3, parent: 1, conversation: 1)],
            ),
    );

    await open(tester);
    expect(find.text('reply 3'), findsNothing);

    await tester.tap(find.text('Show more replies'));
    await tester.pumpAndSettle();

    expect(find.text('reply 3'), findsOneWidget);
    expect(find.text('Show more replies'), findsNothing);
  });

  testWidgets('a failed page shows an inline retry above the loaded replies', (
    tester,
  ) async {
    var fail = true;
    stubThread((token) async {
      if (token.isEmpty) {
        return pb.GetThreadResponse(
          focal: postView(1),
          replies: [replyView(2, parent: 1, conversation: 1)],
          nextPageToken: 'n1',
        );
      }
      if (fail) throw const NetworkException('offline');
      return pb.GetThreadResponse(
        focal: postView(1),
        replies: [replyView(3, parent: 1, conversation: 1)],
      );
    });

    await open(tester);
    await tester.tap(find.text('Show more replies'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load more replies."), findsOneWidget);
    expect(find.text('reply 2'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('reply 3'), findsOneWidget);
  });

  testWidgets('NOT_FOUND: "This post isn\'t available", no retry', (
    tester,
  ) async {
    stubThread((_) async => throw const NotFoundException('post not found'));

    await open(tester);

    expect(find.text("This post isn't available"), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Post your reply'), findsNothing);
  });

  testWidgets('a network error offers Retry', (tester) async {
    stubThread((_) async => throw const NetworkException('offline'));
    await open(tester);
    expect(
      find.text('No connection. Check your network and try again.'),
      findsOneWidget,
    );

    stubThread(
      (_) async => pb.GetThreadResponse(focal: postView(1, text: 'back')),
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('back'), findsOneWidget);
  });

  testWidgets('server FEATURE_DISABLED degrades to the plain post view', (
    tester,
  ) async {
    stubThread(
      (_) async =>
          throw const FeatureDisabledException('off', feature: 'replies'),
    );
    when(() => posts.getPost(postId(1)))
        .thenAnswer((_) async => postView(1, text: 'plain view'));

    await open(tester);

    expect(find.text('plain view'), findsOneWidget);
    expect(find.text('Post your reply'), findsNothing);
    expect(find.text("This feature isn't available yet."), findsNothing);
  });

  testWidgets('replies flag off: plain GetPost, no thread RPC', (tester) async {
    when(() => posts.getPost(postId(1)))
        .thenAnswer((_) async => postView(1, text: 'plain view'));

    await open(tester, features: const {'posts'});

    expect(find.text('plain view'), findsOneWidget);
    expect(find.text('Post your reply'), findsNothing);
    verifyNever(
      () => posts.getThread(
        any(),
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    );
  });

  group('reply composer', () {
    void stubReply(Future<pb.PostView> Function() answer) {
      when(
        () => posts.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          replyToPostId: postId(1),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
        ),
      ).thenAnswer((_) => answer());
    }

    setUp(() {
      stubThread(
        (_) async => pb.GetThreadResponse(focal: postView(1, text: 'root')),
      );
    });

    AppPillButton replyButton(WidgetTester tester) =>
        tester.widget(find.widgetWithText(AppPillButton, 'Reply'));

    testWidgets('starts disabled; sends a reply to the open post and shows '
        'it', (tester) async {
      final done = Completer<pb.PostView>();
      stubReply(() => done.future);
      await open(tester);
      expect(replyButton(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'my reply');
      await tester.pump();
      expect(replyButton(tester).onPressed, isNotNull);

      await tester.tap(find.widgetWithText(AppPillButton, 'Reply'));
      await tester.pump();
      // In flight: the optimistic row.
      expect(find.text('Posting...'), findsOneWidget);

      done.complete(
        replyView(
          9,
          parent: 1,
          conversation: 1,
          text: 'my reply',
          authorId: 'me',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Posting...'), findsNothing);
      expect(find.text('my reply'), findsOneWidget); // the real reply row
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      verify(
        () => posts.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: 'my reply',
          replyToPostId: postId(1),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
        ),
      ).called(1);
    });

    testWidgets('a failed reply keeps the text and says why', (tester) async {
      stubReply(() async => throw const NotFoundException('post not found'));
      await open(tester);

      await tester.enterText(find.byType(TextField), 'my reply');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Reply'));
      await tester.pumpAndSettle();

      expect(
        find.text("The post you're replying to isn't available any more."),
        findsOneWidget,
      );
      expect(find.text('Posting...'), findsNothing);
      expect(find.text('my reply'), findsOneWidget); // still in the field
      expect(replyButton(tester).onPressed, isNotNull);
    });

    testWidgets('FEATURE_DISABLED on reply removes the composer, keeps the '
        'thread', (tester) async {
      stubReply(
        () async =>
            throw const FeatureDisabledException('off', feature: 'replies'),
      );
      await open(tester);

      await tester.enterText(find.byType(TextField), 'my reply');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Reply'));
      await tester.pumpAndSettle();

      expect(find.text("Replies aren't available right now."), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('root'), findsOneWidget);
    });

    testWidgets('281 code points: counter -1 and Reply disabled', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'a' * 281);
      await tester.pump();
      expect(find.text('-1'), findsOneWidget);
      expect(replyButton(tester).onPressed, isNull);
    });
  });

  testWidgets('dark mode, text scale 2.0, narrow: no overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    stubThread(
      (_) async => pb.GetThreadResponse(
        focal: replyView(1, parent: 4, conversation: 4, text: 'focal ' * 20),
        parentUnavailable: true,
        replies: [
          replyView(2, parent: 1, conversation: 4, text: 'a reply ' * 20),
        ],
      ),
    );

    await open(tester, theme: appDarkTheme, textScale: 2);

    expect(tester.takeException(), isNull);
    expect(find.text('This post is unavailable'), findsOneWidget);
  });

  testWidgets('wide layout is constrained and does not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    stubThread(
      (_) async => pb.GetThreadResponse(focal: postView(1, text: 'wide')),
    );

    await open(tester, theme: appDarkTheme);

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.text('wide')).width,
      lessThanOrEqualTo(AppBreakpoints.mobile),
    );
  });

  testWidgets('a blocked focal author sits behind a "Show post" banner', (
    tester,
  ) async {
    stubThread(
      (_) async => pb.GetThreadResponse(focal: postView(1, text: 'hidden')),
    );
    when(() => graphRepository.cached('u1'))
        .thenReturn(graph.Relationship(userId: 'u1', blocking: true));

    await open(tester, features: const {'posts', 'replies', 'graph'});

    expect(find.text('You blocked @hu1 ·'), findsOneWidget);
    expect(find.text('hidden'), findsNothing);

    await tester.tap(find.text('Show post'));
    await tester.pumpAndSettle();

    expect(find.text('hidden'), findsOneWidget);
  });

  testWidgets('a blocked parent is gated too', (tester) async {
    stubThread(
      (_) async => pb.GetThreadResponse(
        focal: replyView(1, parent: 5, conversation: 5, text: 'my reply'),
        parent: pb.PostView(
          post: pb.Post(
            postId: postId(5),
            text: 'parent words',
            author: common.AuthorSnapshot(userId: 'bad', handle: 'bad'),
          ),
        ),
      ),
    );
    when(() => graphRepository.cached('bad'))
        .thenReturn(graph.Relationship(userId: 'bad', blocking: true));

    await open(tester, features: const {'posts', 'replies', 'graph'});

    expect(find.text('You blocked @bad ·'), findsOneWidget);
    expect(find.text('parent words'), findsNothing);
    expect(find.text('my reply'), findsOneWidget);
  });

  testWidgets('a post removed elsewhere leaves the replies', (tester) async {
    stubThread(
      (_) async => pb.GetThreadResponse(
        focal: postView(1),
        replies: [
          replyView(2, parent: 1, conversation: 1),
          replyView(3, parent: 1, conversation: 1),
        ],
      ),
    );
    await open(tester);
    expect(find.text('reply 2'), findsOneWidget);

    removed.add(postId(2));
    await tester.pumpAndSettle();

    expect(find.text('reply 2'), findsNothing);
    expect(find.text('reply 3'), findsOneWidget);
  });

  testWidgets('a removed parent becomes a tombstone', (tester) async {
    stubThread(
      (_) async => pb.GetThreadResponse(
        focal: replyView(1, parent: 5, conversation: 5, text: 'focal reply'),
        parent: postView(5, text: 'the parent'),
      ),
    );
    await open(tester);
    expect(find.text('the parent'), findsOneWidget);

    removed.add(postId(5));
    await tester.pumpAndSettle();

    expect(find.text('the parent'), findsNothing);
    expect(find.text('This post is unavailable'), findsOneWidget);
  });

  testWidgets('a failed pull-to-refresh keeps the thread and says so', (
    tester,
  ) async {
    var fail = false;
    stubThread((_) async {
      if (fail) throw const NetworkException('offline');
      return pb.GetThreadResponse(focal: postView(1, text: 'kept'));
    });
    await open(tester);

    fail = true;
    await tester.fling(find.text('kept'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(find.text('kept'), findsOneWidget);
    expect(
      find.text('No connection. Showing the conversation as it was.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed page is not retried by scrolling', (tester) async {
    var pageCalls = 0;
    stubThread((token) async {
      if (token.isEmpty) {
        return pb.GetThreadResponse(
          focal: postView(1),
          replies: [
            for (var n = 2; n < 14; n++)
              replyView(n, parent: 1, conversation: 1),
          ],
          nextPageToken: 'n1',
        );
      }
      pageCalls++;
      throw const NetworkException('offline');
    });
    await open(tester);

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -3000),
      3000,
    );
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load more replies."), findsOneWidget);
    expect(pageCalls, 1);

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 300),
      1000,
    );
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -3000),
      3000,
    );
    await tester.pumpAndSettle();
    expect(pageCalls, 1);
  });

  group('reply permission (ADR-0021)', () {
    void stubFocal(ReplyPermission permission) {
      final focal = postView(1, text: 'the focal post')
        ..viewerReplyPermission = permission;
      stubThread((_) async => pb.GetThreadResponse(focal: focal));
    }

    testWidgets('NOT_ALLOWED disables the docked composer, with no reason', (
      tester,
    ) async {
      stubFocal(ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED);
      await open(tester);

      expect(find.text("You can't reply to this post"), findsOneWidget);
      expect(find.text('Post your reply'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      final pill = tester.widget<AppPillButton>(
        find.widgetWithText(AppPillButton, 'Reply'),
      );
      expect(pill.onPressed, isNull);
    });

    for (final permission in [
      ReplyPermission.REPLY_PERMISSION_UNSPECIFIED,
      ReplyPermission.REPLY_PERMISSION_UNKNOWN,
      ReplyPermission.REPLY_PERMISSION_ALLOWED,
    ]) {
      testWidgets('${permission.name} keeps the composer usable', (
        tester,
      ) async {
        stubFocal(permission);
        await open(tester);

        expect(find.text('Post your reply'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
      });
    }
  });
}
