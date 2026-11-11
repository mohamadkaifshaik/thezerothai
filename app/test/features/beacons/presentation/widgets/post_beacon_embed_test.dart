import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/post_beacon_embed.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as beacons;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import 'package:dzeroth/features/timeline/presentation/widgets/feed_post_row.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
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
  }) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Directionality(
              textDirection: direction,
              child: SingleChildScrollView(
                child: PostCard(
                  view: view,
                  viewerUserId: 'me',
                  focal: focal,
                  graphActionsEnabled: false,
                ),
              ),
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
      RepositoryProvider<BeaconsRepository>.value(
        value: repository ?? server,
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
    testWidgets('unavailable: "Plan unavailable", nothing of the plan', (
      tester,
    ) async {
      await pump(tester, view: post(beacon: preview(unavailable: true)));

      expect(find.text(kPlanUnavailable), findsOneWidget);
      expect(find.text(kPlanAskToJoin), findsNothing);
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

      expect(server.calls, containsAllInOrder(['get', 'request']));
      expect(server.lastNote, 'See you there');
      expect(find.text(kPlanRequested), findsOneWidget);
      expect(find.text(kPlanAskToJoin), findsNothing);
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

    testWidgets('RTL: Join sits at the start-opposite edge', (tester) async {
      await pump(tester, view: post(), direction: TextDirection.rtl);

      final strip = tester.getRect(find.byType(PostBeaconEmbed));
      final join = tester.getRect(find.text(kPlanAskToJoin));
      expect(join.center.dx, lessThan(strip.center.dx));
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
    testWidgets('keyboard focus on the strip shows on the navy fill', (
      tester,
    ) async {
      await pump(tester, view: post());

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      // Tab until focus lands in the strip (the card's own controls come
      // first).
      for (var i = 0; i < 8; i++) {
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused?.findAncestorWidgetOfExactType<AppPlanStrip>() != null) {
          break;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(focused.findAncestorWidgetOfExactType<AppPlanStrip>(), isNotNull);
      final inkWell = tester.widget<InkWell>(
        find
            .descendant(
              of: find.byType(AppPlanStrip),
              matching: find.byType(InkWell),
            )
            .first,
      );
      // A pearl overlay: the theme's navy-family default would not show.
      expect(inkWell.focusColor, AppPlanStrip.focusOverlay);
      final over = Color.alphaBlend(AppPlanStrip.focusOverlay, AppPalette.navy);
      expect(contrast(over, AppPalette.navy), greaterThanOrEqualTo(3));
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
