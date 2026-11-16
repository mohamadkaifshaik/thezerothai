import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
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
import 'package:dzeroth/features/posts/presentation/reply_composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';
import '../../../support/posts_fixtures.dart';

class _Posts extends Mock implements PostsRepository {}

class _Auth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The very-narrow / very-wide photo warning in the root composer and in the
/// reply composer.
void main() {
  setUpAll(registerMediaFallbacks);

  late _Posts posts;
  late FakeImagePicker picker;
  late PendingPostsCubit pending;

  setUp(() {
    posts = _Posts();
    picker = FakeImagePicker();
    pending = PendingPostsCubit();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => posts.getPost(any())).thenAnswer((_) async => postView(1));
  });

  tearDown(() => pending.close());

  Future<void> open(
    WidgetTester tester, {
    required bool reply,
    double width = 390,
    double scale = 1,
  }) async {
    final auth = _Auth();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    final onboarding = _Onboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
        enabledFeatures: const {kFeatureMedia, 'posts', 'replies'},
      ),
    );
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) => reply
              ? ReplyComposerScreen(postId: postId(1))
              : const ComposerScreen(),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<MediaRepository>.value(
            value: MockMediaRepository(),
          ),
          RepositoryProvider<ImagePickerService>.value(value: picker),
          RepositoryProvider<ImageProcessor>.value(
            value: FakeImageProcessor(
              sizes: {
                'n': (width: 38, height: 2048),
                'm': (width: 40, height: 2000),
                'p': (width: 1080, height: 1350),
              },
            ),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: appLightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    unawaited(router.push('/compose'));
    await tester.pumpAndSettle();
  }

  Future<void> addPhotos(WidgetTester tester, List<String> tags) async {
    picker.next = [for (final t in tags) imageBytes(t)];
    await tester.tap(find.byTooltip('Add photos'));
    await tester.pumpAndSettle();
  }

  AppPillButton post(WidgetTester tester) =>
      tester.widget<AppPillButton>(find.byType(AppPillButton).last);

  for (final reply in [false, true]) {
    final where = reply ? 'reply composer' : 'composer';

    testWidgets(
      '$where: a narrow photo shows the notice; Keep photo keeps it and '
      'Post still works',
      (tester) async {
        await open(tester, reply: reply);
        await addPhotos(tester, ['n']);
        expect(find.textContaining('very narrow, so it will'), findsOneWidget);

        await tester.tap(find.text('Keep photo'));
        await tester.pumpAndSettle();
        expect(find.textContaining('very narrow'), findsNothing);
        expect(find.byTooltip('Remove photo 1'), findsOneWidget);
        expect(post(tester).onPressed, isNotNull);
      },
    );

    testWidgets('$where: Remove drops the photo', (tester) async {
      await open(tester, reply: reply);
      await addPhotos(tester, ['n']);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove photo 1'), findsNothing);
      expect(find.textContaining('very narrow'), findsNothing);
    });

    testWidgets('$where: a 4:5 photo shows nothing', (tester) async {
      await open(tester, reply: reply);
      await addPhotos(tester, ['p']);
      expect(find.textContaining('very narrow'), findsNothing);
      expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    });

    testWidgets('$where: two photos, one thin: no notice', (tester) async {
      await open(tester, reply: reply);
      await addPhotos(tester, ['n', 'p']);
      expect(find.textContaining('very narrow'), findsNothing);
      expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    });

    testWidgets('$where: 320 dp at x2 text, no overflow', (tester) async {
      await open(tester, reply: reply, width: 320, scale: 2);
      await addPhotos(tester, ['n']);
      expect(find.textContaining('very narrow'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
