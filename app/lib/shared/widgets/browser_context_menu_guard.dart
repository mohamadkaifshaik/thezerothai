import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What [BrowserContextMenuGuard] switches. The real one is Flutter's
/// [BrowserContextMenu] (web only); tests pass a fake.
abstract interface class BrowserContextMenuToggle {
  Future<void> disable();
  Future<void> enable();
}

class _PlatformToggle implements BrowserContextMenuToggle {
  const _PlatformToggle();

  @override
  Future<void> disable() => BrowserContextMenu.disableContextMenu();

  @override
  Future<void> enable() => BrowserContextMenu.enableContextMenu();
}

/// Turns the browser's own right-click menu off while the pointer is over
/// [child], so an app menu opened by a secondary click (W7-18: "Report
/// message" on a peer's bubble) is not shown on top of it. On the web
/// Flutter leaves the browser menu enabled; elsewhere this widget does
/// nothing and adds no layer.
///
/// - Scoped to [child] on purpose: a text field elsewhere on the page keeps
///   the browser's copy / paste menu.
/// - Several guards share one count, so moving from one guarded widget to the
///   next never leaves the menu enabled over the second (or disabled outside
///   both). The menu is enabled again when the last guard is left or
///   disposed (a widget removed under the pointer sends no exit).
///   Leaving the last guarded widget re-enables the browser menu even if other
///   code had disabled it on purpose: the guard keeps no memory of the state it
///   found.
/// - Not verified in a real browser yet (the tests use a fake toggle).
class BrowserContextMenuGuard extends StatefulWidget {
  const BrowserContextMenuGuard({super.key, required this.child});

  final Widget child;

  /// Test seam: replaces the web-only platform toggle (and its `kIsWeb`
  /// guard). Reset it to null in `tearDown`.
  @visibleForTesting
  static BrowserContextMenuToggle? debugToggle;

  /// Test seam: forgets the shared hover count between tests.
  @visibleForTesting
  static void debugReset() {
    debugToggle = null;
    _hovering = 0;
  }

  static int _hovering = 0;

  @override
  State<BrowserContextMenuGuard> createState() =>
      _BrowserContextMenuGuardState();
}

class _BrowserContextMenuGuardState extends State<BrowserContextMenuGuard> {
  BrowserContextMenuToggle? _held;

  BrowserContextMenuToggle? get _toggle =>
      BrowserContextMenuGuard.debugToggle ??
      (kIsWeb ? const _PlatformToggle() : null);

  void _enter(PointerEnterEvent event) {
    if (_held != null) return;
    final toggle = _toggle;
    if (toggle == null) return;
    _held = toggle;
    if (++BrowserContextMenuGuard._hovering == 1) _fire(toggle.disable());
  }

  void _exit(PointerExitEvent event) => _release();

  void _release() {
    final toggle = _held;
    if (toggle == null) return;
    _held = null;
    if (--BrowserContextMenuGuard._hovering == 0) _fire(toggle.enable());
  }

  /// The platform call is best effort: a failure leaves the browser menu as
  /// it was, which is only a cosmetic double menu.
  void _fire(Future<void> call) => unawaited(call.catchError((Object _) {}));

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_toggle == null) return widget.child;
    return MouseRegion(onEnter: _enter, onExit: _exit, child: widget.child);
  }
}
