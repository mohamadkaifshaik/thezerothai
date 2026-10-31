import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/domain/engagement_feature_flag.dart';
import 'package:dzeroth/features/media/data/gif_source.dart';
import 'package:dzeroth/features/media/data/image_picker_service.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/features/posts/presentation/widgets/composer_extras_buttons.dart';
import 'package:dzeroth/features/posts/presentation/widgets/draft_problem_hint.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';
import '../../../support/posts_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The Poll and GIF buttons of `/compose` (W6-11, ADR-0029): flag gates, the
/// disabled reasons, and the layout across widths, themes and text scales.
/// The poll builder and the GIF picker behind the buttons are W6-12 / W6-16.
void main() {
  setUpAll(registerMediaFallbacks);

  late _MockPostsRepository repo;
  late MockMediaRepository media;
  late FakeImagePicker picker;
  late FakeGifSource gifSource;
  late PendingPostsCubit pending;

  const all = {
    kFeaturePosts,
    kFeatureMedia,
    kFeatureEngagement,
    kFeaturePolls,
    kFeatureGif,
    kFeatureScheduledPosts,
  };

  setUp(() {
    repo = _MockPostsRepository();
    media = MockMediaRepository();
    picker = FakeImagePicker();
    gifSource = FakeGifSource();
    pending = PendingPostsCubit();
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() => pending.close());

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = all,
    String quote = '',
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
        enabledFeatures: features,
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) => ComposerScreen(
            quoteOfPostId: quote,
            scheduleClock: () => DateTime.now().add(const Duration(hours: 1)),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: repo),
          RepositoryProvider<MediaRepository>.value(value: media),
          RepositoryProvider<ImagePickerService>.value(value: picker),
          RepositoryProvider<ImageProcessor>.value(value: FakeImageProcessor()),
          RepositoryProvider<GifSource>.value(value: gifSource),
          RepositoryProvider<GifPreparer>.value(value: FakeGifPreparer()),
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
    unawaited(router.push('/compose'));
    await tester.pumpAndSettle();
  }

  Finder gif() => find.byType(ComposerGifButton);
  Finder poll() => find.byType(ComposerPollButton);
  Finder inner(Finder button) =>
      find.descendant(of: button, matching: find.byType(IconButton));
  bool enabled(WidgetTester tester, Finder button) =>
      tester.widget<IconButton>(inner(button)).onPressed != null;
  String tooltip(WidgetTester tester, Finder button) =>
      tester.widget<IconButton>(inner(button)).tooltip!;

  group('flag gates', () {
    testWidgets('flags off: no new buttons, the old ones stay', (tester) async {
      await open(tester, features: {kFeaturePosts, kFeatureMedia});
      expect(gif(), findsNothing);
      expect(poll(), findsNothing);
      expect(find.byTooltip('Add photos'), findsOneWidget);
    });

    testWidgets('polls needs engagement; gif needs media', (tester) async {
      await open(
        tester,
        features: {kFeaturePosts, kFeatureMedia, kFeaturePolls, kFeatureGif},
      );
      expect(poll(), findsNothing);
      expect(gif(), findsOneWidget);
      await open(
        tester,
        features: {
          kFeaturePosts,
          kFeatureEngagement,
          kFeaturePolls,
          kFeatureGif,
        },
      );
      expect(poll(), findsOneWidget);
      expect(gif(), findsNothing);
    });

    testWidgets('X order: photo, GIF, poll, schedule', (tester) async {
      await open(tester);
      final xs = [
        tester.getCenter(find.byTooltip('Add photos')).dx,
        tester.getCenter(gif()).dx,
        tester.getCenter(poll()).dx,
        tester.getCenter(find.byTooltip('Schedule post')).dx,
      ];
      expect(xs, orderedEquals([...xs]..sort()));
    });

    testWidgets('a quote offers no poll', (tester) async {
      await open(tester, features: {...all, 'quotes'}, quote: postId(5));
      expect(poll(), findsNothing);
      expect(gif(), findsOneWidget);
    });
  });

  group('exclusion reasons', () {
    testWidgets('a schedule disables the poll with its reason', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Schedule post'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(tooltip(tester, poll()), "Polls can't be scheduled");
      expect(enabled(tester, poll()), isFalse);
      // A GIF cannot be scheduled either (SchedulePost refuses it); photos
      // still can.
      expect(tooltip(tester, gif()), "GIFs can't be scheduled");
      expect(enabled(tester, gif()), isFalse);
      expect(find.byTooltip('Add photos'), findsOneWidget);
    });

    testWidgets('a GIF disables photos, the poll and Schedule with reasons', (
      tester,
    ) async {
      await open(tester);
      expect(enabled(tester, gif()), isTrue, reason: 'nothing attached yet');
      gifSource.next = imageBytes('a');
      await tester.tap(inner(gif()));
      await tester.pumpAndSettle();

      expect(gifSource.calls, 1);
      expect(find.byTooltip('Remove GIF'), findsOneWidget);
      expect(find.text('GIF'), findsWidgets);
      expect(tooltip(tester, poll()), "Polls can't have a GIF");
      expect(enabled(tester, poll()), isFalse);
      expect(find.byTooltip("A GIF can't be added to photos"), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.image_outlined),
            )
            .onPressed,
        isNull,
      );
      expect(find.byTooltip("GIFs can't be scheduled"), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.schedule_send_outlined),
            )
            .onPressed,
        isNull,
      );
      // The GIF button itself stays off: one GIF per post.
      expect(tooltip(tester, gif()), 'One GIF per post');
      expect(enabled(tester, gif()), isFalse);

      // Removing it puts everything back.
      await tester.tap(find.byTooltip('Remove GIF'));
      await tester.pumpAndSettle();
      expect(enabled(tester, gif()), isTrue);
      // The Poll button has no handler until W6-12, so it is off either way;
      // what changes is its reason.
      expect(tooltip(tester, poll()), 'Add poll');
    });

    testWidgets('a refused GIF says why and attaches nothing', (tester) async {
      await open(tester);
      gifSource.next = badBytes; // FakeGifPreparer refuses a leading 0
      await tester.tap(inner(gif()));
      await tester.pumpAndSettle();
      expect(find.text('GIFs can be up to 2 MB.'), findsOneWidget);
      expect(find.byTooltip('Remove GIF'), findsNothing);
      expect(enabled(tester, gif()), isTrue);
    });

    testWidgets('photos disable the GIF and the poll with their reasons', (
      tester,
    ) async {
      await open(tester);
      picker.next = [imageBytes('a')];
      await tester.tap(find.byTooltip('Add photos'));
      await tester.pumpAndSettle();
      expect(tooltip(tester, gif()), "A GIF can't be added to photos");
      expect(enabled(tester, gif()), isFalse);
      expect(tooltip(tester, poll()), "Polls can't have photos");
      expect(enabled(tester, poll()), isFalse);
    });
  });

  group('buttons', () {
    testWidgets('enabled with a handler, off without one or while sending', (
      tester,
    ) async {
      var taps = 0;
      Future<void> pump({bool sending = false, VoidCallback? onTap}) =>
          tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(brightness: Brightness.light),
              home: Row(
                children: [
                  ComposerGifButton(
                    block: ComposerBlock.none,
                    enabled: !sending,
                    onPressed: onTap,
                  ),
                  ComposerPollButton(
                    block: ComposerBlock.none,
                    enabled: !sending,
                    selected: true,
                    onPressed: onTap,
                  ),
                ],
              ),
            ),
          );
      await pump(onTap: () => taps++);
      await tester.tap(gif());
      await tester.tap(poll());
      expect(taps, 2);
      expect(find.byIcon(Icons.poll), findsOneWidget);
      await pump(onTap: () => taps++, sending: true);
      expect(enabled(tester, gif()), isFalse);
      expect(enabled(tester, poll()), isFalse);
      await pump();
      expect(enabled(tester, gif()), isFalse);
    });
  });

  group('accessibility and layout', () {
    testWidgets('labelled, 48dp targets', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      expect(tester.getSemantics(inner(gif())).tooltip, 'Add a GIF');
      expect(tester.getSemantics(inner(poll())).tooltip, 'Add poll');
      for (final b in [gif(), poll()]) {
        final size = tester.getSize(inner(b));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      handle.dispose();
    });

    testWidgets('360dp, x2.0, four buttons, hint and negative counter', (
      tester,
    ) async {
      await open(tester, size: const Size(360, 800), textScale: 2);
      await tester.enterText(find.byType(TextField), 'a' * 300);
      await tester.pump();
      expect(find.byType(DraftProblemHint), findsOneWidget);
      expect(find.textContaining("-20"), findsWidgets);
      expect(gif(), findsOneWidget);
      expect(poll(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final width in [360.0, 600.0, 1200.0]) {
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 1.5, 2.0]) {
          testWidgets(
            '${width.toInt()} ${brightness.name} x$scale: no overflow',
            (tester) async {
              await open(
                tester,
                size: Size(width, 800),
                brightness: brightness,
                textScale: scale,
              );
              expect(gif(), findsOneWidget);
              expect(poll(), findsOneWidget);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  });
}
