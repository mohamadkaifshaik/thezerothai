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

  const both = {kFeaturePosts, kFeatureScheduledPosts};

  setUp(() {
    repo = _MockPostsRepository();
    media = MockMediaRepository();
    picker = FakeImagePicker();
    pending = PendingPostsCubit();
    sent = [];
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() => pending.close());

  /// Answers each SchedulePost with the next of [answers] (a value, an
  /// exception to throw, or a Future to wait for); the last one repeats.
  void stubSchedule(List<Object> answers) {
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
      final answer = answers[call < answers.length ? call : answers.length - 1];
      call++;
      if (answer is Exception) throw answer;
      if (answer is Future<pb.ScheduledPost>) return answer;
      return answer as pb.ScheduledPost;
    });
  }

  Future<GoRouter> open(
    WidgetTester tester, {
    Set<String> features = both,
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
          builder: (context, state) =>
              ComposerScreen(quoteOfPostId: quote, quoteUiEnabled: true),
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
      await open(tester, features: {...both, 'engagement'}, quote: postId(5));
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
      final before = DateTime.now();
      await chooseDefaultSchedule(tester);

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();

      final call = sent.single;
      expect(call.text, 'see you later');
      expect(call.publishAt.isUtc, isTrue);
      expect(call.policy, ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
      expect(call.mediaIds, isEmpty);
      // The default time: a few minutes from when the dialog was opened.
      final lead = call.publishAt.difference(before);
      expect(lead, greaterThanOrEqualTo(const Duration(minutes: 2)));
      expect(lead, lessThanOrEqualTo(const Duration(minutes: 5)));

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
        'No connection. Your post was not scheduled; check your network and '
            'try again.',
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

    testWidgets('FEATURE_DISABLED: the schedule UI goes, Post comes back', (
      tester,
    ) async {
      stubSchedule([
        const FeatureDisabledException('x', feature: kFeatureScheduledPosts),
      ]);
      await open(tester);
      await type(tester, 'hello');
      await chooseDefaultSchedule(tester);
      // The gate remembers the answer.
      when(() => repo.subFeatureEnabled(kFeatureScheduledPosts))
          .thenReturn(false);

      await tester.tap(primaryButton('Schedule'));
      await tester.pumpAndSettle();

      expect(
        find.text("Scheduling isn't available right now."),
        findsOneWidget,
      );
      expect(scheduleIcon(), findsNothing);
      expect(willSendLine(), findsNothing);
      expect(primaryButton('Post'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
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
