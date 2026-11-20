import 'dart:async';

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/conversation_encryption_panel.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/shared/widgets/primitives/app_dialog.dart';
import 'package:dzeroth/shared/widgets/primitives/app_sheet.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';
import '../../../../support/scheduled_flags.dart';

const _digits =
    '11111222223333344444555556666677777888889999900000'
    '1234567890';

/// The panel at the three widths: phone bottom sheet, tablet side sheet,
/// desktop dialog; and at text scale 2.0.
void main() {
  Future<void> open(
    WidgetTester tester,
    double width, {
    double height = 900,
    double textScale = 1,
    // Null: the default decision (the band and the tablet flags).
    bool? tabletLayout,
    Set<String> flags = const {kFeatureE2eeDm, 'ui_shell', 'ui_tablet'},
  }) async {
    final port = FakeEncryptedMessaging();
    addTearDown(port.dispose);
    port.setSecurityCode(
      'c1',
      const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
    );
    final changes = StreamController<ConversationSecurity?>.broadcast();
    addTearDown(changes.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<EncryptedMessaging>.value(value: port),
          RepositoryProvider<EncryptionDevice>.value(
            value: FakeEncryptionDevice(),
          ),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboardingWithFlags(flags),
          child: MaterialApp(
            theme: appLightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showConversationEncryption(
                    context,
                    conversationId: 'c1',
                    peerName: 'Sam',
                    securityChanges: changes.stream,
                    isWeb: false,
                    tabletLayout: tabletLayout,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The number of distinct x positions of the group texts.
  int columns(WidgetTester tester) {
    final xs = <int>{};
    for (final g in securityCodeGroups(_digits)) {
      final f = find.text(g);
      if (f.evaluate().isEmpty) continue;
      xs.add(tester.getTopLeft(f.first).dx.round());
    }
    return xs.length;
  }

  testWidgets('390 dp: a bottom sheet at the bottom, 3 columns', (
    tester,
  ) async {
    await open(tester, 390);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(AppSheetHandle), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(columns(tester), 3);
  });

  for (final width in [700.0, 1000.0]) {
    testWidgets('$width dp on the tablet layout: the side sheet, 3 columns', (
      tester,
    ) async {
      await open(tester, width, tabletLayout: true);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AppDialog), findsNothing);
      final header = tester.getRect(find.text(kSecurityCodeHeader));
      expect(header.right, lessThanOrEqualTo(width));
      expect(header.left, greaterThanOrEqualTo(width - AppSize.sideSheet));
      expect(tester.takeException(), isNull);
      expect(columns(tester), 3);
    });
  }

  for (final width in [700.0, 1000.0]) {
    testWidgets('$width dp with the tablet flags and no override: the side '
        'sheet', (tester) async {
      await open(tester, width);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AppDialog), findsNothing);
      final header = tester.getRect(find.text(kSecurityCodeHeader));
      expect(header.left, greaterThanOrEqualTo(width - AppSize.sideSheet));
      expect(tester.takeException(), isNull);
    });

    testWidgets('$width dp without ui_tablet and no override: the bottom '
        'sheet', (tester) async {
      await open(tester, width, flags: const {kFeatureE2eeDm, 'ui_shell'});
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('1300 dp: a dialog no wider than 560, the grid at most 360', (
    tester,
  ) async {
    await open(tester, 1300);
    final dialog = find.byType(Dialog);
    expect(dialog, findsOneWidget);
    // The dialog's surface (the clipped rounded box), not the barrier-sized
    // Dialog widget around it.
    final surface = find
        .ancestor(
          of: find.text(kSecurityCodeHeader),
          matching: find.byType(ClipRRect),
        )
        .first;
    expect(tester.getSize(surface).width, lessThanOrEqualTo(AppSize.dialogMax));
    final xs = securityCodeGroups(_digits)
        .map((g) => tester.getRect(find.text(g).first))
        .toList();
    final left = xs.map((r) => r.left).reduce((a, b) => a < b ? a : b);
    final right = xs.map((r) => r.right).reduce((a, b) => a > b ? a : b);
    expect(right - left, lessThanOrEqualTo(360));
    expect(tester.takeException(), isNull);
    expect(columns(tester), 3);
  });

  testWidgets('text scale 2.0 at 390 dp: 2 columns, no overflow', (
    tester,
  ) async {
    await open(tester, 390, textScale: 2);
    expect(tester.takeException(), isNull);
    expect(columns(tester), 2);
    for (final g in securityCodeGroups(_digits)) {
      final r = tester.getRect(find.text(g).first);
      expect(r.right, lessThanOrEqualTo(390));
      expect(r.left, greaterThanOrEqualTo(0));
    }
  });
}
