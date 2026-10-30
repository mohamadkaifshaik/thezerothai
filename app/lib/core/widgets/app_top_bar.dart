import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../shared/widgets/app_avatar.dart';
import '../theme/app_theme.dart';
import 'app_shell_scope.dart';

/// The top bar of a main screen: a 53dp row with, on narrow layouts, the
/// account **avatar button** (32dp avatar in a 48dp tap target) that opens the
/// shell's drawer, then the [title] and trailing [actions], over the 1px
/// hairline of the app bar theme.
///
/// The avatar button exists only below 600dp *and* inside the shell (an
/// [AppShellScope]); on wide layouts the navigation rail carries the account
/// chip, and the bar shows just the title.
///
/// The surface is the page colour at 92 % alpha, so content scrolls faintly
/// under it like on X (decision D4 of `docs/plans/ui-w0-foundations.md`: no
/// blur by default; a blur is costly on the web).
///
/// Use [AppTopBar.new] as a `Scaffold.appBar`, or [AppTopBar.sliver] at the
/// top of a `CustomScrollView` (floating and snapping, like the Home feed).
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTopBar({super.key, this.title, this.subtitle, this.actions});

  final String? title;

  /// A second, secondary line under the title (the handle, a post count).
  final String? subtitle;

  final List<Widget>? actions;

  /// The same bar as a floating, snapping sliver.
  static Widget sliver({
    Key? key,
    String? title,
    String? subtitle,
    List<Widget>? actions,
  }) => _SliverTopBar(
    key: key,
    title: title,
    subtitle: subtitle,
    actions: actions,
  );

  @override
  Size get preferredSize => const Size.fromHeight(AppSize.headerRow);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
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
            height: AppSize.headerRow,
            // A `Scaffold.appBar` has a fixed height: at a large text scale
            // the title block scales down to fit instead of overflowing.
            child: _BarRow(
              title: title,
              subtitle: subtitle,
              actions: actions,
              fitText: true,
            ),
          ),
        ),
      ),
    );
  }
}

const double _alpha = 0.92;

class _SliverTopBar extends StatelessWidget {
  const _SliverTopBar({super.key, this.title, this.subtitle, this.actions});

  final String? title;
  final String? subtitle;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // A sliver can grow with the text scale (a title plus a subtitle needs
    // more than 53dp at 1.3x); a title alone fits in 53dp.
    final height = subtitle == null
        ? AppSize.headerRow
        : MediaQuery.textScalerOf(context).scale(AppSize.headerRow);
    return SliverAppBar(
      floating: true,
      snap: true,
      automaticallyImplyLeading: false,
      toolbarHeight: height < AppSize.headerRow ? AppSize.headerRow : height,
      titleSpacing: 0,
      backgroundColor: colors.surface.withValues(alpha: _alpha),
      title: _BarRow(title: title, subtitle: subtitle, actions: actions),
    );
  }
}

/// The content of the bar: avatar button, title block, trailing actions.
class _BarRow extends StatelessWidget {
  const _BarRow({
    this.title,
    this.subtitle,
    this.actions,
    this.fitText = false,
  });

  final String? title;
  final String? subtitle;
  final List<Widget>? actions;

  /// Scale the title block down to the row height (fixed-height bars).
  final bool fitText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final scope = AppShellScope.maybeOf(context);
    final showAvatar = narrow && scope != null;
    Widget titleBlock(double? width) {
      final block = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
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
      if (width == null) return block;
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: SizedBox(width: width, child: block),
      );
    }

    return Row(
      children: [
        if (showAvatar)
          const Padding(
            padding: EdgeInsets.only(left: AppSpacing.sm),
            child: AppAvatarButton(),
          )
        else
          const SizedBox(width: AppSpacing.md),
        if (showAvatar) const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: fitText
              ? LayoutBuilder(
                  builder: (context, box) => titleBlock(box.maxWidth),
                )
              : titleBlock(null),
        ),
        ...?actions,
        const SizedBox(width: AppSpacing.xs),
      ],
    );
  }
}

/// The 32dp avatar in a 48dp tap target; opens the drawer. Public so other
/// header rows (the Explore search row) can lead with it on narrow layouts;
/// it needs an [AppShellScope] above it.
class AppAvatarButton extends StatelessWidget {
  const AppAvatarButton({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppShellScope.maybeOf(context)!;
    final avatarUrl = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.avatarThumbUrl ?? '',
    );
    return Semantics(
      button: true,
      label: 'Account menu',
      excludeSemantics: true,
      onTap: scope.openDrawer,
      child: InkResponse(
        onTap: scope.openDrawer,
        radius: AppSpacing.minTapTarget / 2,
        child: SizedBox(
          width: AppSpacing.minTapTarget,
          height: AppSpacing.minTapTarget,
          child: Center(
            child: AppAvatar(url: avatarUrl, radius: AppSize.avatarSm / 2),
          ),
        ),
      ),
    );
  }
}
