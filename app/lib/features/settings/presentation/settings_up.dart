import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../domain/settings_categories.dart';

// "Up" for the Settings pages on the tablet layout (`ui_shell` +
// `ui_tablet`, 600-1199dp; tablet plan section 3: "When `canPop()` is false
// (deep link or after a resize), up does `go(parentPath)`").
//
// A leaf page goes up to its category (`/settings?c=<id>`), a category page
// to `/settings`. Off the tablet layout nothing changes: no extra button,
// and the leaves' own exits keep going to `/settings`.

/// Whether [context] is inside the tablet shell's panes.
bool _onTabletLayout(BuildContext context) =>
    ShellGeometry.maybeOf(context)?.tablet ?? false;

/// The parent of the Settings page at [path]: the category of a leaf, else
/// `/settings`.
String settingsUpLocation(String path) {
  final category = settingsCategoryOfLeaf(path);
  return category == null
      ? AppRouter.settingsPath
      : settingsCategoryLocation(category);
}

/// Where the leaf at [leafPath] goes when it closes with nothing to pop
/// (Cancel, or after saving): its category on the tablet layout,
/// `/settings` everywhere else (as before).
String settingsLeafExitLocation(BuildContext context, String leafPath) =>
    _onTabletLayout(context)
    ? settingsUpLocation(leafPath)
    : AppRouter.settingsPath;

/// An `AppBar.leading` that goes up to [upLocation], for a Settings page on
/// the tablet layout whose route cannot pop: a typed URL, or a leaf opened
/// with `go` beside the categories (band B). Null everywhere else, so the bar
/// keeps its default (the back arrow when the route can pop, else nothing).
Widget? settingsUpButton(BuildContext context, String upLocation) {
  if (!_onTabletLayout(context)) return null;
  if (ModalRoute.of(context)?.canPop ?? false) return null;
  return BackButton(onPressed: () => context.go(upLocation));
}
