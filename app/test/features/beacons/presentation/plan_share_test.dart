import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/share/native_share.dart';
import 'package:dzeroth/core/share/share_links.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_share.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/widgets/share_post_bar.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts;
import 'package:dzeroth/shared/widgets/post/post_share_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/fake_people_source.dart';
import '../../../support/fake_send_repository.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockGraph extends Mock implements GraphRepository {}

class _NoNativeShare implements NativeShare {
  const _NoNativeShare();

  @override
  bool get isAvailable => false;

  @override
  Future<NativeShareStatus> shareUrl(String url, {Rect? anchor}) async =>
      NativeShareStatus.unavailable;
}

const _origin = 'https://dzeroth.com';
const _link = '$_origin/plans/$kBeaconIdA';

const _all = {
  kFeatureBeacons,
  kFeaturePostBeaconEmbed,
  kFeatureMessaging,
  'graph',
};

class _Rig {
  final server = FakeBeaconsServer();
  final messaging = FakeSendRepository();
  final graph = _MockGraph();
  final clipboard = <String>[];
  String? composeLocation;
  Object? composeExtra;

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = _all,
    bool organiser = true,
    pb.BeaconStatus status = pb.BeaconStatus.BEACON_STATUS_OPEN,
    bool hidden = false,
    String communityId = '',
    bool scope = true,
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
  }) async {
    server.public.add(
      beaconView(
        startAt: DateTime.now().add(const Duration(hours: 2)),
        title: 'Flat white before work',
        canManage: organiser,
        status: status,
        hidden: hidden,
        communityId: communityId,
      ),
    );
    when(
      () => graph.listFollowing(
        userId: any(named: 'userId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => GraphPage(
        items: [person(1, name: 'Sana')],
        nextPageToken: '',
      ),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: features,
        profile: identity.Profile(userId: 'u-me', handle: 'me'),
      ),
    );
    final router = GoRouter(
      initialLocation: '/plans/$kBeaconIdA',
      routes: [
        GoRoute(
          path: '/plans',
          builder: (_, _) => const Scaffold(body: Text('plans')),
        ),
        GoRoute(
          path: '/plans/:id',
          builder: (_, state) => ShareLinksScope(
            links: scope
                ? const ShareLinks(
                    origin: _origin,
                    nativeShare: _NoNativeShare(),
                  )
                : null,
            child: BeaconScreen(beaconId: state.pathParameters['id']!),
          ),
        ),
        GoRoute(
          path: '/compose',
          builder: (_, state) {
            composeLocation = state.uri.toString();
            composeExtra = state.extra;
            return const Scaffold(body: Text('composer stub'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<BeaconsRepository>.value(value: server),
          RepositoryProvider<MessagingRepository>.value(value: messaging),
          RepositoryProvider<GraphRepository>.value(value: graph),
          RepositoryProvider<IdentityRepository>.value(value: _MockIdentity()),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Finder get _shareButton => find.byTooltip(kSharePlanTitle);

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(_shareButton);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => registerFallbackValue(const <String>[]));

  group('the Share entry on the plan page', () {
    testWidgets('shows for the organiser and for a visitor', (tester) async {
      await _Rig().open(tester);
      expect(_shareButton, findsOneWidget);
    });

    testWidgets('shows for a visitor too (copy link, message)', (tester) async {
      await _Rig().open(tester, organiser: false);
      expect(_shareButton, findsOneWidget);
    });

    testWidgets('is hidden with beacons off', (tester) async {
      await _Rig().open(tester, features: {kFeatureMessaging});
      expect(_shareButton, findsNothing);
    });

    testWidgets('is hidden without share links (no ShareLinksScope)', (
      tester,
    ) async {
      await _Rig().open(tester, scope: false);
      expect(_shareButton, findsNothing);
    });

    testWidgets('is hidden for a plan hidden by moderation', (tester) async {
      await _Rig().open(tester, hidden: true);
      expect(_shareButton, findsNothing);
    });
  });

  group('the Share sheet options', () {
    testWidgets('organiser, everything on: post, message, copy link', (
      tester,
    ) async {
      await _Rig().open(tester);
      await _openMenu(tester);

      expect(find.text(kPostAboutPlanLabel), findsOneWidget);
      expect(find.text(kSendInMessageLabel), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
      // No native share sheet on this device: no "Share via...".
      expect(find.text('Share via...'), findsNothing);
    });

    testWidgets('a visitor gets no "Post about this plan"', (tester) async {
      await _Rig().open(tester, organiser: false);
      await _openMenu(tester);

      expect(find.text(kPostAboutPlanLabel), findsNothing);
      expect(find.text(kSendInMessageLabel), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
    });

    testWidgets('post_beacon_embed off: no "Post about this plan"', (
      tester,
    ) async {
      await _Rig().open(
        tester,
        features: {kFeatureBeacons, kFeatureMessaging, 'graph'},
      );
      await _openMenu(tester);

      expect(find.text(kPostAboutPlanLabel), findsNothing);
      expect(find.text(kSendInMessageLabel), findsOneWidget);
    });

    testWidgets('an ended plan cannot be posted about', (tester) async {
      await _Rig().open(tester, status: pb.BeaconStatus.BEACON_STATUS_ENDED);
      await _openMenu(tester);

      expect(find.text(kPostAboutPlanLabel), findsNothing);
      expect(find.text('Copy link'), findsOneWidget);
    });

    testWidgets('messaging off: no "Send in a message"', (tester) async {
      await _Rig().open(
        tester,
        features: {kFeatureBeacons, kFeaturePostBeaconEmbed},
      );
      await _openMenu(tester);

      expect(find.text(kSendInMessageLabel), findsNothing);
      expect(find.text(kPostAboutPlanLabel), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
    });

    testWidgets('Copy link puts the plan link on the clipboard and says so', (
      tester,
    ) async {
      final rig = _Rig();
      await rig.open(tester);
      await _openMenu(tester);

      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();

      expect(rig.clipboard, [_link]);
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });

    testWidgets('"Post about this plan" opens the composer with the plan', (
      tester,
    ) async {
      final rig = _Rig();
      await rig.open(tester);
      await _openMenu(tester);

      await tester.tap(find.text(kPostAboutPlanLabel));
      await tester.pumpAndSettle();

      expect(rig.composeLocation, '/compose?plan=$kBeaconIdA');
      final extra = rig.composeExtra as posts.BeaconPreview;
      expect(extra.beaconId, kBeaconIdA);
      expect(extra.title, 'Flat white before work');
    });

    testWidgets('"Send in a message" sends the plan link as plain text', (
      tester,
    ) async {
      final rig = _Rig();
      await rig.open(tester);
      await _openMenu(tester);

      await tester.tap(find.text(kSendInMessageLabel));
      await tester.pumpAndSettle();
      // No dm_post_share needed: the picker is open.
      expect(find.text('Send in a message'), findsOneWidget);
      await tester.tap(find.text('Sana'));
      await tester.pump();
      await tester.tap(find.byKey(kShareSendButtonKey));
      await tester.pumpAndSettle();

      expect(rig.messaging.sendRecipients, ['u1']);
      expect(rig.messaging.sendSharedPostIds, [null]);
      expect(rig.messaging.sendTexts, [_link]);
    });
  });

  group('a community plan', () {
    const community = '2234567890123456789';

    testWidgets('is posted to its own community (preselected)', (tester) async {
      final rig = _Rig();
      await rig.open(
        tester,
        communityId: community,
        features: {..._all, 'communities'},
      );
      await _openMenu(tester);

      await tester.tap(find.text(kPostAboutPlanLabel));
      await tester.pumpAndSettle();

      expect(
        rig.composeLocation,
        '/compose?plan=$kBeaconIdA&community=$community',
      );
    });

    testWidgets('cannot be posted about with communities off', (tester) async {
      await _Rig().open(tester, communityId: community);
      await _openMenu(tester);

      expect(find.text(kPostAboutPlanLabel), findsNothing);
      expect(find.text('Copy link'), findsOneWidget);
    });
  });

  group('layouts', () {
    for (final brightness in Brightness.values) {
      for (final size in const [
        Size(390, 844),
        Size(800, 900),
        Size(1280, 900),
      ]) {
        testWidgets(
          '${size.width.toInt()} dp, ${brightness.name}: entry and menu, '
          'no overflow',
          (tester) async {
            await _Rig().open(tester, size: size, brightness: brightness);
            expect(_shareButton, findsOneWidget);
            await _openMenu(tester);

            expect(find.text(kPostAboutPlanLabel), findsOneWidget);
            expect(find.text(kSendInMessageLabel), findsOneWidget);
            expect(find.text('Copy link'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });
}
