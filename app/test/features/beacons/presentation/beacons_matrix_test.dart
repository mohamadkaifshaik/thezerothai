import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/create_beacon_screen.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

/// The three Plans screens at 360 / 600 / 1200 dp, light and dark, text
/// scale 1.0 / 1.3 / 2.0: nothing overflows.
void main() {
  final now = DateTime.now();

  Future<void> open(
    WidgetTester tester,
    Widget screen,
    FakeBeaconsServer server,
    MatrixEnv env,
  ) => pumpThemed(
    tester,
    RepositoryProvider<BeaconsRepository>.value(value: server, child: screen),
    brightness: env.brightness,
    size: env.size,
    textScale: env.textScale,
    useScaffold: false,
  );

  forEachThemeAndWidth(
    'the list with a long title, a full plan and a cancelled one fits',
    (tester, env) async {
      final server = FakeBeaconsServer();
      server.public.addAll([
        beaconView(
          startAt: now.add(const Duration(hours: 1)),
          title: 'A very long plan title that could fill the whole row twice',
          venue: 'The north entrance of the central library, ground floor',
          accepted: 2,
        ),
        beaconView(
          startAt: now.add(const Duration(hours: 2)),
          id: kBeaconIdB,
          title: 'Run',
          status: pb.BeaconStatus.BEACON_STATUS_FULL,
          accepted: 3,
        ),
      ]);
      await open(tester, const BeaconsScreen(), server, env);
      expectNoOverflow(tester);
      expect(find.text('Full'), findsOneWidget);
    },
    textScales: kMatrixTextScalesLarge,
  );

  forEachThemeAndWidth(
    'the detail with details, a hidden notice and Cancel fits',
    (tester, env) async {
      final server = FakeBeaconsServer();
      server.public.add(
        beaconView(
          startAt: now.add(const Duration(hours: 1)),
          title: 'A very long plan title that could fill the whole row twice',
          details: 'Bring a book and something to write with. ' * 4,
          venue: 'The north entrance of the central library, ground floor',
          canManage: true,
          hidden: true,
          accepted: 1,
        ),
      );
      await open(tester, const BeaconScreen(beaconId: kBeaconIdA), server, env);
      expectNoOverflow(tester);
      expect(find.text('Cancel plan'), findsOneWidget);
    },
    textScales: kMatrixTextScalesLarge,
    height: 2400,
  );

  forEachThemeAndWidth(
    'the form fits',
    (tester, env) async {
      final server = FakeBeaconsServer();
      await open(tester, CreateBeaconScreen(now: () => now), server, env);
      expectNoOverflow(tester);
      expect(find.text('New plan'), findsOneWidget);
    },
    textScales: kMatrixTextScalesLarge,
    height: 3000,
  );
}
