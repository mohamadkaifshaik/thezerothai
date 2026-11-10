import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
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
/// body built from [AppDialog] or [AppConfirmDialog]. The dialog is centred on
/// the window; a later change can centre it on the content area without
/// touching call sites.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 560,
  bool destructive = false,
  bool barrierDismissible = true,
}) {
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

class _AppDialogFrame extends StatelessWidget {
  const _AppDialogFrame({
    required this.maxWidth,
    required this.destructive,
    required this.child,
  });

  final double maxWidth;
  final bool destructive;
  final Widget child;

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
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
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
