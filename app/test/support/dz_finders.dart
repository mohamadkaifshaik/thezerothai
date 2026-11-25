import 'package:dzeroth/core/icons/dz_icon.dart';
import 'package:dzeroth/core/icons/dz_icon_data.dart';
import 'package:dzeroth/core/icons/dz_icons.dart';
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

/// The five post-action icons in the order the compact row draws them.
const dzActionIcons = [
  DzIcons.reply,
  DzIcons.repost,
  DzIcons.like,
  DzIcons.save,
  DzIcons.share,
];
