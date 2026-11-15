import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../shell_entries.dart';
import '../../../features/premium/presentation/premium_dialog.dart';
import '../app_router.dart';

/// The Premium dialog on the root navigator, when that shell is visible.
/// [premiumPushAllowed] lets a history entry restored without its extra
/// render nothing instead of the dialog.
List<RouteBase> premiumRoutes({
  required bool Function(Object? extra) premiumPushAllowed,
}) => [
  // A dialog over the current page, so it lives on the root navigator
  // outside the shell. Only `push` (with `kShellPushExtra`) opens it: a
  // typed URL, a reload or a cold start lands Home (`_shellsFlagRedirect`).
  if (kVisibleShells.contains(ShellKind.premium))
    GoRoute(
      path: AppRouter.premiumPath,
      // A push restored from web history skips the redirects (go_router
      // re-applies it as is) and loses its extra, so the builder checks
      // again and shows nothing then (security review M-1).
      pageBuilder: (context, state) => premiumPushAllowed(state.extra)
          ? PremiumDialogPage(key: state.pageKey)
          : NoTransitionPage<void>(
              key: state.pageKey,
              child: const _PopOnFirstFrame(),
            ),
    ),
];

/// Pops itself after its first frame: what a `/premium` entry restored from
/// web history renders instead of the dialog, so Back / Forward never reopens
/// it without a tap.
class _PopOnFirstFrame extends StatefulWidget {
  const _PopOnFirstFrame();

  @override
  State<_PopOnFirstFrame> createState() => _PopOnFirstFrameState();
}

class _PopOnFirstFrameState extends State<_PopOnFirstFrame> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) GoRouter.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
