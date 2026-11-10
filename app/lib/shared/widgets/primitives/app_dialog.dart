import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/tablet_modal.dart';
import 'app_pill_button.dart';

/// Shows a dialog on the root navigator (above the shell) with the redesign
/// frame: the scrim as the barrier, a safe area, a width of
/// `min(maxWidth, W - 48)` and a height that stops above the keyboard.
///
/// Focus is the route's: it moves into the dialog, Tab cycles inside it,
/// Escape (and the system back) closes it when [barrierDismissible], and focus
/// returns to whatever held it before the dialog opened.
///
/// [destructive] announces the dialog as an alert dialog. Call sites pass a
/// body built from [AppDialog] or [AppConfirmDialog].
///
/// On the tablet layout (`ui_shell` + `ui_tablet`, 600-1199 dp) the dialog is
/// centred on the content area instead of the window, `min(maxWidth, C - 48)`
/// wide ([TabletModalHost]); the barrier still covers the whole window, rail
/// included. Elsewhere it is centred on the window, as before.
///
/// [host] overrides the tablet presentation resolved from [context]: a
/// caller that opens the dialog from a navigator's own context after an
/// `await` resolves it from its own context first
/// (`TabletModalHost.of(context)`) and passes it here.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 560,
  bool destructive = false,
  bool barrierDismissible = true,
  TabletModalHost? host,
}) {
  final resolved = host ?? TabletModalHost.of(context);
  if (resolved != null) {
    return showDialog<T>(
      context: context,
      useRootNavigator: true,
      // The insets carry the safe area (the content area starts past it).
      useSafeArea: false,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) => TabletModalScope(
        host: resolved,
        child: Builder(
          builder: (context) => _AppDialogFrame(
            maxWidth: maxWidth,
            destructive: destructive,
            insetPadding: resolved.dialogInsets(context),
            child: builder(context),
          ),
        ),
      ),
    );
  }
  return showDialog<T>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) => _AppDialogFrame(
      maxWidth: maxWidth,
      destructive: destructive,
      child: builder(dialogContext),
    ),
  );
}

/// Shows a dialog whose [builder] returns the whole Material dialog (an
/// `AlertDialog`, a `Dialog`), for the call sites that predate [AppDialog].
///
/// Outside the tablet layout this is exactly
/// `showDialog(context:, barrierDismissible:, builder:)`, so phones, desktop
/// and the 600-1199 dp layout with `ui_tablet` off do not change (ruling
/// R-1).
///
/// On the tablet layout (`ui_shell` + `ui_tablet`, 600-1199 dp) it goes on
/// the root navigator with the barrier over the whole window (rail
/// included), and the dialog is centred on the content area, between
/// [minWidth] and `min(maxWidth, C - 48)` wide, its height at most
/// `H - keyboard - 48` (tablet plan section 5.4). The defaults are the
/// confirm and alert range, 280-400; a form dialog passes its own width.
/// The dialog picks both up from the ambient `DialogTheme`, so a call site
/// that sets `insetPadding` or `constraints` itself keeps its own. [host] is
/// as for [showAppDialog].
Future<T?> showAppMaterialDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double minWidth = AppSize.alertDialogMin,
  double maxWidth = AppSize.alertDialogMax,
  bool barrierDismissible = true,
  TabletModalHost? host,
}) {
  final resolved = host ?? TabletModalHost.of(context);
  if (resolved == null) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: builder,
    );
  }
  return showDialog<T>(
    context: context,
    useRootNavigator: true,
    useSafeArea: false,
    barrierDismissible: barrierDismissible,
    builder: (_) => TabletModalScope(
      host: resolved,
      child: Builder(
        builder: (context) => DialogTheme(
          data: DialogTheme.of(context).copyWith(
            insetPadding: resolved.dialogInsets(context),
            constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
          ),
          child: Builder(builder: builder),
        ),
      ),
    ),
  );
}

class _AppDialogFrame extends StatelessWidget {
  const _AppDialogFrame({
    required this.maxWidth,
    required this.destructive,
    required this.child,
    this.insetPadding = const EdgeInsets.all(AppSpacing.lg),
  });

  final double maxWidth;
  final bool destructive;
  final Widget child;

  /// Space around the dialog (the keyboard inset is added to it).
  final EdgeInsets insetPadding;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(AppRadius.card);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      // Dialog adds the keyboard inset to this, so the height stops above it.
      insetPadding: insetPadding,
      constraints: BoxConstraints(maxWidth: maxWidth),
      semanticsRole: destructive
          ? SemanticsRole.alertDialog
          : SemanticsRole.dialog,
      // The shadow is AppShadows.brand: DialogThemeData cannot hold it.
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: radius,
          boxShadow: AppShadows.brand,
          border: dark ? Border.all(color: colors.hairline) : null,
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

/// The content of a dialog: a title (a heading, and the name of the dialog), a
/// scrolling [body] and [actions].
///
/// [actions] are listed in reading order, dismissive first (Cancel, then
/// Save). Wide dialogs lay them in a row at the end; narrow ones stack them
/// full width with the primary action on top, as in the designs.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    this.body,
    this.actions = const [],
    this.eyebrow,
  });

  final String title;
  final Widget? body;
  final List<Widget> actions;

  /// Small kicker above the title, in the danger colour.
  final String? eyebrow;

  /// Below this inner width the actions stack.
  static const double _stackBelow = 420;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title and body scroll together; the actions stay in reach.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (eyebrow != null) ...[
                      Text(
                        eyebrow!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    Semantics(
                      header: true,
                      child: Text(title, style: theme.textTheme.headlineSmall),
                    ),
                    if (body != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      DefaultTextStyle.merge(
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        child: body!,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              LayoutBuilder(
                builder: (context, box) {
                  if (box.maxWidth < _stackBelow) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = actions.length - 1; i >= 0; i--) ...[
                          actions[i],
                          if (i > 0) const SizedBox(height: AppSpacing.sm),
                        ],
                      ],
                    );
                  }
                  return Wrap(
                    alignment: WrapAlignment.end,
                    runAlignment: WrapAlignment.end,
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: actions,
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A confirm dialog: pops `true` on confirm and `false` on cancel (`null` when
/// dismissed). Use [AppConfirmDialog.show].
///
/// A destructive confirm uses the danger button, is announced as an alert
/// dialog, and its cancel button takes the initial focus so that Enter never
/// deletes. A plain confirm focuses its confirm button.
class AppConfirmDialog extends StatelessWidget {
  const AppConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    this.destructive = false,
    this.eyebrow,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final String? eyebrow;

  /// Shows the confirm dialog and resolves to `true` only when confirmed.
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    String cancelLabel = 'Cancel',
    bool destructive = false,
    String? eyebrow,
  }) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      destructive: destructive,
      builder: (_) => AppConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: destructive,
        eyebrow: eyebrow,
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final navigator = Navigator.of(context);
    return AppDialog(
      title: title,
      eyebrow: eyebrow,
      body: Text(message),
      actions: [
        AppPillButton(
          label: cancelLabel,
          variant: AppButtonVariant.outline,
          autofocus: destructive,
          onPressed: () => navigator.pop(false),
        ),
        AppPillButton(
          label: confirmLabel,
          variant: destructive
              ? AppButtonVariant.danger
              : AppButtonVariant.primary,
          autofocus: !destructive,
          onPressed: () => navigator.pop(true),
        ),
      ],
    );
  }
}
