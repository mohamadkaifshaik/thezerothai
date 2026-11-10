import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../shared/widgets/primitives/app_avatar.dart';
import '../../shared/widgets/primitives/app_icon_button.dart';
import '../feature_flags/feature_flags.dart';
import '../feature_flags/ui_shell_feature_flag.dart';
import '../theme/app_theme.dart';
import 'app_shell_scope.dart';

/// The top bar of a main screen: a row with, on narrow layouts, the account
/// **avatar button** (36dp avatar in a 48dp tap target) that opens the
/// shell's drawer, then the [title] and trailing [actions], over the 1px
/// hairline of the app bar theme.
///
/// The avatar button exists only below 600dp *and* inside the shell (an
/// [AppShellScope]); on wide layouts the navigation rail carries the account
/// chip, and the bar shows just the title.
///
/// With the `ui_shell` flag on (the redesign, ADR-0034):
///
/// * the surface is the page colour at 88 % alpha, so content scrolls faintly
///   under it (decision D4 of the W0 plan: no blur; a blur is costly on the
///   web);
/// * the row is 53dp and **grows with the text scale** instead of scaling the
///   title down. A `Scaffold.appBar` reads [preferredSize] without a
///   `BuildContext`, so build it with [AppTopBar.of], which measures the
///   height from the ambient text scale. The sliver measures it itself;
/// * [wordmark] replaces the title with the "DZEROTH" wordmark (Home).
///
/// With `ui_shell` off the legacy bar is drawn unchanged: 53dp, 92 % alpha,
/// the title block scaled down to fit a fixed row.
///
/// Use [AppTopBar.of] as a `Scaffold.appBar`, or [AppTopBar.sliver] at the
/// top of a `CustomScrollView` (floating and snapping, like the Home feed).
/// [AppTopBar.new] is the fixed 53dp bar; with `ui_shell` on it clips a title
/// block that is taller than the row.
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTopBar({
    super.key,
    this.title,
    this.subtitle,
    this.actions,
    this.showAccountAvatar = true,
    this.centerTitle = false,
    this.wordmark = false,
  }) : _height = null;

  const AppTopBar._({
    super.key,
    this.title,
    this.subtitle,
    this.actions,
    this.showAccountAvatar = true,
    this.centerTitle = false,
    this.wordmark = false,
    required double height,
  }) : _height = height;

  /// The bar sized for the text scale of [context]: the row is [heightOf],
  /// so a large text scale grows the bar instead of shrinking the title.
  /// Call it in `build` (it reads `MediaQuery` and the `ui_shell` flag, so
  /// the caller rebuilds when either changes).
  static AppTopBar of(
    BuildContext context, {
    Key? key,
    String? title,
    String? subtitle,
    List<Widget>? actions,
    bool showAccountAvatar = true,
    bool centerTitle = false,
    bool wordmark = false,
  }) => AppTopBar._(
    key: key,
    title: title,
    subtitle: subtitle,
    actions: actions,
    showAccountAvatar: showAccountAvatar,
    centerTitle: centerTitle,
    wordmark: wordmark,
    height: heightOf(
      context,
      title: title != null,
      subtitle: subtitle != null,
      wordmark: wordmark,
    ),
  );

  /// The row height at the text scale of [context]:
  /// `max(headerRow, textScaler.scale(line heights) + padding)`. Always
  /// [AppSize.headerRow] with `ui_shell` off (the legacy bar is fixed).
  static double heightOf(
    BuildContext context, {
    bool title = true,
    bool subtitle = false,
    bool wordmark = false,
  }) {
    if (!isFeatureEnabled(context, kFeatureUiShell)) return AppSize.headerRow;
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double line(TextStyle? style) {
      if (style == null) return 0;
      return scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.2);
    }

    final text =
        (wordmark
            ? line(AppTextStyles.wordmark(theme))
            : title
            ? line(theme.textTheme.titleLarge)
            : 0.0) +
        (subtitle ? line(theme.textTheme.bodyMedium) : 0.0);
    return math.max(
      AppSize.headerRow,
      (text + _verticalPadding * 2).ceilToDouble(),
    );
  }

  final String? title;

  /// A second, secondary line under the title (the handle, a post count).
  final String? subtitle;

  final List<Widget>? actions;

  /// Whether narrow layouts show the account drawer button. Every primary
  /// destination keeps it: with Profile off the phone bar (ADR-0034) the avatar
  /// is how phones reach Profile and the secondary destinations.
  final bool showAccountAvatar;

  /// Centers the title independently of the leading and trailing controls.
  final bool centerTitle;

  /// With `ui_shell` on, draws the centred "DZEROTH" wordmark instead of the
  /// [title] (Home). The [title] stays the accessible name of the header;
  /// pass no [title] when the screen has a heading of its own, and the
  /// wordmark is then left out of the semantics tree. Ignored with
  /// `ui_shell` off.
  final bool wordmark;

  /// The row height measured by [AppTopBar.of]; null for the fixed bar.
  final double? _height;

  /// The same bar as a floating, snapping sliver.
  static Widget sliver({
    Key? key,
    String? title,
    String? subtitle,
    List<Widget>? actions,
    bool showAccountAvatar = true,
    bool centerTitle = false,
    bool wordmark = false,
  }) => _SliverTopBar(
    key: key,
    title: title,
    subtitle: subtitle,
    actions: actions,
    showAccountAvatar: showAccountAvatar,
    centerTitle: centerTitle,
    wordmark: wordmark,
  );

  @override
  Size get preferredSize => Size.fromHeight(_height ?? AppSize.headerRow);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (!isFeatureEnabled(context, kFeatureUiShell)) {
      return PreferredSize(
        preferredSize: const Size.fromHeight(AppSize.headerRow),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: _legacyAlpha),
            border: Border(bottom: BorderSide(color: colors.outlineVariant)),
          ),
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: AppSize.headerRow,
              // The legacy bar has a fixed height: at a large text scale
              // the title block scales down to fit instead of overflowing.
              child: _BarRow(
                title: title,
                subtitle: subtitle,
                actions: actions,
                showAccountAvatar: showAccountAvatar,
                centerTitle: centerTitle,
                fitText: true,
              ),
            ),
          ),
        ),
      );
    }
    return PreferredSize(
      preferredSize: preferredSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: _alpha),
          border: Border(bottom: BorderSide(color: colors.outlineVariant)),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: preferredSize.height,
            child: _BarRow(
              title: title,
              subtitle: subtitle,
              actions: actions,
              showAccountAvatar: showAccountAvatar,
              centerTitle: centerTitle,
              wordmark: wordmark,
              redesign: true,
              // A bar built without [AppTopBar.of] cannot grow: clip.
              clipText: _height == null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Surface alpha with `ui_shell` on, and the legacy one.
const double _alpha = 0.88;
const double _legacyAlpha = 0.92;

/// Space kept above and below the title block when the bar grows.
const double _verticalPadding = AppSpacing.xs;

/// The wordmark; a brand name, not translatable copy.
const String _wordmark = 'DZEROTH';

class _SliverTopBar extends StatelessWidget {
  const _SliverTopBar({
    super.key,
    this.title,
    this.subtitle,
    this.actions,
    this.showAccountAvatar = true,
    this.centerTitle = false,
    this.wordmark = false,
  });

  final String? title;
  final String? subtitle;
  final List<Widget>? actions;
  final bool showAccountAvatar;
  final bool centerTitle;
  final bool wordmark;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (isFeatureEnabled(context, kFeatureUiShell)) {
      return SliverAppBar(
        floating: true,
        snap: true,
        automaticallyImplyLeading: false,
        // Grows with the text scale, for a title alone too.
        toolbarHeight: AppTopBar.heightOf(
          context,
          title: title != null,
          subtitle: subtitle != null,
          wordmark: wordmark,
        ),
        titleSpacing: 0,
        backgroundColor: colors.surface.withValues(alpha: _alpha),
        // Material's `AppBar` caps the text scale of its title at 1.34; the
        // row has grown to fit, so give the title the ambient scale back.
        title: MediaQuery(
          data: MediaQuery.of(context),
          child: _BarRow(
            title: title,
            subtitle: subtitle,
            actions: actions,
            showAccountAvatar: showAccountAvatar,
            centerTitle: centerTitle,
            wordmark: wordmark,
            redesign: true,
          ),
        ),
      );
    }
    // Legacy: a title plus a subtitle needs more than 53dp at 1.3x; a title
    // alone fits in 53dp.
    final height = subtitle == null
        ? AppSize.headerRow
        : MediaQuery.textScalerOf(context).scale(AppSize.headerRow);
    return SliverAppBar(
      floating: true,
      snap: true,
      automaticallyImplyLeading: false,
      toolbarHeight: height < AppSize.headerRow ? AppSize.headerRow : height,
      titleSpacing: 0,
      backgroundColor: colors.surface.withValues(alpha: _legacyAlpha),
      title: _BarRow(
        title: title,
        subtitle: subtitle,
        actions: actions,
        showAccountAvatar: showAccountAvatar,
        centerTitle: centerTitle,
      ),
    );
  }
}

/// The content of the bar: avatar button, title block, trailing actions.
class _BarRow extends StatelessWidget {
  const _BarRow({
    this.title,
    this.subtitle,
    this.actions,
    this.showAccountAvatar = true,
    this.centerTitle = false,
    this.fitText = false,
    this.wordmark = false,
    this.redesign = false,
    this.clipText = false,
  });

  final String? title;
  final String? subtitle;
  final List<Widget>? actions;
  final bool showAccountAvatar;
  final bool centerTitle;

  /// Legacy only: scale the title block down to the row height.
  final bool fitText;

  /// Redesign only: the wordmark instead of the title.
  final bool wordmark;

  /// `ui_shell` is on.
  final bool redesign;

  /// Redesign only: clip a title block taller than a fixed row.
  final bool clipText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final scope = AppShellScope.maybeOf(context);
    final showAvatar = showAccountAvatar && narrow && scope != null;
    final showWordmark = redesign && wordmark;
    final centered = centerTitle || showWordmark;
    Widget titleBlock(double? width) {
      final block = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showWordmark)
            _Wordmark(label: title)
          else if (title != null)
            Semantics(
              header: true,
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge,
              ),
            ),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      );
      if (clipText) {
        return ClipRect(
          child: OverflowBox(
            minHeight: 0,
            maxHeight: double.infinity,
            alignment: centered ? Alignment.center : Alignment.centerLeft,
            child: block,
          ),
        );
      }
      if (width == null) return block;
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: SizedBox(width: width, child: block),
      );
    }

    final leading = showAvatar
        ? const Padding(
            padding: EdgeInsets.only(left: AppSpacing.sm),
            child: AppAvatarButton(),
          )
        : const SizedBox(width: AppSpacing.md);
    // Raised actions are discs: they need more air from the screen edge.
    final endGap = SizedBox(width: redesign ? AppSpacing.sm : AppSpacing.xs);
    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [...?actions, endGap],
    );
    if (centered) {
      return Row(
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: leading),
          ),
          Expanded(
            flex: 2,
            child: LayoutBuilder(
              builder: (context, constraints) => Center(
                child: titleBlock(fitText ? constraints.maxWidth : null),
              ),
            ),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: trailing),
          ),
        ],
      );
    }
    return Row(
      children: [
        leading,
        if (showAvatar) const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: fitText
              ? LayoutBuilder(
                  builder: (context, box) => titleBlock(box.maxWidth),
                )
              : titleBlock(null),
        ),
        ...?actions,
        endGap,
      ],
    );
  }
}

/// The "DZEROTH" wordmark of the Home bar. [label] (the screen's name) is its
/// accessible name and makes it the screen's header; without one the screen
/// has a heading of its own and the wordmark is decoration.
class _Wordmark extends StatelessWidget {
  const _Wordmark({this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      _wordmark,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.fade,
      style: AppTextStyles.wordmark(Theme.of(context)),
    );
    if (label == null) return ExcludeSemantics(child: text);
    return Semantics(
      header: true,
      label: label,
      excludeSemantics: true,
      child: text,
    );
  }
}

/// A trailing action of the top bar: a raised [AppIconButton] with `ui_shell`
/// on, the plain icon button of the legacy bar with it off.
class AppTopBarAction extends StatelessWidget {
  const AppTopBarAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeatureUiShell)) {
      return IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
      );
    }
    return AppIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
      raised: true,
    );
  }
}

/// The 36dp avatar in a 48dp tap target; opens the drawer. Public so other
/// header rows (the Explore search row) can lead with it on narrow layouts;
/// it needs an [AppShellScope] above it (so it exists with `ui_shell` only).
class AppAvatarButton extends StatelessWidget {
  const AppAvatarButton({super.key});

  /// Diameter of the avatar inside the 48dp target.
  static const double avatarSize = 36;

  @override
  Widget build(BuildContext context) {
    final scope = AppShellScope.maybeOf(context)!;
    final avatarUrl = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.avatarThumbUrl ?? '',
    );
    return Semantics(
      button: true,
      label: 'Open account menu',
      excludeSemantics: true,
      onTap: scope.openDrawer,
      child: InkResponse(
        onTap: scope.openDrawer,
        radius: AppSpacing.minTapTarget / 2,
        child: SizedBox(
          width: AppSpacing.minTapTarget,
          height: AppSpacing.minTapTarget,
          child: Center(
            child: AppAvatar(url: avatarUrl, radius: avatarSize / 2),
          ),
        ),
      ),
    );
  }
}
