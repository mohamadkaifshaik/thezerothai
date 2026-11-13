import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/posts/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/features/posts/presentation/post_detail_screen.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPermission;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/timeline_fixtures.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockEngagementRepository extends Mock implements EngagementRepository {}

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
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
            BlocProvider<EngagementCubit>(
              create: (_) =>
                  EngagementCubit(repository: _MockEngagementRepository()),
            ),
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
            'text x$textScale: no overflow, replies, reply entry',
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
              // builds lazily, so scroll to the last reply.
              await tester.scrollUntilVisible(
                find.text('second reply'),
                200,
                // The list itself (an inline reply field has its own).
                scrollable: find
                    .descendant(
                      of: find.byType(CustomScrollView),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              );
              expect(find.text('second reply'), findsOneWidget);
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

    testWidgets('no heading between the open post and its replies (X)', (
      tester,
    ) async {
      stubThread(
        () async => pb.GetThreadResponse(
          focal: postView(1, text: 'root'),
          replies: [_reply(2, text: 'a reply')],
        ),
      );
      await open(tester);

      expect(find.text('Replies'), findsNothing);
      expect(find.text('a reply'), findsOneWidget);
    });

    for (final width in const [360.0, 599.0]) {
      testWidgets('phones (${width.toInt()}) put the reply row in the list, '
          'right under the open post', (tester) async {
        stubThread(
          () async => pb.GetThreadResponse(
            focal: postView(1, text: 'root'),
            replies: [_reply(2, text: 'a reply')],
          ),
        );
        await open(tester, size: Size(width, 844));

        final entry = tester.getTopLeft(find.text('Post your reply')).dy;
        expect(entry, greaterThan(tester.getTopLeft(find.text('root')).dy));
        expect(entry, lessThan(tester.getTopLeft(find.text('a reply')).dy));
        expect(
          find.ancestor(
            of: find.text('Post your reply'),
            matching: find.byType(CustomScrollView),
          ),
          findsOneWidget,
        );
        // The design's row: a 36 dp avatar and the compact Reply.
        final avatar = find.descendant(
          of: find
              .ancestor(
                of: find.text('Post your reply'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byType(AppAvatar),
        );
        expect(tester.getSize(avatar), const Size.square(36));
        expect(replyButton(tester).compact, isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the phone reply row survives the keyboard: focused, it stays '
        'on screen above the inset', (tester) async {
      stubThread(
        () async => pb.GetThreadResponse(
          focal: postView(1, text: 'root'),
          replies: [for (var i = 2; i < 12; i++) _reply(i, text: 'reply $i')],
        ),
      );
      await open(tester, size: const Size(360, 640));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      final field = tester.getRect(find.byType(TextField));
      expect(field.bottom, lessThanOrEqualTo(640 - 300));
      expect(field.top, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('wide screens put the reply entry right under the open post', (
      tester,
    ) async {
      stubThread(
        () async => pb.GetThreadResponse(
          focal: postView(1, text: 'root'),
          replies: [_reply(2, text: 'a reply')],
        ),
      );
      await open(tester, size: const Size(1440, 900));

      final entry = tester.getTopLeft(find.text('Post your reply')).dy;
      expect(entry, greaterThan(tester.getTopLeft(find.text('root')).dy));
      expect(entry, lessThan(tester.getTopLeft(find.text('a reply')).dy));
      expect(
        find.ancestor(
          of: find.text('Post your reply'),
          matching: find.byType(CustomScrollView),
        ),
        findsOneWidget,
      );
    });

    for (final (from, to) in const [
      (Size(390, 844), Size(1440, 900)),
      (Size(1440, 900), Size(390, 844)),
    ]) {
      testWidgets('a draft survives crossing the width '
          '(${from.width.toInt()} -> ${to.width.toInt()})', (tester) async {
        stubThread(
          () async => pb.GetThreadResponse(
            focal: postView(1, text: 'root'),
            replies: [_reply(2, text: 'a reply')],
          ),
        );
        await open(tester, size: from);

        await tester.enterText(find.byType(TextField), 'half a reply');
        await tester.pump();
        tester.view.physicalSize = to;
        await tester.pumpAndSettle();

        expect(find.text('half a reply'), findsOneWidget);
        expect(find.text('root'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('Reply on the open post focuses the reply entry '
          '(${size.width.toInt()})', (tester) async {
        stubThread(
          () async => pb.GetThreadResponse(
            focal: postView(1, text: 'root'),
            replies: [_reply(2, text: 'a reply')],
          ),
        );
        await open(
          tester,
          size: size,
          features: const {'posts', 'replies', 'engagement'},
        );

        // The open post's own Reply (on wide screens the entry's pill is
        // under the same key).
        final focal = find.descendant(
          of: find.byKey(ValueKey('focal-${postId(1)}')),
          matching: find.byType(PostCard),
        );
        await tester.tap(
          find.descendant(of: focal, matching: find.bySemanticsLabel('Reply')),
        );
        await tester.pump();

        final field = tester.widget<TextField>(
          find.ancestor(
            of: find.text('Post your reply'),
            matching: find.byType(TextField),
          ),
        );
        expect(field.focusNode!.hasFocus, isTrue);
      });
    }

    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('NOT_ALLOWED: the open post keeps a disabled Reply with the '
          'hint (${size.width.toInt()})', (tester) async {
        final handle = tester.ensureSemantics();
        stubThread(
          () async => pb.GetThreadResponse(
            focal: postView(1, text: 'root')
              ..viewerReplyPermission =
                  ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED,
          ),
        );
        await open(
          tester,
          size: size,
          features: const {'posts', 'replies', 'engagement'},
        );

        final reply = find.descendant(
          of: find.descendant(
            of: find.byKey(ValueKey('focal-${postId(1)}')),
            matching: find.byType(PostCard),
          ),
          matching: find.bySemanticsLabel('Reply'),
        );
        expect(reply, findsOneWidget);
        expect(
          tester.getSemantics(reply),
          isSemantics(
            label: 'Reply',
            hint: kReplyNotAllowedHint,
            isEnabled: false,
          ),
        );
        expect(tester.takeException(), isNull);
        handle.dispose();
      });
    }

    testWidgets('replies closed: the open post still uses the focal layout '
        'and offers no Reply', (tester) async {
      stubThread(
        () async => pb.GetThreadResponse(focal: postView(1, text: 'root')),
      );
      await open(tester, features: const {'posts', 'replies', 'engagement'});
      final context = tester.element(find.byType(PostCard).first);
      context.read<ThreadCubit>().repliesBecameUnavailable();
      await tester.pumpAndSettle();

      final card = tester.widget<PostCard>(find.byType(PostCard).first);
      expect(card.focal, isTrue);
      expect(card.showReply, isFalse);
      expect(find.text('Post your reply'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(ValueKey('focal-${postId(1)}')),
          matching: find.bySemanticsLabel('Reply'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
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

    testWidgets('the open post sits on the plain background, above the '
        'replies, in the focal layout', (tester) async {
      stubThread(
        () async => pb.GetThreadResponse(
          focal: postView(1, text: 'root'),
          replies: [_reply(2, text: 'a reply')],
        ),
      );
      await open(tester, brightness: Brightness.dark);

      final focal = find.byKey(ValueKey('focal-${postId(1)}'));
      expect(
        find
            .ancestor(of: focal, matching: find.byType(ColoredBox))
            .evaluate()
            .map((e) => (e.widget as ColoredBox).color),
        isNot(contains(appDarkTheme.colorScheme.surfaceContainerLow)),
      );
      expect(
        tester
            .widget<PostCard>(
              find.descendant(of: focal, matching: find.byType(PostCard)),
            )
            .focal,
        isTrue,
      );
      expect(
        tester.getTopLeft(find.text('a reply')).dy,
        greaterThan(tester.getTopLeft(find.text('root')).dy),
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

    for (final (width, avatar) in const [(599.0, 36.0), (600.0, 48.0)]) {
      testWidgets('at ${width.toInt()}dp the entry is inline, with a '
          '${avatar.toInt()} dp avatar column', (tester) async {
        await open(tester, size: Size(width, 844));

        expect(
          find.ancestor(
            of: find.text('Post your reply'),
            matching: find.byType(CustomScrollView),
          ),
          findsOneWidget,
        );
        final row = find
            .ancestor(
              of: find.text('Post your reply'),
              matching: find.byType(Row),
            )
            .first;
        final lead = find.descendant(of: row, matching: find.byType(AppAvatar));
        expect(tester.getSize(lead).width, lessThanOrEqualTo(avatar));
        expect(replyButton(tester).compact, isTrue);
      });
    }

    testWidgets('wide: the inline entry keeps focus scrolled far away, and a '
        'reply sent meanwhile leaves no draft', (tester) async {
      stubThread(
        () async => pb.GetThreadResponse(
          focal: postView(1, text: 'root'),
          replies: [
            for (var i = 2; i < 30; i++) _reply(i, text: 'reply $i ' * 8),
          ],
        ),
      );
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
      await open(tester, size: const Size(1440, 600));

      await tester.enterText(find.byType(TextField), 'my reply');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Reply'));
      await tester.pump();

      final list = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.drag(list, const Offset(0, -3000));
      // The busy Reply spinner never settles while the send is pending.
      await tester.pump(const Duration(seconds: 1));
      // Still built while scrolled away (not a lazy list child).
      expect(find.byType(TextField, skipOffstage: false), findsOneWidget);

      done.complete(
        pb.PostView(
          post: pb.Post(
            postId: postId(99),
            text: 'my reply',
            replyToPostId: postId(1),
            conversationId: postId(1),
            author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(list, const Offset(0, 6000));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);
      expect(find.text('Post your reply'), findsOneWidget);

      // Focus survives scrolling the entry out of view.
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.drag(list, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byType(TextField, skipOffstage: false))
            .focusNode!
            .hasFocus,
        isTrue,
      );
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
