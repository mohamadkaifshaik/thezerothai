import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../shared/widgets/primitives/app_pill_button.dart';
import '../theme/app_theme.dart';
import 'app_bottom_bar.dart';
import 'app_nav_rail.dart';
import 'app_shell_scope.dart';
import 'context_pane.dart';
import 'shell_geometry.dart';
import 'tablet_modal.dart';

export 'app_nav_destination.dart';
export 'shell_geometry.dart' show ShellLayout;

/// Adaptive shell used by every top-level, authenticated screen:
///
/// - `< 600dp` (phone): a [AppBottomBar] (icons only; with [floatingBar] the
///   [AppFloatingBottomBar] pill over the body), the avatar [drawer]
///   (opened from the screen's top bar through an [AppShellScope]) and, when
///   [onCompose] is set and [showFab] is true, a floating compose button.
/// - `600-1199dp` (tablet), [ShellLayout.legacy]: an icon-only
///   `NavigationRail` with a round compose button on top and the avatar at
///   the bottom; the content is capped at 600dp and the cluster is centred.
/// - `600-1199dp`, [ShellLayout.tablet] (`ui_shell` + `ui_tablet`): the
///   [AppNavRail] pinned to the leading edge and the [body] filling the rest
///   of the width as one pane, with no outer `SafeArea`: the rail pads itself
///   by the leading, top and bottom insets; the pane ends at the trailing
///   inset (a strip in the page colour fills it) and gets the top and bottom
///   ones (its header pads by the top inset, its scrollables by the bottom
///   one). The pane is exactly the content of its [ShellGeometry].
///   From 840dp (band B), when the page has [contextSections], the content
///   splits into the primary pane and the [ContextPane] after a 1dp hairline
///   (`ShellGeometry.contextPaneWidthFor`); below 840 (band A) the body keeps
///   the whole content. [sideColumn] and [masterPane] are not shown there.
/// - `>= 1200dp` (desktop/web): an extended `NavigationRail` with the "Post"
///   pill on top and the account chip at the bottom, the 600dp content column
///   between two hairlines, and the 350dp [sideColumn] when a screen provides
///   one. The cluster is centred.
///
/// Mirrors X's web layout. The
/// destinations are the high-frequency ones only; Settings/Sign out live in
/// the drawer and the account chip menu. A destination in
/// `AppNavGroup.secondary` (Lists, History...) is left out of the phone bar; one
/// with `onActivate` (More) opens a menu anchored at its icon instead of
/// navigating.
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
    this.redesignedRail = false,
    this.drawer,
    this.accountChipBuilder,
    this.masterPane,
    this.floatingBar = false,
    this.layout = ShellLayout.legacy,
    this.moreHasOwnRows = true,
    this.onMoreFolded,
    this.contextSections,
  });

  /// Tablet layout, band B (840-1199dp) only: the sections of the context
  /// pane beside the [body] (tablet plan section 3, code P). Null or empty:
  /// no pane, the body keeps the whole content width. Ignored in band A, on
  /// phones, on desktop (which keeps [sideColumn]) and in the legacy layout.
  final List<ContextSection>? contextSections;

  /// The composition at 600-1199dp. [ShellLayout.tablet] only with
  /// `ui_shell` and `ui_tablet` both on; phones and desktop ignore it.
  final ShellLayout layout;

  /// Tablet layout only: whether the More destination (the one with
  /// `onActivate`) has rows of its own. See [AppNavRail.moreHasOwnRows].
  final bool moreHasOwnRows;

  /// Tablet layout only: opens More with the destinations folded into it at
  /// a short height. See [AppNavRail.onMoreFolded].
  final void Function(BuildContext anchor, List<int> folded)? onMoreFolded;

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

  /// Whether the rail (600dp and up) takes the redesigned style (`ui_shell`):
  /// the `selectedIndicator` pill behind the filled selected glyph, w800
  /// selected and w600 `text2` unselected labels, and the gradient compose
  /// controls with their glow. Off: the legacy rail, unchanged. Style only:
  /// the rail's composition (widths, order, compose and chip placement) is
  /// the same in both.
  final bool redesignedRail;

  /// The avatar drawer of the narrow layout.
  final Widget? drawer;

  /// Builds the account chip of the rail (`extended`: with the name block).
  final Widget Function(bool extended)? accountChipBuilder;

  /// A list pane shown only at desktop widths, between the rail and the
  /// [body] (master-detail: Settings). It takes the place of the
  /// [sideColumn].
  final Widget? masterPane;

  /// Whether the narrow layout uses the redesigned chrome (`ui_shell`): the
  /// [AppFloatingBottomBar] over the body and the gradient compose button.
  /// Off: the legacy docked [AppBottomBar].
  final bool floatingBar;

  @override
  State<ResponsiveScaffold> createState() => _ResponsiveScaffoldState();
}

class _ResponsiveScaffoldState extends State<ResponsiveScaffold> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _showMobileNavigation = true;

  @override
  void didUpdateWidget(covariant ResponsiveScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A bar hidden by scrolling should not stay hidden after the user changes
    // to another top-level destination.
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _showMobileNavigation = true;
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        notification is! UserScrollNotification) {
      return false;
    }
    final show = switch (notification.direction) {
      ScrollDirection.forward => true,
      ScrollDirection.reverse => false,
      ScrollDirection.idle => _showMobileNavigation,
    };
    if (show != _showMobileNavigation) {
      setState(() => _showMobileNavigation = show);
    }
    return false;
  }

  // Anchors of the rail destinations that open a menu (`onActivate`), by index.
  final _anchorKeys = <int, GlobalKey>{};

  void _selectOnRail(int index) {
    final activate = widget.destinations[index].onActivate;
    if (activate == null) {
      widget.onDestinationSelected(index);
      return;
    }
    final anchor = _anchorKeys[index]?.currentContext;
    if (anchor != null) activate(anchor);
  }

  static const _composeTooltip = 'New post';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width < AppBreakpoints.mobile) return _narrow(context);
        final isDesktop = width >= AppBreakpoints.tablet;
        if (!isDesktop && widget.layout == ShellLayout.tablet) {
          return _tablet(context, constraints.biggest);
        }
        return _wide(context, isDesktop: isDesktop);
      },
    );
  }

  /// The tablet shell (600-1199dp, [ShellLayout.tablet]): the pinned rail,
  /// then the body as one pane over the rest of the width.
  Widget _tablet(BuildContext context, Size window) {
    final media = MediaQuery.of(context);
    final direction = Directionality.of(context);
    final geometry = ShellGeometry.contentRectFor(
      window,
      media.padding,
      ShellLayout.tablet,
      textDirection: direction,
    );
    final ltr = direction == TextDirection.ltr;
    final trailing = ltr ? media.padding.right : media.padding.left;
    // A modal opened from anywhere in the shell (the rail's account menu
    // included, not only the panes) is over the rail: it centres on the
    // content area. This is the root Scaffold of the shell's routes, so it
    // shows their snack bars: centred over the pane area, not the rail.
    return TabletModalScope(
      host: const TabletModalHost(overShell: true),
      child: TabletSnackBarTheme(
        content: geometry.content,
        child: _tabletScaffold(context, geometry, trailing),
      ),
    );
  }

  Widget _tabletScaffold(
    BuildContext context,
    ShellGeometryData geometry,
    double trailing,
  ) {
    final compose = widget.onCompose;
    final sections = widget.contextSections;
    // Band B with sections: the primary pane and the context pane.
    final pane =
        geometry.band == ShellBand.expanded &&
            sections != null &&
            sections.isNotEmpty
        ? sections
        : null;
    final colors = context.appColors;
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: geometry.railWidth,
            // Focus order: the rail, then the pane.
            child: FocusTraversalGroup(
              child: AppNavRail(
                destinations: widget.destinations,
                selectedIndex: widget.selectedIndex,
                onDestinationSelected: widget.onDestinationSelected,
                compose: compose == null
                    ? null
                    : _GradientComposeCircle(onPressed: compose),
                account: widget.accountChipBuilder?.call(false),
                moreHasOwnRows: widget.moreHasOwnRows,
                onMoreFolded: widget.onMoreFolded,
              ),
            ),
          ),
          Expanded(
            // The rail took the leading inset and the strip below takes the
            // trailing one (a `ListView` pads only along its scroll axis, so
            // the pane must stop there itself): the pane is
            // `geometry.content` and keeps the top and bottom insets.
            child: MediaQuery.removePadding(
              context: context,
              removeLeft: true,
              removeRight: true,
              child: ShellGeometry(
                data: geometry,
                // The pages learn which sections the pane shows, so an
                // inline copy (Explore's "Who to follow") steps aside.
                child: ContextPaneScope(
                  shown: {
                    if (pane != null)
                      for (final section in pane) section.kind,
                  },
                  child: FocusTraversalGroup(child: widget.body),
                ),
              ),
            ),
          ),
          // Focus order: the rail, the primary pane, then the context pane.
          if (pane != null)
            SizedBox(
              key: const ValueKey('tablet-context-pane'),
              width:
                  ShellGeometry.contextPaneWidthFor(geometry.content.width) + 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: BorderDirectional(
                    start: BorderSide(color: colors.hairline),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 1),
                  child: MediaQuery.removePadding(
                    context: context,
                    removeLeft: true,
                    removeRight: true,
                    child: FocusTraversalGroup(
                      child: ContextPane(sections: pane),
                    ),
                  ),
                ),
              ),
            ),
          // The trailing inset (a landscape notch), in the page colour.
          SizedBox(
            width: trailing,
            child: ColoredBox(
              key: const ValueKey('tablet-trailing-inset'),
              color: Theme.of(context).scaffoldBackgroundColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _narrow(BuildContext context) {
    // The bar leaves out the rail-only destinations; indexes are translated
    // both ways (the selection of a rail-only one is "none").
    final bar = <int>[
      for (var i = 0; i < widget.destinations.length; i++)
        if (widget.destinations[i].group == AppNavGroup.primary) i,
    ];
    final selected = widget.selectedIndex == null
        ? -1
        : bar.indexOf(widget.selectedIndex!);
    if (widget.floatingBar) {
      return _withShellScope(_narrowFloating(context, bar, selected));
    }
    final scaffold = Scaffold(
      key: _scaffoldKey,
      drawer: widget.drawer,
      body: SafeArea(
        bottom: false,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: widget.body,
        ),
      ),
      floatingActionButton: widget.onCompose != null && widget.showFab
          ? FloatingActionButton(
              tooltip: _composeTooltip,
              onPressed: widget.onCompose,
              child: const Icon(Icons.edit_outlined),
            )
          : null,
      bottomNavigationBar: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _showMobileNavigation
            ? AppBottomBar(
                destinations: [for (final i in bar) widget.destinations[i]],
                selectedIndex: selected < 0 ? null : selected,
                onSelected: (index) => widget.onDestinationSelected(bar[index]),
              )
            : const SizedBox.shrink(),
      ),
    );
    return _withShellScope(scaffold);
  }

  Widget _withShellScope(Widget scaffold) {
    if (widget.drawer == null) return scaffold;
    return AppShellScope(
      openDrawer: () => _scaffoldKey.currentState?.openDrawer(),
      child: scaffold,
    );
  }

  /// The redesigned phone chrome: the bar floats over the body, so the body
  /// extends behind it and gets the bar's height as bottom padding (in
  /// `padding` and `viewPadding`, so scrollables, safe areas and the compose
  /// buttons of nested scaffolds all end above the pill). The padding stays
  /// while the bar is scrolled away, so the page does not jump.
  Widget _narrowFloating(BuildContext context, List<int> bar, int selected) {
    final media = MediaQuery.of(context);
    // An open keyboard takes the bar away: it would float over the field.
    final keyboardOpen = media.viewInsets.bottom > 0;
    final hidden = !_showMobileNavigation;
    final movement = AppMotion.of(context).movement;
    const duration = Duration(milliseconds: 180);
    final reserved = media.padding.bottom + AppFloatingBottomBar.reservedHeight;
    return Scaffold(
      key: _scaffoldKey,
      drawer: widget.drawer,
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          // The same wrapper with or without the bar, so the page keeps its
          // state (and its focused field) when the keyboard opens.
          child: Builder(
            builder: (context) {
              // Below the SafeArea: only the bottom edge changes.
              final inner = MediaQuery.of(context);
              if (keyboardOpen) {
                return MediaQuery(data: inner, child: widget.body);
              }
              return MediaQuery(
                data: inner.copyWith(
                  padding: inner.padding.copyWith(bottom: reserved),
                  viewPadding: inner.viewPadding.copyWith(bottom: reserved),
                ),
                child: widget.body,
              );
            },
          ),
        ),
      ),
      floatingActionButton: widget.onCompose != null && widget.showFab
          ? _ComposeFab(onPressed: widget.onCompose!)
          : null,
      bottomNavigationBar: keyboardOpen
          ? null
          : IgnorePointer(
              ignoring: hidden,
              child: ExcludeSemantics(
                excluding: hidden,
                child: AnimatedSlide(
                  // Reduced motion: fade only.
                  offset: hidden && movement ? const Offset(0, 1) : Offset.zero,
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: hidden ? 0 : 1,
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    child: AppBottomBar(
                      floating: true,
                      destinations: [
                        for (final i in bar) widget.destinations[i],
                      ],
                      selectedIndex: selected < 0 ? null : selected,
                      onSelected: (index) =>
                          widget.onDestinationSelected(bar[index]),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  NavigationRailDestination _railDestination(int index, AppNavDestination d) {
    final label = Text(d.label);
    final icon = d.iconWidget(d.icon);
    return NavigationRailDestination(
      icon: d.onActivate == null
          ? icon
          : KeyedSubtree(
              key: _anchorKeys.putIfAbsent(index, GlobalKey.new),
              child: icon,
            ),
      selectedIcon: d.iconWidget(d.selectedIcon),
      label: d.semanticsLabel == null
          ? label
          : Semantics(
              label: d.semanticsLabel,
              excludeSemantics: true,
              child: label,
            ),
    );
  }

  Widget _wide(BuildContext context, {required bool isDesktop}) {
    final colors = Theme.of(context).colorScheme;
    final master = isDesktop ? widget.masterPane : null;
    final side = master == null ? widget.sideColumn : null;
    final compose = widget.onCompose;
    final accountChip = widget.accountChipBuilder?.call(isDesktop);
    // `ui_shell` only; null keeps the theme's legacy rail as it is.
    final style = widget.redesignedRail ? _RailStyle.of(context) : null;
    return Scaffold(
      body: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NavigationRail(
              extended: isDesktop,
              selectedIndex: widget.selectedIndex,
              onDestinationSelected: _selectOnRail,
              indicatorShape: style?.indicatorShape,
              indicatorColor: style?.indicatorColor,
              selectedIconTheme: style?.selectedIconTheme,
              unselectedIconTheme: style?.unselectedIconTheme,
              selectedLabelTextStyle: style?.selectedLabelTextStyle,
              unselectedLabelTextStyle: style?.unselectedLabelTextStyle,
              // X's order: the items, then the Post control right below them,
              // then (pushed to the bottom) the account chip.
              trailing: Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    if (compose != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.md),
                        child: switch ((isDesktop, style != null)) {
                          (true, false) => _PostPill(onPressed: compose),
                          (false, false) => _ComposeCircle(onPressed: compose),
                          (true, true) => _GradientPostPill(onPressed: compose),
                          (false, true) => _GradientComposeCircle(
                            onPressed: compose,
                          ),
                        },
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
                for (var i = 0; i < widget.destinations.length; i++)
                  _railDestination(i, widget.destinations[i]),
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

/// The compose button of the redesigned phone chrome: a 58dp circle with the
/// primary gradient and its glow, above the floating bar.
class _ComposeFab extends StatelessWidget {
  const _ComposeFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: const CircleBorder(),
        gradient: colors.primaryFillGradient,
        shadows: AppShadows.primaryGlow,
      ),
      child: Theme(
        data: theme.copyWith(
          floatingActionButtonTheme: theme.floatingActionButtonTheme.copyWith(
            backgroundColor: Colors.transparent,
            foregroundColor: colors.primaryFillLabel,
            sizeConstraints: const BoxConstraints.tightFor(
              width: AppSize.fabRedesign,
              height: AppSize.fabRedesign,
            ),
          ),
        ),
        child: FloatingActionButton(
          tooltip: _ResponsiveScaffoldState._composeTooltip,
          onPressed: onPressed,
          child: const Icon(Icons.edit_outlined),
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

/// The redesigned rail look (`ui_shell`, PR 3.5), set on the
/// `NavigationRail` itself so the theme (and with it the legacy rail) stays
/// as it is. The selected item is marked three ways: the pill, the filled
/// glyph and the w800 label, never by colour alone.
class _RailStyle {
  const _RailStyle({
    required this.indicatorColor,
    required this.selectedIconTheme,
    required this.unselectedIconTheme,
    required this.selectedLabelTextStyle,
    required this.unselectedLabelTextStyle,
  });

  factory _RailStyle.of(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final label = theme.textTheme.labelMedium;
    return _RailStyle(
      indicatorColor: colors.selectedIndicator,
      // The glyph sits on the pill: onPrimary is the pill's ink in both
      // themes (selectedIndicator is the primary).
      selectedIconTheme: IconThemeData(
        color: theme.colorScheme.onPrimary,
        size: AppIconSize.lg,
      ),
      unselectedIconTheme: IconThemeData(
        color: colors.text2,
        size: AppIconSize.lg,
      ),
      selectedLabelTextStyle: label?.copyWith(
        fontWeight: AppTypeTokens.weightDisplay,
        color: theme.colorScheme.onSurface,
      ),
      unselectedLabelTextStyle: label?.copyWith(
        fontWeight: AppTypeTokens.weightLabel,
        color: colors.text2,
      ),
    );
  }

  /// The indicator is a pill (the full-row pill of the design is T1's
  /// `AppNavRail`).
  ShapeBorder get indicatorShape => const StadiumBorder();
  final Color indicatorColor;
  final IconThemeData selectedIconTheme;
  final IconThemeData unselectedIconTheme;
  final TextStyle? selectedLabelTextStyle;
  final TextStyle? unselectedLabelTextStyle;
}

/// The "Post" pill of the extended rail under `ui_shell`: the primary
/// button (the brand gradient, a navy label and the glow), 233dp wide and
/// 52dp tall; it grows taller with the text scale, never wider.
class _GradientPostPill extends StatelessWidget {
  const _GradientPostPill({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _ResponsiveScaffoldState._composeTooltip,
      child: SizedBox(
        width: AppSize.railPostWidth,
        child: AppPillButton(
          label: 'Post',
          onPressed: onPressed,
          size: AppButtonSize.large,
        ),
      ),
    );
  }
}

/// The round compose button of the icon-only rail under `ui_shell`: a 52dp
/// circle with the brand gradient, a navy glyph and the glow.
class _GradientComposeCircle extends StatelessWidget {
  const _GradientComposeCircle({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Tooltip(
      message: _ResponsiveScaffoldState._composeTooltip,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: const CircleBorder(),
          gradient: colors.primaryFillGradient,
          shadows: AppShadows.primaryGlow,
        ),
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            fixedSize: const Size.square(AppSize.railPostHeight),
            minimumSize: const Size.square(AppSize.railPostHeight),
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            // The gradient below is the fill; the button keeps its focus,
            // hover and press overlays in the label colour.
            backgroundColor: Colors.transparent,
            foregroundColor: colors.primaryFillLabel,
          ),
          child: const Icon(Icons.edit_outlined),
        ),
      ),
    );
  }
}
