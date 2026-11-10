import 'package:flutter/widgets.dart';

/// The last sliver of every scroll view a shell screen builds with
/// `CustomScrollView`: empty space as tall as the bottom padding of the
/// `MediaQuery`, so the end of the content can scroll clear of the floating
/// bottom bar (`ui_shell`, which reports its height as that padding).
///
/// `ListView`, `GridView` and `SafeArea` read the padding on their own; a
/// `CustomScrollView` does not, hence this sliver. It is zero tall wherever
/// the padding is already taken: the docked bar of the legacy chrome (the
/// `Scaffold` removes it from the body), the wide layouts and a `SafeArea`
/// above the scroll view, so those layouts are unchanged. The tablet layout
/// (`ui_tablet`, no outer `SafeArea`) passes the bottom safe-area inset
/// through, so there it keeps the end of the content clear of the home
/// indicator.
///
/// Under a `NestedScrollView` put it in the inner scroll views (the tabs).
/// `test/guards/shell_bottom_inset_guard_test.dart` checks every call site.
class ShellBottomInsetSliver extends StatelessWidget {
  const ShellBottomInsetSliver({super.key});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return SliverToBoxAdapter(child: SizedBox(height: bottom));
  }
}
