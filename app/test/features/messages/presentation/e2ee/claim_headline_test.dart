import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/claim_headline.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/encrypted_inbox_rig.dart';
import '../../../../support/fake_encryption_device.dart';

/// Plan 6 Task 4.A: the claim headline in the Messages inbox header.
void main() {
  const live = {kFeatureClaimLive, kFeatureE2eeRequired};

  setUpAll(() {
    registerFallbackValue(Folder.FOLDER_INBOX);
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  /// A signed-in user whose flag set is known (the claim's precondition).
  EncryptedInboxRig rigWith({
    Set<String> features = live,
    VaultStatus vaultStatus = VaultStatus.ready,
    bool withDevice = true,
    String? signedInAs = 'uid-1',
  }) => EncryptedInboxRig(
    extraFeatures: features,
    vaultStatus: vaultStatus,
    withDevice: withDevice,
    signedInAs: signedInAs,
  );

  Finder headline() => find.text(kClaimHeadline);
  Finder covers() => find.byKey(ClaimHeadlineBody.coversKey);

  testWidgets('the headline is hidden without claim_live', (tester) async {
    await rigWith(features: {kFeatureE2eeRequired}).open(tester);
    expect(headline(), findsNothing);
    expect(covers(), findsNothing);
  });

  testWidgets('hidden without e2ee_required', (tester) async {
    await rigWith(features: {kFeatureClaimLive}).open(tester);
    expect(headline(), findsNothing);
  });

  testWidgets('hidden on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await rigWith().open(tester);
      expect(headline(), findsNothing);
      expect(covers(), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('hidden while the vault is unavailable', (tester) async {
    await rigWith(vaultStatus: VaultStatus.unavailable).open(tester);
    expect(headline(), findsNothing);
    expect(covers(), findsNothing);
  });

  testWidgets('hidden while the vault is open in another tab', (tester) async {
    await rigWith(vaultStatus: VaultStatus.heldElsewhere).open(tester);
    expect(headline(), findsNothing);
  });

  testWidgets('hides at once when the vault stops opening', (tester) async {
    final rig = rigWith();
    await rig.open(tester);
    expect(headline(), findsOneWidget);
    rig.device.vaultStatus.value = VaultStatus.unavailable;
    await tester.pump();
    expect(headline(), findsNothing);
    expect(covers(), findsNothing);
  });

  testWidgets('hidden while the encryption status blocks messaging', (
    tester,
  ) async {
    final rig = rigWith();
    rig.device.engineUnavailable.value = true;
    await rig.open(tester);
    expect(rig.statusCubit!.state.blocksMessaging, isTrue);
    expect(headline(), findsNothing);
  });

  testWidgets('hidden while the flag set is not known', (tester) async {
    // No signed-in user and an `unknown` onboarding state: featuresPending.
    await rigWith(signedInAs: null).open(tester);
    expect(headline(), findsNothing);
  });

  testWidgets('hidden while the flag set is another user\'s', (tester) async {
    final rig = rigWith()..stateUid = 'uid-2';
    await rig.open(tester);
    expect(headline(), findsNothing);
  });

  testWidgets('hidden without the encryption wiring', (tester) async {
    await rigWith(withDevice: false).open(tester);
    expect(headline(), findsNothing);
  });

  for (final (name, size) in const [
    ('phone', Size(400, 800)),
    ('tablet', Size(900, 900)),
    ('desktop', Size(1300, 900)),
  ]) {
    testWidgets('always shown with its covers link ($name)', (tester) async {
      final rig = rigWith();
      await rig.open(tester, size: size);
      expect(tester.takeException(), isNull);
      expect(headline(), findsOneWidget);
      expect(covers(), findsOneWidget);
      expect(
        find.descendant(of: covers(), matching: find.text(kClaimCoversLink)),
        findsOneWidget,
      );
      // Beside the headline: in the same widget, on the same line or the
      // next one.
      final h = tester.getRect(headline());
      final l = tester.getRect(covers());
      expect((l.center.dy - h.center.dy).abs(), lessThan(h.height + l.height));
      expect(
        find.ancestor(of: headline(), matching: find.byType(ClaimHeadlineBody)),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: covers(), matching: find.byType(ClaimHeadlineBody)),
        findsOneWidget,
      );
      await tester.tap(covers());
      await tester.pumpAndSettle();
      expect(rig.pushed, [AppRouter.encryptionAboutPath]);
    });
  }

  testWidgets('always shown with its covers link at text scale 2', (
    tester,
  ) async {
    await rigWith().open(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    expect(headline(), findsOneWidget);
    expect(covers(), findsOneWidget);
  });

  testWidgets('ClaimHeadline alone: no OnboardingBloc means hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: RepositoryProvider<EncryptionDevice>.value(
            value: FakeEncryptionDevice(),
            child: const ClaimHeadline(),
          ),
        ),
      ),
    );
    expect(headline(), findsNothing);
  });

  group('GetMe stays fresh while the claim shows (fix round 1, M1)', () {
    late DateTime now;

    /// A rig with a [ResumeFlagsRefresh] on a fake clock; its GetMe asks
    /// are the bloc's `add(OnboardingRefreshRequested)` calls. The refresher
    /// is built in `open` and takes its last answer as [answerAge] before
    /// [now] (the clock reads that while it is being constructed).
    EncryptedInboxRig rigWithRefresh({
      Set<String> features = live,
      Duration answerAge = Duration.zero,
    }) {
      now = DateTime.now();
      return rigWith(features: features)
        ..flagsRefreshFactory = (bloc) {
          var constructing = true;
          final refresh = ResumeFlagsRefresh(
            bloc,
            now: () => constructing ? now.subtract(answerAge) : now,
          );
          constructing = false;
          return refresh;
        };
    }

    int refreshes(EncryptedInboxRig rig) => verify(
      () => rig.onboarding.add(any(that: isA<OnboardingRefreshRequested>())),
    ).callCount;

    /// Unmounts the tree, so its periodic check ends with the test.
    Future<void> close(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox());

    testWidgets('opening the inbox with a GetMe 15 minutes old asks again', (
      tester,
    ) async {
      final rig = rigWithRefresh(answerAge: kResumeFlagsMaxAge);
      await rig.open(tester);
      expect(headline(), findsOneWidget);
      expect(refreshes(rig), 1);
      await close(tester);
    });

    testWidgets('opening the inbox with a fresh GetMe asks nothing', (
      tester,
    ) async {
      final rig = rigWithRefresh(answerAge: const Duration(minutes: 14));
      await rig.open(tester);
      expect(headline(), findsOneWidget);
      verifyNever(
        () => rig.onboarding.add(any(that: isA<OnboardingRefreshRequested>())),
      );
      await close(tester);
    });

    testWidgets('the foreground check asks once GetMe is 15 minutes old', (
      tester,
    ) async {
      final rig = rigWithRefresh();
      await rig.open(tester);
      verifyNever(
        () => rig.onboarding.add(any(that: isA<OnboardingRefreshRequested>())),
      );
      // 14 minutes in: each check finds the answer fresh.
      for (var i = 0; i < 14; i++) {
        now = now.add(kClaimFlagsCheckEvery);
        await tester.pump(kClaimFlagsCheckEvery);
      }
      verifyNever(
        () => rig.onboarding.add(any(that: isA<OnboardingRefreshRequested>())),
      );
      // The 15th minute: one ask.
      now = now.add(kClaimFlagsCheckEvery);
      await tester.pump(kClaimFlagsCheckEvery);
      expect(refreshes(rig), 1);
      // The ask restarts the clock: the next minute asks nothing.
      now = now.add(kClaimFlagsCheckEvery);
      await tester.pump(kClaimFlagsCheckEvery);
      verifyNever(
        () => rig.onboarding.add(any(that: isA<OnboardingRefreshRequested>())),
      );
      await close(tester);
    });

    testWidgets('the check stops when the claim stops showing', (tester) async {
      final rig = rigWithRefresh();
      await rig.open(tester);
      expect(headline(), findsOneWidget);
      rig.device.vaultStatus.value = VaultStatus.unavailable;
      await tester.pump();
      expect(headline(), findsNothing);
      for (var i = 0; i < 20; i++) {
        now = now.add(kClaimFlagsCheckEvery);
        await tester.pump(kClaimFlagsCheckEvery);
      }
      verifyNever(
        () => rig.onboarding.add(any(that: isA<OnboardingRefreshRequested>())),
      );
      // Showing again restarts it: the answer is 20 minutes old, one ask.
      rig.device.vaultStatus.value = VaultStatus.ready;
      await tester.pump();
      expect(headline(), findsOneWidget);
      expect(refreshes(rig), 1);
      await close(tester);
    });

    testWidgets('the keeper stays mounted while the claim comes and goes', (
      tester,
    ) async {
      final rig = rigWithRefresh();
      await rig.open(tester);
      final keeper = tester.element(find.byType(ClaimFlagsKeeper));
      rig.device.vaultStatus.value = VaultStatus.unavailable;
      await tester.pump();
      rig.device.vaultStatus.value = VaultStatus.ready;
      await tester.pump();
      expect(tester.element(find.byType(ClaimFlagsKeeper)), same(keeper));
      await close(tester);
    });

    testWidgets('offline: hidden once the last successful GetMe is over 30 '
        'minutes old, shown again after an answer', (tester) async {
      final rig = rigWithRefresh();
      await rig.open(tester);
      // The asks at 15 and 30 minutes get no answer (offline).
      for (var i = 0; i < 30; i++) {
        now = now.add(kClaimFlagsCheckEvery);
        await tester.pump(kClaimFlagsCheckEvery);
      }
      expect(refreshes(rig), 2);
      expect(headline(), findsOneWidget, reason: 'exactly 30 minutes old');
      now = now.add(kClaimFlagsCheckEvery);
      await tester.pump(kClaimFlagsCheckEvery);
      expect(headline(), findsNothing, reason: '31 minutes old');
      expect(covers(), findsNothing);
      // An answer arrives (the bloc applied a GetMe).
      when(() => rig.onboarding.flagsGeneration).thenReturn(1);
      rig.setFlagOn(true);
      await tester.pump();
      now = now.add(kClaimFlagsCheckEvery);
      await tester.pump(kClaimFlagsCheckEvery);
      expect(headline(), findsOneWidget);
      expect(covers(), findsOneWidget);
      await close(tester);
    });

    testWidgets('no check while the claim is hidden', (tester) async {
      final rig = rigWithRefresh(
        features: {kFeatureE2eeRequired},
        answerAge: kResumeFlagsMaxAge,
      );
      await rig.open(tester);
      now = now.add(const Duration(minutes: 30));
      await tester.pump(const Duration(minutes: 30));
      expect(headline(), findsNothing);
      verifyNever(
        () => rig.onboarding.add(any(that: isA<OnboardingRefreshRequested>())),
      );
      await close(tester);
    });
  });
}
