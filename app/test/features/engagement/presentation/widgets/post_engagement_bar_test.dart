import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/share/native_share.dart';
import 'package:dzeroth/core/share/share_links.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
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
import 'package:dzeroth/shared/widgets/post_action_bar.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';

class MockEngagementRepository extends Mock implements EngagementRepository {}

class MockPostsRepository extends Mock implements PostsRepository {}

class _FakeNativeShare implements NativeShare {
  @override
  bool get isAvailable => true;

  final calls = <({String url, Rect? anchor})>[];

  @override
  Future<void> shareUrl(String url, {Rect? anchor}) async =>
      calls.add((url: url, anchor: anchor));
}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

eng.PostEngagement _answer({
  bool liked = false,
  bool reposted = false,
  int likes = 0,
  int reposts = 0,
}) => eng.PostEngagement(
  postId: postId(1),
  likedByViewer: liked,
  repostedByViewer: reposted,
  likeCount: Int64(likes),
  repostCount: Int64(reposts),
);

pb.PostView _view({
  bool liked = false,
  bool reposted = false,
  int likes = 4,
  int reposts = 2,
  int replies = 1,
}) => pb.PostView(
  post: pb.Post(
    postId: postId(1),
    text: 'hello',
    author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
    likeCount: Int64(likes),
    repostCount: Int64(reposts),
    replyCount: Int64(replies),
  ),
  likedByViewer: liked,
  repostedByViewer: reposted,
);

pb.PostView _repostView({bool liked = false}) => pb.PostView(
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
  likedByViewer: liked,
);

void main() {
  late MockEngagementRepository repo;
  late MockPostsRepository posts;
  late MockOnboardingBloc onboarding;
  late EngagementCubit cubit;
  Object? pushedExtra;
  String? pushedLocation;

  setUp(() {
    repo = MockEngagementRepository();
    posts = MockPostsRepository();
    onboarding = MockOnboardingBloc();
    cubit = EngagementCubit(repository: repo);
    pushedExtra = null;
    pushedLocation = null;
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {'engagement', 'replies', 'quotes'},
      ),
    );
  });

  tearDown(() => cubit.close());

  Future<void> pump(
    WidgetTester tester,
    pb.PostView view, {
    double width = 400,
    double textScale = 1,
    bool showReply = true,
    Set<String> features = const {'engagement', 'replies', 'quotes'},
    ThemeData? theme,
    ShareLinks? shareLinks,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: features,
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: PostEngagementBar(view: view, showReply: showReply),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) {
            pushedLocation = state.uri.toString();
            return const Scaffold(body: Text('post page'));
          },
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) {
            pushedLocation = state.uri.toString();
            pushedExtra = state.extra;
            return const Scaffold(body: Text('compose page'));
          },
        ),
      ],
    );
    await tester.pumpWidget(
      ShareLinksScope(
        links: shareLinks,
        child: RepositoryProvider<PostsRepository>.value(
          value: posts,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<OnboardingBloc>.value(value: onboarding),
              BlocProvider<EngagementCubit>.value(value: cubit),
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
      ),
    );
    await tester.pumpAndSettle();
  }

  void stubLike(Future<eng.PostEngagement> Function() answer) {
    when(
      () => repo.like(
        postId: any(named: 'postId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) => answer());
  }

  testWidgets('shows counts, reply/repost/like and no Share without a scope', (
    tester,
  ) async {
    await pump(tester, _view(liked: true, likes: 1200));

    expect(find.text('1.2K'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byIcon(Icons.ios_share), findsNothing);
  });

  testWidgets('semantics: labelled buttons with the state and count', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester, _view(liked: true, reposted: true));

    final like = tester.getSemantics(find.bySemanticsLabel('Unlike, 4'));
    expect(like.flagsCollection.isButton, isTrue);
    expect(like.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(like.rect.size.shortestSide, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Undo repost, 2'), findsOneWidget);
    expect(find.bySemanticsLabel('Reply, 1'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('Like is optimistic and sends the post id', (tester) async {
    final completer = Completer<eng.PostEngagement>();
    stubLike(() => completer.future);
    await pump(tester, _view());

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump();

    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    verify(
      () => repo.like(
        postId: postId(1),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);

    completer.complete(_answer(liked: true, likes: 9));
    await tester.pumpAndSettle();
    expect(find.text('9'), findsOneWidget);
  });

  testWidgets('a failed Like rolls back and shows one friendly snackbar', (
    tester,
  ) async {
    stubLike(
      () async => throw const QuotaExceededException('x', quota: 'likes'),
    );
    await pump(tester, _view());

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(
      find.text("You've reached today's limit for likes. It resets tomorrow."),
      findsOneWidget,
    );
    expect(cubit.state.failure, isNull, reason: 'cleared once shown');
  });

  testWidgets('a REPOST row acts on the original post', (tester) async {
    stubLike(() async => _answer(liked: true, likes: 11));
    await pump(tester, _repostView());

    // Counts are unknown on a REPOST row: nothing is shown until an answer.
    expect(find.text('0'), findsNothing);
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();

    verify(
      () => repo.like(
        postId: postId(1),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(find.text('11'), findsOneWidget);
  });

  testWidgets('a refreshed row beats an older cubit entry', (tester) async {
    stubLike(() async => _answer(liked: true, likes: 5));
    await pump(tester, _view());
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();
    expect(find.text('5'), findsOneWidget);

    // The feed refreshed: other people liked it too and the row says 30.
    await pump(tester, _view(liked: true, likes: 30));
    expect(find.text('30'), findsOneWidget);
    expect(find.text('5'), findsNothing);
  });

  group('repost sheet', () {
    testWidgets('Repost sends RepostPost', (tester) async {
      when(
        () => repo.repost(
          postId: any(named: 'postId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async => _answer(reposted: true, reposts: 3));
      await pump(tester, _view());

      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pumpAndSettle();
      expect(find.text('Repost'), findsOneWidget);
      expect(find.text('Quote'), findsOneWidget);
      await tester.tap(find.text('Repost'));
      await tester.pumpAndSettle();

      verify(
        () => repo.repost(
          postId: postId(1),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('a reposted post offers Undo repost', (tester) async {
      when(
        () => repo.undoRepost(
          postId: any(named: 'postId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async => _answer(reposts: 1));
      await pump(tester, _view(reposted: true));

      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo repost'));
      await tester.pumpAndSettle();

      verify(
        () => repo.undoRepost(
          postId: postId(1),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });

    testWidgets('Quote opens the quote composer with a preview', (
      tester,
    ) async {
      await pump(tester, _view());

      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quote'));
      await tester.pumpAndSettle();

      expect(pushedLocation, '/compose?quote=${postId(1)}');
      expect(pushedExtra, isA<pb.EmbeddedPost>());
      expect((pushedExtra as pb.EmbeddedPost).text, 'hello');
      verifyNever(
        () => repo.repost(
          postId: any(named: 'postId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    Future<void> expectQuoteAbsent(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pumpAndSettle();

      expect(find.text('Repost'), findsOneWidget);
      expect(find.text('Quote'), findsNothing);
    }

    // W2-11: Quote needs `engagement` AND `quotes` in GetMe.enabled_features.
    for (final c in <(String, Set<String>)>[
      ('engagement only', {'engagement', 'replies'}),
      ('quotes only', {'quotes', 'replies'}),
      ('neither', {'replies'}),
    ]) {
      testWidgets('Quote is not offered with ${c.$1}', (tester) async {
        await pump(tester, _view(), features: c.$2);

        await expectQuoteAbsent(tester);
      });
    }

    testWidgets('Quote is not offered after a server FEATURE_DISABLED quotes, '
        'even with both flags in GetMe', (tester) async {
      when(() => posts.subFeatureEnabled('quotes')).thenReturn(false);
      await pump(tester, _view());

      await expectQuoteAbsent(tester);
    });

    testWidgets('dismissing the sheet sends nothing', (tester) async {
      await pump(tester, _view());

      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      verifyZeroInteractions(repo);
    });
  });

  group('reply', () {
    testWidgets('opens the post when replies are on', (tester) async {
      await pump(tester, _view());

      await tester.tap(find.byIcon(Icons.chat_bubble_outline));
      await tester.pumpAndSettle();

      expect(pushedLocation, '/post/${postId(1)}');
    });

    testWidgets('hidden with the replies flag off or showReply false', (
      tester,
    ) async {
      await pump(tester, _view(), features: const {'engagement'});
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);

      await pump(tester, _view(), showReply: false);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
    });
  });

  group('reply permission (ADR-0021)', () {
    pb.PostView withPermission(ReplyPermission permission) {
      final view = _view();
      view.viewerReplyPermission = permission;
      return view;
    }

    testWidgets('NOT_ALLOWED: Reply stays, disabled, with a why-less hint', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        withPermission(ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED),
      );

      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
      final node = tester.getSemantics(find.bySemanticsLabel('Reply, 1'));
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isEnabled, Tristate.isFalse);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      expect(node.hint, "You can't reply to this post");
      expect(node.rect.size.shortestSide, greaterThanOrEqualTo(48));

      // Tapping does nothing; long press shows the tooltip.
      await tester.tap(find.byIcon(Icons.chat_bubble_outline));
      await tester.pumpAndSettle();
      expect(pushedLocation, isNull);
      await tester.longPress(find.byIcon(Icons.chat_bubble_outline));
      await tester.pumpAndSettle();
      expect(find.text("You can't reply to this post"), findsOneWidget);
      handle.dispose();
    });

    testWidgets(
      'NOT_ALLOWED adds nothing with replies off or showReply false',
      (tester) async {
        await pump(
          tester,
          withPermission(ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED),
          features: const {'engagement'},
        );
        expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);

        await pump(
          tester,
          withPermission(ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED),
          showReply: false,
        );
        expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      },
    );

    for (final permission in [
      ReplyPermission.REPLY_PERMISSION_UNSPECIFIED,
      ReplyPermission.REPLY_PERMISSION_UNKNOWN,
      ReplyPermission.REPLY_PERMISSION_ALLOWED,
    ]) {
      testWidgets('${permission.name}: Reply stays enabled', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester, withPermission(permission));

        final node = tester.getSemantics(find.bySemanticsLabel('Reply, 1'));
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        expect(node.hint, isNot("You can't reply to this post"));
        await tester.tap(find.byIcon(Icons.chat_bubble_outline));
        await tester.pumpAndSettle();
        expect(pushedLocation, '/post/${postId(1)}');
        handle.dispose();
      });
    }

    testWidgets('NOT_ALLOWED at 320dp and text x2 does not overflow', (
      tester,
    ) async {
      await pump(
        tester,
        withPermission(ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED),
        width: 320,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a REPOST with no usable embed renders nothing', (tester) async {
    final view = pb.PostView(
      post: pb.Post(
        postId: postId(50),
        kind: PostKind.POST_KIND_REPOST,
        embedded: pb.EmbeddedPost(postId: postId(1), unavailable: true),
      ),
    );
    await pump(tester, view);

    expect(find.byIcon(Icons.favorite_border), findsNothing);
  });

  testWidgets('large text on a narrow phone does not overflow', (tester) async {
    await pump(
      tester,
      _view(liked: true, reposted: true, likes: 2500000, reposts: 1200),
      width: 320,
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------
  // W2-13 (tester): the repost / quote sheet (W2-11) across the responsive
  // matrix.
  // ---------------------------------------------------------------------

  group('W2-13 responsive matrix: repost sheet with Quote', () {
    for (final dark in [false, true]) {
      for (final width in const [360.0, 600.0, 1200.0]) {
        for (final scale in const [1.0, 1.3, 2.0]) {
          testWidgets(
            '${dark ? 'dark' : 'light'} ${width.toInt()}dp x$scale: both rows '
            'visible, 48dp, inside the screen',
            (tester) async {
              tester.view.physicalSize = Size(width, 900);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
              final handle = tester.ensureSemantics();
              await pump(
                tester,
                _view(),
                width: width,
                textScale: scale,
                theme: dark ? appDarkTheme : appLightTheme,
              );

              await tester.tap(find.byIcon(Icons.repeat));
              await tester.pumpAndSettle();

              expect(tester.takeException(), isNull);
              for (final label in ['Repost', 'Quote']) {
                expect(find.text(label), findsOneWidget);
                final row = tester.getSemantics(find.bySemanticsLabel(label));
                expect(row.rect.height, greaterThanOrEqualTo(48));
                final box = tester.getRect(find.text(label));
                expect(box.left, greaterThanOrEqualTo(0));
                expect(box.right, lessThanOrEqualTo(width));
                expect(box.bottom, lessThanOrEqualTo(900));
              }
              handle.dispose();
            },
          );
        }
      }
    }
  });

  testWidgets('W2-13: Quote from a REPOST row quotes the original, with the '
      'original as the preview', (tester) async {
    await pump(tester, _repostView());

    await tester.tap(find.byIcon(Icons.repeat));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quote'));
    await tester.pumpAndSettle();

    expect(pushedLocation, '/compose?quote=${postId(1)}');
    expect(pushedExtra, isA<pb.EmbeddedPost>());
    expect((pushedExtra as pb.EmbeddedPost).postId, postId(1));
    expect((pushedExtra as pb.EmbeddedPost).text, 'original');
  });

  group('share (W2-8)', () {
    late List<String> clipboard;
    late _FakeNativeShare native;
    late ShareLinks links;

    setUp(() {
      clipboard = [];
      native = _FakeNativeShare();
      links = ShareLinks(origin: 'https://dzeroth.com', nativeShare: native);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    testWidgets('is the right-most action and labelled', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, _view(), shareLinks: links);

      final share = find.byIcon(Icons.ios_share);
      expect(share, findsOneWidget);
      expect(find.bySemanticsLabel('Share'), findsOneWidget);
      final bar = tester.getRect(find.byType(PostActionBar));
      expect(bar.right - tester.getRect(share).right, lessThan(24));
      handle.dispose();
    });

    testWidgets('a plain row copies its own link', (tester) async {
      await pump(tester, _view(), shareLinks: links);
      await tester.tap(find.byIcon(Icons.ios_share));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();

      expect(clipboard, ['https://dzeroth.com/post/${postId(1)}']);
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });

    testWidgets('a REPOST row shares the original, at 1200dp too', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(tester.view.reset);
      await pump(tester, _repostView(), width: 500, shareLinks: links);
      final shareCenter = tester.getCenter(find.byIcon(Icons.ios_share));
      await tester.tap(find.byIcon(Icons.ios_share));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('Share via...'));
      await tester.pumpAndSettle();

      expect(native.calls.single.url, 'https://dzeroth.com/post/${postId(1)}');
      // The popover anchor is the Share button (a reorder of the row fails here).
      expect(native.calls.single.anchor!.contains(shareCenter), isTrue);
      expect(clipboard, isEmpty);
    });

    testWidgets('sends no request and needs no flag beyond the bar', (
      tester,
    ) async {
      await pump(tester, _view(), shareLinks: links);
      await tester.tap(find.byIcon(Icons.ios_share));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();

      verifyZeroInteractions(repo);
    });
  });
}
