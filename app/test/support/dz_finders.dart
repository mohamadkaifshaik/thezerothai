import 'package:dzeroth/core/icons/dz_icon.dart';
import 'package:dzeroth/core/icons/dz_icon_data.dart';
import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_tap_area.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Finds a painted Dz icon by its data, like `find.byIcon` for a Material
/// icon. [filled] narrows it to the filled (fill > 0) or outline (fill 0)
/// state; null matches both.
Finder findDz(DzIconData data, {bool? filled}) => find.byWidgetPredicate(
  (widget) =>
      widget is DzIcon &&
      identical(widget.data, data) &&
      (filled == null || (widget.fill > 0) == filled),
  description:
      'DzIcon(${_nameOf(data)}${filled == null ? '' : ', filled: $filled'})',
);

/// `find.byIcon` for tests written against the Material action glyphs: the
/// five post-action Material icons map to their [DzIcons] twin (the outline
/// and filled Material pairs to the unfilled and filled state), any other icon
/// is found as `find.byIcon` finds it.
Finder byActionIcon(IconData icon) {
  if (icon == Icons.chat_bubble_outline) return findDz(DzIcons.reply);
  if (icon == Icons.repeat) return findDz(DzIcons.repost);
  if (icon == Icons.favorite_border) return findDz(DzIcons.like, filled: false);
  if (icon == Icons.favorite) return findDz(DzIcons.like, filled: true);
  if (icon == Icons.ios_share) return findDz(DzIcons.share);
  if (icon == Icons.bookmark_border) return findDz(DzIcons.save, filled: false);
  if (icon == Icons.bookmark) return findDz(DzIcons.save, filled: true);
  return find.byIcon(icon);
}

/// `find.byIcon` for shell tests: the main destinations are Material icons on
/// the rail and the design's [DzIcons] on the floating phone bar, where the
/// selected item is the one in `navBarSelected` (the others are
/// `navBarUnselected`). This finds the Material icon *or* the bar's twin, so a
/// test is the same on a phone and wide. Other icons are found as
/// `find.byIcon` finds them.
Finder byNavIcon(IconData icon) {
  const pairs = <(IconData, IconData, DzIconData)>[
    (Icons.home_outlined, Icons.home, DzIcons.home),
    (Icons.search, Icons.manage_search, DzIcons.search),
    (Icons.track_changes, Icons.adjust, DzIcons.plans),
    (Icons.notifications_none, Icons.notifications, DzIcons.bell),
    (Icons.mail_outline, Icons.mail, DzIcons.mail),
  ];
  for (final (idle, selected, dz) in pairs) {
    if (icon != idle && icon != selected) continue;
    final wantSelected = icon == selected;
    return find.byWidgetPredicate(
      (widget) =>
          (widget is Icon && widget.icon == icon) ||
          (widget is DzIcon &&
              identical(widget.data, dz) &&
              (widget.color == AppColors.light.navBarSelected) == wantSelected),
      description: 'Icon($icon) or its bar twin',
    );
  }
  return find.byIcon(icon);
}

/// The glyphs inside [of], in tree order, as the Material icons the main
/// destinations used before the Dz bar: a [DzIcon] of a nav destination is
/// reported as its Material pair (selected when painted in `navBarSelected`),
/// a Material [Icon] as itself.
List<IconData> navGlyphsIn(WidgetTester tester, Finder of) {
  final dzToMaterial = <DzIconData, (IconData, IconData)>{
    DzIcons.home: (Icons.home_outlined, Icons.home),
    DzIcons.search: (Icons.search, Icons.manage_search),
    DzIcons.plans: (Icons.track_changes, Icons.adjust),
    DzIcons.bell: (Icons.notifications_none, Icons.notifications),
    DzIcons.mail: (Icons.mail_outline, Icons.mail),
  };
  final glyphs = find.descendant(
    of: of,
    matching: find.byWidgetPredicate((w) => w is Icon || w is DzIcon),
  );
  return [
    for (final w in tester.widgetList(glyphs))
      if (w is Icon)
        w.icon!
      else if (w is DzIcon)
        if (dzToMaterial[w.data] case final pair?)
          w.color == AppColors.light.navBarSelected ? pair.$2 : pair.$1,
  ];
}

/// The widget behind [findDz] (for its colour, size or fill).
DzIcon dzIconOf(WidgetTester tester, DzIconData data, {bool? filled}) =>
    tester.widget<DzIcon>(findDz(data, filled: filled).first);

/// The fill actually painted right now (0 to 1): [DzIcon.fill] is the target,
/// the painted value eases to it over `fillDuration`.
double paintedFill(WidgetTester tester, DzIconData data) {
  final paint = tester.widget<CustomPaint>(
    find
        .descendant(of: findDz(data).first, matching: find.byType(CustomPaint))
        .first,
  );
  // The painter is private to the icon; its `fill` is read dynamically.
  // ignore: avoid_dynamic_calls
  return (paint.painter! as dynamic).fill as double;
}

String _nameOf(DzIconData data) {
  for (final MapEntry(:key, :value) in DzIcons.all.entries) {
    if (identical(value, data)) return key;
  }
  return 'custom';
}

/// The tap area (global rect) of the control around [of]: the nearest
/// single-control [AppTapArea] above it, grown to its minimum size. The
/// drawn box can be smaller (the Dz 44 dp actions); this is what a tap
/// reaches.
Rect tapAreaOf(WidgetTester tester, Finder of) {
  final area = find
      .ancestor(
        of: of,
        matching: find.byWidgetPredicate(
          (w) => w is AppTapArea && w.mergeSemantics,
        ),
      )
      .first;
  final box = tester.renderObject<RenderAppTapArea>(area);
  final rect = box.hitRect;
  return Rect.fromPoints(
    box.localToGlobal(rect.topLeft),
    box.localToGlobal(rect.bottomRight),
  );
}

/// The drawn (layout) box of the post action around [icon]: its InkResponse.
Rect actionBoxOf(WidgetTester tester, DzIconData icon) => tester.getRect(
  find.ancestor(of: findDz(icon), matching: find.byType(InkResponse)).first,
);

/// Checks how the compact action row of [bar] flows: one line, in order,
/// when its drawn boxes fit the row (its width plus the 10 dp it hangs into
/// the gutter on each side); otherwise save and share keep the first line's
/// end and the counted actions wrap only where the next one does not fit.
/// [boxes] are the five drawn boxes in [dzActionIcons] order. Returns
/// whether the row is on one line.
bool expectCompactRowFlow(Rect bar, List<Rect> boxes, {String reason = ''}) {
  const bleed = 10.0;
  final available = bar.width + 2 * bleed;
  final needed = boxes.fold(0.0, (sum, box) => sum + box.width);
  // Save and share always keep the first line's trailing edge.
  expect(boxes[3].top, boxes.first.top, reason: reason);
  expect(boxes[4].top, boxes.first.top, reason: reason);
  expect(boxes[4].right, closeTo(bar.right + bleed, 0.01), reason: reason);
  if (needed <= available + 0.01) {
    for (var i = 1; i < boxes.length; i++) {
      expect(boxes[i].top, boxes.first.top, reason: '$reason box $i');
      expect(
        boxes[i].left,
        greaterThanOrEqualTo(boxes[i - 1].right - 0.01),
        reason: '$reason box $i',
      );
    }
    return true;
  }
  // Wrapped: the leading part has the width save and share leave.
  final leading = available - boxes[3].width - boxes[4].width;
  var line = boxes.first.width;
  for (var i = 1; i < 3; i++) {
    if (boxes[i].top == boxes[i - 1].top) {
      expect(
        boxes[i].left,
        greaterThanOrEqualTo(boxes[i - 1].right - 0.01),
        reason: '$reason box $i',
      );
      line += boxes[i].width;
    } else {
      // It moved down only because it did not fit after the previous one.
      expect(boxes[i].top, greaterThanOrEqualTo(boxes[i - 1].bottom - 0.01));
      expect(line + boxes[i].width, greaterThan(leading), reason: reason);
      line = boxes[i].width;
    }
  }
  return false;
}

/// The five post-action icons in the order the compact row draws them.
const dzActionIcons = [
  DzIcons.reply,
  DzIcons.repost,
  DzIcons.like,
  DzIcons.save,
  DzIcons.share,
];
