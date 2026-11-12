import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import 'app_accent_headline.dart';
import 'app_pill_button.dart';

/// One action of an [AppFormPage].
@immutable
class AppFormAction {
  const AppFormAction({
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.busy = false,
    this.busySemanticsLabel,
  });

  final String label;

  /// Null shows the action disabled.
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final IconData? icon;
  final bool busy;
  final String? busySemanticsLabel;
}

/// A single-purpose page (Change handle, Download my data, Delete account):
/// the app bar, a [eyebrow] kicker (upper-cased by the caller) over the headline, the [children], then
/// the actions. One page, two arrangements from the mocks: below 600 dp the
/// actions are pinned to the bottom as full-width pills (the [secondary] one
/// quiet, as a text button); from 600 dp they follow the content, the
/// [secondary] one first as an outline pill.
class AppFormPage extends StatelessWidget {
  const AppFormPage({
    super.key,
    required this.title,
    required this.headlineLead,
    this.headlineAccent,
    this.headlineTail = '.',
    required this.children,
    this.leading,
    this.eyebrow,
    this.eyebrowColor,
    this.primary,
    this.secondary,
  });

  final String title;

  /// The display headline: [headlineLead], the accented [headlineAccent]
  /// (none: a plain headline, with no tail) and [headlineTail].
  final String headlineLead;
  final String? headlineAccent;
  final String headlineTail;
  final List<Widget> children;

  /// The app bar's leading widget; null keeps its default.
  final Widget? leading;
  final String? eyebrow;

  /// Defaults to the accent text colour.
  final Color? eyebrowColor;
  final AppFormAction? primary;
  final AppFormAction? secondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final size = phone
        ? AppAccountLayout.phoneHeadline
        : AppAccountLayout.wideHeadline;
    final headline = headlineAccent == null
        ? AppAccentHeadline.plain(headlineLead, size: size)
        : AppAccentHeadline(
            lead: headlineLead,
            accent: headlineAccent!,
            size: size,
            tail: headlineTail,
          );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (eyebrow != null) ...[
          Text(
            eyebrow!,
            style: AppTextStyles.eyebrow(theme)
                .copyWith(color: eyebrowColor ?? context.appColors.accentText),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        headline,
        for (final child in children) ...[
          const SizedBox(height: AppAccountLayout.sectionGap),
          child,
        ],
      ],
    );
    final actions = _actions(phone);
    return Scaffold(
      appBar: AppBar(leading: leading, title: Text(title)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          // 680 as a leaf in the tablet shell (the readable column); 600
          // everywhere else, including routes outside the shell.
          constraints: BoxConstraints(
            maxWidth: (ShellGeometry.maybeOf(context)?.tablet ?? false)
                ? AppSize.readableMax
                : AppSize.contentMax,
          ),
          // On the phone the page fills the screen, so the actions sit at the
          // bottom (the mock's `margin-top: auto`); it scrolls when it cannot
          // fit. Wider layouts keep the actions under the content.
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                AppAccountLayout.pagePaddingH,
                AppAccountLayout.pagePaddingTop,
                AppAccountLayout.pagePaddingH,
                // The floating bar's inset (`ui_shell`); 0 under the docked
                // bar.
                AppAccountLayout.pagePaddingBottom +
                    MediaQuery.paddingOf(context).bottom,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: !phone
                      ? 0
                      : math.max(
                          0,
                          constraints.maxHeight -
                              AppAccountLayout.pagePaddingTop -
                              AppAccountLayout.pagePaddingBottom -
                              MediaQuery.paddingOf(context).bottom,
                        ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    content,
                    if (actions != null)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: AppAccountLayout.actionsTop,
                        ),
                        child: actions,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget? _actions(bool phone) {
    final first = primary;
    final second = secondary;
    if (first == null && second == null) return null;
    Widget pill(
      AppFormAction action, {
      AppButtonVariant? variant,
      AppButtonSize size = AppButtonSize.regular,
    }) => AppPillButton(
      label: action.label,
      onPressed: action.onPressed,
      variant: variant ?? action.variant,
      size: size,
      icon: action.icon,
      busy: action.busy,
      busySemanticsLabel: action.busySemanticsLabel,
    );
    if (phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (first != null) pill(first, size: AppButtonSize.large),
          if (first != null && second != null)
            const SizedBox(height: AppAccountLayout.actionsGap),
          if (second != null) pill(second, variant: AppButtonVariant.text),
        ],
      );
    }
    return Wrap(
      spacing: AppAccountLayout.actionsGap,
      runSpacing: AppAccountLayout.actionsGap,
      children: [
        if (second != null) pill(second, variant: AppButtonVariant.outline),
        if (first != null) pill(first),
      ],
    );
  }
}
