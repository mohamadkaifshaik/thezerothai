import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// One stat of the profile hero's pill: `posts`, `followers` or `following`.
Finder heroStat(String name) => find.byKey(ValueKey('profile-stat-$name'));

/// The stat's number with its label ("2 Posts" as the pill draws it: the
/// number over the label, both inside the one stat).
Finder heroStatText(String name, int count) =>
    find.descendant(of: heroStat(name), matching: find.text('$count'));
