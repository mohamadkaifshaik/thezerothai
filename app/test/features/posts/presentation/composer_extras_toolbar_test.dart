import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/domain/engagement_feature_flag.dart';
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
import 'package:dzeroth/features/posts/presentation/widgets/composer_poll_builder.dart';
import 'package:dzeroth/features/posts/presentation/widgets/schedule_controls.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:dzeroth/features/posts/presentation/widgets/draft_problem_hint.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/poll_rules.dart';
import 'package:dzeroth/features/posts/presentation/post_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPolicy;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// The poll builder (W6-12) is tested here too; the GIF picker is W6-16.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    registerFallbackValue(newDraftPoll());
  });

  late _MockPostsRepository repo;
  late MockMediaRepository media;
  late FakeImagePicker picker;
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
      // The GIF and photos are still available with a schedule.
      expect(tooltip(tester, gif()), 'Add a GIF');
      expect(find.byTooltip('Add photos'), findsOneWidget);
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

    testWidgets('on the screen the Poll button is really enabled (W6-12)', (
      tester,
    ) async {
      await open(tester);
      expect(enabled(tester, poll()), isTrue);
      expect(tooltip(tester, poll()), 'Add poll');
      // The GIF picker is W6-16: its button has no handler yet.
      expect(enabled(tester, gif()), isFalse);
    });

    testWidgets('Poll opens the builder and the button shows it is open', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(poll());
      await tester.pumpAndSettle();
      expect(find.byType(ComposerPollBuilder), findsOneWidget);
      expect(find.byIcon(Icons.poll), findsOneWidget);
      // Photos, GIF and Schedule now say why they are off.
      expect(
        tooltip(tester, find.byType(ComposerGifButton)),
        contains('Polls'),
      );
      expect(enabled(tester, find.byType(ScheduleButton)), isFalse);
      expect(
        tester.widget<IconButton>(inner(find.byType(ScheduleButton))).tooltip,
        "Polls can't be scheduled",
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.image_outlined),
            )
            .onPressed,
        isNull,
      );
    });
  });

  group('poll builder', () {
    Finder field(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label,
    );
    Finder question() => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == kPollQuestionHint,
    );
    AppPillButton post(WidgetTester tester) => tester.widget<AppPillButton>(
      find.widgetWithText(AppPillButton, 'Post'),
    );

    Future<void> openBuilder(WidgetTester tester, {Size? size}) async {
      await open(tester, size: size ?? const Size(390, 844));
      await tester.tap(poll());
      await tester.pumpAndSettle();
    }

    testWidgets('shows the question hint, two choices and the controls', (
      tester,
    ) async {
      await openBuilder(tester);
      expect(question(), findsOneWidget);
      expect(field('Choice 1'), findsOneWidget);
      expect(field('Choice 2'), findsOneWidget);
      expect(field('Choice 3 (optional)'), findsNothing);
      expect(find.text('Add a choice'), findsOneWidget);
      expect(find.text('Poll length'), findsOneWidget);
      expect(find.text('1 day, 0 hours, 0 minutes'), findsOneWidget);
      expect(find.text('Remove poll'), findsOneWidget);
      expect(find.text('0 / 25'), findsNWidgets(2));
      expect(post(tester).onPressed, isNull);
    });

    testWidgets('2 filled choices and text enable Post', (tester) async {
      await openBuilder(tester);
      await tester.enterText(question(), 'Best colour?');
      await tester.enterText(field('Choice 1'), 'Red');
      await tester.pump();
      expect(post(tester).onPressed, isNull);
      await tester.enterText(field('Choice 2'), 'Blue');
      await tester.pump();
      expect(post(tester).onPressed, isNotNull);
      expect(find.text('3 / 25'), findsOneWidget);
      expect(find.text('4 / 25'), findsOneWidget);
    });

    testWidgets('a 26th code point turns the counter red and disables Post', (
      tester,
    ) async {
      await openBuilder(tester);
      await tester.enterText(question(), 'Best colour?');
      await tester.enterText(field('Choice 1'), 'a' * 26);
      await tester.enterText(field('Choice 2'), 'b');
      await tester.pump();
      final counter = tester.widget<Text>(find.text('26 / 25'));
      final context = tester.element(find.text('26 / 25'));
      expect(counter.style!.color, Theme.of(context).colorScheme.error);
      expect(post(tester).onPressed, isNull);
    });

    testWidgets('duplicate choices show the hint and disable Post', (
      tester,
    ) async {
      await openBuilder(tester);
      await tester.enterText(question(), 'Best colour?');
      await tester.enterText(field('Choice 1'), 'Red');
      await tester.enterText(field('Choice 2'), 'red');
      await tester.pump();
      expect(find.text(kPollDuplicateHint), findsOneWidget);
      expect(post(tester).onPressed, isNull);
    });

    testWidgets('Add a choice goes to four, then the button is gone', (
      tester,
    ) async {
      await openBuilder(tester);
      await tester.tap(find.text('Add a choice'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add a choice'));
      await tester.tap(find.text('Add a choice'));
      await tester.pumpAndSettle();
      expect(field('Choice 3 (optional)'), findsOneWidget);
      expect(field('Choice 4 (optional)'), findsOneWidget);
      expect(find.text('Add a choice'), findsNothing);
      expect(find.byTooltip('Remove choice 1'), findsNothing);
      expect(find.byTooltip('Remove choice 3'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Remove choice 4'));
      await tester.tap(find.byTooltip('Remove choice 4'));
      await tester.pumpAndSettle();
      expect(field('Choice 4 (optional)'), findsNothing);
      expect(find.text('Add a choice'), findsOneWidget);
    });

    testWidgets('removing a middle choice keeps the others typed text', (
      tester,
    ) async {
      await openBuilder(tester);
      await tester.tap(find.text('Add a choice'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add a choice'));
      await tester.tap(find.text('Add a choice'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Choice 3 (optional)'), 'three');
      await tester.enterText(field('Choice 4 (optional)'), 'four');
      await tester.pump();
      await tester.ensureVisible(find.byTooltip('Remove choice 3'));
      await tester.tap(find.byTooltip('Remove choice 3'));
      await tester.pumpAndSettle();
      final c3 = tester.widget<TextField>(field('Choice 3 (optional)'));
      expect(c3.controller!.text, 'four');
    });

    testWidgets('Remove poll goes back to a plain post', (tester) async {
      await openBuilder(tester);
      await tester.enterText(question(), 'kept text');
      await tester.ensureVisible(find.text('Remove poll'));
      await tester.tap(find.text('Remove poll'));
      await tester.pumpAndSettle();
      expect(find.byType(ComposerPollBuilder), findsNothing);
      expect(find.text('kept text'), findsOneWidget);
      expect(find.byTooltip('Add poll'), findsOneWidget);
    });

    testWidgets('under 600dp the length row opens the wheel sheet', (
      tester,
    ) async {
      await openBuilder(tester);
      await tester.tap(find.text('1 day, 0 hours, 0 minutes'));
      await tester.pumpAndSettle();
      expect(find.text('Days'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('1 day, 0 hours, 0 minutes'), findsOneWidget);
    });

    testWidgets(
      'wide: dropdowns, and 0 days is raised to 5 minutes with a hint',
      (tester) async {
        await openBuilder(tester, size: const Size(1200, 900));
        expect(find.byType(DropdownButtonFormField<int>), findsNWidgets(3));
        await tester.tap(find.byKey(const ValueKey('poll-Days-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('0').last);
        await tester.pumpAndSettle();
        expect(find.text(kPollMinLengthHint), findsOneWidget);
        expect(find.byKey(const ValueKey('poll-Minutes-5')), findsOneWidget);
      },
    );

    testWidgets('Tab moves through the question and the choices in order', (
      tester,
    ) async {
      await openBuilder(tester);
      await tester.tap(question());
      await tester.pump();
      for (final next in ['Choice 1', 'Choice 2']) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          Focus.of(
            tester.element(
              find.descendant(
                of: field(next),
                matching: find.byType(EditableText),
              ),
            ),
          ).hasFocus,
          isTrue,
          reason: next,
        );
      }
    });

    group('after Post', () {
      void stubCreate(pb.PostView answer) {
        when(
          () => repo.createPost(
            idempotencyKey: any(named: 'idempotencyKey'),
            text: any(named: 'text'),
            replyToPostId: any(named: 'replyToPostId'),
            quoteOfPostId: any(named: 'quoteOfPostId'),
            mediaIds: any(named: 'mediaIds'),
            mediaAltTexts: any(named: 'mediaAltTexts'),
            replyPolicy: any(named: 'replyPolicy'),
            poll: any(named: 'poll'),
          ),
        ).thenAnswer((_) async => answer);
        when(
          () => repo.deletePost(
            postId: any(named: 'postId'),
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenAnswer((_) async {});
      }

      Future<void> fillAndPost(WidgetTester tester) async {
        await openBuilder(tester);
        await tester.enterText(question(), 'Best colour?');
        await tester.enterText(field('Choice 1'), 'Red');
        await tester.enterText(field('Choice 2'), 'Blue');
        await tester.pump();
        await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
        await tester.pumpAndSettle();
      }

      testWidgets('the echo has a poll: no warning', (tester) async {
        final view = postView(1, text: 'Best colour?');
        view.post.poll = pb.Poll();
        stubCreate(view);
        await fillAndPost(tester);
        expect(find.text('home page'), findsOneWidget);
        expect(find.text(kPollNotAddedMessage), findsNothing);
      });

      testWidgets('the echo has no poll: warns, Delete deletes that post', (
        tester,
      ) async {
        stubCreate(postView(7, text: 'Best colour?'));
        await fillAndPost(tester);
        expect(find.text(kPollNotAddedMessage), findsOneWidget);
        expect(find.text('Keep'), findsOneWidget);
        await tester.tap(find.text('Delete'));
        await tester.pump();
        verify(
          () => repo.deletePost(
            postId: postId(7),
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).called(1);
      });

      testWidgets('Keep dismisses the warning and deletes nothing', (
        tester,
      ) async {
        stubCreate(postView(7, text: 'Best colour?'));
        await fillAndPost(tester);
        await tester.tap(find.text('Keep'));
        await tester.pumpAndSettle();
        expect(find.text(kPollNotAddedMessage), findsNothing);
        verifyNever(
          () => repo.deletePost(
            postId: any(named: 'postId'),
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        );
      });
    });

    testWidgets('semantics: choices labelled, remove has a tooltip', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await openBuilder(tester);
      expect(find.bySemanticsLabel(RegExp('Choice 1')), findsWidgets);
      expect(
        find.bySemanticsLabel('Poll length, 1 day, 0 hours, 0 minutes'),
        findsOneWidget,
      );
      handle.dispose();
    });

    for (final width in [360.0, 600.0, 1200.0]) {
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 1.5, 2.0]) {
          testWidgets(
            '${width.toInt()} ${brightness.name} x$scale: four choices, no overflow',
            (tester) async {
              await open(
                tester,
                size: Size(width, 800),
                brightness: brightness,
                textScale: scale,
              );
              await tester.tap(poll());
              await tester.pumpAndSettle();
              await tester.tap(find.text('Add a choice'));
              await tester.pumpAndSettle();
              await tester.ensureVisible(find.text('Add a choice'));
              await tester.tap(find.text('Add a choice'));
              await tester.pumpAndSettle();
              await tester.enterText(field('Choice 1'), 'a' * 26);
              await tester.enterText(field('Choice 2'), 'A' * 26);
              await tester.pump();
              await tester.ensureVisible(find.text('Remove poll'));
              expect(find.text('Remove poll'), findsOneWidget);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
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
