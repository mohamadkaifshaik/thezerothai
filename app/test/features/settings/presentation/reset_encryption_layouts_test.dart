import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/settings/presentation/reset_encryption_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_encryption_device.dart';

class _MockVaultSession extends Mock implements VaultSession {}

/// The reset screen at 390, 700, 1000 and 1300 dp and at text scale 2.0.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required double width,
    double textScale = 1,
    E2eeFlag flag = E2eeFlag.on,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);
    final device = FakeEncryptionDevice(status: VaultStatus.keyLost)
      ..flag = flag;
    final status = EncryptionStatusCubit(device: device, flagOn: () => true);
    addTearDown(status.close);
    final router = GoRouter(
      initialLocation: AppRouter.resetEncryptionPath,
      routes: [
        GoRoute(
          path: AppRouter.resetEncryptionPath,
          builder: (context, state) => const ResetEncryptionScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      BlocProvider<EncryptionStatusCubit>.value(
        value: status,
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<VaultSession>.value(value: _MockVaultSession()),
            RepositoryProvider<UnexpectedErrorReporter?>.value(
              value: (_, _) {},
            ),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: Brightness.light),
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
  }

  for (final (name, width) in const [
    ('phone', 390.0),
    ('tablet', 700.0),
    ('tablet detail', 1000.0),
    ('desktop', 1300.0),
  ]) {
    testWidgets('$name: content, no overflow, the button before Cancel', (
      tester,
    ) async {
      await pump(tester, width: width);
      expect(tester.takeException(), isNull);
      expect(find.text(kResetLead), findsOneWidget);
      final action = find.widgetWithText(AppPillButton, kResetAction);
      final cancel = find.widgetWithText(AppPillButton, 'Cancel');
      expect(action, findsOneWidget);
      expect(cancel, findsOneWidget);
      final a = tester.getRect(action);
      final c = tester.getRect(cancel);
      if (width < 600) {
        expect(a.width, greaterThan(300), reason: 'full width on the phone');
        expect(c.top, greaterThan(a.top));
      } else {
        // The button at the start of the row, Cancel after it.
        expect(c.left, greaterThan(a.left));
        expect(a.width, lessThan(width));
      }
    });
  }

  testWidgets('text scale 2.0 scrolls instead of clipping', (tester) async {
    await pump(tester, width: 390, textScale: 2, flag: E2eeFlag.off);
    expect(tester.takeException(), isNull);
    final action = find.widgetWithText(AppPillButton, kResetAction);
    await tester.scrollUntilVisible(
      action,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(action, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
