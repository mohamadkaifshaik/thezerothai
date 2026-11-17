import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'app_router.dart';

/// Makes the system back gesture/button land on Home instead of closing the
/// app, for screens reached with `context.go` (the navigation bar, the drawer):
/// those replace the stack, so there is nothing to pop and Android would exit.
///
/// When [enabled], back first pops a page pushed over this screen (if any),
/// otherwise goes to [AppRouter.homePath]. When not [enabled] (Home itself,
/// or a screen that handles back on its own) back behaves normally, so on Home
/// it exits the app.
class BackToHome extends StatelessWidget {
  const BackToHome({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !enabled,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final router = GoRouter.maybeOf(context);
        if (router == null) return;
        if (router.canPop()) {
          router.pop();
        } else {
          router.go(AppRouter.homePath);
        }
      },
      child: child,
    );
  }
}
