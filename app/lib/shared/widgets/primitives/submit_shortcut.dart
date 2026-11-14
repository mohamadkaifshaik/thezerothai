import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Ctrl+Enter (Windows, Linux) or Cmd+Enter (macOS) runs [onSubmit] while
/// focus is anywhere inside [child] (the composers' text fields).
///
/// [canSubmit] is asked at key time, never captured at build: it must say
/// false while the button is disabled or a send is in flight, so the shortcut
/// can never do what the button cannot. Plain Enter and Shift+Enter are not
/// bound and keep their meaning (a new line).
class SubmitShortcut extends StatelessWidget {
  const SubmitShortcut({
    super.key,
    required this.canSubmit,
    required this.onSubmit,
    required this.child,
  });

  final bool Function() canSubmit;
  final VoidCallback onSubmit;
  final Widget child;

  void _run() {
    if (canSubmit()) onSubmit();
  }

  @override
  Widget build(BuildContext context) {
    // `includeSemantics: false`: the key handler's focus node must not add a
    // semantics node over the screen (it would merge the labels below it).
    return Shortcuts(
      includeSemantics: false,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter, control: true):
            _SubmitIntent(),
        SingleActivator(LogicalKeyboardKey.enter, meta: true): _SubmitIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
            _SubmitIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true):
            _SubmitIntent(),
      },
      child: Actions(
        actions: {
          _SubmitIntent: CallbackAction<_SubmitIntent>(
            onInvoke: (_) {
              _run();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

class _SubmitIntent extends Intent {
  const _SubmitIntent();
}
