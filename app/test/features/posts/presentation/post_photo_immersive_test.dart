import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/post_detail_screen.dart';
import 'package:dzeroth/features/posts/presentation/post_photo_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class _Posts extends Mock implements PostsRepository {}

class _Engagement extends Mock implements EngagementRepository {}

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _phone = Size(390, 844);

/// The loading spinner under a photo never stops animating, so
/// `pumpAndSettle` would time out: run the fades and zooms out by time.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// The immersive viewer: one tap on the picture hides every control and the
/// system bars, the next brings them back; the photo opens filling the screen
/// (cover) and double-tap shows the whole photo (contain) and back.
void main() {
  late _Posts posts;
  late _Engagement engagement;
  late EngagementCubit cubit;
  late GoRouter router;
  final uiModes = <String>[];

  setUp(() {
    posts = _Posts();
    engagement = _Engagement();
    cubit = EngagementCubit(repository: engagement);
    uiModes.clear();
    final view = postView(1, text: 'Two photos of the harbour.');
    view.post.media.addAll([
      common.MediaRef(
        url: 'https://cdn.example/p1.jpg',
        thumbUrl: 'https://cdn.example/p1_t.jpg',
        width: 1600,
        height: 900,
      ),
      common.MediaRef(
        url: 'https://cdn.example/p2.jpg',
        thumbUrl: 'https://cdn.example/p2_t.jpg',
        width: 900,
        height: 1600,
      ),
    ]);
    when(() => posts.getPost(any())).thenAnswer((_) async => view);
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    // The details pane (a thread) listens for removed posts.
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(
      () => posts.getThread(
        any(),
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((_) => Completer<pb.GetThreadResponse>().future);
  });

  tearDown(() => cubit.close());

  Future<void> open(
    WidgetTester tester, {
    bool reduceMotion = false,
    Size size = _phone,
  }) async {
    addTearDown(() => tester.takeException());
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          uiModes.add(call.arguments as String);
        } else if (call.method == 'SystemChrome.setEnabledSystemUIOverlays') {
          // The manual mode (Flutter's default) with the overlays it shows.
          uiModes.add('manual ${call.arguments}');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final onboarding = _Onboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: const {'posts', 'engagement', 'replies'},
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
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      RepositoryProvider<PostsRepository>.value(
        value: posts,
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
                  .copyWith(disableAnimations: reduceMotion),
              child: child!,
            ),
          ),
        ),
      ),
    );
    unawaited(router.push(AppRouter.postPhotoPath(postId(1), 1)));
    await settle(tester);
  }

  Future<void> tapPicture(WidgetTester tester) async {
    await tester.tapAt(tester.getCenter(find.byType(PageView)));
    // Past the double-tap window, then the fade.
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await settle(tester);
  }

  Future<void> doubleTapPicture(WidgetTester tester) async {
    final at = tester.getCenter(find.byType(PageView));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(at);
    await settle(tester);
  }

  /// The semantics label of the control found by [tooltip], or '' when it is
  /// out of the semantics tree.
  String labelOf(WidgetTester tester, String tooltip) {
    final root = tester
        .renderObject(find.byType(Scaffold).first)
        .owner!
        .semanticsOwner!
        .rootSemanticsNode!;
    var found = '';
    bool visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.tooltip.contains(tooltip) || data.label.contains(tooltip)) {
        found = '${data.label} ${data.tooltip}';
      }
      node.visitChildren(visit);
      return true;
    }

    visit(root);
    return found;
  }

  Rect photo(WidgetTester tester) =>
      tester.getRect(find.byType(CachedNetworkImage).first);

  double chromeOpacity(WidgetTester tester) => tester
      .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
      .map((o) => o.opacity)
      .reduce((a, b) => a < b ? a : b);

  group('opening fit', () {
    testWidgets('a landscape photo fills the phone screen (cover)', (
      tester,
    ) async {
      await open(tester);
      final rect = photo(tester);
      // No black on any side: the photo covers the whole 390 x 844 screen.
      expect(rect.left, lessThanOrEqualTo(0.01));
      expect(rect.top, lessThanOrEqualTo(0.01));
      expect(rect.right, greaterThanOrEqualTo(_phone.width - 0.01));
      expect(rect.bottom, greaterThanOrEqualTo(_phone.height - 0.01));
      // ... and keeps its aspect.
      expect(rect.width / rect.height, closeTo(1600 / 900, 0.01));
    });

    testWidgets('the picture runs under the status bar (no SafeArea)', (
      tester,
    ) async {
      await open(tester);
      expect(tester.getTopLeft(find.byType(PageView)), Offset.zero);
      expect(tester.getSize(find.byType(PageView)), _phone);
    });

    testWidgets('double-tap shows the whole photo, again goes back', (
      tester,
    ) async {
      await open(tester);
      await doubleTapPicture(tester);
      var rect = photo(tester);
      expect(rect.width, closeTo(390, 0.5));
      expect(rect.height, closeTo(390 * 900 / 1600, 0.5));
      expect(rect.center.dy, closeTo(844 / 2, 0.5));

      await doubleTapPicture(tester);
      rect = photo(tester);
      expect(rect.height, greaterThanOrEqualTo(844 - 0.01));
    });

    testWidgets('a pinch zooms in, and a page swipe is then off', (
      tester,
    ) async {
      await open(tester);
      final center = tester.getCenter(find.byType(PageView));
      final a = await tester.startGesture(center - const Offset(20, 0));
      final b = await tester.startGesture(center + const Offset(20, 0));
      await tester.pump();
      await a.moveBy(const Offset(-60, 0));
      await b.moveBy(const Offset(60, 0));
      await tester.pump();
      await a.up();
      await b.up();
      await settle(tester);
      expect(photo(tester).height, greaterThan(844 * 1.5));
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await settle(tester);
      expect(find.text('1 / 2'), findsOneWidget);
    });
  });

  group('tap toggles the controls', () {
    testWidgets('one tap hides them and the system bars, the next shows', (
      tester,
    ) async {
      await open(tester);
      expect(chromeOpacity(tester), 1);
      expect(find.byTooltip('Close image'), findsOneWidget);

      await tapPicture(tester);
      expect(chromeOpacity(tester), 0);
      expect(uiModes.last, 'SystemUiMode.immersiveSticky');

      await tapPicture(tester);
      expect(chromeOpacity(tester), 1);
      expect(uiModes.last, 'SystemUiMode.edgeToEdge');
    });

    testWidgets('hidden controls take no taps', (tester) async {
      await open(tester);
      await tapPicture(tester);
      final close = tester.getCenter(find.byTooltip('Close image'));
      await tester.tapAt(close);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      // The tap landed on the picture: it only brought the controls back.
      await settle(tester);
      expect(find.text('Timeline'), findsNothing);
      expect(chromeOpacity(tester), 1);
    });

    testWidgets('hidden controls are not in the semantics tree', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      expect(labelOf(tester, 'Close image'), contains('Close image'));
      expect(labelOf(tester, 'Next image'), contains('Next image'));
      await tapPicture(tester);
      expect(labelOf(tester, 'Close image'), isNot(contains('Close image')));
      expect(labelOf(tester, 'Next image'), isNot(contains('Next image')));
      handle.dispose();
    });

    testWidgets('a screen reader can bring them back from the picture', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      await tapPicture(tester);
      expect(chromeOpacity(tester), 0);

      tester.semantics.tap(find.semantics.byLabel('Image 1 of 2'));
      await settle(tester);
      expect(chromeOpacity(tester), 1);
      expect(labelOf(tester, 'Close image'), contains('Close image'));
      handle.dispose();
    });

    testWidgets('reduced motion: no fade, they are gone at once', (
      tester,
    ) async {
      await open(tester, reduceMotion: true);
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      // One frame, no settling.
      expect(chromeOpacity(tester), 0);
    });

    testWidgets('swiping between photos still works with them hidden', (
      tester,
    ) async {
      await open(tester);
      await tapPicture(tester);
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await settle(tester);
      // The counter is hidden, so read the page itself.
      final pages = tester.widget<PageView>(find.byType(PageView));
      expect(pages.controller!.page, 1);
    });

    testWidgets('leaving restores the system bars', (tester) async {
      await open(tester);
      await tapPicture(tester);
      expect(uiModes.last, 'SystemUiMode.immersiveSticky');
      router.pop();
      await settle(tester);
      // Back to Flutter's default: every overlay shown.
      expect(uiModes.last, startsWith('manual'));
      expect(uiModes.last, contains('SystemUiOverlay.top'));
      expect(uiModes.last, contains('SystemUiOverlay.bottom'));
    });

    testWidgets('a viewer that never hid anything leaves the bars alone', (
      tester,
    ) async {
      await open(tester);
      router.pop();
      await settle(tester);
      expect(uiModes, isEmpty);
    });
  });

  group('wide layout: the details pane is part of the controls', () {
    const wide = Size(1280, 800);

    double paneWidth(WidgetTester tester) =>
        tester.getSize(find.byType(PostDetailScreen)).width;

    testWidgets('a tap closes the pane, the photo takes the width, a tap '
        'brings both back', (tester) async {
      await open(tester, size: wide);
      expect(find.byType(PostDetailScreen), findsOneWidget);
      final shownPane = paneWidth(tester);
      expect(shownPane, 380);
      final shownArea = tester.getSize(find.byType(PageView)).width;
      expect(shownArea, wide.width - shownPane);

      await tapPicture(tester);
      // The pane's slot is closed and the photo area fills the window.
      expect(tester.getSize(find.byType(PageView)).width, wide.width);

      await tapPicture(tester);
      expect(tester.getSize(find.byType(PageView)).width, shownArea);
      expect(paneWidth(tester), shownPane);
    });

    testWidgets('while closed the pane takes no touches or semantics', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester, size: wide);
      await tapPicture(tester);
      final ignore = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byType(PostDetailScreen),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(ignore.ignoring, isTrue);
      handle.dispose();
    });

    testWidgets('it animates, and reduced motion skips that', (tester) async {
      await open(tester, size: wide);
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 90));
      final mid = tester.getSize(find.byType(PageView)).width;
      expect(mid, greaterThan(wide.width - 380));
      expect(mid, lessThan(wide.width));
      await settle(tester);
    });

    testWidgets('reduced motion: it is closed in the first frame', (
      tester,
    ) async {
      await open(tester, size: wide, reduceMotion: true);
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
      await tester.pump();
      expect(tester.getSize(find.byType(PageView)).width, wide.width);
    });

    testWidgets('a pane the user closed with its own button stays closed', (
      tester,
    ) async {
      await open(tester, size: wide);
      await tester.tap(find.byTooltip('Hide post'));
      await settle(tester);
      expect(find.byType(PostDetailScreen), findsNothing);
      await tapPicture(tester);
      await tapPicture(tester);
      expect(find.byType(PostDetailScreen), findsNothing);
    });
  });

  group('fit math', () {
    test('cover scale fills the viewport, contain is the zoom floor', () {
      final wide = photoFit(const Size(390, 844), 16 / 9);
      expect(wide.fitted.width, 390);
      expect(wide.fitted.height, closeTo(219.375, 0.001));
      expect(wide.cover, closeTo(844 / 219.375, 0.001));
      final tall = photoFit(const Size(390, 844), 9 / 16);
      expect(tall.fitted.width, 390);
      expect(tall.fitted.height, closeTo(693.333, 0.001));
      expect(tall.cover, closeTo(844 / 693.333, 0.001));
    });

    test('an unknown aspect or a matching one is simply contained', () {
      expect(photoFit(const Size(390, 844), 0).cover, 1);
      expect(photoFit(const Size(400, 800), 0.5).cover, closeTo(1, 1e-9));
    });

    test('panning stays inside the photo and centres where it fits', () {
      const viewport = Size(390, 844);
      const fitted = Size(390, 219);
      // Contain: nothing to pan.
      expect(
        clampPhotoOffset(const Offset(50, 50), fitted, 1, viewport),
        Offset.zero,
      );
      // At 4x: up to half of the overflow either way.
      final o = clampPhotoOffset(
        const Offset(9999, -9999),
        fitted,
        4,
        viewport,
      );
      expect(o.dx, (390 * 4 - 390) / 2);
      // 219 * 4 = 876 > 844: a sliver of vertical overflow only.
      expect(o.dy, -(219 * 4 - 844) / 2);
    });
  });
}
