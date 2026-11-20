import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status_banner.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/theme_harness.dart';

EncryptionStatus st(
  EncryptionStatusKind kind, {
  bool mayStart = true,
  bool historyLost = false,
  bool unavailableLong = false,
}) => EncryptionStatus(
  kind: kind,
  mayStart: mayStart,
  historyLost: historyLost,
  unavailableLong: unavailableLong,
  access: EncryptionAccess.full,
);

class _Taps {
  final List<String> log = [];
  late final fake = FakeEncryptedMessaging();

  Widget card(EncryptionStatus s, {bool retrying = false}) =>
      EncryptionStatusCard(
        status: s,
        retrying: retrying,
        onRetry: () => log.add('retry'),
        onReset: () => log.add('reset'),
        onManageDevices: () => log.add('manage'),
        onSetUpAgain: () {
          log.add('setUpAgain');
          fake.removedElsewhere.value = true;
          fake.setUpDeviceAgain();
        },
        onCheckAgain: () {
          log.add('checkAgain');
          fake.checkRemovedAgain();
        },
        onSignOut: () => log.add('signOut'),
        onDismissHistoryLost: () => log.add('dismiss'),
      );
}

List<String> buttonLabels(WidgetTester tester) => tester
    .widgetList<AppPillButton>(find.byType(AppPillButton))
    .map((b) => b.label)
    .toList();

void main() {
  // kind -> (title, body, actions). A null title means no header line.
  final table = <EncryptionStatusKind, (String?, String?, List<String>, bool)>{
    EncryptionStatusKind.opening: (null, kStatusOpeningText, [], true),
    EncryptionStatusKind.keyLostPending: (
      kStatusKeyLostTitle,
      kStatusKeyLostBody,
      [kStatusTryAgain, kStatusReset],
      true,
    ),
    EncryptionStatusKind.storageChanged: (
      kStatusStorageChangedTitle,
      kStatusStorageChangedBody,
      [kStatusReset],
      true,
    ),
    EncryptionStatusKind.unavailable: (
      kStatusUnavailableTitle,
      kStatusUnavailableBody,
      [kStatusTryAgain],
      true,
    ),
    EncryptionStatusKind.heldElsewhere: (
      kStatusHeldElsewhereTitle,
      kStatusHeldElsewhereBody,
      [kStatusTryAgain],
      true,
    ),
    EncryptionStatusKind.engineUnavailable: (
      kStatusEngineUnavailableTitle,
      kStatusEngineUnavailableBody,
      [],
      true,
    ),
    EncryptionStatusKind.removedElsewhere: (
      kStatusRemovedTitle,
      kStatusRemovedBody,
      [kSetUpAgainAction, kStatusCheckAgain, kSignOutVaultLabel],
      true,
    ),
    EncryptionStatusKind.deviceLimitReached: (
      kStatusDeviceLimitTitle,
      kStatusDeviceLimitBody,
      [kStatusManageDevices],
      true,
    ),
    EncryptionStatusKind.deviceRecordUnusable: (
      kStatusDeviceRecordTitle,
      kStatusDeviceRecordBody,
      [kStatusReset],
      true,
    ),
    EncryptionStatusKind.setupFailed: (null, kStatusSetupFailedText, [], true),
    EncryptionStatusKind.dormant: (null, kStatusDormantText, [], true),
    EncryptionStatusKind.offline: (null, kStatusOfflineText, [], true),
  };

  group('card: every kind shows its title, body and buttons', () {
    table.forEach((kind, row) {
      testWidgets('$kind', (tester) async {
        final taps = _Taps();
        await pumpThemed(tester, taps.card(st(kind)));
        final (title, body, actions, _) = row;
        if (title != null) expect(find.text(title), findsOneWidget);
        expect(find.text(body!), findsOneWidget);
        expect(buttonLabels(tester), actions);
        // Nothing else of the status copy is on screen.
        for (final other in [
          kStatusKeyLostTitle,
          kStatusHistoryLostTitle,
          kStatusUnavailableLongBody,
        ]) {
          if (other != title) expect(find.text(other), findsNothing);
        }
      });
    });
    test('every kind but none is in the table', () {
      expect(
        table.keys.toSet(),
        EncryptionStatusKind.values.toSet()..remove(EncryptionStatusKind.none),
      );
    });
  });

  testWidgets('none draws nothing at zero height', (tester) async {
    await pumpThemed(tester, _Taps().card(st(EncryptionStatusKind.none)));
    expect(find.byType(AppPillButton), findsNothing);
    expect(find.byType(Text), findsNothing);
    expect(tester.getSize(find.byType(EncryptionStatusCard)).height, 0);
  });

  testWidgets('each button calls exactly its callback once', (tester) async {
    final cases = <(EncryptionStatusKind, String, String)>[
      (EncryptionStatusKind.keyLostPending, kStatusTryAgain, 'retry'),
      (EncryptionStatusKind.keyLostPending, kStatusReset, 'reset'),
      (EncryptionStatusKind.storageChanged, kStatusReset, 'reset'),
      (EncryptionStatusKind.unavailable, kStatusTryAgain, 'retry'),
      (EncryptionStatusKind.heldElsewhere, kStatusTryAgain, 'retry'),
      (EncryptionStatusKind.deviceLimitReached, kStatusManageDevices, 'manage'),
      (EncryptionStatusKind.deviceRecordUnusable, kStatusReset, 'reset'),
      (EncryptionStatusKind.removedElsewhere, kSetUpAgainAction, 'setUpAgain'),
      (EncryptionStatusKind.removedElsewhere, kStatusCheckAgain, 'checkAgain'),
      (EncryptionStatusKind.removedElsewhere, kSignOutVaultLabel, 'signOut'),
    ];
    for (final (kind, label, expected) in cases) {
      final taps = _Taps();
      await pumpThemed(tester, taps.card(st(kind)));
      await tester.tap(find.widgetWithText(AppPillButton, label));
      await tester.pump();
      expect(taps.log, [expected], reason: '$kind $label');
    }
  });

  testWidgets('keyLostPending and removedElsewhere switch body when mayStart '
      'is false, and Set up again is absent', (tester) async {
    await pumpThemed(
      tester,
      _Taps().card(st(EncryptionStatusKind.keyLostPending, mayStart: false)),
    );
    expect(find.text(kStatusKeyLostBodyNoRestart), findsOneWidget);
    expect(find.text(kStatusKeyLostBody), findsNothing);
    await pumpThemed(
      tester,
      _Taps().card(st(EncryptionStatusKind.removedElsewhere, mayStart: false)),
    );
    expect(find.text(kStatusRemovedBodyNoRestart), findsOneWidget);
    expect(find.text(kStatusRemovedBody), findsNothing);
    expect(buttonLabels(tester), [kStatusCheckAgain, kSignOutVaultLabel]);
  });

  testWidgets('the removed card always offers Check again, which calls back '
      'and is not destructive', (tester) async {
    for (final mayStart in [true, false]) {
      final taps = _Taps();
      await pumpThemed(
        tester,
        taps.card(
          st(EncryptionStatusKind.removedElsewhere, mayStart: mayStart),
        ),
      );
      final button = tester.widget<AppPillButton>(
        find.widgetWithText(AppPillButton, kStatusCheckAgain),
      );
      expect(button.variant, isNot(AppButtonVariant.danger));
      await tester.tap(find.widgetWithText(AppPillButton, kStatusCheckAgain));
      await tester.pump();
      expect(taps.fake.checkRemovedAgainCalls, 1);
      expect(taps.fake.setUpAgainCalls, 0);
      expect(taps.log, ['checkAgain']);
    }
  });

  testWidgets('Set up again calls the port once', (tester) async {
    final taps = _Taps();
    await pumpThemed(
      tester,
      taps.card(st(EncryptionStatusKind.removedElsewhere)),
    );
    await tester.tap(find.widgetWithText(AppPillButton, kSetUpAgainAction));
    await tester.pump();
    expect(taps.fake.setUpAgainCalls, 1);
  });

  testWidgets('a persistent unavailable states its way out', (tester) async {
    await pumpThemed(
      tester,
      _Taps().card(st(EncryptionStatusKind.unavailable)),
    );
    expect(find.text(kStatusUnavailableBody), findsOneWidget);
    expect(kStatusUnavailableBody, contains('Try again'));
    expect(kStatusUnavailableBody, contains("You don't need to sign out"));
    expect(buttonLabels(tester), [kStatusTryAgain]);
    expect(find.text(kStatusReset), findsNothing);
  });

  testWidgets('an unavailable status lasting 24 h across launches names '
      'sign-out and its cost', (tester) async {
    await pumpThemed(
      tester,
      _Taps().card(st(EncryptionStatusKind.unavailable, unavailableLong: true)),
    );
    expect(find.text(kStatusUnavailableLongBody), findsOneWidget);
    expect(find.text(kStatusUnavailableBody), findsNothing);
    expect(kStatusUnavailableLongBody, contains('signing out'));
    expect(
      kStatusUnavailableLongBody,
      contains('deletes the encrypted messages on this device'),
    );
    expect(
      kStatusUnavailableLongBody,
      isNot(contains("don't need to sign out")),
    );
    expect(buttonLabels(tester), [kStatusTryAgain]);
    // The long body appears in no other state.
    for (final kind in EncryptionStatusKind.values) {
      if (kind == EncryptionStatusKind.unavailable) continue;
      await pumpThemed(tester, _Taps().card(st(kind, unavailableLong: true)));
      expect(find.text(kStatusUnavailableLongBody), findsNothing);
    }
  });

  testWidgets('historyLost is shown above any kind with Dismiss', (
    tester,
  ) async {
    final taps = _Taps();
    await pumpThemed(
      tester,
      taps.card(st(EncryptionStatusKind.unavailable, historyLost: true)),
    );
    expect(find.text(kStatusHistoryLostTitle), findsOneWidget);
    expect(find.text(kStatusHistoryLostBody), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(kStatusHistoryLostTitle)).dy,
      lessThan(tester.getTopLeft(find.text(kStatusUnavailableTitle)).dy),
    );
    expect(buttonLabels(tester), [kStatusDismiss, kStatusTryAgain]);
    await tester.tap(find.widgetWithText(AppPillButton, kStatusDismiss));
    expect(taps.log, ['dismiss']);
  });

  testWidgets('historyLost alone (kind none) still draws its card', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      _Taps().card(st(EncryptionStatusKind.none, historyLost: true)),
    );
    expect(find.text(kStatusHistoryLostTitle), findsOneWidget);
    expect(buttonLabels(tester), [kStatusDismiss]);
  });

  testWidgets('the card title is a header', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(
      tester,
      _Taps().card(st(EncryptionStatusKind.keyLostPending)),
    );
    expect(
      tester.getSemantics(find.text(kStatusKeyLostTitle)),
      matchesSemantics(
        label: kStatusKeyLostTitle,
        isHeader: true,
        textDirection: TextDirection.ltr,
      ),
    );
    handle.dispose();
  });

  testWidgets('retrying makes Try again busy and ignores taps', (tester) async {
    final taps = _Taps();
    await pumpThemed(
      tester,
      taps.card(st(EncryptionStatusKind.unavailable), retrying: true),
      disableAnimations: true,
    );
    final button = tester.widget<AppPillButton>(
      find.widgetWithText(AppPillButton, kStatusTryAgain),
    );
    expect(button.busy, isTrue);
  });

  group('banner', () {
    Widget banner(EncryptionStatus s, {bool details = true}) =>
        EncryptionStatusBanner(
          status: s,
          onDetails: details ? () => taps.add('details') : null,
          onDismissHistoryLost: () => taps.add('dismiss'),
        );

    testWidgets('draws nothing for none, dormant and setupFailed', (
      tester,
    ) async {
      for (final kind in [
        EncryptionStatusKind.none,
        EncryptionStatusKind.dormant,
        EncryptionStatusKind.setupFailed,
      ]) {
        await pumpThemed(tester, banner(st(kind)));
        expect(find.byType(Text), findsNothing, reason: '$kind');
        expect(find.byType(AppPillButton), findsNothing);
        expect(tester.getSize(find.byType(EncryptionStatusBanner)).height, 0);
      }
    });

    testWidgets('shows the title and Details for every other kind', (
      tester,
    ) async {
      final titles = <EncryptionStatusKind, String>{
        EncryptionStatusKind.opening: kStatusOpeningText,
        EncryptionStatusKind.keyLostPending: kStatusKeyLostTitle,
        EncryptionStatusKind.storageChanged: kStatusStorageChangedTitle,
        EncryptionStatusKind.unavailable: kStatusUnavailableTitle,
        EncryptionStatusKind.heldElsewhere: kStatusHeldElsewhereTitle,
        EncryptionStatusKind.engineUnavailable: kStatusEngineUnavailableTitle,
        EncryptionStatusKind.removedElsewhere: kStatusRemovedTitle,
        EncryptionStatusKind.deviceLimitReached: kStatusDeviceLimitTitle,
        EncryptionStatusKind.deviceRecordUnusable: kStatusDeviceRecordTitle,
        EncryptionStatusKind.offline: kStatusOfflineText,
      };
      for (final e in titles.entries) {
        taps.clear();
        await pumpThemed(tester, banner(st(e.key)));
        expect(find.text(e.value), findsOneWidget, reason: '${e.key}');
        expect(buttonLabels(tester), [kStatusDetails], reason: '${e.key}');
        await tester.tap(find.widgetWithText(AppPillButton, kStatusDetails));
        expect(taps, ['details']);
      }
    });

    testWidgets('historyLost alone offers Dismiss only', (tester) async {
      taps.clear();
      await pumpThemed(
        tester,
        banner(st(EncryptionStatusKind.none, historyLost: true)),
      );
      expect(find.text(kStatusHistoryLostTitle), findsOneWidget);
      expect(buttonLabels(tester), [kStatusDismiss]);
      await tester.tap(find.widgetWithText(AppPillButton, kStatusDismiss));
      expect(taps, ['dismiss']);
    });

    testWidgets('historyLost above a kind shows both lines', (tester) async {
      await pumpThemed(
        tester,
        banner(st(EncryptionStatusKind.unavailable, historyLost: true)),
      );
      expect(buttonLabels(tester), [kStatusDismiss, kStatusDetails]);
    });

    testWidgets('the banner is a live region', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, banner(st(EncryptionStatusKind.keyLostPending)));
      final node = tester.getSemantics(
        find.descendant(
          of: find.byType(EncryptionStatusBanner),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.liveRegion == true,
          ),
        ),
      );
      expect(node.flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });
  });

  forEachThemeAndWidth(
    'text scale 2.0 does not overflow at 320 dp wide',
    (tester, env) async {
      for (final kind in EncryptionStatusKind.values) {
        await pumpThemed(
          tester,
          SingleChildScrollView(
            child: Column(
              children: [
                _Taps().card(st(kind, historyLost: true)),
                EncryptionStatusBanner(
                  status: st(kind, historyLost: true),
                  onDetails: () {},
                  onDismissHistoryLost: () {},
                ),
              ],
            ),
          ),
          brightness: env.brightness,
          size: const Size(320, 800),
          textScale: 2.0,
        );
        expect(tester.takeException(), isNull, reason: '$kind');
      }
    },
    widths: const [320],
    textScales: const [2.0],
  );
}

final List<String> taps = [];
