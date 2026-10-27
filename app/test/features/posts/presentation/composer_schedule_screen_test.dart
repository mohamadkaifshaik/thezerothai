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
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/domain/schedule_rules.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/features/posts/presentation/widgets/schedule_dialog.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/format/scheduled_time.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/scheduled_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The schedule UI of `/compose` (CMP-D6, ADR-0021 D4): gating, the dialog,
/// the line above the text, the "Schedule" button, what is sent, the toast and
/// the reset, and every error mapping.
void main() {
  setUpAll(() {
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    registerFallbackValue(DateTime.fromMillisecondsSinceEpoch(0));
    registerMediaFallbacks();
  });

  late _MockPostsRepository repo;
  late MockMediaRepository media;
  late FakeImagePicker picker;
  late PendingPostsCubit pending;
  late List<_Sent> sent;

  /// What the Schedule dialog thinks the time is, for the whole test. The
  /// dialog opens on the next whole minute plus 3 minutes and checks that
  /// again on Confirm, against the clock it is given. On the real clock a
  /// minute boundary between opening and Confirm made Confirm refuse ("too
  /// soon") and the dialog stay up, so a case failed about once in a hundred
  /// dialogs (CI, 2026-10-27). Frozen, nothing the test takes to run can move
  /// it. Built from the real clock (one hour ahead, so a dialog that ignored
  /// it would show) and not as a fixed date, which the date guard forbids.
  late DateTime scheduleNow;

  const both = {kFeaturePosts, kFeatureScheduledPosts};

  setUp(() {
    repo = _MockPostsRepository();
    media = MockMediaRepository();
    picker = FakeImagePicker();
    pending = PendingPostsCubit();
    sent = [];
    scheduleNow = DateTime.now().add(const Duration(hours: 1));
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() => pending.close());

  /// Answers each SchedulePost with the next of [answers] (a value, an
  /// exception to throw, or a Future to wait for); the last one repeats.
  /// [onCall] runs when a call reaches the "server", before it answers (the
  /// gate learning a refusal).
  void stubSchedule(List<Object> answers, {void Function()? onCall}) {
    var call = 0;
    when(
      () => repo.schedulePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        publishAt: any(named: 'publishAt'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: any(named: 'replyPolicy'),
      ),
    ).thenAnswer((invocation) async {
      sent.add(
        _Sent(
          key: invocation.namedArguments[#idempotencyKey] as String,
          text: invocation.namedArguments[#text] as String,
          publishAt: invocation.namedArguments[#publishAt] as DateTime,
          mediaIds: invocation.namedArguments[#mediaIds] as List<String>,
          policy: invocation.namedArguments[#replyPolicy] as ReplyPolicy,
        ),
      );
      onCall?.call();
      final answer = answers[call < answers.length ? call : answers.length - 1];
      call++;
      if (answer is Exception) throw answer;
      if (answer is Future<pb.ScheduledPost>) return answer;
      return answer as pb.ScheduledPost;
    });
  }

  void stubCreatePost() {
    when(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: any(named: 'replyPolicy'),
      ),
    ).thenAnswer((_) async => postView(1));
  }

  /// A gate for which the scheduling sub-feature (and, with [allOfPosts],
  /// every sub-feature) can be switched off from the test, like the real one
  /// does when the server answers FEATURE_DISABLED.
  ({void Function() switchOff}) stubGate({bool allOfPosts = false}) {
    var on = true;
    when(() => repo.subFeatureEnabled(any())).thenAnswer(
      (invocation) =>
          on ||
          (!allOfPosts &&
              invocation.positionalArguments.first != kFeatureScheduledPosts),
    );
    return (switchOff: () => on = false);
  }

  Future<GoRouter> open(
    WidgetTester tester, {
    Set<String> features = both,
    String quote = '',
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    DateTime Function()? clock,
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
            scheduleClock: clock ?? () => scheduleNow,
          ),
        ),
        GoRoute(
          path: '/scheduled',
          builder: (context, state) =>
              const Scaffold(body: Text('scheduled list page')),
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
    return router;
  }

  Finder scheduleIcon() => find.byTooltip('Schedule post');
  Finder willSendLine() => find.textContaining('Will send on');
  Finder primaryButton(String label) =>
      find.widgetWithText(AppPillButton, label);

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(scheduleIcon());
    await tester.pumpAndSettle();
  }

  Future<void> chooseDefaultSchedule(WidgetTester tester) async {
    await openDialog(tester);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  Future<void> addPhotos(WidgetTester tester, List<String> tags) async {
    picker.next = [for (final t in tags) imageBytes(t)];
    await tester.tap(find.byTooltip('Add photos'));
    await tester.pumpAndSettle();
  }

  group('gating', () {
    testWidgets('needs both posts and scheduled_posts', (tester) async {
      for (final features in <Set<String>>[
        const {},
        const {kFeaturePosts},
        const {kFeatureScheduledPosts},
      ]) {
        await open(tester, features: features);
        expect(scheduleIcon(), findsNothing, reason: '$features');
        expect(find.text('Scheduled posts'), findsNothing);
      }
    });

    testWidgets('shown on a new post, a 48dp target', (tester) async {
      await open(tester);
      expect(scheduleIcon(), findsOneWidget);
      final target = find.widgetWithIcon(
        IconButton,
        Icons.schedule_send_outlined,
      );
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
    });

    testWidgets('not offered when quoting', (tester) async {
      await open(
        tester,
        features: {...both, 'engagement', 'quotes'},
        quote: postId(5),
      );
      expect(scheduleIcon(), findsNothing);
    });

    testWidgets('not offered once the server said FEATURE_DISABLED', (
      tester,
    ) async {
      when(() => repo.subFeatureEnabled(kFeatureScheduledPosts))
          .thenReturn(false);
      await open(tester);
      expect(scheduleIcon(), findsNothing);
    });
  });

  group('the dialog and what it changes in the composer', () {
    testWidgets('Confirm: the line above the text, "Schedule" instead of '
        '"Post"', (tester) async {
      await open(tester);
      expect(primaryButton('Post'), findsOneWidget);
      expect(willSendLine(), findsNothing);

      await chooseDefaultSchedule(tester);

      expect(willSendLine(), findsOneWidget);
      expect(find.byIcon(Icons.schedule_outlined), findsOneWidget);
      expect(primaryButton('Schedule'), findsOneWidget);
      expect(primaryButton('Post'), findsNothing);
      // Above the text, below the header.
      expect(
        tester.getTopLeft(willSendLine()).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
      );
      // Today at the default time: the specified sentence shape.
      expect(
        tester.widget<Text>(willSendLine()).data,
        matches(RegExp(r'^Will send on .+, \d{4} at .+$')),
      );
    });

    testWidgets(
      'the line is one labelled 48dp button that reopens the dialog',
      (tester) async {
        final handle = tester.ensureSemantics();
        await open(tester);
        await chooseDefaultSchedule(tester);

        final text = tester.widget<Text>(willSendLine()).data!;
        final node = tester.getSemantics(find.bySemanticsLabel(text));
        expect(node.rect.height, greaterThanOrEqualTo(48));
        expect(node.getSemanticsData().flagsCollection.isButton, isTrue);

        await tester.tap(willSendLine());
        await tester.pumpAndSettle();
        expect(find.text('Schedule'), findsOneWidget);
        expect(find.text('Remove schedule'), findsOneWidget);
        handle.dispose();
      },
    );

    testWidgets('Remove schedule: back to Post, the line is gone', (
      tester,
    ) async {
      await open(tester);
      await chooseDefaultSchedule(tester);
      await tester.tap(willSendLine());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Remove schedule'));
      await tester.pumpAndSettle();

      expect(willSendLine(), findsNothing);
      expect(primaryButton('Post'), findsOneWidget);
      expect(primaryButton('Schedule'), findsNothing);
    });

    testWidgets('Close keeps things as they were', (tester) async {
      await open(tester);
      await openDialog(tester);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(willSendLine(), findsNothing);
      expect(primaryButton('Post'), findsOneWidget);
    });

    testWidgets('"Who can reply?" stays enabled with a schedule set', (
      tester,
    ) async {
      await open(tester, features: {...both, 'reply_audience'});
      await chooseDefaultSchedule(tester);

      await tester.tap(find.text('Everyone can reply'));
      await tester.pumpAndSettle();
      expect(find.text('Who can reply?'), findsOneWidget);
      await tester.tap(find.text('Accounts you follow'));
      await tester.pumpAndSettle();

      expect(find.text('Accounts you follow can reply'), findsOneWidget);
      expect(willSendLine(), findsOneWidget);
    });

    testWidgets('the footer link opens the list and the draft survives', (
      tester,
    ) async {
      final router = await open(tester);
      await type(tester, 'my draft');
      await openDialog(tester);

      await tester.tap(find.text('Scheduled posts'));
      await tester.pumpAndSettle();
      expect(find.text('scheduled list page'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('my draft'), findsOneWidget);
    });

    testWidgets('the images note shows only with photos attached', (
      tester,
    ) async {
      await open(tester, features: {...both, 'media'});
      await openDialog(tester);
      expect(find.text(kScheduleImagesNote), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await addPhotos(tester, ['a']);
      await openDialog(tester);
      expect(find.text(kScheduleImagesNote), findsOneWidget);
    });
  });

  group('Schedule', () {
    testWidgets('sends the UTC time, then resets the composer and shows the '
        'toast with the time the server stored', (tester) async {
      final stored = scheduledBase().add(const Duration(days: 9));
      stubSchedule([scheduledPost(1, publishAt: stored)]);
      final router = await open(tester);
      await type(tester, 'see you later');
      await chooseDefaultSchedule(tester);

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();

      final call = sent.single;
      expect(call.text, 'see you later');
      expect(call.publishAt.isUtc, isTrue);
      expect(call.policy, ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
      expect(call.mediaIds, isEmpty);
      // The default time, exactly: the next whole minute after the dialog's
      // clock plus the lead. (It also proves the dialog read the screen's
      // clock, which is an hour ahead of the device's.)
      expect(call.publishAt, defaultPublishAt(scheduleNow).toUtc());

      // The toast shows the STORED time, not the requested one.
      expect(
        find.text('Your post will be sent on ${formatScheduledTime(stored)}'),
        findsOneWidget,
      );
      expect(find.text('View'), findsOneWidget);
      // The composer is reset, still open, and the button is "Post" again.
      expect(find.text('home page'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(willSendLine(), findsNothing);
      expect(primaryButton('Post'), findsOneWidget);
      expect(
        tester.widget<AppPillButton>(primaryButton('Post')).onPressed,
        isNull,
      );

      // "View" opens the Scheduled list.
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(find.text('scheduled list page'), findsOneWidget);
      router.pop();
    });

    testWidgets('a minute boundary between opening the dialog and Confirm: '
        'Confirm is refused with the reason, nothing is scheduled', (
      tester,
    ) async {
      // The race that made this file flaky on the real clock, as a case. The
      // dialog opens on the next whole minute plus 3 (set one second before
      // the minute turns); at Confirm the minute has turned and that time is
      // under the 2 minute lead, so the server's rule says no, early.
      final minute = truncatedToMinute(scheduleNow);
      var reads = 0;
      DateTime steppingClock() => reads++ == 0
          ? minute.add(const Duration(seconds: 59))
          : minute.add(const Duration(minutes: 1, seconds: 1));
      stubSchedule([scheduledPost(1)]);
      await open(tester, clock: steppingClock);
      await type(tester, 'late');
      await openDialog(tester);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.text(kScheduleTooSoonMessage), findsOneWidget);
      expect(find.text('Confirm'), findsOneWidget, reason: 'the dialog stays');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(willSendLine(), findsNothing);
      expect(primaryButton('Post'), findsOneWidget);
      expect(sent, isEmpty);
    });

    testWidgets('while sending: progress shows, nothing is cleared', (
      tester,
    ) async {
      final done = Completer<pb.ScheduledPost>();
      stubSchedule([done.future]);
      await open(tester);
      await type(tester, 'slow');
      await chooseDefaultSchedule(tester);

      await tester.tap(primaryButton('Schedule'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.text('slow'), findsOneWidget);
      expect(willSendLine(), findsOneWidget);
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.schedule_send),
      );
      expect(button.onPressed, isNull);

      done.complete(scheduledPost(1));
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('slow'), findsNothing);
    });

    testWidgets('a retry reuses the key; an edit makes a new one', (
      tester,
    ) async {
      stubSchedule([
        const NetworkException('offline'),
        const NetworkException('offline'),
        scheduledPost(1),
      ]);
      await open(tester);
      await type(tester, 'one');
      await chooseDefaultSchedule(tester);

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();
      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();
      expect(sent.map((s) => s.key).toSet(), hasLength(1));
      // The text and the schedule survived both failures.
      expect(find.text('one'), findsOneWidget);
      expect(willSendLine(), findsOneWidget);

      await type(tester, 'one, edited');
      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();
      expect(sent.map((s) => s.key).toSet(), hasLength(2));
    });

    testWidgets('a chosen reply audience is sent with the schedule', (
      tester,
    ) async {
      stubSchedule([scheduledPost(1)]);
      await open(tester, features: {...both, 'reply_audience'});
      await type(tester, 'hello');
      await chooseDefaultSchedule(tester);
      await tester.tap(find.text('Everyone can reply'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Only accounts you mention'));
      await tester.pumpAndSettle();

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();

      expect(sent.single.policy, ReplyPolicy.REPLY_POLICY_MENTIONED_ONLY);
    });

    testWidgets('photos are uploaded first and their ids sent', (tester) async {
      stubHappyUpload(media);
      stubSchedule([scheduledPost(1)]);
      await open(tester, features: {...both, 'media'});
      await addPhotos(tester, ['a', 'b']);
      await chooseDefaultSchedule(tester);

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();

      expect(sent.single.mediaIds, ['m1', 'm2']);
      expect(find.byTooltip('Remove photo 1'), findsNothing);
    });
  });

  group('errors', () {
    Future<void> failWith(WidgetTester tester, Exception error) async {
      stubSchedule([error]);
      await open(tester);
      await type(tester, 'hello');
      await chooseDefaultSchedule(tester);
      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();
    }

    final cases = <(String, Exception, String)>[
      (
        'scheduled_pending',
        const LimitReachedException('x', quota: 'scheduled_pending'),
        'You have too many scheduled posts. Cancel one first.',
      ),
      (
        'scheduled_window',
        const LimitReachedException('x', quota: 'scheduled_window'),
        'Too many posts are scheduled around that time. Pick another time.',
      ),
      (
        'schedules (daily cap)',
        const QuotaExceededException('x', quota: 'schedules'),
        "You've reached today's limit for scheduling posts. It resets "
            'tomorrow.',
      ),
      (
        'MEDIA_NOT_READY',
        const MediaNotReadyException('x'),
        'One of your photos is no longer available. Remove it and try again.',
      ),
      (
        'offline',
        const NetworkException('x'),
        "Couldn't confirm your post was scheduled. Tap Schedule to try again, "
            'or check Scheduled posts.',
      ),
    ];
    for (final (name, error, message) in cases) {
      testWidgets('$name: friendly message, text and schedule kept', (
        tester,
      ) async {
        await failWith(tester, error);

        expect(find.text(message), findsOneWidget);
        expect(find.text('hello'), findsOneWidget);
        expect(willSendLine(), findsOneWidget);
        expect(primaryButton('Schedule'), findsOneWidget);
      });
    }

    testWidgets('FEATURE_DISABLED from the SERVER: the schedule UI goes, '
        'Post comes back and posts now', (tester) async {
      final gate = stubGate();
      stubSchedule([
        const FeatureDisabledException('x', feature: kFeatureScheduledPosts),
      ], onCall: gate.switchOff);
      stubCreatePost();
      await open(tester);
      await type(tester, 'hello');
      await chooseDefaultSchedule(tester);

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();

      // One request reached the server: this is its answer, not a local
      // refusal (the gate only turned off while that call was in flight).
      expect(sent, hasLength(1));
      expect(
        find.text("Scheduling isn't available right now."),
        findsOneWidget,
      );
      expect(scheduleIcon(), findsNothing);
      expect(willSendLine(), findsNothing);
      expect(primaryButton('Post'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);

      // The time did not stay behind: Post is a plain CreatePost.
      await tester.tap(primaryButton('Post'));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      verify(
        () => repo.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: 'hello',
          replyToPostId: any(named: 'replyToPostId'),
          quoteOfPostId: any(named: 'quoteOfPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
          replyPolicy: any(named: 'replyPolicy'),
        ),
      ).called(1);
      expect(find.text('home page'), findsOneWidget);
    });

    testWidgets('FEATURE_DISABLED for all of posts (no feature named): the '
        'schedule UI goes too', (tester) async {
      final gate = stubGate(allOfPosts: true);
      stubSchedule([
        const FeatureDisabledException('x'),
      ], onCall: gate.switchOff);
      await open(tester);
      await type(tester, 'hello');
      await chooseDefaultSchedule(tester);

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();

      expect(sent, hasLength(1));
      expect(find.text("Posting isn't available right now."), findsOneWidget);
      expect(scheduleIcon(), findsNothing);
      expect(willSendLine(), findsNothing);
      expect(primaryButton('Post'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('FEATURE_DISABLED for reply_audience: says the post will be '
        'open to everyone, and the schedule stays', (tester) async {
      stubSchedule([
        const FeatureDisabledException('x', feature: 'reply_audience'),
        scheduledPost(1),
      ]);
      await open(tester, features: {...both, 'reply_audience'});
      await type(tester, 'hello');
      await chooseDefaultSchedule(tester);
      await tester.tap(find.text('Everyone can reply'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Only accounts you mention'));
      await tester.pumpAndSettle();

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Choosing who can reply isn't available right now. Your post will "
          'be open to everyone.',
        ),
        findsOneWidget,
      );
      expect(find.text("Scheduling isn't available right now."), findsNothing);
      expect(willSendLine(), findsOneWidget);
      expect(find.text('Everyone can reply'), findsOneWidget);

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();
      expect(sent.last.policy, ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    });

    testWidgets('VALIDATION on publish_at reopens the dialog with the reason', (
      tester,
    ) async {
      await failWith(
        tester,
        const ValidationException('x', field: 'publish_at'),
      );

      // No snackbar: the dialog is back, saying why.
      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text(kScheduleRejectedMessage), findsOneWidget);
      expect(find.text('Remove schedule'), findsOneWidget);
      expect(
        find.text(
          "This post can't be scheduled. Check the text and "
          'try again.',
        ),
        findsNothing,
      );
    });
  });

  group('photos', () {
    testWidgets('a retry after a failed SchedulePost keeps the key and the '
        'media ids (the uploads are not repeated)', (tester) async {
      stubHappyUpload(media);
      stubSchedule([const NetworkException('offline'), scheduledPost(1)]);
      await open(tester, features: {...both, 'media'});
      await addPhotos(tester, ['a', 'b']);
      await chooseDefaultSchedule(tester);

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(find.byTooltip('Remove photo 1'), findsOneWidget, reason: 'kept');
      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();

      expect(sent, hasLength(2));
      expect(sent[1].key, sent[0].key);
      expect(sent[0].mediaIds, ['m1', 'm2']);
      expect(sent[1].mediaIds, ['m1', 'm2']);
      verify(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      ).called(1);
    });

    testWidgets('photos added AFTER the time was chosen still show the images '
        'note in the composer', (tester) async {
      await open(tester, features: {...both, 'media'});
      await chooseDefaultSchedule(tester);
      expect(find.text(kScheduleImagesNote), findsNothing, reason: 'no photos');

      await addPhotos(tester, ['a']);

      expect(find.text(kScheduleImagesNote), findsOneWidget);
      // Below the "Will send on" line, above the text.
      expect(
        tester.getTopLeft(find.text(kScheduleImagesNote)).dy,
        greaterThan(tester.getBottomLeft(willSendLine()).dy - 1),
      );
      expect(
        tester.getTopLeft(find.text(kScheduleImagesNote)).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
      );
    });

    testWidgets('photos first, then the time: the note shows; removing the '
        'time removes it; photos alone show none', (tester) async {
      await open(tester, features: {...both, 'media'});
      await addPhotos(tester, ['a']);
      expect(find.text(kScheduleImagesNote), findsNothing, reason: 'no time');

      await chooseDefaultSchedule(tester);
      expect(find.text(kScheduleImagesNote), findsOneWidget);

      await tester.tap(willSendLine());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove schedule'));
      await tester.pumpAndSettle();
      expect(find.text(kScheduleImagesNote), findsNothing);
    });
  });

  group('scheduling switched off while the composer is open', () {
    testWidgets('the list learned it: back in the composer the line, the '
        'button and "Schedule" are gone, the draft stays', (tester) async {
      final gate = stubGate();
      stubCreatePost();
      final router = await open(tester);
      await type(tester, 'my draft');
      await chooseDefaultSchedule(tester);
      expect(willSendLine(), findsOneWidget);
      await tester.tap(willSendLine());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scheduled posts'));
      await tester.pumpAndSettle();
      expect(find.text('scheduled list page'), findsOneWidget);

      // The list's own request was answered FEATURE_DISABLED.
      gate.switchOff();
      router.pop();
      await tester.pumpAndSettle();

      expect(willSendLine(), findsNothing);
      expect(scheduleIcon(), findsNothing);
      expect(primaryButton('Post'), findsOneWidget);
      expect(primaryButton('Schedule'), findsNothing);
      expect(find.text('my draft'), findsOneWidget);

      // What the button says is what it does: a plain post, no leftover time
      // to refuse it first.
      await tester.tap(primaryButton('Post'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      verify(
        () => repo.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: 'my draft',
          replyToPostId: any(named: 'replyToPostId'),
          quoteOfPostId: any(named: 'quoteOfPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
          replyPolicy: any(named: 'replyPolicy'),
        ),
      ).called(1);
      expect(find.text("Scheduling isn't available right now."), findsNothing);
    });

    testWidgets('after "View" in the toast the Schedule button follows the '
        'gate too', (tester) async {
      final gate = stubGate();
      stubSchedule([scheduledPost(1)]);
      final router = await open(tester);
      await type(tester, 'soon');
      await chooseDefaultSchedule(tester);
      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();
      expect(scheduleIcon(), findsOneWidget);

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(find.text('scheduled list page'), findsOneWidget);
      gate.switchOff();
      router.pop();
      await tester.pumpAndSettle();

      expect(scheduleIcon(), findsNothing);
      expect(primaryButton('Post'), findsOneWidget);
    });

    testWidgets('a tap on a stale Schedule button opens nothing', (
      tester,
    ) async {
      final gate = stubGate();
      await open(tester);
      gate.switchOff();

      await tester.tap(scheduleIcon());
      await tester.pumpAndSettle();

      expect(find.text('Confirm'), findsNothing);
      expect(scheduleIcon(), findsNothing);
    });
  });

  testWidgets('while sending, "Scheduling post" is announced once', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final done = Completer<pb.ScheduledPost>();
    stubSchedule([done.future]);
    await open(tester);
    await type(tester, 'slow');
    await chooseDefaultSchedule(tester);

    await tester.tap(primaryButton('Schedule'));
    await tester.pump();
    await tester.pump();

    expect(find.bySemanticsLabel('Scheduling post'), findsOneWidget);
    done.complete(scheduledPost(1));
    await tester.pumpAndSettle();
    handle.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('text x2 on 320dp with photos and a schedule, '
        '${brightness.name}: no overflow', (tester) async {
      await open(
        tester,
        features: {...both, 'media', 'reply_audience'},
        size: const Size(320, 640),
        brightness: brightness,
        textScale: 2,
      );
      await addPhotos(tester, ['a']);
      await chooseDefaultSchedule(tester);
      await type(tester, 'hello');

      expect(tester.takeException(), isNull);
      expect(willSendLine(), findsOneWidget);
      expect(scheduleIcon(), findsOneWidget);
    });
  }
}

class _Sent {
  const _Sent({
    required this.key,
    required this.text,
    required this.publishAt,
    required this.mediaIds,
    required this.policy,
  });

  final String key;
  final String text;
  final DateTime publishAt;
  final List<String> mediaIds;
  final ReplyPolicy policy;
}
