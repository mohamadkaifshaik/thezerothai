import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status_banner.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/theme_harness.dart';

const _widths = <double>[390, 700, 1000, 1300];

EncryptionStatus _st(EncryptionStatusKind kind, {bool historyLost = false}) =>
    EncryptionStatus(
      kind: kind,
      mayStart: true,
      historyLost: historyLost,
      access: EncryptionAccess.full,
    );

Widget _card(EncryptionStatusKind kind, {bool historyLost = false}) =>
    SingleChildScrollView(
      child: EncryptionStatusCard(
        status: _st(kind, historyLost: historyLost),
        onRetry: () {},
        onReset: () {},
        onManageDevices: () {},
        onSetUpAgain: () {},
        onCheckAgain: () {},
        onSignOut: () {},
        onDismissHistoryLost: () {},
      ),
    );

Finder _button(String label) => find.widgetWithText(AppPillButton, label);

void main() {
  forEachThemeAndWidth(
    'the card is no wider than the readable column, actions stack on a '
    'phone and sit in a row on desktop',
    (tester, env) async {
      await pumpThemed(
        tester,
        _card(EncryptionStatusKind.removedElsewhere),
        brightness: env.brightness,
        size: env.size,
      );
      expect(tester.takeException(), isNull);
      final width = tester.getSize(find.byType(AppCard)).width;
      expect(width, lessThanOrEqualTo(AppSize.readableMax));
      final a = tester.getTopLeft(_button(kSetUpAgainAction));
      final b = tester.getTopLeft(_button(kStatusCheckAgain));
      if (env.size.width < AppBreakpoints.mobile) {
        expect(a.dy, lessThan(b.dy), reason: 'stacked on a phone');
        expect(
          tester.getSize(_button(kSetUpAgainAction)).width,
          tester.getSize(find.byType(AppCard)).width - 2 * AppSpacing.md,
          reason: 'full width',
        );
      } else {
        expect(a.dy, b.dy, reason: 'one row');
        expect(a.dx, lessThan(b.dx));
      }
    },
    widths: _widths,
    textScales: const [1.0],
  );

  forEachThemeAndWidth(
    'every kind lays out at text scale 2.0 without an exception',
    (tester, env) async {
      for (final kind in EncryptionStatusKind.values) {
        await pumpThemed(
          tester,
          Column(
            children: [
              Expanded(child: _card(kind, historyLost: true)),
              EncryptionStatusBanner(
                status: _st(kind, historyLost: true),
                onDetails: () {},
                onDismissHistoryLost: () {},
              ),
            ],
          ),
          brightness: env.brightness,
          size: Size(env.size.width, 1400),
          textScale: 2.0,
        );
        expect(tester.takeException(), isNull, reason: '$kind');
      }
    },
    widths: _widths,
    textScales: const [2.0],
  );

  testWidgets('right to left lays out without an exception', (tester) async {
    for (final width in _widths) {
      for (final kind in EncryptionStatusKind.values) {
        await pumpThemed(
          tester,
          Directionality(
            textDirection: TextDirection.rtl,
            child: Column(
              children: [
                Expanded(child: _card(kind, historyLost: true)),
                EncryptionStatusBanner(
                  status: _st(kind, historyLost: true),
                  onDetails: () {},
                  onDismissHistoryLost: () {},
                ),
              ],
            ),
          ),
          size: Size(width, 1400),
          textScale: 2.0,
        );
        expect(tester.takeException(), isNull, reason: '$kind at $width');
      }
    }
  });
}
