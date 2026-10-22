import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/post_detail_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/timeline_fixtures.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

pb.PostView _reply(int n, {required String text}) => pb.PostView(
  post: pb.Post(
    postId: postId(n),
    text: text,
    replyToPostId: postId(1),
    replyToHandle: 'hu1',
    conversationId: postId(1),
    author: common.AuthorSnapshot(userId: 'u2', handle: 'hu2'),
  ),
);

/// Layout and state coverage of the restyled post detail: the focal post, its
/// replies and the reply entry (UI slice compose + detail). Thread behaviour
/// is owned by thread_screen_test.dart and post_detail_screen_test.dart.
void main() {
  late MockPostsRepository posts;
  late _MockGraphRepository graphRepository;
  late _MockOnboardingBloc onboardingBloc;
  late StreamController<String> removed;

  setUp(() {
    removed = StreamController<String>.broadcast();
    addTearDown(removed.close);
    posts = MockPostsRepository();
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
    graphRepository = _MockGraphRepository();
    onboardingBloc = _MockOnboardingBloc();
    when(() => graphRepository.cached(any())).thenReturn(null);
  });

  void stubThread(Future<pb.GetThreadResponse> Function() answer) {
    when(
      () => posts.getThread(
        postId(1),
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((_) => answer());
  }

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    Set<String> features = const {'posts', 'replies'},
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    unawaited(router.push('/post/${postId(1)}'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  AppPillButton replyButton(WidgetTester tester) =>
      tester.widget(find.widgetWithText(AppPillButton, 'Reply'));

  group('data, in every size, theme and text scale', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final brightness in Brightness.values) {
        for (final textScale in const [1.0, 2.0]) {
          testWidgets(
            '${size.width.toInt()}x${size.height.toInt()} ${brightness.name} '
            'text x$textScale: no overflow, Replies header, reply entry',
            (tester) async {
              stubThread(
                () async => pb.GetThreadResponse(
                  focal: postView(1, text: 'the focal post ' * 6),
                  replies: [
                    _reply(2, text: 'first reply ' * 6),
                    _reply(3, text: 'second reply'),
                  ],
                ),
              );
              await open(
                tester,
                size: size,
                brightness: brightness,
                textScale: textScale,
              );

              expect(tester.takeException(), isNull);
              // At large text the focal post can fill the screen: the list
              // builds lazily, so scroll to the heading.
              await tester.scrollUntilVisible(
                find.text('Replies'),
                200,
                scrollable: find.descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                ),
              );
              expect(find.text('Replies'), findsOneWidget);
              expect(find.text('Post your reply'), findsOneWidget);
              expect(tester.takeException(), isNull);
              expect(
                tester.getSize(find.byType(AppPillButton)).height,
                greaterThanOrEqualTo(48),
              );
            },
          );
        }
      }
    }

    testWidgets('the Replies heading is announced as a header', (tester) async {
      final handle = tester.ensureSemantics();
      stubThread(
        () async => pb.GetThreadResponse(
          focal: postView(1, text: 'root'),
          replies: [_reply(2, text: 'a reply')],
        ),
      );
      await open(tester);

      expect(
        tester.getSemantics(find.text('Replies')),
        isSemantics(label: 'Replies', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('wide screens keep the thread and the reply entry in the '
        'main column', (tester) async {
      stubThread(
        () async => pb.GetThreadResponse(
          focal: postView(1, text: 'root'),
          replies: [_reply(2, text: 'a reply')],
        ),
      );
      await open(tester, size: const Size(1440, 900));

      const gutter = (1440 - AppLayout.mainColumnMaxWidth) / 2;
      expect(
        tester.getTopRight(find.byType(AppPillButton)).dx,
        lessThanOrEqualTo(1440 - gutter),
      );
      expect(
        tester.getTopLeft(find.text('root')).dx,
        greaterThanOrEqualTo(gutter),
      );
    });

    testWidgets('the focal post sits on its own tint, above the replies', (
      tester,
    ) async {
      stubThread(
        () async => pb.GetThreadResponse(
          focal: postView(1, text: 'root'),
          replies: [_reply(2, text: 'a reply')],
        ),
      );
      await open(tester, brightness: Brightness.dark);

      final tint = tester.widget<ColoredBox>(
        find
            .ancestor(of: find.text('root'), matching: find.byType(ColoredBox))
            .first,
      );
      expect(tint.color, appDarkTheme.colorScheme.surfaceContainerLow);
      expect(
        tester.getTopLeft(find.text('Replies')).dy,
        greaterThan(tester.getTopLeft(find.text('root')).dy),
      );
      expect(
        tester.getTopLeft(find.text('a reply')).dy,
        greaterThan(tester.getTopLeft(find.text('Replies')).dy),
      );
    });
  });

  group('loading, empty and error', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('loading ${size.width.toInt()}: skeleton, no overflow', (
        tester,
      ) async {
        final done = Completer<pb.GetThreadResponse>();
        stubThread(() => done.future);
        await open(tester, size: size, settle: false);

        expect(find.bySemanticsLabel('Loading conversation'), findsOneWidget);
        expect(tester.takeException(), isNull);

        done.complete(pb.GetThreadResponse(focal: postView(1, text: 'root')));
        await tester.pumpAndSettle();
      });

      testWidgets('empty ${size.width.toInt()}: guidance, no Replies header', (
        tester,
      ) async {
        stubThread(
          () async => pb.GetThreadResponse(focal: postView(1, text: 'root')),
        );
        await open(tester, size: size, brightness: Brightness.dark);

        expect(find.text('No replies yet'), findsOneWidget);
        expect(find.text('Replies'), findsNothing);
        expect(find.text('Post your reply'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('error ${size.width.toInt()}: friendly message and Retry', (
        tester,
      ) async {
        stubThread(() async => throw const NetworkException('offline'));
        await open(tester, size: size);

        expect(
          find.text('No connection. Check your network and try again.'),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Post your reply'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('reply entry', () {
    setUp(() {
      stubThread(
        () async => pb.GetThreadResponse(focal: postView(1, text: 'root')),
      );
    });

    testWidgets('disabled while empty, enabled with text', (tester) async {
      await open(tester);
      expect(replyButton(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'my reply');
      await tester.pump();
      expect(replyButton(tester).onPressed, isNotNull);
      expect(find.text('272'), findsOneWidget);
    });

    testWidgets('the counter still counts NFC code points: 280 decomposed '
        'pairs post, 281 do not', (tester) async {
      await open(tester);

      await tester.enterText(find.byType(TextField), 'é' * 280);
      await tester.pump();
      expect(find.text('0'), findsOneWidget);
      expect(replyButton(tester).onPressed, isNotNull);

      await tester.enterText(find.byType(TextField), 'é' * 281);
      await tester.pump();
      expect(find.text('-1'), findsOneWidget);
      expect(replyButton(tester).onPressed, isNull);
    });

    testWidgets('sending: busy button announced as "Sending reply", field '
        'off, optimistic row', (tester) async {
      final handle = tester.ensureSemantics();
      final done = Completer<pb.PostView>();
      when(
        () => posts.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          replyToPostId: postId(1),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
        ),
      ).thenAnswer((_) => done.future);
      await open(tester);

      await tester.enterText(find.byType(TextField), 'my reply');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Reply'));
      await tester.pump();

      expect(replyButton(tester).busy, isTrue);
      expect(replyButton(tester).onPressed, isNull);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.text('Posting...'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(AppPillButton)),
        isSemantics(label: 'Sending reply', isButton: true, isLiveRegion: true),
      );

      done.complete(
        pb.PostView(
          post: pb.Post(
            postId: postId(9),
            text: 'my reply',
            replyToPostId: postId(1),
            conversationId: postId(1),
            author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(replyButton(tester).busy, isFalse);
      handle.dispose();
    });

    testWidgets('Reply is a button for assistive tech, once', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      expect(find.bySemanticsLabel('Reply'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(AppPillButton)),
        isSemantics(label: 'Reply', isButton: true, isEnabled: false),
      );
      handle.dispose();
    });
  });

  group('plain post (replies flag off)', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '${size.width.toInt()} ${brightness.name}: the post stays in the '
          'main column, no overflow',
          (tester) async {
            when(() => posts.getPost(postId(1)))
                .thenAnswer((_) async => postView(1, text: 'plain ' * 20));
            await open(
              tester,
              size: size,
              brightness: brightness,
              features: const {'posts'},
            );

            expect(tester.takeException(), isNull);
            expect(
              tester.getSize(find.textContaining('plain')).width,
              lessThanOrEqualTo(AppLayout.mainColumnMaxWidth),
            );
            expect(find.text('Post your reply'), findsNothing);
          },
        );
      }
    }
  });
}
