import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/post_photo_screen.dart';
import 'package:dzeroth/features/posts/presentation/reply_composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class _Posts extends Mock implements PostsRepository {}

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late _Posts posts;
  late _Onboarding onboarding;
  late pb.PostView parent;
  final boundary = GlobalKey();

  setUp(() {
    final reflect = GoRouter.optionURLReflectsImperativeAPIs;
    GoRouter.optionURLReflectsImperativeAPIs = true;
    addTearDown(() => GoRouter.optionURLReflectsImperativeAPIs = reflect);
    posts = _Posts();
    onboarding = _Onboarding();
    parent = postView(1, text: 'A conversation worth continuing.');
    parent.post.media.addAll([common.MediaRef(), common.MediaRef()]);
    when(() => posts.getPost(any())).thenAnswer((_) async => parent);
  });

  Future<GoRouter> open(
    WidgetTester tester,
    String path, {
    Size size = const Size(600, 800),
    bool replies = true,
    bool dark = false,
  }) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: {'posts', if (replies) 'replies'},
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
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Home')),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (_, _) => const Scaffold(body: Text('Parent post')),
        ),
        GoRoute(
          path: '/compose/reply/:id',
          builder: (_, state) =>
              ReplyComposerScreen(postId: state.pathParameters['id']!),
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
          child: RepaintBoundary(
            key: boundary,
            child: MaterialApp.router(
              routerConfig: router,
              theme: dark ? appDarkTheme : appLightTheme,
            ),
          ),
        ),
      ),
    );
    unawaited(router.push(path));
    await tester.pumpAndSettle();
    return router;
  }

  test('photo and reply deep links survive authentication', () {
    expect(
      AppRouter.deepLinkTarget(
        Uri.parse(AppRouter.postPhotoPath(postId(1), 2)),
      ),
      '/post/${postId(1)}/photo/2',
    );
    expect(
      AppRouter.deepLinkTarget(
        Uri.parse(AppRouter.composeReplyPath(postId(1))),
      ),
      '/compose/reply/${postId(1)}',
    );
    expect(
      AppRouter.deepLinkTarget(Uri.parse('/post/${postId(1)}/photo/9')),
      isNull,
    );
  });

  testWidgets('reply retains target and protects unsent text on Close', (
    tester,
  ) async {
    await open(tester, AppRouter.composeReplyPath(postId(1)));
    expect(find.text('Replying to @hu1'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Keep this reply');
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Discard reply?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Keep this reply'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Timeline'), findsOneWidget);
  });

  testWidgets('reply posts once to selected parent and returns', (
    tester,
  ) async {
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: postId(1),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((_) async => postView(2, text: 'A reply'));
    await open(tester, AppRouter.composeReplyPath(postId(1)));
    await tester.enterText(find.byType(TextField), 'A reply');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Reply'));
    await tester.pumpAndSettle();
    expect(find.text('Timeline'), findsOneWidget);
    verify(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: 'A reply',
        replyToPostId: postId(1),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).called(1);
  });

  testWidgets('disabled replies cannot submit', (tester) async {
    await open(tester, AppRouter.composeReplyPath(postId(1)), replies: false);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Reply'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('missing parent shows unavailable instead of composer', (
    tester,
  ) async {
    when(() => posts.getPost(any())).thenThrow(const NotFoundException('gone'));
    await open(tester, AppRouter.composeReplyPath(postId(1)));
    expect(find.text("This post isn't available"), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('image selection updates URL and Escape returns to timeline', (
    tester,
  ) async {
    final router = await open(tester, AppRouter.postPhotoPath(postId(1), 1));
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.path,
      AppRouter.postPhotoPath(postId(1), 2),
    );
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Timeline'), findsOneWidget);
  });

  testWidgets('invalid image index is handled without opening an image', (
    tester,
  ) async {
    await open(tester, AppRouter.postPhotoPath(postId(1), 9));
    expect(find.text('This image is not available.'), findsOneWidget);
    await tester.tap(find.byTooltip('Close image'));
    await tester.pumpAndSettle();
    expect(find.text('Timeline'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('reply layout fits narrow ${dark ? "dark" : "light"}', (
      tester,
    ) async {
      await open(
        tester,
        AppRouter.composeReplyPath(postId(1)),
        size: const Size(360, 780),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      // Opt-in local visual QA artifacts; never contacts a live API.
      if (Platform.environment['POST_UI_CAPTURE'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/post-ui/reply-${dark ? "dark" : "light"}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
