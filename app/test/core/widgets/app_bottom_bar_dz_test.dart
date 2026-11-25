import 'dart:ui' show Tristate;

import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_nav_destination.dart';
import 'package:dzeroth/shared/widgets/primitives/app_badge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/dz_finders.dart';
import '../../support/theme_harness.dart';

const _home = AppNavDestination(
  icon: Icons.home_outlined,
  selectedIcon: Icons.home,
  label: 'Home',
  dzIcon: DzIcons.home,
  dzFilledWhenSelected: true,
);
const _search = AppNavDestination(
  icon: Icons.search,
  selectedIcon: Icons.manage_search,
  label: 'Explore',
  dzIcon: DzIcons.search,
);
const _plans = AppNavDestination(
  icon: Icons.track_changes,
  selectedIcon: Icons.adjust,
  label: 'Plans',
  dzIcon: DzIcons.plans,
);
const _bell = AppNavDestination(
  icon: Icons.notifications_none,
  selectedIcon: Icons.notifications,
  label: 'Notifications',
  dzIcon: DzIcons.bell,
  badgeLabel: '1',
  badgeSemanticLabel: 'New activity',
);
const _mail = AppNavDestination(
  icon: Icons.mail_outline,
  selectedIcon: Icons.mail,
  label: 'Messages',
  dzIcon: DzIcons.mail,
);
const _five = [_home, _search, _plans, _bell, _mail];

Future<void> _pump(
  WidgetTester tester, {
  int? selected = 0,
  ValueChanged<int>? onSelected,
  Brightness brightness = Brightness.light,
  bool disableAnimations = false,
  double width = 390,
}) => pumpThemed(
  tester,
  Align(
    alignment: Alignment.bottomCenter,
    child: AppFloatingBottomBar(
      destinations: _five,
      selectedIndex: selected,
      onSelected: onSelected ?? (_) {},
    ),
  ),
  size: Size(width, 844),
  brightness: brightness,
  disableAnimations: disableAnimations,
);

final _pill = find.descendant(
  of: find.byType(AppFloatingBottomBar),
  matching: find.byType(Material),
);

void main() {
  testWidgets('the pill is 64 tall, inset 16, 14 above the bottom', (
    tester,
  ) async {
    await _pump(tester);
    final pill = tester.getRect(_pill.first);
    expect(pill.height, 64);
    expect(pill.left, 16);
    expect(pill.right, 390 - 16);
    expect(pill.bottom, 844 - 14);
    final material = tester.widget<Material>(_pill.first);
    expect(material.shape, const StadiumBorder());
    expect(material.color, AppColors.light.navBarSurface);
    expect(AppFloatingBottomBar.reservedHeight, 78);
  });

  testWidgets('draws the design icons, not the Material glyphs', (
    tester,
  ) async {
    await _pump(tester);
    for (final icon in [
      DzIcons.home,
      DzIcons.search,
      DzIcons.plans,
      DzIcons.bell,
      DzIcons.mail,
    ]) {
      expect(findDz(icon), findsOneWidget);
      expect(tester.getSize(findDz(icon)), const Size.square(24));
    }
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('five 50 dp round items sit in cells wide enough to tap', (
    tester,
  ) async {
    await _pump(tester);
    final items = find.descendant(
      of: find.byType(AppFloatingBottomBar),
      matching: find.byType(AnimatedContainer),
    );
    expect(items, findsNWidgets(5));
    for (var i = 0; i < 5; i++) {
      expect(tester.getSize(items.at(i)), const Size.square(50));
    }
    final cells = find.descendant(
      of: find.byType(AppFloatingBottomBar),
      matching: find.byType(InkResponse),
    );
    for (var i = 0; i < 5; i++) {
      final size = tester.getSize(cells.at(i));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('only the selected item has the tinted pill and teal glyph', (
    tester,
  ) async {
    await _pump(tester, selected: 2);
    final items = find.descendant(
      of: find.byType(AppFloatingBottomBar),
      matching: find.byType(AnimatedContainer),
    );
    for (var i = 0; i < 5; i++) {
      final decoration =
          tester.widget<AnimatedContainer>(items.at(i)).decoration!
              as ShapeDecoration;
      expect(
        decoration.color,
        i == 2 ? AppFloatingBottomBar.activePill : isNull,
        reason: 'item $i',
      );
    }
    expect(
      dzIconOf(tester, DzIcons.plans).color,
      AppColors.light.navBarSelected,
    );
    expect(
      dzIconOf(tester, DzIcons.home).color,
      AppColors.light.navBarUnselected,
    );
    // Only Home turns solid when selected.
    expect(paintedFill(tester, DzIcons.plans), 0);
  });

  testWidgets('Home is solid when selected, an outline otherwise', (
    tester,
  ) async {
    await _pump(tester, selected: 0);
    expect(dzIconOf(tester, DzIcons.home).fill, 1);
    await _pump(tester, selected: 1);
    expect(dzIconOf(tester, DzIcons.home).fill, 0);
  });

  testWidgets('no selection: no pill', (tester) async {
    await _pump(tester, selected: null);
    final items = find.descendant(
      of: find.byType(AppFloatingBottomBar),
      matching: find.byType(AnimatedContainer),
    );
    for (var i = 0; i < 5; i++) {
      final decoration =
          tester.widget<AnimatedContainer>(items.at(i)).decoration!
              as ShapeDecoration;
      expect(decoration.color, isNull);
    }
  });

  testWidgets(
    'semantics: icon-only items carry their names, selection, badge',
    (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, selected: 1);
      expect(find.bySemanticsLabel('Home'), findsOneWidget);
      expect(find.bySemanticsLabel('Plans'), findsOneWidget);
      expect(find.bySemanticsLabel('Messages'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Notifications, New activity'),
        findsOneWidget,
      );
      final selected = tester.getSemantics(find.bySemanticsLabel('Explore'));
      expect(selected.flagsCollection.isSelected, Tristate.isTrue);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Home'))
            .flagsCollection
            .isSelected,
        Tristate.isFalse,
      );
      handle.dispose();
    },
  );

  testWidgets('the unread dot: 8 dp, top 12 / right 12 of the 50 dp item, '
      'no ring on the bar', (tester) async {
    await _pump(tester);
    final item = tester.getRect(
      find
          .ancestor(
            of: findDz(DzIcons.bell),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect(item.size, const Size.square(50));
    final circles = find.descendant(
      of: find.byType(AppUnreadDot),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle,
      ),
    );
    // One circle: the teal core, no ring around it.
    expect(circles, findsOneWidget);
    final dot = tester.getRect(circles);
    expect(dot.size, const Size.square(AppUnreadDot.size));
    expect(dot.top - item.top, 12);
    expect(item.right - dot.right, 12);
    expect(
      (tester.widget<DecoratedBox>(circles).decoration as BoxDecoration).color,
      AppColors.dark.accentText,
    );
  });

  testWidgets('tapping a cell selects it; the page below gets no tap', (
    tester,
  ) async {
    final taps = <int>[];
    await _pump(tester, onSelected: taps.add);
    await tester.tap(findDz(DzIcons.mail));
    await tester.tap(findDz(DzIcons.search));
    expect(taps, [4, 1]);
  });

  testWidgets('the pill change is animated, instant under reduce motion', (
    tester,
  ) async {
    await _pump(tester, selected: 0);
    await _pump(tester, selected: 3);
    AnimatedContainer item(int i) => tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byType(AppFloatingBottomBar),
            matching: find.byType(AnimatedContainer),
          )
          .at(i),
    );
    expect(item(3).duration, AppFloatingBottomBar.fadeTime);
    await _pump(tester, selected: 0, disableAnimations: true);
    expect(item(3).duration, Duration.zero);
  });

  for (final width in [360.0, 390.0, 700.0, 1100.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('lays out at $width dp (${brightness.name})', (tester) async {
        await _pump(tester, width: width, brightness: brightness);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
