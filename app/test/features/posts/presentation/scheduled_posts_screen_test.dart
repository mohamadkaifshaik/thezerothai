import 'dart:async';

import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/post_error_messages.dart'
    show kScheduledUnavailableTitle;
import 'package:dzeroth/features/posts/presentation/scheduled_posts_screen.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/format/scheduled_time.dart';
import 'package:dzeroth/shared/widgets/app_notice_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/scheduled_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

/// `/scheduled` (CMP-D6): loading, empty, rows, error, load more,
/// refresh, the cancel confirmation, dismiss and the row removal.
void main() {
  late _MockPostsRepository repo;
  late List<String> cancelled;

  setUp(() {
    repo = _MockPostsRepository();
    cancelled = [];
  });

  pb.ListScheduledPostsResponse page(
    List<pb.ScheduledPost> items, [
    String next = '',
  ]) =>
      pb.ListScheduledPostsResponse(scheduledPosts: items, nextPageToken: next);

  void stubList(
    FutureOr<pb.ListScheduledPostsResponse> Function(String token) a,
  ) {
    when(
      () => repo.listScheduledPosts(
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer(
      (invocation) async => a(invocation.namedArguments[#pageToken] as String),
    );
  }

  void stubCancel([
    pb.ScheduledPost Function(String id)? answer,
    Exception? error,
  ]) {
    when(
      () => repo.cancelScheduledPost(
        scheduledId: any(named: 'scheduledId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((invocation) async {
      final id = invocation.namedArguments[#scheduledId] as String;
      cancelled.add(id);
      if (error != null) throw error;
      return answer?.call(id) ??
          pb.ScheduledPost(
            scheduledId: id,
            status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
          );
    });
  }

  Future<GoRouter> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('came from')),
        ),
        GoRoute(
          path: '/scheduled',
          builder: (context, state) => const ScheduledPostsScreen(),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: repo),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
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
    );
    unawaited(router.push('/scheduled'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return router;
  }

  Finder willSend(pb.ScheduledPost p) =>
      find.text(willSendOnText(p.publishAt.toDateTime()));

  group('states', () {
    testWidgets('loading: a skeleton, announced', (tester) async {
      final handle = tester.ensureSemantics();
      final gate = Completer<pb.ListScheduledPostsResponse>();
      when(
        () => repo.listScheduledPosts(
          pageToken: any(named: 'pageToken'),
          pageSize: any(named: 'pageSize'),
        ),
      ).thenAnswer((_) => gate.future);
      await open(tester, settle: false);

      expect(find.bySemanticsLabel('Loading scheduled posts'), findsOneWidget);
      expect(find.text('Nothing scheduled'), findsNothing);
      expect(find.text('Scheduled posts'), findsOneWidget, reason: 'header');
      gate.complete(page([]));
      await tester.pumpAndSettle();
      handle.dispose();
    });

    testWidgets('empty: a heading over a muted line, no illustration', (
      tester,
    ) async {
      stubList((_) => page([]));
      await open(tester);

      expect(find.text('Nothing scheduled'), findsOneWidget);
      expect(
        find.text('Schedule a post and it will show up here.'),
        findsOneWidget,
      );
      expect(find.byType(Icon), findsOneWidget, reason: 'only the back arrow');
      // Start aligned, near the top.
      final heading = tester.getTopLeft(find.text('Nothing scheduled'));
      expect(heading.dx, lessThan(40));
      expect(heading.dy, lessThan(200));
    });

    testWidgets('error: a friendly message and Retry', (tester) async {
      var fail = true;
      stubList(
        (_) => fail
            ? throw const NetworkException('offline')
            : page([scheduledPost(1)]),
      );
      await open(tester);

      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('scheduled 1'), findsOneWidget);
    });

    testWidgets(
      'FEATURE_DISABLED: "not available", no Retry, a pull recovers',
      (tester) async {
        var off = true;
        stubList(
          (_) => off
              ? throw const FeatureDisabledException(
                  'x',
                  feature: 'scheduled_posts',
                )
              : page([scheduledPost(1, text: 'back again')]),
        );
        await open(tester);

        expect(find.text(kScheduledUnavailableTitle), findsOneWidget);
        expect(find.text(kScheduledUnavailableBody), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
        expect(find.text('Nothing scheduled'), findsNothing);
        expect(
          find.text("This feature isn't available yet."),
          findsNothing,
          reason: 'not the generic error view',
        );
        // Start aligned near the top, like the empty state.
        final heading = tester.getTopLeft(
          find.text(kScheduledUnavailableTitle),
        );
        expect(heading.dx, lessThan(40));
        expect(heading.dy, lessThan(200));

        off = false;
        await tester.fling(
          find.text(kScheduledUnavailableTitle),
          const Offset(0, 400),
          1000,
        );
        await tester.pumpAndSettle();
        expect(find.text('back again'), findsOneWidget);
        expect(find.text(kScheduledUnavailableTitle), findsNothing);
      },
    );

    testWidgets('rows: the time, the text, a photo count and Cancel', (
      tester,
    ) async {
      final first = scheduledPost(1, text: 'first post', media: 2);
      final second = scheduledPost(2, text: 'second post', media: 1);
      stubList((_) => page([first, second]));
      await open(tester);

      expect(willSend(first), findsOneWidget);
      expect(find.text('first post'), findsOneWidget);
      expect(find.text('2 photos'), findsOneWidget);
      expect(willSend(second), findsOneWidget);
      expect(find.text('1 photo'), findsOneWidget);
      expect(find.text('Cancel'), findsNWidgets(2));
      expect(find.text('Dismiss'), findsNothing);
      // The server order is kept.
      expect(
        tester.getTopLeft(find.text('first post')).dy,
        lessThan(tester.getTopLeft(find.text('second post')).dy),
      );
    });

    testWidgets('a long text is cut at three lines', (tester) async {
      stubList((_) => page([scheduledPost(1, text: 'word ' * 200)]));
      await open(tester);
      final text = tester.widget<Text>(find.textContaining('word word'));
      expect(text.maxLines, 3);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('a FAILED row: the due time, the reason, no text, Dismiss', (
      tester,
    ) async {
      final failures = {
        ScheduledPostFailure.SCHEDULED_POST_FAILURE_MEDIA_UNAVAILABLE:
            'An image is no longer available.',
        ScheduledPostFailure.SCHEDULED_POST_FAILURE_QUOTA_EXCEEDED:
            'You reached the daily post limit.',
        ScheduledPostFailure.SCHEDULED_POST_FAILURE_ACCOUNT_RESTRICTED:
            'Your account could not post.',
        ScheduledPostFailure.SCHEDULED_POST_FAILURE_INVALID_CONTENT:
            'The post no longer meets the rules.',
        ScheduledPostFailure.SCHEDULED_POST_FAILURE_EXPIRED:
            'It could not be sent in time.',
        ScheduledPostFailure.SCHEDULED_POST_FAILURE_INTERNAL:
            'Something went wrong.',
        ScheduledPostFailure.SCHEDULED_POST_FAILURE_UNSUPPORTED:
            'Something went wrong.',
      };
      var n = 0;
      final items = [
        for (final f in failures.keys) failedScheduledPost(++n, failure: f),
      ];
      stubList((_) => page(items));
      await open(tester, size: const Size(390, 2400));

      for (final message in failures.values.toSet()) {
        expect(find.text(message), findsWidgets, reason: message);
      }
      expect(find.text('Dismiss'), findsNWidgets(failures.length));
      expect(find.text('Cancel'), findsNothing);
      expect(find.textContaining('Could not send on'), findsWidgets);
      expect(
        find.textContaining('scheduled '),
        findsNothing,
        reason: 'no text',
      );
      expect(find.text('Something went wrong.'), findsNWidgets(2));
    });

    testWidgets('a row reads as one node: time then text; the button apart', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final item = scheduledPost(1, text: 'hello there');
      stubList((_) => page([item]));
      await open(tester);

      final label =
          '${willSendOnText(item.publishAt.toDateTime())}. hello there';
      expect(find.bySemanticsLabel(label), findsOneWidget);
      final button = tester.getSemantics(
        find.bySemanticsLabel('Cancel scheduled post'),
      );
      expect(button.rect.height, greaterThanOrEqualTo(48));
      expect(button.rect.width, greaterThanOrEqualTo(48));
      expect(button.getSemanticsData().flagsCollection.isButton, isTrue);
      handle.dispose();
    });
  });

  group('paging and refresh', () {
    testWidgets('scrolling near the end loads the next page', (tester) async {
      stubList(
        (token) => token.isEmpty
            ? page([for (var i = 1; i <= 20; i++) scheduledPost(i)], 'p2')
            : page([scheduledPost(21, text: 'the last one')]),
      );
      await open(tester);
      verify(() => repo.listScheduledPosts(pageToken: '', pageSize: 20))
          .called(1);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2500));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2500));
      await tester.pumpAndSettle();

      verify(() => repo.listScheduledPosts(pageToken: 'p2', pageSize: 20))
          .called(1);
      expect(find.text('the last one'), findsOneWidget);
    });

    testWidgets('a failed page is not asked for again on every scroll tick; '
        'Retry asks once', (tester) async {
      var failPage = true;
      final tokens = <String>[];
      stubList((token) {
        tokens.add(token);
        if (token.isEmpty) {
          return page([for (var i = 1; i <= 20; i++) scheduledPost(i)], 'p2');
        }
        if (failPage) throw const NetworkException('offline');
        return page([scheduledPost(21, text: 'the last one')]);
      });
      await open(tester);

      for (var i = 0; i < 4; i++) {
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -2500),
        );
        await tester.pumpAndSettle();
      }

      // The first page, and the one page that failed: four scroll gestures
      // (dozens of scroll ticks) asked for nothing more.
      expect(tokens, ['', 'p2']);
      expect(find.byType(AppNoticeBanner), findsOneWidget);

      failPage = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(tokens, ['', 'p2', 'p2']);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2500));
      await tester.pumpAndSettle();
      expect(find.text('the last one'), findsOneWidget);
    });

    testWidgets('pull to refresh reloads, also on a short list', (
      tester,
    ) async {
      var round = 0;
      stubList(
        (_) => page([scheduledPost(1, text: round++ == 0 ? 'old' : 'new')]),
      );
      await open(tester);
      expect(find.text('old'), findsOneWidget);

      await tester.fling(find.text('old'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(find.text('new'), findsOneWidget);
      expect(find.text('old'), findsNothing);
    });

    testWidgets('a failed refresh keeps the rows under a banner with Retry', (
      tester,
    ) async {
      var round = 0;
      stubList(
        (_) => round++ == 0
            ? page([scheduledPost(1, text: 'kept')])
            : throw const NetworkException('offline'),
      );
      await open(tester);

      await tester.fling(find.text('kept'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(find.text('kept'), findsOneWidget);
      expect(find.byType(AppNoticeBanner), findsOneWidget);
      expect(
        find.text(
          "You're offline. Showing the scheduled posts already loaded.",
        ),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('Cancel', () {
    testWidgets('asks first: Keep leaves everything as it was', (tester) async {
      stubList((_) => page([scheduledPost(1, text: 'keep me')]));
      stubCancel();
      await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel this scheduled post?'), findsOneWidget);
      expect(find.text('It will not be sent.'), findsOneWidget);
      expect(find.text('Cancel post'), findsOneWidget);
      expect(find.text('Keep'), findsOneWidget);

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();

      expect(find.text('keep me'), findsOneWidget);
      expect(cancelled, isEmpty);
    });

    testWidgets('the confirmation is an alert dialog with a red primary '
        'and an outlined secondary pill, both 48dp', (tester) async {
      stubList((_) => page([scheduledPost(1)]));
      await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      final primary = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Cancel post'),
      );
      final colors = Theme.of(tester.element(find.byType(AlertDialog)))
          .colorScheme;
      expect(primary.style!.backgroundColor!.resolve({}), colors.error);
      expect(find.widgetWithText(OutlinedButton, 'Keep'), findsOneWidget);
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Cancel post')).height,
        greaterThanOrEqualTo(48),
      );
      // Full width: both pills are as wide as each other.
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Cancel post')).width,
        tester.getSize(find.widgetWithText(OutlinedButton, 'Keep')).width,
      );
    });

    testWidgets('Cancel post removes the row at once and says so', (
      tester,
    ) async {
      final gate = Completer<pb.ScheduledPost>();
      stubList(
        (_) => page([
          scheduledPost(1, text: 'drop me'),
          scheduledPost(2, text: 'stay'),
        ]),
      );
      when(
        () => repo.cancelScheduledPost(
          scheduledId: any(named: 'scheduledId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) => gate.future);
      await open(tester);

      await tester.tap(find.text('Cancel').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel post'));
      await tester.pump();
      await tester.pump();
      // Before the server answered.
      expect(find.text('drop me'), findsNothing);
      expect(find.text('stay'), findsOneWidget);

      gate.complete(
        scheduledPost(
          1,
          status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Scheduled post cancelled.'), findsOneWidget);
      expect(find.text('stay'), findsOneWidget);
    });

    testWidgets('an error puts the row back and explains', (tester) async {
      stubList((_) => page([scheduledPost(1, text: 'still here')]));
      stubCancel(null, const NetworkException('offline'));
      await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel post'));
      await tester.pumpAndSettle();

      expect(find.text('still here'), findsOneWidget);
      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
    });

    testWidgets('already sent: the row goes and the user is told', (
      tester,
    ) async {
      stubList((_) => page([scheduledPost(1, text: 'too late')]));
      stubCancel(
        (id) => pb.ScheduledPost(
          scheduledId: id,
          status: ScheduledPostStatus.SCHEDULED_POST_STATUS_PUBLISHED,
        ),
      );
      await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel post'));
      await tester.pumpAndSettle();

      expect(find.text('too late'), findsNothing);
      expect(find.text('That post was already sent.'), findsOneWidget);
    });

    testWidgets('already cancelled elsewhere: the row just goes', (
      tester,
    ) async {
      stubList((_) => page([scheduledPost(1, text: 'gone')]));
      stubCancel();
      await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel post'));
      await tester.pumpAndSettle();

      expect(find.text('gone'), findsNothing);
      expect(find.text('Nothing scheduled'), findsOneWidget);
    });
  });

  group('Dismiss', () {
    testWidgets('no confirmation: the row goes, nothing to undo', (
      tester,
    ) async {
      final failed = failedScheduledPost(5);
      stubList((_) => page([failed]));
      stubCancel();
      await open(tester);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(cancelled, [failed.scheduledId]);
      expect(find.text('It could not be sent in time.'), findsNothing);
      expect(find.text('Nothing scheduled'), findsOneWidget);
    });

    testWidgets('an error puts it back with dismiss wording', (tester) async {
      stubList((_) => page([failedScheduledPost(5)]));
      stubCancel(null, const UnknownApiException('x'));
      await open(tester);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      expect(find.text('It could not be sent in time.'), findsOneWidget);
      expect(
        find.text("Couldn't dismiss that post. Please try again."),
        findsOneWidget,
      );
    });
  });

  testWidgets('Back returns to where the user came from', (tester) async {
    stubList((_) => page([]));
    await open(tester);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('came from'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('text x2 on 320dp, ${brightness.name}: every row kind fits', (
      tester,
    ) async {
      stubList(
        (_) => page([
          scheduledPost(1, text: 'word ' * 60, media: 3),
          failedScheduledPost(
            2,
            failure:
                ScheduledPostFailure.SCHEDULED_POST_FAILURE_INVALID_CONTENT,
          ),
        ]),
      );
      await open(
        tester,
        size: const Size(320, 1600),
        brightness: brightness,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
      // Large text: the action sits under the text, not squeezing it.
      expect(
        tester.getTopLeft(find.text('Cancel')).dy,
        greaterThan(tester.getBottomLeft(find.textContaining('word word')).dy),
      );
      final button = tester.getRect(find.widgetWithText(TextButton, 'Cancel'));
      expect(button.height, greaterThanOrEqualTo(48));
      expect(button.right, lessThanOrEqualTo(320));
    });
  }
}
