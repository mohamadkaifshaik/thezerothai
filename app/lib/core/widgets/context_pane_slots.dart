import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'context_pane.dart';

/// Page to pane, for the context-pane sections built over a page's own state
/// (tablet plan section 5.1, "one widget, two placements"; T8a).
///
/// Band B's context pane is a sibling of the shell navigator, so it cannot
/// read a page's cubits or form controllers through the tree, and building
/// its own copies would send the page's calls a second time. A page lends the
/// pane a builder instead: while it is mounted it puts `kind -> builder`
/// under its own location ([ContextPaneLease]), and the [ContextPaneSlot] of
/// that kind and location draws the latest one. The builders close over the
/// page's own state, so the pane shows the page's data, with no call of its
/// own, and both stay in step (a Join in the pane is the page's Join).
///
/// Whether the pane exists, and which kinds it shows, stays a pure function
/// of the route (`contextSectionsFor`); only a slot's content comes from the
/// page, so the primary pane's width never waits on it.
class ContextPaneSlots extends ChangeNotifier {
  final _leases = <_Lease>[];
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// Puts [builders] under [location] for [owner], replacing what [owner]
  /// lent before. The latest lease of a location wins: a page pushed over
  /// another page of the same location shows its own sections, and the
  /// lower page's come back when it is removed.
  void put(
    Object owner,
    String location,
    Map<ContextSectionKind, WidgetBuilder> builders,
  ) {
    _leases
      ..removeWhere((l) => identical(l.owner, owner))
      ..add(_Lease(owner, _normalized(location), Map.of(builders)));
    _changed();
  }

  /// Drops what [owner] lent (the page is gone).
  void remove(Object owner) {
    final before = _leases.length;
    _leases.removeWhere((l) => identical(l.owner, owner));
    if (_leases.length != before) _changed();
  }

  /// The builder of [kind] lent under [location], or null.
  WidgetBuilder? builderFor(String location, ContextSectionKind kind) {
    final path = _normalized(location);
    for (final lease in _leases.reversed) {
      if (lease.location != path) continue;
      final builder = lease.builders[kind];
      if (builder != null) return builder;
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
  const _Lease(this.owner, this.location, this.builders);

  final Object owner;
  final String location;
  final Map<ContextSectionKind, WidgetBuilder> builders;
}

/// Owns the [ContextPaneSlots] of one shell, above both the shell navigator
/// (the pages) and the context pane (the slots). `MainShell` puts it around
/// its scaffold at every width, so the tree keeps its shape.
class ContextPaneSlotsHost extends StatefulWidget {
  const ContextPaneSlotsHost({super.key, required this.child});

  final Widget child;

  @override
  State<ContextPaneSlotsHost> createState() => _ContextPaneSlotsHostState();
}

class _ContextPaneSlotsHostState extends State<ContextPaneSlotsHost> {
  final _slots = ContextPaneSlots();

  @override
  void dispose() {
    _slots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _ContextPaneSlotsScope(slots: _slots, child: widget.child);
}

class _ContextPaneSlotsScope extends InheritedWidget {
  const _ContextPaneSlotsScope({required this.slots, required super.child});

  final ContextPaneSlots slots;

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

  /// Lends [builders] under [location]; only the first call counts. The
  /// builders should read the page's state when they build (a `BlocBuilder`
  /// over the page's cubit, a listenable of its form), not capture it.
  void attach(
    BuildContext context,
    String location,
    Map<ContextSectionKind, WidgetBuilder> builders,
  ) {
    if (_attached) return;
    _attached = true;
    _slots = ContextPaneSlots.maybeOf(context)?..put(this, location, builders);
  }

  void dispose() {
    _slots?.remove(this);
    _slots = null;
  }
}

/// The content of one context-pane section that a page lends (see
/// [ContextPaneSlots]): the latest builder of [kind] under [location], or
/// nothing (0 height) until a page lends one.
class ContextPaneSlot extends StatefulWidget {
  const ContextPaneSlot({
    super.key,
    required this.kind,
    required this.location,
  });

  final ContextSectionKind kind;

  /// The location of the page that lends the content: the shell navigator's
  /// top page.
  final String location;

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
    final builder = _slots?.builderFor(widget.location, widget.kind);
    return builder == null ? const SizedBox.shrink() : builder(context);
  }
}
