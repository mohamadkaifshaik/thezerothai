import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/plans_session.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/post_beacon_embed.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as beacons;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import 'package:dzeroth/features/timeline/presentation/widgets/feed_post_row.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/post/unavailable_post_box.dart';
import 'package:dzeroth/shared/widgets/primitives/app_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../../support/beacons_fixtures.dart';
import '../../../../support/beacons_rig.dart';
import '../../../../support/contrast.dart';
import '../../../../support/fake_beacons_server.dart';
import '../../../../support/geometry.dart';
import '../../../../support/posts_fixtures.dart';

/// F5 plan embeds in posts (`post_beacon_embed`): the plan card inside a post
/// in every list and on the opened post (all of them draw [PostCard]), per
/// flag mode, per status, and the Join flow through the plans cubit.
void main() {
  final start = DateTime.now().add(const Duration(days: 1));

  pb.BeaconPreview preview({
    beacons.BeaconStatus status = beacons.BeaconStatus.BEACON_STATUS_OPEN,
    bool unavailable = false,
  }) => unavailable
      ? pb.BeaconPreview(beaconId: kBeaconIdA, unavailable: true)
      : pb.BeaconPreview(
          beaconId: kBeaconIdA,
          title: 'Sunrise walk',
          activity: beacons.BeaconActivity.BEACON_ACTIVITY_WALK,
          startAt: ts.Timestamp.fromDateTime(start.toUtc()),
          status: status,
        );

  pb.PostView post({
    pb.BeaconPreview? beacon,
    String authorId = 'org',
    bool repost = false,
  }) => pb.PostView(
    post: repost
        ? pb.Post(
            postId: postId(2),
            kind: PostKind.POST_KIND_REPOST,
            author: common.AuthorSnapshot(userId: 'u2', handle: 'bob'),
            embedded: pb.EmbeddedPost(
              postId: postId(1),
              text: 'Anyone up for a walk?',
              author: common.AuthorSnapshot(userId: authorId, handle: 'orla'),
            ),
            beacon: beacon,
          )
        : pb.Post(
            postId: postId(1),
            text: 'Anyone up for a walk?',
            author: common.AuthorSnapshot(userId: authorId, handle: 'orla'),
            beacon: beacon ?? preview(),
          ),
  );

  late FakeBeaconsServer server;

  setUp(() {
    server = FakeBeaconsServer()
      ..viewerId = 'me'
      ..public.add(beaconView(startAt: start, title: 'Sunrise walk'));
  });

  Future<GoRouter> pump(
    WidgetTester tester, {
    required pb.PostView view,
    Set<String> features = const {kFeaturePostBeaconEmbed, kFeatureBeacons},
    bool focal = false,
    double width = 360,
    double textScale = 1.0,
    TextDirection direction = TextDirection.ltr,
    BeaconsRepository? repository,
    Brightness brightness = Brightness.light,
    bool longFeed = false,
    PlansSession? session,
  }) async {
    final card = PostCard(
      view: view,
      viewerUserId: 'me',
      focal: focal,
      graphActionsEnabled: false,
    );
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Directionality(
              textDirection: direction,
              child: longFeed
                  // A feed: the card, then rows tall enough that scrolling to
                  // the end disposes it.
                  ? ListView.builder(
                      itemCount: 30,
                      itemBuilder: (context, i) => i == 0
                          ? card
                          : SizedBox(height: 300, child: Text('row $i')),
                    )
                  : SingleChildScrollView(child: card),
            ),
          ),
        ),
        GoRoute(
          path: '/plans/:id',
          builder: (context, state) =>
              Scaffold(body: Text('plan page ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<BeaconsRepository>.value(
            value: repository ?? server,
          ),
          RepositoryProvider<PlansSession>.value(
            value: session ?? PlansSession(repository: repository ?? server),
          ),
        ],
        child: withPlansFeatures(
          MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: router,
          ),
          features,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  group('flag modes', () {
    testWidgets('post_beacon_embed off: no plan card at all', (tester) async {
      await pump(tester, view: post(), features: {kFeatureBeacons});

      expect(find.byType(PostBeaconEmbed), findsNothing);
      expect(find.text('Sunrise walk'), findsNothing);
      expect(server.calls, isEmpty);
    });

    testWidgets('embed on, beacons off: the card shows, display only', (
      tester,
    ) async {
      await pump(tester, view: post(), features: {kFeaturePostBeaconEmbed});

      expect(find.byType(PostBeaconEmbed), findsOneWidget);
      expect(find.text('Sunrise walk'), findsOneWidget);
      expect(find.text('PLAN · WALK'), findsOneWidget);
      expect(find.text(kPlanAskToJoin), findsNothing);
      await tester.tap(find.text('Sunrise walk'));
      await tester.pumpAndSettle();
      expect(find.textContaining('plan page'), findsNothing);
      expect(server.calls, isEmpty);
    });

    testWidgets('both on: Ask to join, and the card opens the plan', (
      tester,
    ) async {
      await pump(tester, view: post());

      expect(find.text(kPlanAskToJoin), findsOneWidget);
      // Drawing the card costs no RPC.
      expect(server.calls, isEmpty);
      await tester.tap(find.text('Sunrise walk'));
      await tester.pumpAndSettle();
      expect(find.text('plan page $kBeaconIdA'), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('unavailable: nothing at all (no box, no gap, no claim)', (
      tester,
    ) async {
      // Search, bookmarks and likes send the bare unavailable form for every
      // plan (no hydration there), so the card must not call it unavailable.
      await pump(tester, view: post(beacon: preview(unavailable: true)));

      expect(find.byType(PostBeaconEmbed), findsNothing);
      expect(find.byType(AppPlanStrip), findsNothing);
      expect(find.byType(UnavailablePostBox), findsNothing);
      expect(find.textContaining('unavailable'), findsNothing);
      expect(find.textContaining('PLAN'), findsNothing);
    });

    for (final status in const [
      beacons.BeaconStatus.BEACON_STATUS_FULL,
      beacons.BeaconStatus.BEACON_STATUS_CANCELLED,
      beacons.BeaconStatus.BEACON_STATUS_ENDED,
    ]) {
      testWidgets('${status.name}: the status, no Join', (tester) async {
        await pump(
          tester,
          view: post(beacon: preview(status: status)),
        );

        expect(find.byKey(const ValueKey('post-plan-status')), findsOneWidget);
        expect(find.text(kPlanAskToJoin), findsNothing);
      });
    }

    testWidgets('the viewer\'s own post (their plan): no Join', (tester) async {
      await pump(tester, view: post(authorId: 'me'));

      expect(find.byType(PostBeaconEmbed), findsOneWidget);
      expect(find.text(kPlanAskToJoin), findsNothing);
    });

    testWidgets('a REPOST row never draws a plan card', (tester) async {
      await pump(tester, view: post(repost: true, beacon: preview()));

      expect(find.byType(PostBeaconEmbed), findsNothing);
    });

    testWidgets('the opened post draws it too', (tester) async {
      await pump(tester, view: post(), focal: true, width: 1200);

      expect(find.byType(PostBeaconEmbed), findsOneWidget);
      expect(find.text(kPlanAskToJoin), findsOneWidget);
    });
  });

  group('join', () {
    testWidgets('Ask to join: GetBeacon, the note sheet, then the request', (
      tester,
    ) async {
      await pump(tester, view: post());

      await tester.tap(find.text(kPlanAskToJoin));
      await tester.pumpAndSettle();
      expect(server.calls, ['get']);
      expect(find.text('Send request'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'See you there');
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();

      // The cubit reloads after every write (R35): get, request, get.
      expect(server.calls, ['get', 'request', 'get']);
      expect(server.lastNote, 'See you there');
      expect(find.text(kPlanRequested), findsOneWidget);
      expect(find.text(kPlanAskToJoin), findsNothing);
    });

    testWidgets('"Requested" survives scrolling the card away and back', (
      tester,
    ) async {
      final session = PlansSession(repository: server);
      await pump(tester, view: post(), longFeed: true, session: session);

      await tester.tap(find.text(kPlanAskToJoin));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();
      expect(find.text(kPlanRequested), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(find.byType(PostBeaconEmbed), findsNothing, reason: 'disposed');
      await tester.drag(find.byType(ListView), const Offset(0, 8000));
      await tester.pumpAndSettle();

      expect(find.text(kPlanRequested), findsOneWidget);
      expect(find.text(kPlanAskToJoin), findsNothing);
      expect(session.requestedFromPost(kBeaconIdA), isTrue);
    });

    testWidgets('a new session (another account) asks again', (tester) async {
      final session = PlansSession(repository: server);
      await pump(tester, view: post(), session: session);
      await tester.tap(find.text(kPlanAskToJoin));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();
      expect(session.requestedFromPost(kBeaconIdA), isTrue);

      session.reset();
      expect(session.requestedFromPost(kBeaconIdA), isFalse);
    });

    testWidgets('dismissing the sheet sends nothing', (tester) async {
      await pump(tester, view: post());

      await tester.tap(find.text(kPlanAskToJoin));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(server.calls, ['get']);
      expect(find.text(kPlanAskToJoin), findsOneWidget);
    });

    testWidgets('a viewer who cannot ask (already asked) gets the plan page', (
      tester,
    ) async {
      server.public
        ..clear()
        ..add(
          beaconView(startAt: start, title: 'Sunrise walk')
            ..viewer.canRequest = false
            ..viewer.canWithdraw = true,
        );
      await pump(tester, view: post());

      await tester.tap(find.text(kPlanAskToJoin));
      await tester.pumpAndSettle();

      expect(server.calls, ['get']);
      expect(find.text('plan page $kBeaconIdA'), findsOneWidget);
    });

    testWidgets('a refused request shows the plans error copy', (tester) async {
      await pump(tester, view: post());

      await tester.tap(find.text(kPlanAskToJoin));
      await tester.pumpAndSettle();
      server.refusals.add(const NotFoundException('gone'));
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();

      expect(find.text('This plan is unavailable.'), findsOneWidget);
      expect(find.text(kPlanAskToJoin), findsOneWidget);
    });

    testWidgets('a failed GetBeacon shows the plans error copy', (
      tester,
    ) async {
      server.refusals.add(const NetworkException('offline'));
      await pump(tester, view: post());

      await tester.tap(find.text(kPlanAskToJoin));
      await tester.pumpAndSettle();

      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
      expect(find.text('Send request'), findsNothing);
    });
  });

  group('layout', () {
    for (final width in const [360.0, 600.0, 1200.0]) {
      testWidgets('at $width x2.0: no overflow, Join is 48 dp and whole', (
        tester,
      ) async {
        await pump(tester, view: post(), width: width, textScale: 2.0);

        expectNoOverflow(tester);
        final join = find.ancestor(
          of: find.text(kPlanAskToJoin),
          matching: find.byType(TextButton),
        );
        expect(
          tester.getSize(join).height,
          greaterThanOrEqualTo(AppSpacing.minTapTarget),
        );
        final text = tester.widget<Text>(find.text(kPlanAskToJoin));
        expect(text.overflow, isNot(TextOverflow.ellipsis));
        expect(text.maxLines, isNull);
      });
    }

    for (final scale in const [1.0, 2.0]) {
      testWidgets('at 360 x$scale the summary keeps at least 140 dp, else Join '
          'goes under it', (tester) async {
        await pump(tester, view: post(), textScale: scale);

        expectNoOverflow(tester);
        final summary = tester.getRect(
          find.byKey(const ValueKey('post-plan-summary')),
        );
        final join = tester.getRect(
          find.ancestor(
            of: find.text(kPlanAskToJoin),
            matching: find.byType(TextButton),
          ),
        );
        expect(
          summary.width >= 140 || join.top >= summary.bottom,
          isTrue,
          reason: 'summary $summary, join $join',
        );
        if (scale == 2.0) {
          // Too narrow beside Join at 2.0: Join moves under the summary.
          expect(join.top, greaterThanOrEqualTo(summary.bottom));
        }
      });
    }

    testWidgets('the time drops the year in the current year', (tester) async {
      await pump(tester, view: post());

      final when = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('post-plan-summary')),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data ?? '')
          .firstWhere((t) => t.contains(' at '));
      final now = DateTime.now();
      if (start.year == now.year) {
        expect(when, isNot(contains('${start.year}')));
      } else {
        expect(when, contains('${start.year}'));
      }
    });

    testWidgets('RTL, beside the summary (1200): Join sits at the end edge', (
      tester,
    ) async {
      await pump(
        tester,
        view: post(),
        direction: TextDirection.rtl,
        width: 1200,
      );

      final strip = tester.getRect(find.byType(PostBeaconEmbed));
      final join = tester.getRect(find.text(kPlanAskToJoin));
      expect(join.center.dx, lessThan(strip.center.dx));
      expectNoOverflow(tester);
    });

    testWidgets('RTL, under the summary (360 x2.0): Join starts at the start '
        'edge', (tester) async {
      await pump(
        tester,
        view: post(),
        direction: TextDirection.rtl,
        textScale: 2.0,
      );

      final strip = tester.getRect(find.byType(PostBeaconEmbed));
      final join = tester.getRect(find.text(kPlanAskToJoin));
      expect(join.center.dx, greaterThan(strip.center.dx));
      expectNoOverflow(tester);
    });

    testWidgets('one node for the plan, a separate Join button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, view: post());

      final label = find.bySemanticsLabel(RegExp(r'^Plan, Walk, Sunrise walk'));
      expect(label, findsOneWidget);
      expect(tester.getSemantics(label), isSemantics(isButton: true));
      expect(
        tester.getSemantics(find.bySemanticsLabel(kPlanAskToJoin)),
        isSemantics(isButton: true),
      );
      handle.dispose();
    });
  });

  group(
    'in a feed row (Feed, community, profile and lists draw FeedPostRow)',
    () {
      Future<void> pumpRow(
        WidgetTester tester, {
        Set<String> features = const {kFeaturePostBeaconEmbed, kFeatureBeacons},
      }) async {
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (context, _) => Scaffold(
                body: SingleChildScrollView(
                  child: FeedPostRow(
                    view: post(),
                    viewerUserId: 'me',
                    graphEnabled: false,
                    reportsEnabled: false,
                    engagementEnabled: false,
                  ),
                ),
              ),
            ),
            GoRoute(
              path: '/plans/:id',
              builder: (context, state) => Scaffold(
                body: Text('plan page ${state.pathParameters['id']}'),
              ),
            ),
            GoRoute(
              path: '/post/:id',
              builder: (context, state) => Scaffold(
                body: Text('post page ${state.pathParameters['id']}'),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 800);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          RepositoryProvider<BeaconsRepository>.value(
            value: server,
            child: withPlansFeatures(
              MaterialApp.router(
                theme: buildAppTheme(brightness: Brightness.light),
                routerConfig: router,
              ),
              features,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      testWidgets('the strip opens the plan, not the post', (tester) async {
        await pumpRow(tester);

        await tester.tap(find.text('Sunrise walk'));
        await tester.pumpAndSettle();

        expect(find.text('plan page $kBeaconIdA'), findsOneWidget);
        expect(find.textContaining('post page'), findsNothing);
      });

      testWidgets('with beacons off the tap falls through to the post', (
        tester,
      ) async {
        await pumpRow(tester, features: {kFeaturePostBeaconEmbed});

        await tester.tap(find.text('Sunrise walk'));
        await tester.pumpAndSettle();

        expect(find.text('post page ${postId(1)}'), findsOneWidget);
        expect(find.textContaining('plan page'), findsNothing);
      });

      testWidgets('Join opens the note sheet, neither page', (tester) async {
        await pumpRow(tester);

        await tester.tap(find.text(kPlanAskToJoin));
        await tester.pumpAndSettle();

        expect(find.text('Send request'), findsOneWidget);
        expect(find.textContaining('plan page'), findsNothing);
        expect(find.textContaining('post page'), findsNothing);
      });
    },
  );

  group('focus and theme', () {
    testWidgets('keyboard focus on the strip: a light fill and a 2 dp pearl '
        'ring, the text stays readable', (tester) async {
      await pump(tester, view: post());

      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused?.findAncestorWidgetOfExactType<AppPlanStrip>() != null &&
            focused?.findAncestorWidgetOfExactType<TextButton>() == null) {
          break;
        }
      }
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(focused.findAncestorWidgetOfExactType<AppPlanStrip>(), isNotNull);
      await tester.pumpAndSettle();

      final inkWell = tester.widget<InkWell>(
        find
            .descendant(
              of: find.byType(AppPlanStrip),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(inkWell.focusColor, AppPlanStrip.focusOverlay);
      expect(AppPlanStrip.focusOverlay.a, lessThanOrEqualTo(0.13));
      // The fill under focus keeps the muted time and the eyebrow at AA.
      final fill = Color.alphaBlend(AppPlanStrip.focusOverlay, AppPalette.navy);
      expect(contrast(AppPalette.mutedOnDark, fill), greaterThanOrEqualTo(4.5));
      expect(contrast(AppPlanStrip.accent, fill), greaterThanOrEqualTo(4.5));
      // The ring.
      final edge = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('app-plan-strip-edge')),
      );
      final border = (edge.decoration as BoxDecoration).border! as Border;
      expect(border.top.width, 2);
      expect(border.top.color, AppPalette.pearl);
      expect(
        contrast(AppPalette.pearl, AppPalette.navy),
        greaterThanOrEqualTo(3),
      );
    });

    testWidgets('dark theme: the strip has a hairline edge on the navy page', (
      tester,
    ) async {
      await pump(tester, view: post(), brightness: Brightness.dark);

      final edge = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('app-plan-strip-edge')),
      );
      final decoration = edge.decoration as BoxDecoration;
      expect(decoration.border, isNotNull);
    });

    testWidgets('UNSPECIFIED status draws no status and offers no Join', (
      tester,
    ) async {
      await pump(
        tester,
        view: post(
          beacon: preview(
            status: beacons.BeaconStatus.BEACON_STATUS_UNSPECIFIED,
          ),
        ),
      );

      expect(find.byKey(const ValueKey('post-plan-status')), findsNothing);
      expect(find.text('Unknown'), findsNothing);
      expect(find.text(kPlanAskToJoin), findsNothing);
    });
  });
}
