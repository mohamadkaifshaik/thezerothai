import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/feature_flags/ui_shell_feature_flag.dart';
import '../../../core/router/app_router.dart';
import 'shells_feature_flag.dart';

/// The read-only "shell" destinations of wave W8: placeholders for features
/// that need a future approved ADR (payments, ads, calls).
enum ShellKind { creatorStudio, premium, advertise, calls }

/// Which shells exist at all (plan decision F1): a shell outside this set has
/// no entry point and no route. A code decision, not a ramp decision; changing
/// it is a one-line PR. Not `final` only so tests can narrow it (reset it in
/// a `tearDown`); production code never assigns it.
Set<ShellKind> kVisibleShells = Set.unmodifiable(ShellKind.values);

/// What [AppRouter.premiumPath] must be pushed with: it is a dialog reachable
/// only by `push` from inside the app. A typed URL, a reload or a cold start
/// carries no such extra and lands on Home.
const kShellPushExtra = 'shell-push';

/// One entry point to a shell: a drawer row (under 600 dp) and an item of the
/// rail's More menu (600 dp and up).
class ShellEntry {
  const ShellEntry({
    required this.kind,
    required this.icon,
    required this.label,
    required this.path,
    this.opensAsDialog = false,
  });

  final ShellKind kind;
  final IconData icon;
  final String label;
  final String path;

  /// Premium only: the path is pushed as a dialog over the current page
  /// instead of replacing it.
  final bool opensAsDialog;
}

/// Every shell, in display order. The only place a shell's icon and label are
/// named.
const List<ShellEntry> kShellEntries = [
  ShellEntry(
    kind: ShellKind.creatorStudio,
    icon: Icons.insights_outlined,
    label: 'Creator tools',
    path: AppRouter.creatorStudioPath,
  ),
  ShellEntry(
    kind: ShellKind.premium,
    icon: Icons.workspace_premium_outlined,
    label: 'Premium',
    path: AppRouter.premiumPath,
    opensAsDialog: true,
  ),
  ShellEntry(
    kind: ShellKind.advertise,
    icon: Icons.campaign_outlined,
    label: 'Advertise',
    path: AppRouter.advertisePath,
  ),
  ShellEntry(
    kind: ShellKind.calls,
    icon: Icons.call_outlined,
    label: 'Calls',
    path: AppRouter.callsPath,
  ),
];

/// The entries to offer the caller: the visible shells ([kVisibleShells]),
/// only when `shells` **and** `ui_shell` are both on (plan decision F6).
/// Empty otherwise. Rebuilds the caller when a flag changes; 0 RPCs.
List<ShellEntry> shellEntriesFor(BuildContext context) {
  final shells = isFeatureEnabled(context, kFeatureShells);
  final newShell = isFeatureEnabled(context, kFeatureUiShell);
  if (!shells || !newShell) return const [];
  return [
    for (final entry in kShellEntries)
      if (kVisibleShells.contains(entry.kind)) entry,
  ];
}

/// Opens [entry]: `go` to its page, or `push` the dialog for Premium.
void openShellEntry(BuildContext context, ShellEntry entry) {
  if (entry.opensAsDialog) {
    context.push(entry.path, extra: kShellPushExtra);
  } else {
    context.go(entry.path);
  }
}
