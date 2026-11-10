import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/app_state_view.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/beacon_row.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/fake_transport.dart';
import '../../../support/geometry.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

/// `/plans` with `beacons` off for the caller (ADR-0034 section 4): the page
/// stays and says Plans are paused, with no create action and no RPC; a kill
/// switch in mid-session ends there too.
void main() {
  // The accepted copy, byte for byte.
  const title = 'Plans are paused';
  const body =
      'Your plans and requests are safe. They will show again when Plans is back.';

  late FakeBeaconsServer server;

  setUp(() {
    server = FakeBeaconsServer();
    server.public.add(
      beaconView(startAt: DateTime.now().add(const Duration(hours: 2))),
    );
  });

  List<GoRoute> routes({bool inShell = false}) => [
    GoRoute(
      path: '/plans',
      builder: (_, _) => inShell
          ? AppShellScope(openDrawer: () {}, child: const BeaconsScreen())
          : const BeaconsScreen(),
    ),
  ];

  void expectPaused() {
    expect(find.text(title), findsOneWidget);
    expect(find.text(body), findsOneWidget);
    final view = _only<AppStateView>();
    expect(view.title, title);
    expect(view.body, body);
    expect(view.action, isNull);
    expect(view.error, isFalse);
  }

  testWidgets('beacons off: the copy, the Plans header, no create action, '
      'no RPC', (tester) async {
    await pumpPlansRouter(
      tester,
      beacons: server,
      features: const {},
      routes: routes(),
    );

    expectPaused();
    expect(kPlansPausedTitle, title);
    expect(kPlansPausedBody, body);
    // Still the Plans page.
    expect(find.text('Plans'), findsOneWidget);
    // Nothing to create or open from here.
    expect(find.byTooltip('New plan'), findsNothing);
    expect(find.byTooltip('My plans'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(BeaconRow), findsNothing);
    expect(find.text('Coffee'), findsNothing);
    expect(server.calls, isEmpty);
  });

  testWidgets('beacons off: the notice is announced (live region)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpPlansRouter(
      tester,
      beacons: server,
      features: const {},
      routes: routes(),
    );

    expect(
      tester.getSemantics(find.byType(AppStateView)),
      isSemantics(isLiveRegion: true),
    );
    handle.dispose();
  });

  testWidgets('beacons off, phone shell: the header leads with the account '
      'avatar, so the drawer stays reachable', (tester) async {
    var opened = 0;
    await pumpPlansRouter(
      tester,
      beacons: server,
      features: const {},
      routes: [
        GoRoute(
          path: '/plans',
          builder: (_, _) => AppShellScope(
            openDrawer: () => opened++,
            child: const BeaconsScreen(),
          ),
        ),
      ],
    );

    expectPaused();
    expect(find.byTooltip('Back'), findsNothing);
    expectMinTarget(tester, find.bySemanticsLabel('Open account menu'));
    await tester.tap(find.bySemanticsLabel('Open account menu'));
    expect(opened, 1);
    expect(server.calls, isEmpty);
  });

  testWidgets('beacons on: the list, never the paused notice', (tester) async {
    await pumpPlansRouter(
      tester,
      beacons: server,
      features: const {kFeatureBeacons},
      routes: routes(),
    );

    expect(find.text(title), findsNothing);
    expect(find.text(body), findsNothing);
    expect(find.byType(AppStateView), findsNothing);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.byTooltip('New plan'), findsOneWidget);
    expect(server.calls, ['list:']);
  });

  testWidgets('kill switch in mid-session: FEATURE_DISABLED asks for GetMe, '
      'and the flag leaving enabled_features rebuilds into the paused '
      'state with nothing more sent', (tester) async {
    final getMe = StreamController<Set<String>>();
    addTearDown(getMe.close);
    // What the last GetMe said, and how often the gate asked for a new one
    // (in the app: OnboardingRefreshRequested, session_wiring.dart).
    var enabledFeatures = const {kFeatureBeacons};
    var refreshRequests = 0;
    final transport = FakeTransport(
      (procedure, input) async => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureBeacons},
      ),
    );
    final repository = BeaconsRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(
        isEnabled: () => enabledFeatures.contains(kFeatureBeacons),
        onDisabledByServer: () => refreshRequests++,
      ),
    );

    await pumpPlansRouter(
      tester,
      beacons: repository,
      features: enabledFeatures,
      featureChanges: getMe.stream,
      routes: routes(),
    );

    // Flag on: the list asked once, the server answered FEATURE_DISABLED,
    // and the page is paused at once, before any GetMe: no "not available"
    // flash, no retry, no create action.
    expect(transport.calledProcedures, [
      '/dzeroth.beacons.v1.BeaconService/ListBeacons',
    ]);
    expect(refreshRequests, 1);
    expectPaused();
    expect(find.text("Plans aren't available yet."), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(find.byTooltip('New plan'), findsNothing);
    expect(find.byTooltip('My plans'), findsNothing);

    // The GetMe the gate asked for answers without `beacons`.
    enabledFeatures = const {};
    getMe.add(enabledFeatures);
    await tester.pumpAndSettle();

    expectPaused();
    expect(find.byTooltip('New plan'), findsNothing);
    expect(find.byTooltip('My plans'), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(transport.calledProcedures, hasLength(1));
    expect(refreshRequests, 1);
  });

  testWidgets('kill switch, and the GetMe that follows fails: still paused '
      '(flag still listed), no retry and no further list RPC', (tester) async {
    final getMe = StreamController<Set<String>>();
    addTearDown(getMe.close);
    const enabledFeatures = {kFeatureBeacons};
    var refreshRequests = 0;
    final transport = FakeTransport(
      (procedure, input) async => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureBeacons},
      ),
    );
    final repository = BeaconsRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(
        isEnabled: () => enabledFeatures.contains(kFeatureBeacons),
        onDisabledByServer: () => refreshRequests++,
      ),
    );

    await pumpPlansRouter(
      tester,
      beacons: repository,
      features: enabledFeatures,
      featureChanges: getMe.stream,
      routes: routes(),
    );
    expect(refreshRequests, 1);
    expectPaused();

    // A failed GetMe keeps the cached flag set: `beacons` is still listed.
    getMe.add(enabledFeatures);
    await tester.pumpAndSettle();

    expectPaused();
    expect(find.text("Plans aren't available yet."), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(find.byTooltip('New plan'), findsNothing);
    expect(find.byTooltip('My plans'), findsNothing);
    // Nothing on the page can ask again: no pull-to-refresh, no button.
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    await tester.drag(find.byType(AppStateView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(transport.calledProcedures, [
      '/dzeroth.beacons.v1.BeaconService/ListBeacons',
    ]);
    expect(refreshRequests, 1);
  });

  testWidgets('kill switch on Load more, and the GetMe that follows fails: '
      'paused, no Load more button, no further list RPC', (tester) async {
    final getMe = StreamController<Set<String>>();
    addTearDown(getMe.close);
    const enabledFeatures = {kFeatureBeacons};
    var refreshRequests = 0;
    var listCalls = 0;
    final transport = FakeTransport((procedure, input) async {
      listCalls++;
      // Page 1 answers with a next page; page 2 meets the kill switch.
      if (listCalls == 1) {
        return pb.ListBeaconsResponse(
          views: [
            beaconView(startAt: DateTime.now().add(const Duration(hours: 2))),
          ],
          nextPageToken: 'p2',
        );
      }
      throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureBeacons},
      );
    });
    final repository = BeaconsRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(
        isEnabled: () => enabledFeatures.contains(kFeatureBeacons),
        onDisabledByServer: () => refreshRequests++,
      ),
    );

    await pumpPlansRouter(
      tester,
      beacons: repository,
      features: enabledFeatures,
      featureChanges: getMe.stream,
      routes: routes(),
    );
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Load more'), findsOneWidget);
    expect(refreshRequests, 0);

    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();

    expect(transport.calledProcedures, hasLength(2));
    expect(refreshRequests, 1);
    expectPaused();

    // A failed GetMe keeps the cached flag set: `beacons` is still listed.
    getMe.add(enabledFeatures);
    await tester.pumpAndSettle();

    expectPaused();
    expect(find.text('Load more'), findsNothing);
    expect(find.text('Coffee'), findsNothing);
    expect(find.byType(BeaconRow), findsNothing);
    expect(find.text("Plans aren't available yet."), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(find.byTooltip('New plan'), findsNothing);
    expect(find.byType(RefreshIndicator), findsNothing);
    await tester.drag(find.byType(AppStateView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(transport.calledProcedures, hasLength(2));
    expect(refreshRequests, 1);
  });

  testWidgets('another list failure keeps its own copy and Try again', (
    tester,
  ) async {
    server.refusals.add(NetworkException('offline'));
    await pumpPlansRouter(
      tester,
      beacons: server,
      features: const {kFeatureBeacons},
      routes: routes(),
    );

    expect(find.text(title), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byTooltip('New plan'), findsOneWidget);
  });

  testWidgets('paused, then Plans is back: the list loads again', (
    tester,
  ) async {
    final getMe = StreamController<Set<String>>();
    addTearDown(getMe.close);
    await pumpPlansRouter(
      tester,
      beacons: server,
      features: const {},
      featureChanges: getMe.stream,
      routes: routes(),
    );
    expectPaused();
    expect(server.calls, isEmpty);

    getMe.add(const {kFeatureBeacons});
    await tester.pumpAndSettle();

    expect(find.text(title), findsNothing);
    expect(find.text('Coffee'), findsOneWidget);
    expect(server.calls, ['list:']);
  });

  group('reflow', () {
    Future<void> paused(WidgetTester tester, MatrixEnv env) async {
      await pumpPlansRouter(
        tester,
        beacons: server,
        features: const {},
        routes: routes(inShell: true),
        env: env,
      );
      expectNoOverflow(tester);
      expectPaused();
      expect(server.calls, isEmpty);
    }

    forEachThemeAndWidth(
      'paused fits (redesign widths)',
      paused,
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    forEachThemeAndWidth(
      'paused fits (600 and 1200 boundaries)',
      paused,
      textScales: kRedesignTextScales,
    );

    testWidgets('a short phone at text scale 2.0 scrolls instead of '
        'overflowing', (tester) async {
      await paused(
        tester,
        const MatrixEnv(
          brightness: Brightness.light,
          size: Size(320, 420),
          textScale: 2.0,
        ),
      );
    });
  });
}

/// The single widget of type [T] in the tree.
T _only<T extends Widget>() => find.byType(T).evaluate().single.widget as T;
