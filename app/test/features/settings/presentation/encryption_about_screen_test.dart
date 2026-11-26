import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/device_sign_out_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/claim_headline.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/settings/presentation/encryption_about_screen.dart';
import 'package:dzeroth/features/settings/presentation/encryption_settings_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_encryption_device.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// Plan 6 Task 4.A: Settings > Encrypted messages > About and the "About
/// encrypted messages" page.
void main() {
  const live = {kFeatureClaimLive, kFeatureE2eeRequired};

  late FakeEncryptionDevice device;

  setUpAll(() => registerFallbackValue(OnboardingState()));
  setUp(() => device = FakeEncryptionDevice());

  Future<GoRouter> pump(
    WidgetTester tester, {
    Set<String> features = live,
    String initial = AppRouter.encryptionAboutPath,
    bool web = false,
    String? platform,
    double width = 400,
    double height = 4000,
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {kFeatureE2eeDm, ...features},
      ),
    );
    // The signed-in user's own, known flag set (the claim's precondition).
    when(() => onboarding.currentUid).thenReturn('uid-1');
    when(() => onboarding.uidOf(any())).thenReturn('uid-1');
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(
          path: AppRouter.encryptionSettingsPath,
          builder: (context, state) => const EncryptionSettingsScreen(),
        ),
        GoRoute(
          path: AppRouter.encryptionAboutPath,
          builder: (context, state) =>
              EncryptionAboutScreen(web: web, platform: platform),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: RepositoryProvider<EncryptionDevice>.value(
          value: device,
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Finder rich(String text) => find.textContaining(text, findRichText: true);

  group('Settings > Encrypted messages > About', () {
    testWidgets('claim live: the headline leads About, with its covers link', (
      tester,
    ) async {
      final router = await pump(
        tester,
        initial: AppRouter.encryptionSettingsPath,
      );
      expect(find.text(kClaimHeadline), findsOneWidget);
      expect(find.byKey(ClaimHeadlineBody.coversKey), findsOneWidget);
      expect(find.text(kEncryptionHelp1), findsOneWidget);
      expect(
        tester.getRect(find.text(kClaimHeadline)).top,
        lessThan(tester.getRect(find.text(kEncryptionHelp1)).top),
      );
      await tester.tap(find.byKey(ClaimHeadlineBody.coversKey));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, AppRouter.encryptionAboutPath);
      expect(find.text(kClaimAboutLead), findsOneWidget);
    });

    testWidgets('the headline is hidden without claim_live: today\'s lines', (
      tester,
    ) async {
      await pump(
        tester,
        features: {kFeatureE2eeRequired},
        initial: AppRouter.encryptionSettingsPath,
      );
      expect(find.text(kClaimHeadline), findsNothing);
      expect(find.byKey(ClaimHeadlineBody.coversKey), findsNothing);
      for (final line in encryptionHelpLines(web: false)) {
        expect(find.text(line), findsOneWidget);
      }
    });

    testWidgets('hidden while the vault is unavailable', (tester) async {
      device.vaultStatus.value = VaultStatus.unavailable;
      await pump(tester, initial: AppRouter.encryptionSettingsPath);
      expect(find.text(kClaimHeadline), findsNothing);
      expect(find.text(kEncryptionHelp1), findsOneWidget);
    });
  });

  group('About encrypted messages', () {
    test('fix round 1 copy (security H1, L4): exact words and order', () {
      expect(kClaimCoversItems, ['The text of your direct messages.']);
      expect(kClaimNotCoveredItems[0].title, 'Who you message and when.');
      expect(kClaimNotCoveredItems[1], (
        title: 'Which post you share.',
        body:
            'When you share a post in a message, we check that it can be '
            'shared, so we can tell which post you shared.',
      ));
      final ios = kClaimNotCoveredItems.singleWhere(
        (i) => i.title.contains('iPhone'),
      );
      expect(ios, (
        title: 'The iPhone and iPad app.',
        body: "Encrypted messages aren't available there yet.",
      ));
    });

    testWidgets('claim live: the §4.2 page, in order', (tester) async {
      await pump(tester, features: {...live, kFeatureDeviceSignOut});
      expect(find.text(kClaimAboutTitle), findsOneWidget);
      expect(find.text(kClaimHeadline), findsOneWidget);
      expect(find.text(kClaimAboutLead), findsOneWidget);
      expect(find.text(kClaimCoversHeader), findsOneWidget);
      for (final item in kClaimCoversItems) {
        expect(find.text(item), findsOneWidget);
      }
      expect(find.text(kClaimNotCoveredHeader), findsOneWidget);
      final items = [
        ...kClaimNotCoveredItems,
        (title: kClaimLostDeviceItemTitle, body: ''),
        ...kClaimNotCoveredItemsAfter,
      ];
      var last = double.negativeInfinity;
      for (final item in items) {
        final f = rich(item.title);
        expect(f, findsOneWidget, reason: item.title);
        if (item.body.isNotEmpty) expect(rich(item.body), findsOneWidget);
        final top = tester.getRect(f).top;
        expect(top, greaterThan(last), reason: item.title);
        last = top;
      }
      // Not a web build: neither web line.
      expect(find.text(kEncryptionHelpWeb), findsNothing);
      expect(find.text(kWebStorageNote), findsNothing);
    });

    testWidgets('device_sign_out on: the lost or stolen paragraph', (
      tester,
    ) async {
      await pump(tester, features: {...live, kFeatureDeviceSignOut});
      expect(find.text(kClaimLostDeviceHeader), findsOneWidget);
      expect(find.text(kClaimLostDeviceBody), findsOneWidget);
      expect(rich(kClaimLostDeviceItemBody), findsOneWidget);
      expect(rich(kClaimLostDeviceItemBodyNoSignOut), findsNothing);
      expect(rich(kRemovalsNote), findsNothing);
    });

    testWidgets('device_sign_out off: the removals note in its place', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text(kClaimLostDeviceHeader), findsNothing);
      expect(find.text(kClaimLostDeviceBody), findsNothing);
      expect(rich(kClaimLostDeviceItemBody), findsNothing);
      // Untitled: the line is the §5.3 sentence and the removals note only.
      expect(
        find.text('$kClaimLostDeviceItemBodyNoSignOut $kRemovalsNote'),
        findsOneWidget,
      );
      expect(rich(kClaimLostDeviceItemTitle), findsNothing);
      // Code review B1: no stolen-device wording anywhere on the page.
      expect(
        find.textContaining(
          RegExp('stolen', caseSensitive: false),
          findRichText: true,
        ),
        findsNothing,
      );
      // The slot keeps its place: after "Your devices.", before "Checking".
      final slot = tester.getRect(rich(kClaimLostDeviceItemBodyNoSignOut)).top;
      expect(slot, greaterThan(tester.getRect(rich('Your devices.')).top));
      expect(
        slot,
        lessThan(tester.getRect(rich("Checking who you're talking to.")).top),
      );
    });

    testWidgets('web builds add the web help and storage lines', (
      tester,
    ) async {
      await pump(tester, web: true, platform: 'web');
      expect(find.text(kClaimHeadline), findsOneWidget);
      expect(find.text(kEncryptionHelpWeb), findsOneWidget);
      expect(find.text(kWebStorageNote), findsOneWidget);
    });

    testWidgets('claim not visible (iOS): only the existing help lines', (
      tester,
    ) async {
      await pump(tester, platform: 'ios');
      expect(find.text(kClaimHeadline), findsNothing);
      expect(find.text(kClaimAboutLead), findsNothing);
      expect(find.text(kClaimNotCoveredHeader), findsNothing);
      for (final line in encryptionHelpLines(web: false)) {
        expect(find.text(line), findsOneWidget);
      }
    });

    testWidgets('claim not visible (no claim_live): the same', (tester) async {
      await pump(
        tester,
        features: {kFeatureE2eeRequired, kFeatureDeviceSignOut},
      );
      expect(find.text(kClaimHeadline), findsNothing);
      expect(find.text(kClaimLostDeviceBody), findsNothing);
      expect(find.text(kEncryptionHelp1), findsOneWidget);
    });

    for (final (name, width) in const [
      ('phone', 390.0),
      ('tablet', 900.0),
      ('desktop', 1300.0),
    ]) {
      for (final brightness in Brightness.values) {
        testWidgets('$name ${brightness.name}: no overflow, readable column', (
          tester,
        ) async {
          await pump(
            tester,
            width: width,
            brightness: brightness,
            features: {...live, kFeatureDeviceSignOut},
          );
          expect(tester.takeException(), isNull);
          expect(find.text(kClaimHeadline), findsOneWidget);
          expect(
            tester.getRect(find.text(kClaimAboutLead)).width,
            lessThanOrEqualTo(width),
          );
        });
      }
    }

    testWidgets('text scale 2.0 scrolls instead of clipping', (tester) async {
      await pump(
        tester,
        height: 800,
        textScale: 2,
        features: {...live, kFeatureDeviceSignOut},
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text(kClaimLostDeviceBody),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(kClaimLostDeviceBody), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
