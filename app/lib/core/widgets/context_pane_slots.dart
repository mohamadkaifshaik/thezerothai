import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Page to side column: how the desktop Profile's media strip is built over
/// the page's own state (#836).
///
/// The side column is a sibling of the shell navigator, so it cannot read a
/// page's cubits through the tree, and building its own copy would send the
/// page's calls a second time. A page lends the column a builder instead:
/// while it is mounted it puts a builder under its own location
/// ([ContextPaneLease]), and the [ContextPaneSlot] of that location draws the
/// latest one. The builder closes over the page's own state, so the column
/// shows the page's data with no call of its own.
///
/// Whether the slot exists stays a pure function of the route (`MainShell`);
/// only its content comes from the page.
class ContextPaneSlots extends ChangeNotifier {
  final _leases = <_Lease>[];
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// Puts [builder] under [location] for [owner], replacing what [owner]
  /// lent before. The latest lease of a location wins: a page pushed over
  /// another page of the same location shows its own builder, and the
  /// lower page's comes back when it is removed.
  void put(Object owner, String location, WidgetBuilder builder) {
    _leases
      ..removeWhere((l) => identical(l.owner, owner))
      ..add(_Lease(owner, _normalized(location), builder));
    _changed();
  }

  /// Drops what [owner] lent (the page is gone).
  void remove(Object owner) {
    final before = _leases.length;
    _leases.removeWhere((l) => identical(l.owner, owner));
    if (_leases.length != before) _changed();
  }

  /// The builder lent under [location] (the latest lease), or null.
  WidgetBuilder? builderFor(String location) {
    final path = _normalized(location);
    for (final lease in _leases.reversed) {
      if (lease.location == path) return lease.builder;
    }
    return null;
  }

  /// Pages put and remove while the tree is being built or torn down, when
  /// no other widget may be marked for a rebuild: the slots hear of it after
  /// that frame.
  void _changed() {
    if (_disposed) return;
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    binding.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
    binding.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    _leases.clear();
    super.dispose();
  }

  /// The slots of the shell around [context], or null (no `MainShell`).
  static ContextPaneSlots? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ContextPaneSlotsScope>()?.slots;

  /// The slots of the side column's page boxes (`ShellSideColumn`), or null
  /// (no `MainShell`).
  static ContextPaneSlots? sideColumnOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<_ContextPaneSlotsScope>()
      ?.sideColumn;

  static String _normalized(String location) {
    final segments = [
      for (final s in Uri.parse(location).pathSegments)
        if (s.isNotEmpty) s,
    ];
    return '/${segments.join('/')}';
  }
}

@immutable
class _Lease {
  const _Lease(this.owner, this.location, this.builder);

  final Object owner;
  final String location;
  final WidgetBuilder builder;
}

/// Owns the [ContextPaneSlots] of one shell, above both the shell navigator
/// (the pages) and the side column (the slots). `MainShell` puts it around
/// its scaffold at every width, so the tree keeps its shape.
class ContextPaneSlotsHost extends StatefulWidget {
  const ContextPaneSlotsHost({super.key, required this.child});

  final Widget child;

  @override
  State<ContextPaneSlotsHost> createState() => _ContextPaneSlotsHostState();
}

class _ContextPaneSlotsHostState extends State<ContextPaneSlotsHost> {
  final _slots = ContextPaneSlots();
  final _sideColumn = ContextPaneSlots();

  @override
  void dispose() {
    _slots.dispose();
    _sideColumn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ContextPaneSlotsScope(
    slots: _slots,
    sideColumn: _sideColumn,
    child: widget.child,
  );
}

class _ContextPaneSlotsScope extends InheritedWidget {
  const _ContextPaneSlotsScope({
    required this.slots,
    required this.sideColumn,
    required super.child,
  });

  final ContextPaneSlots slots;

  /// The boxes pages lend to the whole side column (`ShellSideColumn`).
  final ContextPaneSlots sideColumn;

  @override
  bool updateShouldNotify(_ContextPaneSlotsScope oldWidget) =>
      !identical(slots, oldWidget.slots);
}

/// A page's lease on the shell's [ContextPaneSlots]: [attach] once the page
/// has a context (its `didChangeDependencies`), [dispose] with the page.
/// Outside a shell (no host) both do nothing.
class ContextPaneLease {
  ContextPaneSlots? _slots;
  bool _attached = false;

  /// Lends [builder] under [location]; only the first call counts. The
  /// builder should read the page's state when it builds (a `BlocBuilder`
  /// over the page's cubit, a listenable of its form), not capture it.
  void attach(BuildContext context, String location, WidgetBuilder builder) {
    if (_attached) return;
    _attached = true;
    _slots = ContextPaneSlots.maybeOf(context)?..put(this, location, builder);
  }

  void dispose() {
    _slots?.remove(this);
    _slots = null;
  }
}

/// The content of one side-column section that a page lends (see
/// [ContextPaneSlots]): the latest builder under [location], or
/// [placeholder] until a page lends one.
class ContextPaneSlot extends StatefulWidget {
  const ContextPaneSlot({
    super.key,
    required this.location,
    this.placeholder = const SizedBox.shrink(),
  });

  /// The location of the page that lends the content: the shell navigator's
  /// top page.
  final String location;

  /// Drawn while no page lends a builder under [location] (a page being pushed
  /// has not taken its lease yet): the section's own loading look, so the
  /// column does not show the footer alone and then jump. Nothing (0 height)
  /// by default.
  final Widget placeholder;

  @override
  State<ContextPaneSlot> createState() => _ContextPaneSlotState();
}

class _ContextPaneSlotState extends State<ContextPaneSlot> {
  ContextPaneSlots? _slots;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final slots = ContextPaneSlots.maybeOf(context);
    if (identical(slots, _slots)) return;
    _slots?.removeListener(_changed);
    _slots = slots?..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _slots?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final builder = _slots?.builderFor(widget.location);
    return builder == null ? widget.placeholder : builder(context);
  }
}
