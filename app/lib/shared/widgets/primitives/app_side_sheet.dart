import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';

/// Shows [builder] in a modal side sheet at the end edge of the window
/// (tablet plan section 4.2, code SS: the chat info sheet at 600-1199dp).
///
/// - [width] wide ([AppSize.sideSheet], 360), at most the window, the full
///   window height; on the root navigator, so it sits over the rail and any
///   split page.
/// - The scrim barrier covers the whole window; a tap on it, Escape and the
///   system back close the sheet. Focus moves into the sheet, Tab stays in
///   it, and focus returns to the invoker when it closes (the route's focus
///   scope).
/// - It slides in from the end edge (the left in RTL), with no motion when
///   the platform asks for reduced motion. The sheet pads by the top, bottom
///   and end safe-area insets.
/// - [semanticLabel] names the sheet, announced as a dialog.
///
/// The sheet's content pops its own result (`Navigator.pop(context, value)`);
/// a caller that runs a flow for the result does so from its own context
/// after the sheet has closed.
Future<T?> showAppSideSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required String semanticLabel,
  double width = AppSize.sideSheet,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: context.appColors.scrim,
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 220),
    // The sheet slides on its own (below); the page itself does not fade.
    transitionBuilder: (context, animation, secondary, child) => child,
    pageBuilder: (sheetContext, animation, _) => _AppSideSheet(
      width: width,
      semanticLabel: semanticLabel,
      animation: animation,
      child: Builder(builder: builder),
    ),
  );
}

class _AppSideSheet extends StatelessWidget {
  const _AppSideSheet({
    required this.width,
    required this.semanticLabel,
    required this.animation,
    required this.child,
  });

  final double width;
  final String semanticLabel;
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final theme = Theme.of(context);
    final colors = context.appColors;
    final dark = theme.brightness == Brightness.dark;
    final sheet = SizedBox(
      width: math.min(width, size.width),
      height: size.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          boxShadow: AppShadows.brand,
          border: dark
              ? BorderDirectional(start: BorderSide(color: colors.hairline))
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          // The end edge, top and bottom insets; the start edge faces the
          // window, not a screen edge.
          child: SafeArea(
            left: rtl,
            right: !rtl,
            child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              role: SemanticsRole.dialog,
              label: semanticLabel,
              // Escape closes the sheet even when its content has a
              // `Scaffold`: the Scaffold's drawer `DismissIntent` action
              // would otherwise take the key first and, with no drawer
              // open, do nothing (the photo viewer's post sheet).
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): () =>
                      Navigator.of(context).maybePop(),
                },
                child: _FocusIntoSheet(child: child),
              ),
            ),
          ),
        ),
      ),
    );
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: SlideTransition(
        position:
            Tween<Offset>(
              begin: Offset(rtl ? -1 : 1, 0),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: sheet,
      ),
    );
  }
}

/// Moves focus to the first focusable item of the sheet once it is built,
/// unless something inside already holds it.
class _FocusIntoSheet extends StatefulWidget {
  const _FocusIntoSheet({required this.child});

  final Widget child;

  @override
  State<_FocusIntoSheet> createState() => _FocusIntoSheetState();
}

class _FocusIntoSheetState extends State<_FocusIntoSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scope = FocusScope.of(context);
      final current = FocusManager.instance.primaryFocus;
      final inside =
          current != null &&
          current != scope &&
          current.ancestors.contains(scope);
      if (!inside) scope.nextFocus();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The header of a side sheet: its [title] (a heading) and a Close button
/// (48dp target).
class AppSideSheetHeader extends StatelessWidget {
  const AppSideSheetHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSize.headerRow),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: AppSpacing.md,
          end: AppSpacing.xs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, style: theme.textTheme.titleLarge),
              ),
            ),
            IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }
}
