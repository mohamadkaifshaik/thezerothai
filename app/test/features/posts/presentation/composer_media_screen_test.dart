import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/media/data/image_picker_service.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';
import '../../../support/posts_fixtures.dart';

class MockPostsRepository extends Mock implements PostsRepository {}

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  setUpAll(registerMediaFallbacks);

  late MockPostsRepository posts;
  late MockMediaRepository media;
  late FakeImagePicker picker;
  late MockAuthBloc authBloc;
  late MockOnboardingBloc onboardingBloc;
  late PendingPostsCubit pending;

  setUp(() {
    posts = MockPostsRepository();
    media = MockMediaRepository();
    picker = FakeImagePicker();
    authBloc = MockAuthBloc();
    onboardingBloc = MockOnboardingBloc();
    pending = PendingPostsCubit();
    whenListen(
      authBloc,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((_) async => postView(1));
  });

  tearDown(() => pending.close());

  Future<void> open(
    WidgetTester tester, {
    bool mediaOn = true,
    ThemeData? theme,
    double textScale = 1,
    Size? size,
  }) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
        enabledFeatures: {if (mediaOn) kFeatureMedia},
      ),
    );
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) => const ComposerScreen(),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<MediaRepository>.value(value: media),
          RepositoryProvider<ImagePickerService>.value(value: picker),
          RepositoryProvider<ImageProcessor>.value(value: FakeImageProcessor()),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: authBloc),
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
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
    unawaited(router.push('/compose'));
    await tester.pumpAndSettle();
  }

  FilledButton postButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'));

  Future<void> addPhotos(WidgetTester tester, List<String> tags) async {
    picker.next = [for (final t in tags) imageBytes(t)];
    await tester.tap(find.byTooltip('Add photos'));
    await tester.pumpAndSettle();
  }

  testWidgets('media flag off: no photo button, text posting unchanged', (
    tester,
  ) async {
    await open(tester, mediaOn: false);

    expect(find.byTooltip('Add photos'), findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsNothing);
    expect(postButton(tester).onPressed, isNull);
  });

  testWidgets('adding a photo shows a tile and enables Post with no text', (
    tester,
  ) async {
    await open(tester);
    expect(postButton(tester).onPressed, isNull);

    await addPhotos(tester, ['a']);

    expect(find.bySemanticsLabel('Photo 1 of 1'), findsOneWidget);
    expect(find.byTooltip('Remove photo 1'), findsOneWidget);
    expect(postButton(tester).onPressed, isNotNull);
  });

  testWidgets('removing the only photo disables Post again', (tester) async {
    await open(tester);
    await addPhotos(tester, ['a']);

    await tester.tap(find.byTooltip('Remove photo 1'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Photo 1 of 1'), findsNothing);
    expect(postButton(tester).onPressed, isNull);
  });

  testWidgets('four photos: the add button is disabled', (tester) async {
    await open(tester);
    await addPhotos(tester, ['a', 'b', 'c', 'd']);

    expect(find.byTooltip('Four photos is the limit'), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.image_outlined),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('Post uploads the photos then creates the post and closes', (
    tester,
  ) async {
    stubHappyUpload(media);
    await open(tester);
    await addPhotos(tester, ['a', 'b']);
    await tester.enterText(find.byType(TextField), 'two cats');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();

    verify(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: 'two cats',
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: ['m1', 'm2'],
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).called(1);
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('upload progress shows while sending and locks the tiles', (
    tester,
  ) async {
    final gate = Completer<void>();
    stubHappyUpload(media, onPut: (_) => gate.future);
    await open(tester);
    await addPhotos(tester, ['a']);

    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pump();
    await tester.pump();

    expect(find.bySemanticsLabel('Photo 1 of 1, uploading'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final remove = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Remove photo 1'),
        matching: find.byType(IconButton),
      ),
    );
    expect(remove.onPressed, isNull);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('a rejected photo is explained and the post is not created', (
    tester,
  ) async {
    stubHappyUpload(media, result: (id) => rejectedResult(id, 'Not allowed'));
    await open(tester);
    await addPhotos(tester, ['a']);

    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();

    expect(find.text('Not allowed'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Photo 1 of 1, was not accepted. Remove it.'),
      findsOneWidget,
    );
    expect(postButton(tester).onPressed, isNull);
    verifyNever(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    );
  });

  testWidgets('a network failure says the photos were not sent and Post '
      'retries', (tester) async {
    var fail = true;
    stubHappyUpload(
      media,
      onPut: (_) async {
        if (fail) throw const NetworkException('offline');
      },
    );
    await open(tester);
    await addPhotos(tester, ['a']);

    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();

    expect(find.textContaining('photos were not sent'), findsOneWidget);
    expect(postButton(tester).onPressed, isNotNull);

    fail = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('photo quota and nomedia degraded mode have their own words', (
    tester,
  ) async {
    stubHappyUpload(media);
    when(
      () => media.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenThrow(const DegradedModeException('nomedia'));
    await open(tester);
    await addPhotos(tester, ['a']);

    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Photo uploads are paused'), findsOneWidget);
  });

  testWidgets('alt text can be added and is announced as edit', (tester) async {
    await open(tester);
    await addPhotos(tester, ['a']);

    await tester.tap(find.bySemanticsLabel('Add description for photo 1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'a cat on a sofa');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel('Edit description for photo 1'),
      findsOneWidget,
    );
  });

  testWidgets('dark mode, text scale 2.0, narrow: no overflow, 48dp targets', (
    tester,
  ) async {
    await open(
      tester,
      theme: appDarkTheme,
      textScale: 2,
      size: const Size(320, 640),
    );
    await addPhotos(tester, ['a', 'b', 'c', 'd']);

    expect(tester.takeException(), isNull);
    final add = tester.getSize(
      find.widgetWithIcon(IconButton, Icons.image_outlined),
    );
    expect(add.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
    expect(add.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
  });
}
