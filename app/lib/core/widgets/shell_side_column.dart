import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/primitives/app_side_column.dart';
import '../theme/app_theme.dart';
import 'context_pane_slots.dart';

/// Page to desktop side column: how a page puts its own boxes in the shell's
/// right-hand column (the desktop Community, Members, Moderation log and
/// Create community mocks), the way [ShellFab] gives a page the phone's
/// floating button.
///
/// The column is a sibling of the shell navigator, so it cannot read a page's
/// cubits through the tree. A page wraps itself in a [ShellSideColumn] and
/// lends a builder that closes over its own state; the shell's
/// [ShellSideColumnView] draws the latest builder of the current location
/// inside the column, between the search pill and the footer links. When no
/// page lends one, the view draws the global column as it was (search pill,
/// profile card, trends, who to follow).
///
/// The page's own box content must not call anything of its own: it is built
/// over what the page already loaded.
/// A page's lease on the side column's boxes: call [set] from the page's
/// `build` (or `didChangeDependencies`) with whether the page lends boxes
/// and the [WidgetBuilder] of them, and [dispose] with the page. The boxes
/// stay under the page's current location (a page under another page keeps
/// its lease, and the top page's wins); [set] with `active: false` lends
/// none. Outside a shell it does nothing.
///
/// The builder is called in the column's tree, not the page's: give it what
/// it needs by closure (a cubit through `BlocBuilder(bloc: cubit)`, a
/// `ValueListenable`), never through the page's `BuildContext`. The column
/// calls the latest builder given; it rebuilds when its own state changes,
/// so make it read live state.
class ShellSideColumnLease {
  ContextPaneSlots? _slots;
  String? _location;
  bool _active = false;
  WidgetBuilder? _builder;

  void set(
    BuildContext context, {
    required bool active,
    required WidgetBuilder builder,
  }) {
    _builder = builder;
    final slots = ContextPaneSlots.sideColumnOf(context);
    final location = slots == null ? null : _locationOf(context);
    if (slots == null || location == null) return;
    if (active == _active && slots == _slots && location == _location) return;
    _slots?.remove(this);
    _slots = slots;
    _location = location;
    _active = active;
    if (active) slots.put(this, location, (context) => _builder!(context));
  }

  void dispose() {
    _slots?.remove(this);
    _slots = null;
    _active = false;
  }

  /// The location of the page's route; null when it is not a go_router page
  /// (a dialog's own navigator).
  static String? _locationOf(BuildContext context) {
    try {
      return GoRouterState.of(context).matchedLocation;
    } on GoError {
      return null;
    }
  }
}

/// The shell's side column: the boxes the page at [location] lent
/// ([ShellSideColumn]) between the search pill and the [links]; the
/// [fallback] (the global column) while none is lent.
class ShellSideColumnView extends StatefulWidget {
  const ShellSideColumnView({
    super.key,
    required this.location,
    required this.fallback,
    required this.links,
    this.header,
  });

  /// The location of the page that lends the boxes: the shell navigator's
  /// top page.
  final String location;

  /// Today's global column.
  final Widget fallback;

  /// The footer links of the column, kept under the page's boxes.
  final List<AppSideLink> links;

  /// Above the page's boxes (the search pill), or null.
  final Widget? header;

  @override
  State<ShellSideColumnView> createState() => _ShellSideColumnViewState();
}

class _ShellSideColumnViewState extends State<ShellSideColumnView> {
  ContextPaneSlots? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = ContextPaneSlots.sideColumnOf(context);
    if (identical(registry, _registry)) return;
    _registry?.removeListener(_changed);
    _registry = registry?..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _registry?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final builder = _registry?.builderFor(widget.location);
    if (builder == null) return widget.fallback;
    return AppSideColumn(
      header: widget.header,
      sections: [Builder(builder: builder)],
      links: widget.links,
    );
  }
}

/// Whether the desktop shell's side column is beside this page (a desktop
/// window inside a shell), so the page lends its side boxes
/// ([ShellSideColumn]) and leaves them out of its own body. False for a page
/// pumped on its own, which keeps them inline.
bool shellSideColumnBeside(BuildContext context) =>
    ContextPaneSlots.sideColumnOf(context) != null &&
    MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;
