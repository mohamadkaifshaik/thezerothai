import 'dart:async';

import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/notifications_screen.dart';
import 'package:dzeroth/features/notifications/presentation/widgets/follow_requests_row.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/context_pane_rig.dart';
import '../../../support/fake_push_messaging.dart';
import '../../../support/fake_push_opt_in_store.dart';
import '../../../support/geometry.dart';
import '../../../support/notifications_fixtures.dart';
import '../../../support/suggestions_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

/// Notifications beside its context (tablet plan T3, section 4.1: A "F;
/// FollowRequestsRow kept inline at the top", B "P: list | What's
/// happening"), with R8's follow-requests card (F16): in band B the card
/// joins the pane above What's happening and the inline row hides while it
/// shows; on desktop the card heads the side column. Phones and band A keep
/// the inline row and make no `ListFollowRequests` call.
void main() {
  late _MockNotificationsRepository repo;
  late _MockGraph graphRepo;
  late PushCubit push;
  late PushOptInCubit optIn;
  late int listCalls;
  late Future<GraphPage> Function() answer;

  List<graph.UserListItem> requesters(int n) => [
    for (var i = 1; i <= n; i++) suggestedUser(i, userId: 'r$i'),
  ];

  setUp(() async {
    repo = _MockNotificationsRepository();
    graphRepo = _MockGraph();
    listCalls = 0;
    answer = () async => GraphPage(items: requesters(3), nextPageToken: 'p2');
    when(() => graphRepo.followRequestsUnavailable).thenReturn(false);
    when(() => graphRepo.cached(any())).thenReturn(null);
    when(
      () => graphRepo.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) {
      listCalls++;
      return answer();
    });
    when(() => repo.enabled).thenReturn(true);
    when(() => repo.sinceRefresh).thenReturn(null);
    when(() => repo.sinceRefreshAttempt).thenReturn(null);
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.markSeen(any())).thenAnswer((_) async => kNotifBase);
    final list = snapshotOfNotifs([
      notif('a', minutesAgo: 1, type: _like, postId: '1'),
    ]);
    when(() => repo.cached()).thenAnswer((_) async => list);
    when(() => repo.refresh()).thenAnswer((_) async => list);
    push = PushCubit(
      messaging: FakePushMessaging(supported: false),
      repository: repo,
    );
    optIn = PushOptInCubit(store: FakePushOptInStore(), push: push);
    await optIn.load('uid-a');
  });

  tearDown(() async {
    await optIn.close();
    await push.close();
  });

  Future<ContextPaneRig> open(
    WidgetTester tester, {
    required double width,
    double height = 768,
    Set<String> flags = const {...kContextPaneFlags, 'private_accounts'},
    int pending = 12,
    bool isProtected = true,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    TextDirection textDirection = TextDirection.ltr,
  }) async {
    final rig = ContextPaneRig();
    await rig.pump(
      tester,
      location: '/notifications',
      width: width,
      height: height,
      brightness: brightness,
      textScale: textScale,
      textDirection: textDirection,
      flags: flags,
      pendingFollowRequests: pending,
      isProtected: isProtected,
      page: (path) => path == '/notifications'
          ? const NotificationsScreen()
          : Scaffold(
              appBar: const AppTopBar(title: 'Page'),
              body: Text('$path body'),
            ),
      wrap: (app) => MultiRepositoryProvider(
        providers: [
          RepositoryProvider<NotificationsRepository>.value(value: repo),
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<PushCubit>.value(value: push),
            BlocProvider<PushOptInCubit>.value(value: optIn),
          ],
          child: app,
        ),
      ),
    );
    return rig;
  }

  Finder inScreen(Finder f) =>
      find.descendant(of: find.byType(NotificationsScreen), matching: f);
  Finder inSide(Finder f) =>
      find.descendant(of: find.byType(AppSideColumn), matching: f);
  final card = find.byKey(const ValueKey('follow-requests-card'));
  final inlineRow = find.byKey(const ValueKey('notifications-follow-requests'));

  // Phones and band A: the inline row heads the list, no card, no call.
  for (final width in [360.0, 599.0, 600.0, 834.0, 839.0]) {
    testWidgets('${width.toInt()} dp: the inline row heads the list; no card, '
        'no ListFollowRequests', (tester) async {
      await open(tester, width: width);

      expect(inScreen(inlineRow), findsOneWidget);
      expect(
        tester.getRect(inScreen(inlineRow)).top,
        tester.getRect(inScreen(find.byType(AppTabBar))).bottom,
      );
      expectMinTarget(tester, inScreen(inlineRow));
      expect(card, findsNothing);
      expect(listCalls, 0);
      expectNoOverflow(tester);
    });
  }

  // Band B: the card joins the pane, above What's happening; the inline row
  // hides while it shows.
  for (final width in [840.0, 1024.0, 1199.0]) {
    testWidgets('${width.toInt()} dp: the card heads the pane above What\'s '
        'happening; the inline row hides; one ListFollowRequests(3)', (
      tester,
    ) async {
      await open(tester, width: width);

      expect(inContextPane(card), findsOneWidget);
      expect(inScreen(inlineRow), findsNothing);
      // The sliver stays (0 height), so the list keeps its shape at 840.
      expect(
        find.byType(FollowRequestsRow, skipOffstage: false),
        findsOneWidget,
      );
      expect(
        tester.getRect(card).bottom,
        lessThanOrEqualTo(
          tester.getRect(inContextPane(find.text("What's happening"))).top,
        ),
      );
      expect(inContextPane(find.text('Follow requests')), findsOneWidget);
      expect(inContextPane(find.text('12')), findsOneWidget);
      for (final name in ['User 1', 'User 2', 'User 3']) {
        expect(inContextPane(find.text(name)), findsOneWidget);
      }
      expect(inContextPane(find.text('Accept')), findsNWidgets(3));
      expect(inContextPane(find.text('See all requests')), findsOneWidget);
      expect(listCalls, 1);
      verify(() => graphRepo.listFollowRequests(pageSize: 3, pageToken: ''))
          .called(1);
      expectNoOverflow(tester);
    });
  }

  for (final width in [1200.0, 1440.0]) {
    testWidgets('desktop ${width.toInt()} dp: the card heads the side column; '
        'the inline row hides; one call', (tester) async {
      await open(tester, width: width, height: 1000);

      expect(findContextPane(), findsNothing);
      expect(inSide(card), findsOneWidget);
      expect(inScreen(inlineRow), findsNothing);
      expect(inSide(find.text('Accept')), findsNWidgets(3));
      expect(listCalls, 1);
      expectNoOverflow(tester);
    });
  }

  testWidgets('desktop: a page pushed over Notifications does not keep the '
      'card', (tester) async {
    final rig = await open(tester, width: 1440, height: 1000);
    expect(inSide(card), findsOneWidget);

    unawaited(rig.router.push('/u/u1'));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
  });

  testWidgets('the card speaks its heading once, with the count', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester, width: 1024);

    expect(
      find.bySemanticsLabel('Follow requests, 12 pending'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Accept follow request from @user1'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('Accept answers once; the row leaves at the tap', (tester) async {
    final done = Completer<graph.Relationship>();
    when(
      () => graphRepo.respondToFollowRequest(
        requesterUserId: any(named: 'requesterUserId'),
        accept: any(named: 'accept'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) => done.future);
    await open(tester, width: 1024);

    await tester.tap(
      find.bySemanticsLabel('Accept follow request from @user1'),
    );
    await tester.pump();
    expect(inContextPane(find.text('User 1')), findsNothing);
    verify(
      () => graphRepo.respondToFollowRequest(
        requesterUserId: 'r1',
        accept: true,
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);

    done.complete(graph.Relationship(userId: 'r1'));
    await tester.pumpAndSettle();
    expect(find.text('@user1 can now see your posts.'), findsOneWidget);
    expect(find.text('Follow back'), findsOneWidget);
  });

  testWidgets('a failed Accept puts the row back with a message', (
    tester,
  ) async {
    when(
      () => graphRepo.respondToFollowRequest(
        requesterUserId: any(named: 'requesterUserId'),
        accept: any(named: 'accept'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenThrow(const NetworkException('offline'));
    await open(tester, width: 1024);

    await tester.tap(
      find.bySemanticsLabel('Accept follow request from @user2'),
    );
    await tester.pumpAndSettle();
    expect(inContextPane(find.text('User 2')), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('See all requests opens Follow requests', (tester) async {
    await open(tester, width: 1024);

    await tester.tap(find.text('See all requests'));
    await tester.pumpAndSettle();
    expect(find.text('/follow-requests body'), findsOneWidget);
    expect(inContextPane(find.text('Who to follow')), findsOneWidget);
  });

  testWidgets('loading: the same card (title, count, link) over skeleton '
      'rows, never the footer alone', (tester) async {
    final later = Completer<GraphPage>();
    answer = () => later.future;
    await open(tester, width: 1024);

    expect(inContextPane(card), findsOneWidget);
    expect(inContextPane(find.text('Follow requests')), findsOneWidget);
    expect(inContextPane(find.text('See all requests')), findsOneWidget);
    expect(find.bySemanticsLabel('Loading follow requests'), findsOneWidget);
    later.complete(GraphPage(items: requesters(3), nextPageToken: ''));
    await tester.pumpAndSettle();
    expect(inContextPane(find.text('User 1')), findsOneWidget);
  });

  testWidgets('error: a calm line and a 48 dp Retry that asks again; no '
      'banner', (tester) async {
    var fail = true;
    answer = () async {
      if (fail) throw const NetworkException('offline');
      return GraphPage(items: requesters(2), nextPageToken: '');
    };
    await open(tester, width: 1024);

    expect(inContextPane(find.text("Couldn't load requests.")), findsOneWidget);
    final retry = inContextPane(find.widgetWithText(TextButton, 'Retry'));
    expectMinTarget(tester, retry);
    fail = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(listCalls, 2);
    expect(inContextPane(find.text('User 2')), findsOneWidget);
  });

  testWidgets('empty list against a stale count: the card keeps its link', (
    tester,
  ) async {
    answer = () async => const GraphPage(items: [], nextPageToken: '');
    await open(tester, width: 1024);

    expect(inContextPane(find.text('No follow requests')), findsOneWidget);
    expect(inContextPane(find.text('See all requests')), findsOneWidget);
    // UX review R8-5: a stale count is not repeated over "No follow
    // requests".
    expect(inContextPane(find.text('12')), findsNothing);
  });

  testWidgets('unavailable (FEATURE_DISABLED): no card, no banner', (
    tester,
  ) async {
    answer = () async =>
        throw const FeatureDisabledException('Follow requests are off.');
    await open(tester, width: 1024);

    expect(card, findsNothing);
    expect(inContextPane(find.text("What's happening")), findsOneWidget);
  });

  group('flag modes and the card rule (0 calls when it does not show)', () {
    testWidgets('nothing pending: no card, no row', (tester) async {
      await open(tester, width: 1024, pending: 0);

      expect(find.textContaining('Follow requests'), findsNothing);
      expect(inContextPane(find.text("What's happening")), findsOneWidget);
      expect(listCalls, 0);
    });

    testWidgets('graph off: no card, no row', (tester) async {
      await open(
        tester,
        width: 1024,
        flags: {...kContextPaneFlags, 'private_accounts'}..remove('graph'),
      );

      expect(find.textContaining('Follow requests'), findsNothing);
      expect(listCalls, 0);
    });

    testWidgets('private_accounts off, public caller: no card, no row', (
      tester,
    ) async {
      await open(
        tester,
        width: 1024,
        flags: kContextPaneFlags,
        isProtected: false,
      );

      expect(find.textContaining('Follow requests'), findsNothing);
      expect(listCalls, 0);
    });

    testWidgets('private_accounts off, protected caller: the card stays (the '
        'undo rule)', (tester) async {
      await open(tester, width: 1024, flags: kContextPaneFlags);

      expect(inContextPane(card), findsOneWidget);
      expect(listCalls, 1);
    });

    testWidgets('ui_tablet off at 1024: no pane; the inline row as today', (
      tester,
    ) async {
      await open(
        tester,
        width: 1024,
        flags: {...kContextPaneFlags, 'private_accounts'}
          ..remove(kFeatureUiTablet),
      );

      expect(findContextPane(), findsNothing);
      expect(inScreen(inlineRow), findsOneWidget);
      expect(card, findsNothing);
      expect(listCalls, 0);
    });

    testWidgets('desktop, nothing pending: no card in the side column', (
      tester,
    ) async {
      await open(tester, width: 1440, height: 1000, pending: 0);

      expect(card, findsNothing);
      expect(listCalls, 0);
    });
  });

  testWidgets('RTL band B: the pane on the left holds the card; no overflow', (
    tester,
  ) async {
    await open(tester, width: 1024, textDirection: TextDirection.rtl);

    expect(inContextPane(card), findsOneWidget);
    expect(
      tester.getRect(findContextPane()).right,
      lessThanOrEqualTo(tester.getRect(find.byType(NotificationsScreen)).left),
    );
    expectNoOverflow(tester);
  });

  for (final (width, height) in [
    (840.0, 1194.0),
    (1199.0, 834.0),
    (1440.0, 1000.0),
  ]) {
    testWidgets('${width.toInt()} dp x2.0: the card fits, Accept is 48 dp and '
        'never ellipsized', (tester) async {
      await open(tester, width: width, height: height, textScale: 2);

      expectNoOverflow(tester);
      final accept = find.descendant(of: card, matching: find.text('Accept'));
      expect(accept, findsNWidgets(3));
      for (final element in accept.evaluate()) {
        final paragraph = element.renderObject! as RenderParagraph;
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      expectMinTarget(
        tester,
        find.bySemanticsLabel('Accept follow request from @user1'),
      );
      // UX review R8-7: inside its column, whichever it is.
      final column = width >= AppBreakpoints.tablet
          ? find.byType(AppSideColumn)
          : findContextPane();
      final box = tester.getRect(column);
      final cardRect = tester.getRect(card);
      expect(cardRect.left, greaterThanOrEqualTo(box.left));
      expect(cardRect.right, lessThanOrEqualTo(box.right));
      if (width >= AppBreakpoints.tablet) {
        expect(box.width, lessThanOrEqualTo(AppSize.sideColumn));
      }
      expect(
        find.descendant(of: card, matching: find.text('See all requests')),
        findsOneWidget,
      );
    });
  }

  // UX review R8-3: a page pushed over Notifications in band B drops the
  // card (the shell's top page decides, as on desktop).
  testWidgets('band B: a page pushed over Notifications drops the card', (
    tester,
  ) async {
    final rig = await open(tester, width: 1024);
    expect(inContextPane(card), findsOneWidget);

    unawaited(rig.router.push('/bookmarks'));
    await tester.pumpAndSettle();
    expect(find.text('/bookmarks body'), findsOneWidget);
    expect(card, findsNothing);
    expect(inContextPane(find.text("What's happening")), findsOneWidget);

    rig.router.pop();
    await tester.pumpAndSettle();
    expect(inContextPane(card), findsOneWidget);
  });

  // UX review R8-6: the placeholder rows carry a trailing pill, so the card
  // does not change height when the rows arrive.
  testWidgets('the loading card is as tall as the loaded one', (tester) async {
    final later = Completer<GraphPage>();
    answer = () => later.future;
    await open(tester, width: 1024);
    final loading = tester.getSize(inContextPane(card)).height;

    later.complete(GraphPage(items: requesters(3), nextPageToken: ''));
    await tester.pumpAndSettle();
    expect(inContextPane(find.text('User 3')), findsOneWidget);
    expect(tester.getSize(inContextPane(card)).height, closeTo(loading, 1));
  });

  // The tablet matrix (plan section 5.5): 5 widths x 2 scales x 2 themes,
  // and 840.
  forEachThemeAndWidth(
    'tablet matrix: the list fits the primary pane; the row inline in band '
    'A, the card in the pane in band B',
    (tester, env) async {
      await open(
        tester,
        width: env.size.width,
        height: env.size.height,
        brightness: env.brightness,
        textScale: env.textScale,
      );

      expectNoOverflow(tester);
      expectTabletPanes(
        tester,
        find.byType(NotificationsScreen),
        env.size.width,
      );
      if (env.size.width >= AppBreakpoints.expanded) {
        expect(inScreen(inlineRow), findsNothing);
        expect(inContextPane(card), findsOneWidget);
        expect(inContextPane(find.text("What's happening")), findsOneWidget);
      } else {
        final row = inScreen(inlineRow);
        expect(row, findsOneWidget);
        expect(
          tester.getRect(row).top,
          tester.getRect(inScreen(find.byType(AppTabBar))).bottom,
        );
        expectMinTarget(tester, row);
      }
    },
    // Plus 840, the narrowest band B primary (439 dp).
    widths: [...kTabletMatrixWidths, 840],
    textScales: kTabletTextScales,
    heights: {...kTabletHeights, 840: 1194},
  );
}

const _like = NotificationType.NOTIFICATION_TYPE_LIKE;
