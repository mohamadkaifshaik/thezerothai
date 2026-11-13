import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_surface.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tile_icon.dart';
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/theme_harness.dart';

void main() {
  forEachThemeAndWidth(
    'SettingsGroup look: card radius, tile, muted chevron, 48 dp rows, '
    'button semantics',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await pumpThemed(
        tester,
        SingleChildScrollView(
          child: SettingsGroup(
            title: 'Account',
            rows: [
              SettingsRow(
                icon: Icons.person_outline,
                title: 'Account information and a long second clause',
                subtitle: 'Email, phone and birthday',
                onTap: () => taps++,
              ),
              SettingsRow(
                icon: Icons.logout,
                title: 'Sign out',
                showChevron: false,
                destructive: true,
                onTap: () {},
              ),
            ],
          ),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);

      final colors = env.isDark ? AppColors.dark : AppColors.light;
      final scheme = buildAppTheme(brightness: env.brightness).colorScheme;

      // The card is the .box surface with the cardSmall radius.
      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(AppSurface),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(clip.borderRadius, BorderRadius.circular(AppRadius.cardSmall));

      // Leading tile and muted chevron.
      expect(find.byType(AppTileIcon), findsNWidgets(2));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.chevron_right)).color,
        scheme.onSurfaceVariant,
      );
      expect(
        contrast(scheme.onSurfaceVariant, colors.selectedRow),
        greaterThanOrEqualTo(4.5),
      );

      // Every tappable row is at least 48 dp tall and one button node.
      for (final row in find.byType(SettingsRow).evaluate()) {
        expect(
          tester.getSize(find.byWidget(row.widget)).height,
          greaterThanOrEqualTo(AppSpacing.minTapTarget),
        );
      }
      expect(
        tester.getSemantics(find.text('Sign out')),
        matchesSemantics(label: 'Sign out', isButton: true, hasTapAction: true),
      );
      await tester.tap(find.byIcon(Icons.person_outline));
      expect(taps, 1);
      handle.dispose();
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
  );
}
