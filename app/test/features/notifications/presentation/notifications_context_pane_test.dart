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

/// Notifications on the tablet layout, which has no side context pane, with
/// R8's follow-requests card (F16): phones, band A and band B (840-1199 dp)
/// all keep the inline row at the head of the list and make no
/// `ListFollowRequests` call; only on desktop (>= 1200 dp) the card heads the
/// side column and the inline row hides while it shows.
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
  Finder inCard(Finder f) => find.descendant(of: card, matching: f);
  final inlineRow = find.byKey(const ValueKey('notifications-follow-requests'));

  // Phones, band A and band B: the inline row heads the list, no pane, no
  // card, no call.
  for (final width in [
    360.0,
    599.0,
    600.0,
    834.0,
    839.0,
    840.0,
    1024.0,
    1199.0,
  ]) {
    testWidgets('${width.toInt()} dp: the inline row heads the list; no pane, '
        'no card, no ListFollowRequests', (tester) async {
      await open(tester, width: width);

      expect(findContextPane(), findsNothing);
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

  // The card's own behaviour, where it lives: the desktop side column.
  Future<void> openDesktop(
    WidgetTester tester, {
    Set<String> flags = const {...kContextPaneFlags, 'private_accounts'},
    int pending = 12,
    bool isProtected = true,
  }) => open(
    tester,
    width: 1440,
    height: 1000,
    flags: flags,
    pending: pending,
    isProtected: isProtected,
  );

  testWidgets('the card speaks its heading once, with the count', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openDesktop(tester);

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
    await openDesktop(tester);

    await tester.tap(
      find.bySemanticsLabel('Accept follow request from @user1'),
    );
    await tester.pump();
    expect(inCard(find.text('User 1')), findsNothing);
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
    await openDesktop(tester);

    await tester.tap(
      find.bySemanticsLabel('Accept follow request from @user2'),
    );
    await tester.pumpAndSettle();
    expect(inCard(find.text('User 2')), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('See all requests opens Follow requests', (tester) async {
    await openDesktop(tester);

    await tester.tap(find.text('See all requests'));
    await tester.pumpAndSettle();
    expect(find.text('/follow-requests body'), findsOneWidget);
  });

  testWidgets('loading: the same card (title, count, link) over skeleton '
      'rows, never the footer alone', (tester) async {
    final later = Completer<GraphPage>();
    answer = () => later.future;
    await openDesktop(tester);

    expect(inSide(card), findsOneWidget);
    expect(inSide(find.text('Follow requests')), findsOneWidget);
    expect(inSide(find.text('See all requests')), findsOneWidget);
    expect(find.bySemanticsLabel('Loading follow requests'), findsOneWidget);
    later.complete(GraphPage(items: requesters(3), nextPageToken: ''));
    await tester.pumpAndSettle();
    expect(inCard(find.text('User 1')), findsOneWidget);
  });

  testWidgets('error: a calm line and a 48 dp Retry that asks again; no '
      'banner', (tester) async {
    var fail = true;
    answer = () async {
      if (fail) throw const NetworkException('offline');
      return GraphPage(items: requesters(2), nextPageToken: '');
    };
    await openDesktop(tester);

    expect(inSide(find.text("Couldn't load requests.")), findsOneWidget);
    final retry = inSide(find.widgetWithText(TextButton, 'Retry'));
    expectMinTarget(tester, retry);
    fail = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(listCalls, 2);
    expect(inCard(find.text('User 2')), findsOneWidget);
  });

  testWidgets('empty list against a stale count: the card keeps its link', (
    tester,
  ) async {
    answer = () async => const GraphPage(items: [], nextPageToken: '');
    await openDesktop(tester);

    expect(inSide(find.text('No follow requests')), findsOneWidget);
    expect(inSide(find.text('See all requests')), findsOneWidget);
    // UX review R8-5: a stale count is not repeated over "No follow
    // requests".
    expect(inSide(find.text('12')), findsNothing);
  });

  testWidgets('unavailable (FEATURE_DISABLED): no card, no banner', (
    tester,
  ) async {
    answer = () async =>
        throw const FeatureDisabledException('Follow requests are off.');
    await openDesktop(tester);

    expect(card, findsNothing);
  });

  group('flag modes and the card rule (0 calls when it does not show)', () {
    testWidgets('nothing pending: no card, no row', (tester) async {
      await open(tester, width: 1024, pending: 0);

      expect(find.textContaining('Follow requests'), findsNothing);
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

    testWidgets('private_accounts off, protected caller: the inline row stays '
        'in band B (the undo rule)', (tester) async {
      await open(tester, width: 1024, flags: kContextPaneFlags);

      expect(findContextPane(), findsNothing);
      expect(inScreen(inlineRow), findsOneWidget);
      expect(card, findsNothing);
      expect(listCalls, 0);
    });

    testWidgets('private_accounts off, protected caller, desktop: the card '
        'stays (the undo rule)', (tester) async {
      await openDesktop(tester, flags: kContextPaneFlags);

      expect(inSide(card), findsOneWidget);
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
      await openDesktop(tester, pending: 0);

      expect(card, findsNothing);
      expect(listCalls, 0);
    });
  });

  testWidgets('RTL band B: no pane; the inline row heads the list, no '
      'overflow', (tester) async {
    await open(tester, width: 1024, textDirection: TextDirection.rtl);

    expect(findContextPane(), findsNothing);
    expect(inScreen(inlineRow), findsOneWidget);
    expect(card, findsNothing);
    expectNoOverflow(tester);
  });

  // Band B at text scale 2.0: the inline row fits and stays a 48 dp target.
  for (final (width, height) in [(840.0, 1194.0), (1199.0, 834.0)]) {
    testWidgets('${width.toInt()} dp x2.0: the inline row fits and is 48 dp', (
      tester,
    ) async {
      await open(tester, width: width, height: height, textScale: 2);

      expectNoOverflow(tester);
      expect(findContextPane(), findsNothing);
      expect(inScreen(inlineRow), findsOneWidget);
      expectMinTarget(tester, inScreen(inlineRow));
    });
  }

  testWidgets('desktop 1440 dp x2.0: the card fits, Accept is 48 dp and '
      'never ellipsized', (tester) async {
    await open(tester, width: 1440, height: 1000, textScale: 2);

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
    // UX review R8-7: inside the side column.
    final box = tester.getRect(find.byType(AppSideColumn));
    final cardRect = tester.getRect(card);
    expect(cardRect.left, greaterThanOrEqualTo(box.left));
    expect(cardRect.right, lessThanOrEqualTo(box.right));
    expect(box.width, lessThanOrEqualTo(AppSize.sideColumn));
    expect(
      find.descendant(of: card, matching: find.text('See all requests')),
      findsOneWidget,
    );
  });

  // UX review R8-6: the placeholder rows carry a trailing pill, so the card
  // does not change height when the rows arrive.
  testWidgets('the loading card is as tall as the loaded one', (tester) async {
    final later = Completer<GraphPage>();
    answer = () => later.future;
    await openDesktop(tester);
    final loading = tester.getSize(inSide(card)).height;

    later.complete(GraphPage(items: requesters(3), nextPageToken: ''));
    await tester.pumpAndSettle();
    expect(inCard(find.text('User 3')), findsOneWidget);
    expect(tester.getSize(inSide(card)).height, closeTo(loading, 1));
  });

  // The tablet matrix (plan section 5.5): 5 widths x 2 scales x 2 themes,
  // and 840.
  forEachThemeAndWidth(
    'tablet matrix: the list fills the content with the inline row, no pane',
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
        hasPane: false,
      );
      expect(card, findsNothing);
      final row = inScreen(inlineRow);
      expect(row, findsOneWidget);
      expect(
        tester.getRect(row).top,
        tester.getRect(inScreen(find.byType(AppTabBar))).bottom,
      );
      expectMinTarget(tester, row);
    },
    // Plus 840, the first band B width.
    widths: [...kTabletMatrixWidths, 840],
    textScales: kTabletTextScales,
    heights: {...kTabletHeights, 840: 1194},
  );

  // T8e: the readable column. The tabs sit in the 680 column; their
  // hairline spans the page (wherever the page is wider than the column).
  for (final width in [600.0, 834.0, 839.0, 1024.0]) {
    testWidgets('${width.toInt()} dp: the tab bar in the column, its '
        'hairline across the page', (tester) async {
      await open(tester, width: width);
      final primary = tester.getRect(
        find.byKey(const ValueKey('tablet-primary')),
      );
      final column = primary.width < 680 ? primary.width : 680.0;
      final bar = tester.getRect(inScreen(find.byType(AppTabBar)));
      expect(bar.width, moreOrLessEquals(column));
      expect(bar.center.dx, moreOrLessEquals(primary.center.dx));
      final bleed = (primary.width - column) / 2;
      final hairline = tester.renderObject(
        inScreen(find.byKey(AppTabBar.hairlineKey)),
      );
      if (bleed > 0) {
        expect(
          hairline,
          paints
            ..rect(rect: Rect.fromLTRB(-bleed, bar.height - 1, 0, bar.height))
            ..rect(
              rect: Rect.fromLTRB(
                bar.width,
                bar.height - 1,
                bar.width + bleed,
                bar.height,
              ),
            ),
        );
      } else {
        expect(hairline, isNot(paints..rect()));
      }
    });
  }
}

const _like = NotificationType.NOTIFICATION_TYPE_LIKE;
