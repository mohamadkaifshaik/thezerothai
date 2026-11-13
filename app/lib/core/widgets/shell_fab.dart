import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';

/// The phone shell's floating button for one page: Home's New post, Plans'
/// New plan, Messages' New message, Lists' New List, Communities' New
/// community, a community's Post. Pages without one show no button.
@immutable
class ShellFabAction {
  const ShellFabAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  /// Same look; the callback is not compared (a new closure every build).
  bool looksLike(ShellFabAction? other) =>
      other != null && other.tooltip == tooltip && other.icon == icon;
}

/// The actions pages offer, by the location they belong to. Pages under the
/// top one stay mounted, so the shell shows only the current location's.
class ShellFabRegistry extends ChangeNotifier {
  final _actions = <String, ShellFabAction>{};
  final _owners = <String, Object>{};
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// The action of the page at [location], if it offers one.
  ShellFabAction? actionAt(String location) => _actions[location];

  void _set(String location, Object owner, ShellFabAction? action) {
    // A page's last clear can land after the shell is gone.
    if (_disposed) return;
    if (action == null) {
      // Only the page that set it clears it: a page replacing another at
      // the same location may have published first.
      if (_owners[location] != owner) return;
      _owners.remove(location);
      _actions.remove(location);
      notifyListeners();
      return;
    }
    final current = _actions[location];
    _owners[location] = owner;
    _actions[location] = action;
    // A fresh callback alone needs no rebuild: the shell reads the action
    // when the button is pressed.
    if (!action.looksLike(current)) notifyListeners();
  }
}

/// Provides the [ShellFabRegistry] of the shell to its pages.
class ShellFabScope extends InheritedNotifier<ShellFabRegistry> {
  const ShellFabScope({
    super.key,
    required ShellFabRegistry registry,
    required super.child,
  }) : super(notifier: registry);

  /// The registry, or null outside a shell (a page pumped on its own).
  static ShellFabRegistry? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ShellFabScope>()?.notifier;

  /// The registry, rebuilding [context] when an action comes or goes (the
  /// shell).
  static ShellFabRegistry? watch(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellFabScope>()?.notifier;
}

/// Whether the shell's floating button carries the page's main action here
/// (a phone inside the shell), so the page leaves its own header button out.
bool shellFabCovers(BuildContext context) =>
    MediaQuery.sizeOf(context).width < AppBreakpoints.mobile &&
    ShellFabScope.maybeOf(context) != null;

/// Owns the shell's [ShellFabRegistry] for as long as the shell lives.
class ShellFabHost extends StatefulWidget {
  const ShellFabHost({super.key, required this.child});

  final Widget child;

  @override
  State<ShellFabHost> createState() => _ShellFabHostState();
}

class _ShellFabHostState extends State<ShellFabHost> {
  final _registry = ShellFabRegistry();

  @override
  void dispose() {
    _registry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ShellFabScope(registry: _registry, child: widget.child);
}

/// Offers [action] as the shell's floating button while this page's route is
/// the current location; null offers none. Outside a shell it does nothing.
class ShellFab extends StatefulWidget {
  const ShellFab({super.key, required this.action, required this.child});

  final ShellFabAction? action;
  final Widget child;

  @override
  State<ShellFab> createState() => _ShellFabState();
}

class _ShellFabState extends State<ShellFab> {
  ShellFabRegistry? _registry;
  String? _location;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = ShellFabScope.maybeOf(context);
    final location = registry == null ? null : _locationOf(context);
    if (registry != _registry || location != _location) {
      _clear();
      _registry = registry;
      _location = location;
    }
    _publish();
  }

  @override
  void didUpdateWidget(ShellFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _publish();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  /// After the frame: the shell is an ancestor and must not be marked dirty
  /// while this subtree builds.
  void _publish() {
    final registry = _registry;
    final location = _location;
    if (registry == null || location == null) return;
    final action = widget.action;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _registry != registry || _location != location) return;
      registry._set(location, this, action);
    });
  }

  void _clear() {
    final registry = _registry;
    final location = _location;
    if (registry == null || location == null) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => registry._set(location, this, null),
    );
  }

  /// The location of this page's route; null when it is not a go_router
  /// page (a dialog's own navigator).
  static String? _locationOf(BuildContext context) {
    try {
      return GoRouterState.of(context).matchedLocation;
    } on GoError {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
