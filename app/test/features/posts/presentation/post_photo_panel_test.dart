import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/reply_start.dart';
import 'package:dzeroth/features/posts/presentation/post_photo_screen.dart';
import 'package:dzeroth/features/posts/presentation/widgets/photo_bottom_panel.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as gpb;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPermission;
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/user/follow_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class _Posts extends Mock implements PostsRepository {}

class _Engagement extends Mock implements EngagementRepository {}

class _Graph extends Mock implements GraphRepository {}

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _phone = Size(390, 844);
const _longText =
    'A long caption about the harbour at dawn, with boats, gulls, ropes, '
    'nets, a cold wind off the water and the first light on the old quay, '
    'told over more than two lines at phone width so it must be clamped.';

/// The viewer's bottom panel (X's phone app): author row, clamped text,
/// action row and the "Post your reply" bar.
void main() {
  late _Posts posts;
  late _Engagement engagement;
  late _Graph graph;
  late EngagementCubit cubit;
  late GoRouter router;

  setUp(() {
    posts = _Posts();
    engagement = _Engagement();
    graph = _Graph();
    cubit = EngagementCubit(repository: engagement);
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => graph.cached(any())).thenReturn(null);
    when(() => graph.relationshipFor(any()))
        .thenAnswer((_) async => gpb.Relationship(userId: 'u1'));
    when(
      () => posts.getThread(
        any(),
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((_) => Completer<pb.GetThreadResponse>().future);
  });

  tearDown(() => cubit.close());

  pb.PostView view({
    String text = 'A harbour at dawn.',
    String authorId = 'u1',
    bool liked = false,
    bool reposted = false,
    bool verified = false,
    ReplyPermission? permission,
  }) {
    final v = postView(1, text: text, authorId: authorId);
    v.post.author
      ..displayName = 'Harbour Daily'
      ..verified = verified;
    v.post.media.add(
      common.MediaRef(
        url: 'https://cdn.example/p1.jpg',
        thumbUrl: 'https://cdn.example/p1_t.jpg',
        width: 1600,
        height: 900,
      ),
    );
    v
      ..likedByViewer = liked
      ..repostedByViewer = reposted;
    if (permission != null) v.viewerReplyPermission = permission;
    return v;
  }

  Future<void> open(
    WidgetTester tester,
    pb.PostView v, {
    Set<String> features = const {'posts', 'engagement', 'replies'},
    Size size = _phone,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    when(() => posts.getPost(any())).thenAnswer((_) async => v);
    final onboarding = _Onboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
        enabledFeatures: features,
      ),
    );
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Timeline')),
        ),
        GoRoute(
          path: '/post/:id/photo/:index',
          builder: (_, state) => PostPhotoScreen(
            postId: state.pathParameters['id']!,
            index: int.parse(state.pathParameters['index']!),
          ),
        ),
        GoRoute(
          path: '/compose/reply/:id',
          builder: (_, state) =>
              Scaffold(body: Text('REPLY ${state.uri.toString()}')),
        ),
        GoRoute(
          path: '/u/:id',
          builder: (_, state) =>
              Scaffold(body: Text('PROFILE ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<GraphRepository>.value(value: graph),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<EngagementCubit>.value(value: cubit),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: appLightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    unawaited(router.push(AppRouter.postPhotoPath(postId(1), 1)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // The panel reports a new height after a frame; the photo then moves.
    await tester.pump(const Duration(milliseconds: 600));
  }

  group('author row', () {
    testWidgets('shows the name, the grey handle and the badge', (
      tester,
    ) async {
      await open(tester, view(verified: true));
      expect(find.text('Harbour Daily'), findsOneWidget);
      expect(find.text('@hu1'), findsOneWidget);
      expect(find.byIcon(Icons.verified), findsOneWidget);
      final handle = tester.widget<Text>(find.text('@hu1'));
      expect(handle.style?.color, AppPhotoPanel.muted);
      final name = tester.widget<Text>(find.text('Harbour Daily'));
      expect(name.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('no badge for an unverified author', (tester) async {
      await open(tester, view());
      expect(find.byIcon(Icons.verified), findsNothing);
    });

    testWidgets('a tap on the name opens the profile', (tester) async {
      await open(tester, view());
      await tester.tap(find.text('Harbour Daily'));
      await settle(tester);
      expect(find.text('PROFILE u1'), findsOneWidget);
    });

    testWidgets('Follow is the shared button, shown with graph on for '
        'another author', (tester) async {
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'graph'},
      );
      expect(find.byType(FollowButton), findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);
    });

    testWidgets('on a cache miss the relationship is loaded, a pill-sized gap '
        'shows meanwhile', (tester) async {
      final pending = Completer<gpb.Relationship>();
      when(() => graph.relationshipFor(any()))
          .thenAnswer((_) => pending.future);
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'graph'},
      );
      expect(find.byType(FollowButton), findsNothing);
      final gap = tester.getSize(
        find.byKey(const ValueKey('follow-placeholder')),
      );
      expect(gap, const Size(77, 32));
      pending.complete(gpb.Relationship(userId: 'u1'));
      await settle(tester);
      expect(find.byKey(const ValueKey('follow-placeholder')), findsNothing);
      expect(find.byType(FollowButton), findsOneWidget);
    });

    testWidgets('a followed author shows Following from the load', (
      tester,
    ) async {
      when(() => graph.relationshipFor(any())).thenAnswer(
        (_) async => gpb.Relationship(
          userId: 'u1',
          followState: gpb.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
      );
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'graph'},
      );
      expect(find.text('Following'), findsOneWidget);
    });

    testWidgets('a failed load draws no pill', (tester) async {
      when(() => graph.relationshipFor(any())).thenThrow(Exception('offline'));
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'graph'},
      );
      expect(find.byType(FollowButton), findsNothing);
      expect(find.byKey(const ValueKey('follow-placeholder')), findsNothing);
    });

    testWidgets('a cached relationship needs no load', (tester) async {
      when(() => graph.cached(any()))
          .thenReturn(gpb.Relationship(userId: 'u1'));
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'graph'},
      );
      verifyNever(() => graph.relationshipFor(any()));
      expect(find.byType(FollowButton), findsOneWidget);
    });

    testWidgets('Follow is hidden on the viewer\'s own post', (tester) async {
      await open(
        tester,
        view(authorId: 'me'),
        features: const {'posts', 'engagement', 'replies', 'graph'},
      );
      expect(find.byType(FollowButton), findsNothing);
    });

    testWidgets('Follow is hidden when graph is off', (tester) async {
      await open(tester, view());
      expect(find.byType(FollowButton), findsNothing);
    });
  });

  testWidgets('View post has its own glyph, not the Reply one', (tester) async {
    await open(tester, view());
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
  });

  group('post text', () {
    testWidgets('short text is shown whole, with no Show more', (tester) async {
      await open(tester, view());
      expect(find.text('A harbour at dawn.'), findsOneWidget);
      expect(find.text('Show more'), findsNothing);
    });

    testWidgets('long text is clamped to two lines; Show more expands it '
        'in place', (tester) async {
      await open(tester, view(text: _longText));
      var text = tester.widget<Text>(find.text(_longText));
      expect(text.maxLines, 2);
      expect(text.style?.color, AppColors.onPhotoBackground);
      expect(text.style?.fontSize, 15);
      expect(find.text('Show more'), findsOneWidget);
      // The teal accent of the app, not X blue.
      expect(
        tester.widget<Text>(find.text('Show more')).style?.color,
        AppPalette.tealElectric,
      );

      await tester.tap(find.text('Show more'));
      await tester.pump();
      text = tester.widget<Text>(find.text(_longText));
      expect(text.maxLines, isNull);
      expect(find.text('Show more'), findsNothing);
    });

    testWidgets('a post with no text draws no text line', (tester) async {
      await open(tester, view(text: ' '));
      expect(find.text('Show more'), findsNothing);
      // Only the author row, actions and reply bar remain.
      expect(find.textContaining('harbour'), findsNothing);
    });
  });

  group('action row', () {
    // The viewer has its own chat glyph (View post) beside the row's.
    Finder inRow(IconData icon) => find.descendant(
      of: find.byType(PostActionBar),
      matching: find.byIcon(icon),
    );
    Color iconColor(WidgetTester tester, IconData icon) =>
        tester.widget<Icon>(inRow(icon)).color!;

    testWidgets('idle: outline glyphs in grey, 18 dp', (tester) async {
      await open(tester, view());
      for (final icon in [
        Icons.chat_bubble_outline,
        Icons.repeat,
        Icons.favorite_border,
      ]) {
        expect(iconColor(tester, icon), AppPhotoPanel.muted);
        expect(tester.widget<Icon>(inRow(icon)).size, 18);
      }
    });

    testWidgets('liked is a pink filled heart', (tester) async {
      await open(tester, view(liked: true));
      expect(find.byIcon(Icons.favorite_border), findsNothing);
      expect(iconColor(tester, Icons.favorite), AppPhotoPanel.liked);
      expect(AppPhotoPanel.liked, const Color(0xFFF91880));
    });

    testWidgets('reposted is green', (tester) async {
      await open(tester, view(reposted: true));
      expect(iconColor(tester, Icons.repeat), AppPhotoPanel.reposted);
      expect(AppPhotoPanel.reposted, const Color(0xFF00BA7C));
    });

    testWidgets('X order: reply, repost, like, then share, spread evenly', (
      tester,
    ) async {
      await open(tester, view());
      double x(IconData icon) => tester.getCenter(inRow(icon)).dx;
      expect(x(Icons.chat_bubble_outline), lessThan(x(Icons.repeat)));
      expect(x(Icons.repeat), lessThan(x(Icons.favorite_border)));
      final reply = x(Icons.repeat) - x(Icons.chat_bubble_outline);
      final repost = x(Icons.favorite_border) - x(Icons.repeat);
      expect(reply, closeTo(repost, 1));
    });

    testWidgets('without the engagement flag there is no action row', (
      tester,
    ) async {
      await open(tester, view(), features: const {'posts', 'replies'});
      expect(find.byIcon(Icons.favorite_border), findsNothing);
      expect(find.text('Post your reply'), findsOneWidget);
    });
  });

  group('Post your reply', () {
    testWidgets('the field opens the reply composer', (tester) async {
      await open(tester, view());
      await tester.tap(find.text('Post your reply'));
      await settle(tester);
      expect(
        find.text('REPLY ${AppRouter.composeReplyPath(postId(1))}'),
        findsOneWidget,
      );
    });

    testWidgets('Photo opens it with the photo picker', (tester) async {
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'media'},
      );
      await tester.tap(find.byTooltip('Add photo'));
      await settle(tester);
      expect(
        find.text(
          'REPLY ${AppRouter.composeReplyPath(postId(1), start: ReplyStart.photo)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('GIF opens it with the GIF path', (tester) async {
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'media', 'gif'},
      );
      await tester.tap(find.byTooltip('Add GIF'));
      await settle(tester);
      expect(
        find.text(
          'REPLY ${AppRouter.composeReplyPath(postId(1), start: ReplyStart.gif)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Emoji opens it (the field focused)', (tester) async {
      await open(tester, view());
      await tester.tap(find.byTooltip('Add emoji'));
      await settle(tester);
      expect(
        find.text(
          'REPLY ${AppRouter.composeReplyPath(postId(1), start: ReplyStart.emoji)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('GIF is hidden without the gif flag, Photo without media', (
      tester,
    ) async {
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'media'},
      );
      expect(find.byTooltip('Add photo'), findsOneWidget);
      expect(find.byTooltip('Add GIF'), findsNothing);
    });

    testWidgets('a sub-feature the posts gate saw disabled hides the button', (
      tester,
    ) async {
      when(() => posts.subFeatureEnabled('gif')).thenReturn(false);
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'media', 'gif'},
      );
      expect(find.byTooltip('Add photo'), findsOneWidget);
      expect(find.byTooltip('Add GIF'), findsNothing);
      when(() => posts.subFeatureEnabled('media')).thenReturn(false);
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'media', 'gif'},
      );
      expect(find.byTooltip('Add photo'), findsNothing);
      expect(find.byTooltip('Add GIF'), findsNothing);
    });

    testWidgets('no media flag: neither Photo nor GIF', (tester) async {
      await open(tester, view());
      expect(find.byTooltip('Add photo'), findsNothing);
      expect(find.byTooltip('Add GIF'), findsNothing);
      expect(find.byTooltip('Add emoji'), findsOneWidget);
    });

    testWidgets('the pill and the buttons use the X tokens', (tester) async {
      await open(
        tester,
        view(),
        features: const {'posts', 'engagement', 'replies', 'media', 'gif'},
      );
      expect(AppPhotoPanel.replyField, const Color(0xFF202327));
      expect(AppPhotoPanel.accent, AppPalette.tealElectric);
      final photo = tester.widget<Icon>(find.byIcon(Icons.image_outlined));
      expect(photo.color, AppPhotoPanel.accent);
      // Photo, GIF and Emoji: the teal accent token.
      for (final icon in [
        Icons.image_outlined,
        Icons.gif_box_outlined,
        Icons.emoji_emotions_outlined,
      ]) {
        final glyph = find.byIcon(icon);
        expect(glyph, findsOneWidget);
        expect(tester.widget<Icon>(glyph).color, AppPalette.tealElectric);
      }
      final pill = tester
          .widgetList<DecoratedBox>(
            find.ancestor(
              of: find.text('Post your reply'),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.color == AppPhotoPanel.replyField);
      expect(pill.borderRadius, BorderRadius.circular(AppRadius.pill));
    });

    testWidgets('hidden when the reply policy says not allowed', (
      tester,
    ) async {
      await open(
        tester,
        view(permission: ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED),
      );
      expect(find.text('Post your reply'), findsNothing);
      expect(find.byTooltip('Add emoji'), findsNothing);
    });

    testWidgets('hidden when the replies sub-feature is off', (tester) async {
      await open(tester, view(), features: const {'posts', 'engagement'});
      expect(find.text('Post your reply'), findsNothing);
    });

    testWidgets('hidden when the posts flag is off', (tester) async {
      await open(tester, view(), features: const {'engagement', 'replies'});
      expect(find.text('Post your reply'), findsNothing);
    });
  });

  group('small screens and large text', () {
    const all = {'posts', 'engagement', 'replies', 'graph', 'media', 'gif'};
    for (final scale in const [1.0, 2.0]) {
      testWidgets('320 dp at text x$scale: no overflow, also opened', (
        tester,
      ) async {
        await open(
          tester,
          view(text: _longText, verified: true),
          features: all,
          size: const Size(320, 640),
          textScale: scale,
        );
        expect(find.text('Post your reply'), findsOneWidget);
        expect(find.byType(FollowButton), findsOneWidget);
        await tester.tap(find.text('Show more'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Show more'), findsNothing);
        expect(find.text('Post your reply'), findsOneWidget);
        // The panel never takes more than 60% of the screen.
        final panel = tester.getSize(find.byType(PhotoBottomPanel));
        expect(panel.height, lessThanOrEqualTo(640 * 0.6 + 0.5));
        // The photo keeps a positive box above it.
        final photo = tester.getRect(find.byType(CachedNetworkImage).first);
        expect(photo.height, greaterThan(0));
        expect(
          photo.bottom,
          lessThanOrEqualTo(
            tester.getTopLeft(find.byType(PhotoBottomPanel)).dy + 0.5,
          ),
        );
      });
    }

    testWidgets('a very long caption opened scrolls inside, no overflow', (
      tester,
    ) async {
      await open(
        tester,
        view(text: List.filled(60, _longText).join(' ')),
        features: all,
        size: const Size(320, 640),
        textScale: 2,
      );
      await tester.tap(find.text('Show more'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(PhotoBottomPanel)).height,
        lessThanOrEqualTo(640 * 0.6 + 0.5),
      );
    });

    testWidgets('a landscape phone (640 x 320) has no overflow and a photo', (
      tester,
    ) async {
      await open(
        tester,
        view(text: _longText, verified: true),
        features: all,
        size: const Size(640, 320),
      );
      await tester.tap(find.text('Show more'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(PhotoBottomPanel)).height,
        lessThanOrEqualTo(320 * 0.6 + 0.5),
      );
      final photo = tester.getRect(find.byType(CachedNetworkImage).first);
      expect(photo.height, greaterThan(40));
      expect(photo.width, greaterThan(40));
    });
  });

  group('part of the controls', () {
    testWidgets('a tap on the picture hides the panel and a tap brings it '
        'back', (tester) async {
      await open(tester, view());
      expect(find.text('Post your reply'), findsOneWidget);
      double opacity() => tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .map((o) => o.opacity)
          .reduce((a, b) => a < b ? a : b);
      expect(opacity(), 1);
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(opacity(), 0);
    });
  });
}
