import 'dart:async';
import 'dart:math' as math;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/post_detail_screen.dart';
import 'package:dzeroth/features/posts/presentation/post_photo_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class _Posts extends Mock implements PostsRepository {}

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _tabletFlags = {kFeaturePosts, kFeatureUiShell, kFeatureUiTablet};

const _modes = <String, Set<String>>{
  'neither': {kFeaturePosts},
  'ui_shell only': {kFeaturePosts, kFeatureUiShell},
  'ui_tablet only': {kFeaturePosts, kFeatureUiTablet},
  'ui_shell + ui_tablet': _tabletFlags,
};

/// The photo viewer on the tablet layout (tablet plan section 4.1, PostPhoto
/// row; 5.4): the details pane from 840 dp, `min(380, 0.4 * W)` wide, and a
/// side sheet for "Show post" in band A. Phones, desktop and either flag
/// off keep today's 1000 dp / 380 pane and the pushed post.
void main() {
  late _Posts posts;
  late pb.PostView view;

  setUp(() {
    posts = _Posts();
    view = postView(1, text: 'Two photos of the harbour.');
    view.post.media.addAll([common.MediaRef(), common.MediaRef()]);
    when(() => posts.getPost(any())).thenAnswer((_) async => view);
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
  });

  Future<GoRouter> open(
    WidgetTester tester, {
    double width = 1024,
    double height = 768,
    Set<String> flags = _tabletFlags,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
    final onboarding = _Onboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Timeline')),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (_, _) => const Scaffold(body: Text('Post page')),
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
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp.router(routerConfig: router, theme: appLightTheme),
        ),
      ),
    );
    unawaited(router.push(AppRouter.postPhotoPath(postId(1), 1)));
    await tester.pumpAndSettle();
    return router;
  }

  Future<void> resize(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, tester.view.physicalSize.height);
    await tester.pumpAndSettle();
  }

  /// The details pane beside the photo (not a side sheet).
  Finder pane() => find.byType(PostDetailScreen);

  group('by width and flag mode', () {
    for (final MapEntry(key: mode, value: flags) in _modes.entries) {
      for (final width in <double>[
        390,
        599,
        600,
        744,
        839,
        840,
        950,
        999,
        1000,
        1024,
        1199,
        1200,
        1440,
      ]) {
        final tabletMode = mode == 'ui_shell + ui_tablet';
        final tablet = tabletMode && width >= 600 && width < 1200;
        final wide = tablet ? width >= 840 : width >= 1000;
        final paneWidth = tablet ? math.min(380.0, width * .4) : 380.0;
        final control = wide
            ? 'Hide post'
            : tablet
            ? 'Show post'
            : 'View post';
        testWidgets('$mode at ${width.toInt()}: '
            '${wide ? 'pane ${paneWidth.toStringAsFixed(0)}' : control}', (
          tester,
        ) async {
          await open(tester, width: width, flags: flags);
          expect(tester.takeException(), isNull);
          expect(find.byTooltip(control), findsOneWidget);
          if (wide) {
            expect(pane(), findsOneWidget);
            expect(
              tester.getSize(pane()).width,
              moreOrLessEquals(paneWidth, epsilon: .01),
            );
            expect(tester.getRect(pane()).right, width);
          } else {
            expect(pane(), findsNothing);
          }
        });
      }
    }
  });

  testWidgets('the plan\'s widths: 336 at 840, 380 from 950', (tester) async {
    await open(tester, width: 840);
    expect(tester.getSize(pane()).width, 336);
    await resize(tester, 950);
    expect(tester.getSize(pane()).width, 380);
  });

  group('band A: "Show post" opens a side sheet', () {
    for (final width in <double>[600, 744, 839]) {
      testWidgets('${width.toInt()}', (tester) async {
        final router = await open(tester, width: width, height: 1000);
        await tester.tap(find.byTooltip('Show post'));
        await tester.pumpAndSettle();
        // No page is pushed: the URL is still the photo.
        expect(router.state.uri.path, AppRouter.postPhotoPath(postId(1), 1));
        expect(find.text('Post page'), findsNothing);
        final sheet = find.bySemanticsLabel('Post');
        expect(sheet, findsWidgets);
        expect(pane(), findsOneWidget);
        final rect = tester.getRect(pane());
        expect(rect.right, width);
        expect(rect.width, AppSize.sideSheet);
        expect(find.text('Two photos of the harbour.'), findsWidgets);
        // Escape closes the sheet, not the viewer.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(pane(), findsNothing);
        expect(find.text('1 / 2'), findsOneWidget);
      });
    }
  });

  testWidgets('a phone: "View post" pushes the post, as today', (tester) async {
    final router = await open(tester, width: 390, height: 844);
    await tester.tap(find.byTooltip('View post'));
    await tester.pumpAndSettle();
    expect(find.text('Post page'), findsOneWidget);
    expect(router.state.uri.path, AppRouter.postPath(postId(1)));
  });

  testWidgets('the pane toggle survives 840 and 1200', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Hide post'));
    await tester.pumpAndSettle();
    expect(pane(), findsNothing);
    for (final (width, control) in [
      (839.0, 'Show post'),
      (1024.0, 'Show post'),
      (1200.0, 'Show post'),
      (1199.0, 'Show post'),
    ]) {
      await resize(tester, width);
      expect(find.byTooltip(control), findsOneWidget, reason: '$width');
      expect(pane(), findsNothing, reason: '$width');
    }
    await tester.tap(find.byTooltip('Show post'));
    await tester.pumpAndSettle();
    expect(pane(), findsOneWidget);
    await resize(tester, 840);
    expect(pane(), findsOneWidget);
    expect(find.byTooltip('Hide post'), findsOneWidget);
  });

  testWidgets('the image index survives crossing 840', (tester) async {
    await open(tester, width: 839);
    await tester.tap(find.byTooltip('Next image'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await resize(tester, 840);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(pane(), findsOneWidget);
  });
}
