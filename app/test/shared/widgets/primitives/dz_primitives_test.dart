import 'package:dzeroth/core/icons/dz_icon.dart';
import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_choice_chip.dart';
import 'package:dzeroth/shared/widgets/primitives/app_gradient_fab.dart';
import 'package:dzeroth/shared/widgets/primitives/app_hero_band.dart';
import 'package:dzeroth/shared/widgets/primitives/app_list_row.dart';
import 'package:dzeroth/shared/widgets/primitives/app_media_placeholder.dart';
import 'package:dzeroth/shared/widgets/primitives/app_rings.dart';
import 'package:dzeroth/shared/widgets/primitives/app_round_action.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tile_icon.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/dz_finders.dart';
import '../../../support/theme_harness.dart';

void main() {
  group('AppChoiceChip', () {
    testWidgets('43 dp drawn (content-box: 40 + 2 x 1.5 border), radius 20; '
        'selected is navy with a 16 dp tick at 2.6, 6 dp before a 15/600 '
        'label', (tester) async {
      var taps = 0;
      await pumpThemed(
        tester,
        Row(
          children: [
            AppChoiceChip(
              label: 'Everyone',
              selected: true,
              onPressed: () => taps++,
            ),
            AppChoiceChip(
              label: 'Followers',
              selected: false,
              onPressed: () {},
            ),
          ],
        ),
      );
      final selected = tester.getRect(find.byType(AnimatedContainer).at(0));
      final plain = tester.getRect(find.byType(AnimatedContainer).at(1));
      expect(selected.height, 43);
      expect(plain.height, 43);
      expect(AppChoiceChip.height, 43);
      final tick = dzIconOf(tester, DzIcons.check);
      expect(tester.getSize(findDz(DzIcons.check)), const Size.square(16));
      expect(tick.strokeWidth, 2.6);
      expect(
        tester.getRect(find.text('Everyone')).left -
            tester.getRect(findDz(DzIcons.check)).right,
        6,
      );
      for (final label in ['Everyone', 'Followers']) {
        final text = tester.widget<Text>(find.text(label));
        expect(text.style?.fontSize, 15);
        expect(text.style?.fontWeight, FontWeight.w600, reason: label);
      }
      final decoration =
          tester
                  .widget<AnimatedContainer>(
                    find.byType(AnimatedContainer).at(0),
                  )
                  .decoration!
              as BoxDecoration;
      expect(decoration.color, AppColors.light.strongPillFill);
      expect(decoration.borderRadius, BorderRadius.circular(20));
      expect(decoration.border!.top.width, 1.5);
      expect(findDz(DzIcons.check), findsOneWidget, reason: 'selected only');
      final tap = tester.getRect(find.byType(InkWell).first);
      expect(tap.height, greaterThanOrEqualTo(48));
      await tester.tap(find.text('Everyone'));
      expect(taps, 1);
    });

    testWidgets('semantics: selected button with its label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        AppChoiceChip(label: 'Everyone', selected: true, onPressed: () {}),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Everyone')),
        matchesSemantics(
          label: 'Everyone',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('null onPressed dims it and disables the button', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const AppChoiceChip(label: 'Off', selected: false, onPressed: null),
      );
      expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 0.5);
    });
  });

  group('AppHeroBand', () {
    testWidgets('navy in both themes, rings behind, clipped', (tester) async {
      for (final brightness in Brightness.values) {
        await pumpThemed(
          tester,
          const AppHeroBand(child: SizedBox(height: 100, width: 300)),
          brightness: brightness,
        );
        final color = tester.widget<ColoredBox>(
          find
              .descendant(
                of: find.byType(AppHeroBand),
                matching: find.byType(ColoredBox),
              )
              .first,
        );
        expect(color.color, AppPalette.navy);
        final rings = tester.widget<AppRings>(find.byType(AppRings));
        expect(rings.color, AppPalette.tealElectric);
        expect(rings.rings.length, 3);
        expect(rings.strokeWidth, 1.5);
        expect(find.byType(ClipRRect), findsWidgets);
      }
    });

    testWidgets('presets: profile three rings, list two, welcome three', (
      tester,
    ) async {
      expect(AppHeroRings.profile.rings, [(120, .35), (200, .22), (290, .12)]);
      expect(AppHeroRings.list.rings, [(100, .3), (190, .15)]);
      expect(AppHeroRings.welcome.rings.length, 3);
      const size = Size(390, 300);
      expect(AppHeroRings.profile.centre(size), const Offset(330, 90));
      expect(AppHeroRings.list.centre(size), const Offset(340, 40));
      // ZWelcome: centred across the width at any width.
      expect(AppHeroRings.welcome.centre(size), const Offset(195, 110));
      expect(
        AppHeroRings.welcome.centre(const Size(834, 600)),
        const Offset(417, 110),
      );
    });

    testWidgets('the rings take no input and add no semantics', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await pumpThemed(
        tester,
        AppHeroBand(
          child: TextButton(onPressed: () => taps++, child: const Text('Go')),
        ),
      );
      await tester.tap(find.text('Go'));
      expect(taps, 1);
      expect(find.bySemanticsLabel(RegExp('ring')), findsNothing);
      handle.dispose();
    });

    testWidgets('sizes to its content plus padding', (tester) async {
      await pumpThemed(
        tester,
        const Align(
          alignment: Alignment.topLeft,
          child: AppHeroBand(child: SizedBox(height: 100, width: 100)),
        ),
      );
      final size = tester.getSize(find.byType(AppHeroBand));
      expect(size.height, 100 + 8 + 16);
    });
  });

  group('AppListRow', () {
    testWidgets('leading, title 16/700, subtitle 14 muted, trailing slot', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        AppListRow(
          title: 'Bengaluru builders',
          subtitle: '24 members',
          leading: const AppTileIcon.dz(dzIcon: DzIcons.list),
          trailing: const Text('Pin'),
          onTap: () {},
        ),
      );
      final title = tester.widget<Text>(find.text('Bengaluru builders'));
      expect(title.style?.fontSize, 16);
      expect(title.style?.fontWeight, FontWeight.w700);
      final sub = tester.widget<Text>(find.text('24 members'));
      expect(sub.style?.fontSize, 14);
      final row = tester.getRect(find.byType(AppListRow));
      expect(row.height, greaterThanOrEqualTo(48));
      expect(tester.getSize(find.byType(AppTileIcon)), const Size.square(40));
      // Tile, 12 gap, text, 12 gap, trailing; 16 dp from each edge.
      expect(tester.getRect(find.byType(AppTileIcon)).left, 16);
      expect(
        tester.getRect(find.text('Pin')).right,
        closeTo(row.right - 16, 1),
      );
    });

    testWidgets('tapping the row fires; semantics is one button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await pumpThemed(
        tester,
        AppListRow(title: 'Row', subtitle: 'Sub', onTap: () => taps++),
      );
      await tester.tap(find.text('Row'));
      expect(taps, 1);
      expect(find.bySemanticsLabel(RegExp('Row')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a long title ellipsizes at 2x text without overflow', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const AppListRow(
          title: 'A very long list name that cannot possibly fit in one line',
          subtitle:
              'And a long subtitle that also does not fit on its line, no',
          leading: AppTileIcon.dz(dzIcon: DzIcons.list),
          trailing: Icon(Icons.chevron_right),
        ),
        size: const Size(320, 600),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('divider draws a hairline under the row', (tester) async {
      await pumpThemed(tester, const AppListRow(title: 'Row', divider: true));
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AppListRow),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((box.decoration as BoxDecoration).border, isNotNull);
    });
  });

  group('AppTileIcon.dz', () {
    testWidgets('40 dp, radius 12, teal tint behind the stroke icon', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const Align(
          alignment: Alignment.topLeft,
          child: AppTileIcon.dz(dzIcon: DzIcons.gear),
        ),
      );
      expect(tester.getSize(find.byType(AppTileIcon)), const Size.square(40));
      final box = tester.widget<Container>(find.byType(Container).first);
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(12));
      expect(
        decoration.color,
        AppColors.light.accentText.withValues(alpha: AppTileIcon.tintAlpha),
      );
      expect(findDz(DzIcons.gear), findsOneWidget);
    });

    testWidgets('the Material tile is unchanged (48 dp, radius 14)', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const Align(
          alignment: Alignment.topLeft,
          child: AppTileIcon(icon: Icons.bookmark),
        ),
      );
      expect(tester.getSize(find.byType(AppTileIcon)), const Size.square(48));
      expect(find.byIcon(Icons.bookmark), findsOneWidget);
    });
  });

  group('AppGradientFab', () {
    testWidgets('58 dp teal disc with the design shadow and a navy glyph', (
      tester,
    ) async {
      var taps = 0;
      await pumpThemed(
        tester,
        Align(
          alignment: Alignment.bottomRight,
          child: AppGradientFab(
            tooltip: 'New post',
            dzIcon: DzIcons.compose,
            onPressed: () => taps++,
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(AppGradientFab)),
        const Size.square(58),
      );
      final decorated = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AppGradientFab),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final shape = decorated.decoration as ShapeDecoration;
      expect(shape.color, AppPalette.tealElectric);
      expect(shape.shadows, AppShadows.fab);
      expect(dzIconOf(tester, DzIcons.compose).color, AppPalette.navy);
      await tester.tap(find.byType(AppGradientFab));
      expect(taps, 1);
    });

    testWidgets(
      'named for assistive technology; a Material glyph still works',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pumpThemed(
          tester,
          AppGradientFab(
            tooltip: 'New message',
            icon: Icons.add,
            onPressed: () {},
          ),
        );
        expect(find.bySemanticsLabel('New message'), findsOneWidget);
        expect(find.byIcon(Icons.add), findsOneWidget);
        handle.dispose();
      },
    );

    testWidgets('pressing shrinks it, not under reduce motion', (tester) async {
      await pumpThemed(
        tester,
        AppGradientFab(
          tooltip: 'New post',
          dzIcon: DzIcons.compose,
          onPressed: () {},
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(AppGradientFab)),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.getSize(find.byType(DzIcon)).width,
        24,
        reason: 'layout size is stable',
      );
      expect(
        tester
            .widget<AnimatedScale>(
              find
                  .descendant(
                    of: find.byType(AppGradientFab),
                    matching: find.byType(AnimatedScale),
                  )
                  .first,
            )
            .scale,
        lessThan(1),
        reason: 'scaled down while pressed',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('AppRoundAction', () {
    testWidgets('named, 44 dp drawn with a 48 dp tap area and node, dims when '
        'disabled', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        const Align(
          alignment: Alignment.topLeft,
          child: AppRoundAction(
            icon: DzIcons.gear,
            tooltip: 'Settings',
            onPressed: null,
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(AppRoundAction)),
        const Size.square(44),
      );
      expect(
        tapAreaOf(tester, findDz(DzIcons.gear)).size,
        const Size.square(AppSpacing.minTapTarget),
      );
      expect(find.bySemanticsLabel('Settings'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Settings')).rect.size,
        const Size.square(AppSpacing.minTapTarget),
      );
      expect(dzIconOf(tester, DzIcons.gear).color!.a, lessThan(1));
      handle.dispose();
    });

    testWidgets('a tap 1.5 dp outside the disc still fires', (tester) async {
      var taps = 0;
      await pumpThemed(
        tester,
        // Centred: the ring above the disc must be on screen.
        Center(
          child: AppRoundAction(
            icon: DzIcons.gear,
            tooltip: 'Settings',
            onPressed: () => taps++,
          ),
        ),
      );
      final disc = tester.getRect(find.byType(AppRoundAction));
      await tester.tapAt(disc.topCenter - const Offset(0, 1.5));
      await tester.tapAt(disc.centerRight + const Offset(1.5, 0));
      expect(taps, 2);
    });

    testWidgets('dark mode: raised surface, no shadow', (tester) async {
      await pumpThemed(
        tester,
        AppRoundAction(
          icon: DzIcons.gear,
          tooltip: 'Settings',
          onPressed: () {},
        ),
        brightness: Brightness.dark,
      );
      final decorated = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AppRoundAction),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((decorated.decoration as ShapeDecoration).shadows, isNull);
    });
  });

  group('AppMediaPlaceholder', () {
    testWidgets('a neutral container surface in both themes, never pastel', (
      tester,
    ) async {
      for (final (brightness, fill) in [
        (Brightness.light, AppPalette.lightContainerHigh),
        (Brightness.dark, AppPalette.darkContainer),
      ]) {
        await pumpThemed(
          tester,
          const SizedBox(height: 120, child: AppMediaPlaceholder()),
          brightness: brightness,
        );
        final box = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(AppMediaPlaceholder),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect((box.decoration as BoxDecoration).color, fill);
        expect(findDz(DzIcons.image), findsOneWidget);
      }
    });

    testWidgets('fills the given space; semantic label only when asked', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            height: 100,
            child: AppMediaPlaceholder(icon: null, semanticLabel: 'Photo'),
          ),
        ),
        useScaffold: false,
      );
      expect(
        tester.getSize(find.byType(AppMediaPlaceholder)),
        const Size(200, 100),
      );
      expect(find.bySemanticsLabel('Photo'), findsOneWidget);
      await pumpThemed(
        tester,
        const SizedBox(height: 50, child: AppMediaPlaceholder()),
      );
      expect(find.bySemanticsLabel('Photo'), findsNothing);
      handle.dispose();
    });
  });
}
