import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/theme_harness.dart';

const _tabs = [
  AppTab(label: 'For you'),
  AppTab(label: 'Following'),
  AppTab(label: 'A much longer feed'),
];

/// The underline painted right now (global rect).
Rect _underline(WidgetTester tester) {
  for (final element
      in find
          .descendant(
            of: find.byType(AppTabBar),
            matching: find.byType(CustomPaint),
          )
          .evaluate()) {
    final rect = debugDzUnderlineRect(element.renderObject!);
    if (rect != null) return rect;
  }
  fail('no Dz underline painted');
}

Rect _label(WidgetTester tester, String text) =>
    tester.getRect(find.text(text));

/// The tab cell (its InkWell) of [text].
Rect _cell(WidgetTester tester, String text) => tester.getRect(
  find.ancestor(of: find.text(text), matching: find.byType(InkWell)).first,
);

Future<void> _pump(
  WidgetTester tester, {
  AppTabBarStyle style = AppTabBarStyle.dzFeed,
  int selected = 0,
  TabController? controller,
  bool reduce = false,
  ValueChanged<int>? onChanged,
  Brightness brightness = Brightness.light,
}) => pumpThemed(
  tester,
  Align(
    alignment: Alignment.topCenter,
    child: AppTabBar(
      style: style,
      tabs: _tabs,
      selectedIndex: selected,
      controller: controller,
      onChanged: onChanged ?? (_) {},
    ),
  ),
  size: const Size(390, 844),
  disableAnimations: reduce,
  brightness: brightness,
);

void main() {
  group('DzHome / DzMedia (dzFeed)', () {
    testWidgets('46 dp row plus the hairline; a 3 dp underline as wide as '
        'the label, 10 dp under it, in tealText', (tester) async {
      await _pump(tester);
      final bar = tester.getRect(find.byType(AppTabBar));
      expect(bar.height, 46 + 1);
      final label = _label(tester, 'For you');
      final line = _underline(tester);
      expect(line.height, 3);
      expect(line.left, closeTo(label.left, 0.01));
      expect(line.width, closeTo(label.width, 0.01));
      expect(line.bottom, bar.top + 46);
      expect(line.top - label.bottom, closeTo(10, 0.01));
      // 8 dp row padding, then 12 dp tab padding.
      expect(label.left, 8 + 12);
      final paint = find
          .descendant(
            of: find.byType(AppTabBar),
            matching: find.byType(CustomPaint),
          )
          .evaluate()
          .map((e) => e.renderObject!)
          .firstWhere((r) => debugDzUnderlineRect(r) != null);
      expect(
        paint,
        paints..rrect(
          color: AppColors.light.accentText,
          rrect: RRect.fromRectAndCorners(
            line.shift(-(paint as RenderBox).localToGlobal(Offset.zero)),
            topLeft: const Radius.circular(3),
            topRight: const Radius.circular(3),
          ),
        ),
      );
    });

    testWidgets('labels are 15 at 700 selected and 600 idle', (tester) async {
      await _pump(tester, selected: 1);
      final selected = tester.widget<Text>(find.text('Following'));
      final idle = tester.widget<Text>(find.text('For you'));
      expect(selected.style?.fontSize, 15);
      expect(selected.style?.fontWeight, FontWeight.w700);
      expect(idle.style?.fontSize, 15);
      expect(idle.style?.fontWeight, FontWeight.w600);
    });

    testWidgets('slides and resizes with the TabController, a swipe '
        'included: half way is half way in position and width', (tester) async {
      final controller = TabController(length: 3, vsync: const TestVSync());
      addTearDown(controller.dispose);
      await _pump(tester, controller: controller);
      final a = _label(tester, 'For you');
      final b = _label(tester, 'Following');
      expect(_underline(tester).left, closeTo(a.left, 0.01));

      // A swipe drags the animation value between the pages.
      controller.offset = 0.5;
      await tester.pump();
      final mid = _underline(tester);
      expect(mid.left, closeTo((a.left + b.left) / 2, 0.01));
      expect(mid.width, closeTo((a.width + b.width) / 2, 0.01));

      controller.offset = 0.25;
      await tester.pump();
      final quarter = _underline(tester);
      expect(quarter.left, closeTo(a.left + (b.left - a.left) / 4, 0.01));
      expect(quarter.width, closeTo(a.width + (b.width - a.width) / 4, 0.01));

      // A tap animates the controller to the far tab, through the middle.
      controller.offset = 0;
      controller.animateTo(2);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final c = _label(tester, 'A much longer feed');
      final moving = _underline(tester);
      expect(moving.left, greaterThan(a.left));
      expect(moving.left, lessThan(c.left));
      await tester.pumpAndSettle();
      expect(_underline(tester).left, closeTo(c.left, 0.01));
      expect(_underline(tester).width, closeTo(c.width, 0.01));
    });

    testWidgets('without a controller it eases to a new selection', (
      tester,
    ) async {
      final selected = ValueNotifier(0);
      addTearDown(selected.dispose);
      await pumpThemed(
        tester,
        Align(
          alignment: Alignment.topCenter,
          child: ValueListenableBuilder<int>(
            valueListenable: selected,
            builder: (context, index, _) => AppTabBar(
              style: AppTabBarStyle.dzFeed,
              tabs: _tabs,
              selectedIndex: index,
              onChanged: (_) {},
            ),
          ),
        ),
        size: const Size(390, 844),
      );
      final a = _label(tester, 'For you');
      final b = _label(tester, 'Following');
      selected.value = 1;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final moving = _underline(tester);
      expect(moving.left, greaterThan(a.left));
      expect(moving.left, lessThan(b.left));
      await tester.pumpAndSettle();
      expect(_underline(tester).left, closeTo(b.left, 0.01));
    });

    testWidgets('reduce motion: the underline jumps, never in between', (
      tester,
    ) async {
      final controller = TabController(length: 3, vsync: const TestVSync());
      addTearDown(controller.dispose);
      await _pump(tester, controller: controller, reduce: true);
      final a = _label(tester, 'For you');
      final b = _label(tester, 'Following');
      controller.offset = 0.4;
      await tester.pump();
      expect(_underline(tester).left, closeTo(a.left, 0.01));
      expect(_underline(tester).width, closeTo(a.width, 0.01));
      controller.offset = 0.6;
      await tester.pump();
      expect(_underline(tester).left, closeTo(b.left, 0.01));
      expect(_underline(tester).width, closeTo(b.width, 0.01));

      // Without a controller: at the new tab on the next frame.
      controller.offset = 0;
      await _pump(tester, reduce: true);
      await _pump(tester, selected: 2, reduce: true);
      final c = _label(tester, 'A much longer feed');
      expect(_underline(tester).left, closeTo(c.left, 0.01));
    });

    testWidgets('tapping a tab reports it; named and selected', (tester) async {
      final handle = tester.ensureSemantics();
      final picked = <int>[];
      await _pump(tester, onChanged: picked.add);
      await tester.tap(find.text('Following'));
      expect(picked, [1]);
      final node = tester.getSemantics(find.bySemanticsLabel('For you'));
      expect(node.flagsCollection.isSelected.toBoolOrNull(), isTrue);
      handle.dispose();
    });
  });

  group('the other looks', () {
    testWidgets('DzProfile: equal tabs, 50 dp, a fixed 3 x 44 bar centred '
        'on the tab, 12 dp under the label', (tester) async {
      await _pump(tester, style: AppTabBarStyle.dzProfile, selected: 1);
      final bar = tester.getRect(find.byType(AppTabBar));
      expect(bar.height, 50 + 1);
      final cells = [for (final t in _tabs) _cell(tester, t.label)];
      // 8 dp row padding, then three equal shares.
      expect(cells.first.left, 8);
      expect(cells.last.right, closeTo(390 - 8, 0.01));
      expect(cells[0].width, closeTo(cells[1].width, 0.01));
      final line = _underline(tester);
      expect(line.width, closeTo(44, 0.01));
      expect(line.height, 3);
      expect(line.center.dx, closeTo(cells[1].center.dx, 0.01));
      expect(line.top - _label(tester, 'Following').bottom, closeTo(12, 0.01));
    });

    testWidgets('ZExplore: 4 dp as wide as the label; ZSearch pads 14', (
      tester,
    ) async {
      await _pump(tester, style: AppTabBarStyle.zExplore);
      final label = _label(tester, 'For you');
      final line = _underline(tester);
      expect(line.height, 4);
      expect(line.width, closeTo(label.width, 0.01));
      expect(label.left, 12);
      expect(tester.getRect(find.byType(AppTabBar)).height, 46 + 1);

      await _pump(tester, style: AppTabBarStyle.zSearch);
      expect(_label(tester, 'For you').left, 14);
    });

    testWidgets('ZNotifications: equal tabs, a fixed 4 x 56 bar', (
      tester,
    ) async {
      await _pump(tester, style: AppTabBarStyle.zNotifications, selected: 2);
      final line = _underline(tester);
      expect(line.size, const Size(56, 4));
      final cell = _cell(tester, 'A much longer feed');
      expect(line.center.dx, closeTo(cell.center.dx, 0.01));
      expect(tester.getRect(find.byType(AppTabBar)).height, 46 + 1);
    });

    for (final brightness in Brightness.values) {
      for (final style in AppTabBarStyle.values.skip(1)) {
        testWidgets('${style.name} lays out in ${brightness.name} at 2x '
            'text', (tester) async {
          await pumpThemed(
            tester,
            Align(
              alignment: Alignment.topCenter,
              child: AppTabBar(
                style: style,
                tabs: _tabs,
                selectedIndex: 0,
                onChanged: (_) {},
              ),
            ),
            size: const Size(360, 800),
            textScale: 2,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(find.byType(AppTabBar)).height,
            greaterThanOrEqualTo(47),
          );
        });
      }
    }
  });
}
