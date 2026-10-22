import 'package:flutter/widgets.dart';

/// What the navigation shell offers to the screens inside it: today, opening
/// the avatar drawer (narrow layouts only).
///
/// A screen's top bar reads it with [maybeOf]; outside the shell, or on a
/// layout without a drawer, there is no scope and the top bar simply shows
/// no avatar button. No `Scaffold.of` lookup is needed (the screens have
/// Scaffolds of their own), and no focus node is shared between screens.
class AppShellScope extends InheritedWidget {
  const AppShellScope({
    super.key,
    required this.openDrawer,
    required super.child,
  });

  /// Opens the shell's drawer. Never null: a layout without a drawer does not
  /// provide the scope at all.
  final VoidCallback openDrawer;

  static AppShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppShellScope>();

  @override
  bool updateShouldNotify(AppShellScope oldWidget) =>
      openDrawer != oldWidget.openDrawer;
}
