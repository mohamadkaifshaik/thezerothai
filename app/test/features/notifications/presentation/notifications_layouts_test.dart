import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/notifications_screen.dart';
import 'package:dzeroth/features/notifications/presentation/widgets/notification_row.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/app_fonts.dart';
import '../../../support/context_pane_rig.dart';
import '../../../support/fake_push_messaging.dart';
import '../../../support/fake_push_opt_in_store.dart';
import '../../../support/notifications_fixtures.dart';
import '../../../support/suggestions_fixtures.dart';

// Notifications from the dzeroth-mobile, tablet and desktop mocks: one list,
// the same rows and tabs. Only the desktop has the side column with the
// follow-requests card; phone and tablet keep the inline row.

const _screenshots = bool.fromEnvironment('NOTIFICATIONS_SCREENSHOTS');

class _MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

const _like = NotificationType.NOTIFICATION_TYPE_LIKE;
const _follow = NotificationType.NOTIFICATION_TYPE_FOLLOW;
const _mention = NotificationType.NOTIFICATION_TYPE_MENTION;
const _joinRequest = NotificationType.NOTIFICATION_TYPE_BEACON_REQUEST;
const _beaconId = '1234567890123456789';

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/notifications/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  late _MockNotificationsRepository repo;
  late _MockGraph graphRepo;
  late PushCubit push;
  late PushOptInCubit optIn;

  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  setUp(() async {
    repo = _MockNotificationsRepository();
    graphRepo = _MockGraph();
    when(() => graphRepo.followRequestsUnavailable).thenReturn(false);
    when(() => graphRepo.cached(any())).thenReturn(null);
    when(() => graphRepo.relationshipsFor(any())).thenAnswer((_) async => {});
    when(
      () => graphRepo.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => GraphPage(
        items: [for (var i = 1; i <= 3; i++) suggestedUser(i, userId: 'r$i')],
        nextPageToken: '',
      ),
    );
    when(() => repo.enabled).thenReturn(true);
    when(() => repo.sinceRefresh).thenReturn(null);
    when(() => repo.sinceRefreshAttempt).thenReturn(null);
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.markSeen(any())).thenAnswer((_) async => kNotifBase);
    final list = snapshotOfNotifs([
      notif(
        'p',
        minutesAgo: 5,
        type: _joinRequest,
        actorId: 'u5',
        handle: 'kabir',
        displayName: 'Kabir',
        beaconId: _beaconId,
      ),
      notif('a', minutesAgo: 60, type: _like, postId: '1', actorCount: 2),
      notif('b', minutesAgo: 180, type: _follow, actorId: 'u3', handle: 'sana'),
      notif(
        'c',
        minutesAgo: 1440,
        type: _mention,
        actorId: 'u4',
        handle: 'kabir',
        displayName: 'Kabir',
        postId: '2',
      ),
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

  Future<void> open(
    WidgetTester tester,
    Size size, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    final rig = ContextPaneRig();
    await rig.pump(
      tester,
      location: '/notifications',
      width: size.width,
      height: size.height,
      brightness: brightness,
      textScale: textScale,
      flags: const {...kContextPaneFlags, 'private_accounts', 'beacons'},
      pendingFollowRequests: 3,
      isProtected: true,
      page: (path) => path == '/notifications'
          ? const NotificationsScreen()
          : Text('$path body'),
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
    await tester.pumpAndSettle();
  }

  final inlineRow = find.byKey(const ValueKey('notifications-follow-requests'));
  final card = find.byKey(const ValueKey('follow-requests-card'));

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final desktop = size.width >= 1200;
    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('the look', (tester) async {
        await open(tester, size);
        expect(find.byType(NotificationRow), findsNWidgets(4));
        expect(find.byType(AppTabBar), findsOneWidget);
        // The mock's title leads from the left, not the centre.
        final screen = find.byType(NotificationsScreen);
        final title = tester.getRect(
          find.descendant(of: screen, matching: find.text('Notifications')),
        );
        expect(title.center.dx, lessThan(tester.getRect(screen).center.dx));
        // The three tabs of the mock: All, Plans (beacons on), Mentions.
        expect(
          find.descendant(
            of: find.byType(AppTabBar),
            matching: find.text('Plans'),
          ),
          findsOneWidget,
        );
        // Follow requests: the card in the desktop side column, the inline
        // row everywhere else; never both.
        expect(inlineRow, desktop ? findsNothing : findsOneWidget);
        expect(
          find.descendant(of: find.byType(AppSideColumn), matching: card),
          desktop ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'Review on a join request opens the People page of the plan',
        (tester) async {
          await open(tester, size);
          await tester.tap(find.text('Review'));
          await tester.pumpAndSettle();
          expect(find.text('/plans/$_beaconId/people body'), findsOneWidget);
        },
      );

      testWidgets('Mentions narrows the list; follow requests open the same', (
        tester,
      ) async {
        await open(tester, size);
        await tester.tap(
          find.descendant(
            of: find.byType(AppTabBar),
            matching: find.text('Mentions'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NotificationRow), findsOneWidget);
        expect(find.textContaining('mentioned you'), findsOneWidget);
        if (desktop) {
          expect(find.text('Accept'), findsNWidgets(3));
        } else {
          await tester.tap(inlineRow);
          await tester.pumpAndSettle();
          expect(find.text('/follow-requests body'), findsOneWidget);
        }
      });
    });
  }

  testWidgets('text scale 2.0 on a phone: nothing overflows', (tester) async {
    await open(tester, _sizes['phone']!, textScale: 2);
    expect(tester.takeException(), isNull);
  });

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        testWidgets('$name ${brightness.name}', (tester) async {
          await open(tester, size, brightness: brightness);
          await _capture(tester, '$name-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });
}
