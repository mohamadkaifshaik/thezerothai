import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_bottom_bar.dart';
import 'app_nav_destination.dart';
import 'app_shell_scope.dart';

export 'app_nav_destination.dart';

/// Adaptive shell used by every top-level, authenticated screen:
///
/// - `< 600dp` (phone): a [AppBottomBar] (icons only), the avatar [drawer]
///   (opened from the screen's top bar through an [AppShellScope]) and, when
///   [onCompose] is set and [showFab] is true, a floating compose button.
/// - `600-1199dp` (tablet): an icon-only `NavigationRail` with a round compose
///   button on top and the avatar at the bottom; the content is capped at
///   600dp.
/// - `>= 1200dp` (desktop/web): an extended `NavigationRail` with the "Post"
///   pill on top and the account chip at the bottom, the 600dp content column
///   between two hairlines, and the 350dp [sideColumn] when a screen provides
///   one. The cluster is centred.
///
/// Mirrors X's web layout (`docs/x_research/screens/_shared.md`). The
/// destinations are the high-frequency ones only; Profile/Settings/Sign out
/// live in the drawer and the account chip menu.
class ResponsiveScaffold extends StatefulWidget {
  const ResponsiveScaffold({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.sideColumn,
    this.onCompose,
    this.showFab = true,
    this.drawer,
    this.accountChipBuilder,
    this.masterPane,
  });

  /// The selected destination, or null when none is (Settings).
  final int? selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AppNavDestination> destinations;
  final Widget body;

  /// Extra content shown only at desktop widths (cards: who to follow, trends).
  final Widget? sideColumn;

  /// Starts a new post; null hides every compose control.
  final VoidCallback? onCompose;

  /// Whether the narrow layout shows the floating compose button (it is hidden
  /// where the screen has its own composer entry).
  final bool showFab;

  /// The avatar drawer of the narrow layout.
  final Widget? drawer;

  /// Builds the account chip of the rail (`extended`: with the name block).
  final Widget Function(bool extended)? accountChipBuilder;

  /// A list pane shown only at desktop widths, between the rail and the
  /// [body] (master-detail: Settings). It takes the place of the
  /// [sideColumn].
  final Widget? masterPane;

  @override
  State<ResponsiveScaffold> createState() => _ResponsiveScaffoldState();
}

class _ResponsiveScaffoldState extends State<ResponsiveScaffold> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  static const _composeTooltip = 'New post';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width < AppBreakpoints.mobile) return _narrow(context);
        return _wide(context, isDesktop: width >= AppBreakpoints.tablet);
      },
    );
  }

  Widget _narrow(BuildContext context) {
    final scaffold = Scaffold(
      key: _scaffoldKey,
      drawer: widget.drawer,
      body: SafeArea(bottom: false, child: widget.body),
      floatingActionButton: widget.onCompose != null && widget.showFab
          ? FloatingActionButton(
              tooltip: _composeTooltip,
              onPressed: widget.onCompose,
              child: const Icon(Icons.edit_outlined),
            )
          : null,
      bottomNavigationBar: AppBottomBar(
        destinations: widget.destinations,
        selectedIndex: widget.selectedIndex,
        onSelected: widget.onDestinationSelected,
      ),
    );
    if (widget.drawer == null) return scaffold;
    return AppShellScope(
      openDrawer: () => _scaffoldKey.currentState?.openDrawer(),
      child: scaffold,
    );
  }

  Widget _wide(BuildContext context, {required bool isDesktop}) {
    final colors = Theme.of(context).colorScheme;
    final master = isDesktop ? widget.masterPane : null;
    final side = master == null ? widget.sideColumn : null;
    final compose = widget.onCompose;
    final accountChip = widget.accountChipBuilder?.call(isDesktop);
    return Scaffold(
      body: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NavigationRail(
              extended: isDesktop,
              selectedIndex: widget.selectedIndex,
              onDestinationSelected: widget.onDestinationSelected,
              // X's order: the items, then the Post control right below them,
              // then (pushed to the bottom) the account chip.
              trailing: Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    if (compose != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.md),
                        child: isDesktop
                            ? _PostPill(onPressed: compose)
                            : _ComposeCircle(onPressed: compose),
                      ),
                    const Spacer(),
                    if (accountChip != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: accountChip,
                      ),
                  ],
                ),
              ),
              destinations: [
                for (final d in widget.destinations)
                  NavigationRailDestination(
                    icon: d.iconWidget(d.icon),
                    selectedIcon: d.iconWidget(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            if (master != null)
              SizedBox(
                width: AppSize.sideColumn,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: colors.outlineVariant),
                    ),
                  ),
                  child: master,
                ),
              ),
            // The feed column: at most 600dp, between two hairlines.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: AppSize.contentMax),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.symmetric(
                      vertical: BorderSide(color: colors.outlineVariant),
                    ),
                  ),
                  child: widget.body,
                ),
              ),
            ),
            if (isDesktop && side != null)
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.lg),
                child: SizedBox(
                  width: AppSize.sideColumn,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.md,
                    ),
                    child: side,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The "Post" pill of the extended rail: the strong inverse pill, 233 x 52dp.
class _PostPill extends StatelessWidget {
  const _PostPill({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _ResponsiveScaffoldState._composeTooltip,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          // The themed FilledButton has an infinite minimum width (forms); a
          // fixed pill needs both set.
          minimumSize: const Size(
            AppSize.railPostWidth,
            AppSize.railPostHeight,
          ),
          fixedSize: const Size(AppSize.railPostWidth, AppSize.railPostHeight),
          textStyle: Theme.of(context).textTheme.titleMedium,
        ),
        child: const Text('Post'),
      ),
    );
  }
}

/// The round compose button of the icon-only rail: the strong pill as a
/// 52dp circle.
class _ComposeCircle extends StatelessWidget {
  const _ComposeCircle({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _ResponsiveScaffoldState._composeTooltip,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          fixedSize: const Size.square(AppSize.railPostHeight),
          minimumSize: const Size.square(AppSize.railPostHeight),
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
        ),
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }
}
