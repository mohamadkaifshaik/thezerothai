part of 'profile_header.dart';

/// The numbers of one hero look: phone (< 600dp, the dzeroth-mobile Profile
/// mock) or wide (tablet and desktop share one hero in their mocks).
class _HeroMetrics {
  const _HeroMetrics._({
    required this.phone,
    required this.paddingH,
    required this.paddingTop,
    required this.paddingBottom,
    required this.gap,
    required this.chipGap,
    required this.avatar,
    required this.avatarGap,
    required this.nameSize,
    required this.handleSize,
    required this.bioSize,
    required this.statValueSize,
    required this.statLabelSize,
    required this.statsPaddingV,
    required this.buttonHeight,
    required this.buttonGap,
    required this.iconButton,
    required this.rings,
    required this.ringsFromTopEnd,
  });

  static const _phone = _HeroMetrics._(
    phone: true,
    paddingH: AppProfileLayout.phonePaddingH,
    paddingTop: AppProfileLayout.phonePaddingTop,
    paddingBottom: AppProfileLayout.phonePaddingBottom,
    gap: AppProfileLayout.phoneGap,
    chipGap: AppProfileLayout.phoneChipGap,
    avatar: AppProfileLayout.phoneAvatar,
    avatarGap: AppProfileLayout.phoneAvatarGap,
    nameSize: AppProfileLayout.phoneNameSize,
    handleSize: AppProfileLayout.phoneHandleSize,
    bioSize: AppProfileLayout.phoneBioSize,
    statValueSize: AppProfileLayout.phoneStatValueSize,
    statLabelSize: AppProfileLayout.phoneStatLabelSize,
    statsPaddingV: AppProfileLayout.phoneStatsPaddingV,
    buttonHeight: AppProfileLayout.phoneButtonHeight,
    buttonGap: AppProfileLayout.phoneButtonGap,
    iconButton: AppProfileLayout.phoneIconButton,
    rings: AppProfileLayout.phoneRings,
    ringsFromTopEnd: AppProfileLayout.phoneRingsFromTopEnd,
  );

  static const _wide = _HeroMetrics._(
    phone: false,
    paddingH: AppProfileLayout.widePaddingH,
    paddingTop: AppProfileLayout.widePaddingTop,
    paddingBottom: AppProfileLayout.widePaddingBottom,
    gap: AppProfileLayout.wideGap,
    chipGap: AppProfileLayout.wideChipGap,
    avatar: AppProfileLayout.wideAvatar,
    avatarGap: AppProfileLayout.wideAvatarGap,
    nameSize: AppProfileLayout.wideNameSize,
    handleSize: AppProfileLayout.wideHandleSize,
    bioSize: AppProfileLayout.wideBioSize,
    statValueSize: AppProfileLayout.wideStatValueSize,
    statLabelSize: AppProfileLayout.wideStatLabelSize,
    statsPaddingV: AppProfileLayout.wideStatsPaddingV,
    buttonHeight: AppProfileLayout.wideButtonHeight,
    buttonGap: AppProfileLayout.wideButtonGap,
    iconButton: AppProfileLayout.wideIconButton,
    rings: AppProfileLayout.wideRings,
    ringsFromTopEnd: AppProfileLayout.wideRingsFromTopEnd,
  );

  /// By the width the hero is given (a narrow preview gets the phone look,
  /// the profile in any pane of 600dp or more the wide one).
  static _HeroMetrics forWidth(double width) =>
      width < AppBreakpoints.mobile ? _phone : _wide;

  final bool phone;
  final double paddingH;
  final double paddingTop;
  final double paddingBottom;
  final double gap;
  final double chipGap;
  final double avatar;
  final double avatarGap;
  final double nameSize;
  final double handleSize;
  final double bioSize;
  final double statValueSize;
  final double statLabelSize;
  final double statsPaddingV;
  final double buttonHeight;
  final double buttonGap;
  final double iconButton;
  final List<(double, double)> rings;
  final Offset ringsFromTopEnd;
}

/// A round pearl-tinted icon button of the hero's top row.
class _HeroButtonLook {
  const _HeroButtonLook(this.size);

  final double size;

  Color get color => AppPalette.pearl;

  ButtonStyle get iconStyle => IconButton.styleFrom(
    backgroundColor: AppProfileLayout.onDarkFill,
    foregroundColor: AppPalette.pearl,
    side: const BorderSide(color: AppProfileLayout.onDarkBorder),
    minimumSize: Size.square(size),
    fixedSize: Size.square(size),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.padded,
    shape: const CircleBorder(),
  );
}

/// The navy hero of the Profile mocks: the wordmark and the round icon
/// buttons, the avatar with the name, `@handle` and location, the bio, the
/// stats pill and the action pills. One widget for the three looks; only the
/// metrics ([_HeroMetrics]) differ. Same data and gates as the classic
/// header: it is built by the same body with the same flags.
class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.profile,
    required this.isBlocking,
    required this.showActions,
    required this.showFollowsYou,
    required this.showPostsCount,
    required this.canReport,
    required this.listsEnabled,
    required this.followedBy,
    required this.interactive,
    required this.isOwnProfile,
    required this.nameKey,
    required this.onEditProfile,
    required this.onMessage,
    required this.onOpenWebsite,
    required this.avatarBytes,
    required this.website,
    required this.joined,
    required this.topInset,
    required this.onBack,
  });

  /// The status-bar inset the hero draws under (it starts at the very top of
  /// the screen, behind the transparent app bar).
  final double topInset;

  /// Back, for a profile that was pushed: the first button of the top row.
  final VoidCallback? onBack;
  final identity.Profile profile;
  final bool isBlocking;
  final bool showActions;
  final bool showFollowsYou;
  final bool showPostsCount;
  final bool canReport;
  final bool listsEnabled;
  final bool followedBy;
  final bool interactive;
  final bool isOwnProfile;
  final Key? nameKey;
  final VoidCallback? onEditProfile;
  final VoidCallback? onMessage;
  final void Function(Uri uri)? onOpenWebsite;
  final Uint8List? avatarBytes;
  final ProfileWebsite? website;
  final String? joined;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _build(
      context,
      _HeroMetrics.forWidth(
        constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width,
      ),
    ),
  );

  Widget _build(BuildContext context, _HeroMetrics m) {
    final theme = Theme.of(context);
    final large =
        MediaQuery.textScalerOf(context).scale(1) >
        AppProfileLayout.largeTextScale;
    final location = profile.location.trim();
    final canShare = interactive && ShareLinksScope.maybeOf(context) != null;
    final look = _HeroButtonLook(m.iconButton);
    final rtl = Directionality.of(context) == TextDirection.rtl;

    // Top row, right side: Share, then Settings on the own profile or the
    // overflow menu on another's (Block / Mute / Lists / Report).
    final Widget? menu;
    if (isOwnProfile || !interactive) {
      menu = null;
    } else if (showActions) {
      menu = _OverflowMenu(
        profile: profile,
        canReport: canReport,
        listsEnabled: listsEnabled,
        hero: look,
      );
    } else if (canReport || listsEnabled) {
      menu = _ReportOnlyMenu(
        profile: profile,
        canReport: canReport,
        listsEnabled: listsEnabled,
        hero: look,
      );
    } else {
      menu = null;
    }

    // Action pills: the primary one (Edit profile, or Follow) and the outline
    // one (Share profile, or Message). One alone takes the whole row.
    final Widget? primary;
    final Widget? secondary;
    if (!interactive) {
      primary = null;
      secondary = null;
    } else if (isOwnProfile) {
      primary = onEditProfile == null
          ? null
          : _HeroPill(
              filled: true,
              height: m.buttonHeight,
              onPressed: onEditProfile,
              child: const Text('Edit profile'),
            );
      secondary = canShare
          ? Builder(
              builder: (context) => _HeroPill(
                filled: false,
                height: m.buttonHeight,
                onPressed: () => _shareProfile(context, profile.handle),
                child: const Text('Share profile'),
              ),
            )
          : null;
    } else {
      primary = showActions && !isBlocking
          ? FollowButton(
              followedBy: followedBy,
              source: FollowSource.profile,
              buttonBuilder:
                  (
                    context, {
                    required filled,
                    required onPressed,
                    required child,
                  }) => _HeroPill(
                    filled: filled,
                    height: m.buttonHeight,
                    onPressed: onPressed,
                    child: child,
                  ),
            )
          : null;
      secondary = onMessage != null && !isBlocking
          ? Tooltip(
              message: 'Message @${profile.handle}',
              child: _HeroPill(
                filled: false,
                height: m.buttonHeight,
                onPressed: onMessage,
                child: const Text('Message'),
              ),
            )
          : null;
    }

    Widget content = Padding(
      padding: EdgeInsets.fromLTRB(
        m.paddingH,
        m.paddingTop + topInset,
        m.paddingH,
        m.paddingBottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (onBack case final back?) ...[
                IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  style: look.iconStyle,
                  icon: Icon(
                    Icons.arrow_back,
                    size: AppIconSize.md,
                    color: look.color,
                  ),
                  onPressed: back,
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: ExcludeSemantics(
                  child: Text(
                    'DZEROTH',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.wordmark(theme)
                        .copyWith(color: AppPalette.pearl),
                  ),
                ),
              ),
              if (canShare)
                Builder(
                  builder: (context) => IconButton(
                    tooltip: 'Share profile',
                    style: look.iconStyle,
                    icon: Icon(
                      Icons.ios_share,
                      size: AppIconSize.md,
                      color: look.color,
                    ),
                    onPressed: () => _shareProfile(context, profile.handle),
                  ),
                ),
              if (isOwnProfile && interactive) ...[
                const SizedBox(width: AppSpacing.sm),
                IconButton(
                  tooltip: 'Settings',
                  style: look.iconStyle,
                  icon: Icon(
                    Icons.settings_outlined,
                    size: AppIconSize.md,
                    color: look.color,
                  ),
                  onPressed: () => context.go(AppRouter.settingsPath),
                ),
              ],
              if (menu != null) ...[const SizedBox(width: AppSpacing.sm), menu],
            ],
          ),
          SizedBox(height: m.gap),
          // The avatar beside the name; above it at a large text scale, so
          // the name keeps the width.
          if (large && m.phone) ...[
            _HeroAvatar(
              profile: profile,
              diameter: m.avatar,
              phone: m.phone,
              bytes: avatarBytes,
            ),
            SizedBox(height: m.gap),
            _identity(context, m, theme, location),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _HeroAvatar(
                  profile: profile,
                  diameter: m.avatar,
                  phone: m.phone,
                  bytes: avatarBytes,
                ),
                SizedBox(width: m.avatarGap),
                Expanded(child: _identity(context, m, theme, location)),
              ],
            ),
          if (profile.bio.isNotEmpty) ...[
            SizedBox(height: m.gap),
            Text(
              profile.bio,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: m.bioSize,
                color: AppPalette.pearl,
              ),
            ),
          ],
          if (website != null || joined != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpacing.md,
              children: [
                if (website case final site?)
                  _MetaRow(
                    icon: Icons.link,
                    text: site.host,
                    semanticLabel: 'Website: ${site.host}',
                    onTap: interactive
                        ? () => _openWebsite(context, site.uri, onOpenWebsite)
                        : null,
                    looksLikeLink: true,
                    onDark: true,
                  ),
                if (joined != null)
                  _MetaRow(
                    icon: Icons.calendar_month_outlined,
                    text: joined!,
                    onDark: true,
                  ),
              ],
            ),
          ],
          SizedBox(height: m.gap),
          if (isBlocking)
            _BlockedBanner(handle: profile.handle, onDark: true)
          else
            _HeroStats(
              profile: profile,
              showPostsCount: showPostsCount,
              interactive: interactive,
              metrics: m,
              stacked: large,
            ),
          if (primary != null || secondary != null) ...[
            SizedBox(height: m.gap),
            // Semantics sort key: the actions read after the identity, as in
            // the classic header.
            Semantics(
              container: true,
              explicitChildNodes: true,
              sortKey: const OrdinalSortKey(1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (primary != null) Expanded(child: primary),
                  if (primary != null && secondary != null)
                    SizedBox(width: m.buttonGap),
                  if (secondary != null) Expanded(child: secondary),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    content = Semantics(
      container: true,
      explicitChildNodes: true,
      sortKey: const OrdinalSortKey(0),
      child: content,
    );

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(AppProfileLayout.heroRadius),
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: AppGradients.hero),
        // The gradient paints above the Scaffold's Material: the ink of the
        // stats and the website link needs a Material over the gradient.
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: AppRings(
                  rings: m.rings,
                  color: AppPalette.tealElectric,
                  centre: (size) => Offset(
                    // Top-end corner: the right in LTR, the left in RTL.
                    rtl
                        ? m.ringsFromTopEnd.dx
                        : size.width - m.ringsFromTopEnd.dx,
                    m.ringsFromTopEnd.dy + topInset,
                  ),
                ),
              ),
              content,
            ],
          ),
        ),
      ),
    );
  }

  /// The name, `@handle` (with "Follows you") and the location chip.
  Widget _identity(
    BuildContext context,
    _HeroMetrics m,
    ThemeData theme,
    String location,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: profile.displayName),
                if (profile.subscriptionVerified) ...[
                  const TextSpan(text: '  '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Semantics(
                      label: 'Verified subscription account',
                      child: const Icon(
                        Icons.verified,
                        size: AppIconSize.sm,
                        color: AppPalette.tealElectric,
                      ),
                    ),
                  ),
                ],
                if (profile.isPrivate) ...[
                  const TextSpan(text: ' '),
                  const WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: ProtectedBadge(color: AppPalette.pearl),
                  ),
                ],
              ],
            ),
            key: nameKey,
            // Room for the lock and the check at a large text scale.
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: m.nameSize,
              height: AppTypeTokens.displayLineHeight,
              letterSpacing: AppTypeTokens.displayTracking * m.nameSize,
              color: AppPalette.pearl,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            Text(
              '@${profile.handle}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: m.handleSize,
                color: AppPalette.mutedOnDark,
              ),
            ),
            if (showFollowsYou) const _FollowsYouChip(onDark: true),
          ],
        ),
        if (location.isNotEmpty) ...[
          SizedBox(height: m.chipGap),
          AppChip(
            label: location,
            showDot: true,
            onDark: true,
            semanticsLabel: 'Location: $location',
          ),
        ],
      ],
    );
  }
}

/// Opens the share menu of the profile's link (Copy link, Share via...).
/// Only offered where the app has [ShareLinks] (see [ShareLinksScope]).
void _shareProfile(BuildContext context, String handle) {
  final links = ShareLinksScope.maybeOf(context);
  if (links == null) return;
  final box = context.findRenderObject();
  final anchor = box is RenderBox && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : Rect.zero;
  unawaited(
    showPostShareMenu(
      context,
      url: links.profileUrl(handle),
      nativeShare: links.nativeShare,
      anchor: anchor,
      title: 'Share profile',
    ),
  );
}

/// The avatar of the hero: the phone's navy and teal rings with the teal
/// glow, or the wide look's 4dp pearl ring.
class _HeroAvatar extends StatelessWidget {
  const _HeroAvatar({
    required this.profile,
    required this.diameter,
    required this.phone,
    required this.bytes,
  });

  final identity.Profile profile;
  final double diameter;
  final bool phone;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final avatar = AppAvatar(
      url: profile.avatarUrl,
      radius: diameter / 2,
      bytes: bytes,
      name: profile.displayName,
    );
    if (!phone) {
      return DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppPalette.pearl,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppProfileLayout.wideAvatarRing),
          child: avatar,
        ),
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: AppProfileLayout.avatarGlow,
            blurRadius: AppProfileLayout.phoneAvatarGlowBlur,
          ),
          BoxShadow(
            color: AppPalette.tealElectric,
            spreadRadius: AppProfileLayout.phoneAvatarOuterRing,
          ),
          BoxShadow(
            color: AppPalette.navy,
            spreadRadius: AppProfileLayout.phoneAvatarInnerRing,
          ),
        ],
      ),
      child: avatar,
    );
  }
}

/// The translucent stats pill: Posts (when `posts` is on), Followers and
/// Following, each a number over its label with hairlines between. Followers
/// and Following open their lists; Posts is display only (the Posts tab is
/// the way in).
class _HeroStats extends StatelessWidget {
  const _HeroStats({
    required this.profile,
    required this.showPostsCount,
    required this.interactive,
    required this.metrics,
    required this.stacked,
  });

  final identity.Profile profile;
  final bool showPostsCount;
  final bool interactive;
  final _HeroMetrics metrics;

  /// At a large text scale the stats are rows (label, then its number), so no
  /// label is cut off.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final stats = <Widget>[
      if (showPostsCount)
        _HeroStat(
          stacked: stacked,
          key: const ValueKey('profile-stat-posts'),
          count: profile.postsCount.toInt(),
          label: profile.postsCount == Int64.ONE ? 'Post' : 'Posts',
          metrics: metrics,
        ),
      _HeroStat(
        stacked: stacked,
        key: const ValueKey('profile-stat-followers'),
        count: profile.followersCount.toInt(),
        label: 'Followers',
        metrics: metrics,
        onTap: interactive
            ? () => context.push(
                AppRouter.followersPath(profile.handle),
                extra: profile.userId,
              )
            : null,
      ),
      _HeroStat(
        stacked: stacked,
        key: const ValueKey('profile-stat-following'),
        count: profile.followingCount.toInt(),
        label: 'Following',
        metrics: metrics,
        onTap: interactive
            ? () => context.push(
                AppRouter.followingPath(profile.handle),
                extra: profile.userId,
              )
            : null,
      ),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.fieldFillDark,
        borderRadius: BorderRadius.circular(AppProfileLayout.statsRadius),
        border: Border.all(color: AppPalette.hairlineDark),
      ),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < stats.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: AppProfileLayout.onDarkBorder,
                    ),
                  stats[i],
                ],
              ],
            )
          : IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < stats.length; i++) ...[
                    if (i > 0)
                      const VerticalDivider(
                        width: 1,
                        thickness: 1,
                        indent: AppSpacing.sm,
                        endIndent: AppSpacing.sm,
                        color: AppProfileLayout.onDarkBorder,
                      ),
                    Expanded(child: stats[i]),
                  ],
                ],
              ),
            ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    super.key,
    required this.count,
    required this.label,
    required this.metrics,
    required this.stacked,
    this.onTap,
  });

  final bool stacked;
  final int count;
  final String label;
  final _HeroMetrics metrics;

  /// Null: the same look, not a button (Posts, a preview).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Compact numbers (1.2M) in the pill; the spoken label has the whole one.
    final shown = NumberFormat.compact().format(count);
    final value = Text(
      shown,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleLarge?.copyWith(
        fontSize: metrics.statValueSize,
        letterSpacing:
            AppProfileLayout.statValueTracking * metrics.statValueSize,
        color: AppPalette.pearl,
      ),
    );
    final caption = Text(
      label,
      maxLines: stacked ? null : 1,
      overflow: stacked ? null : TextOverflow.ellipsis,
      style: theme.textTheme.labelMedium?.copyWith(
        fontSize: metrics.statLabelSize,
        color: AppPalette.mutedOnDark,
      ),
    );
    return Semantics(
      button: onTap != null,
      label: '$count $label',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppProfileLayout.statsRadius),
        onTap: onTap,
        focusColor: AppProfileLayout.onDarkInk,
        hoverColor: AppProfileLayout.onDarkInk,
        splashColor: AppProfileLayout.onDarkInk,
        highlightColor: AppProfileLayout.onDarkInk,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: stacked ? AppSpacing.sm : metrics.statsPaddingV,
              horizontal: stacked ? AppSpacing.md : 0,
            ),
            child: stacked
                ? Row(
                    children: [
                      Expanded(child: caption),
                      const SizedBox(width: AppSpacing.sm),
                      value,
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [value, caption],
                  ),
          ),
        ),
      ),
    );
  }
}

/// A full-width action pill of the hero: teal gradient with the glow
/// ([filled]) or a pearl outline. A real Filled / Outlined button, so focus,
/// ripple and semantics are the platform's; the gradient sits behind a
/// transparent filled button.
class _HeroPill extends StatelessWidget {
  const _HeroPill({
    required this.filled,
    required this.height,
    required this.onPressed,
    required this.child,
  });

  final bool filled;
  final double height;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = Size(0, height);
    final enabled = onPressed != null;
    // The busy spinner of Follow draws in the pill's own ink, not the theme's
    // primary (teal on teal, then half faded).
    final label = ProgressIndicatorTheme(
      data: ProgressIndicatorTheme.of(context)
          .copyWith(color: filled ? AppPalette.navy : AppPalette.pearl),
      child: child,
    );
    if (!filled) {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: size,
          foregroundColor: AppPalette.pearl,
          disabledForegroundColor: AppPalette.mutedOnDark,
          side: const BorderSide(
            color: AppProfileLayout.onDarkOutline,
            width: AppSize.componentBorder,
          ),
          shape: const StadiumBorder(),
        ),
        onPressed: onPressed,
        child: label,
      );
    }
    // One button: the gradient is its own background, so the pair of pills
    // are the same height (the glow is the button's elevation shadow).
    return Opacity(
      opacity: enabled ? 1 : AppProfileLayout.disabledOpacity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: size,
          backgroundColor: AppPalette.teal,
          disabledBackgroundColor: AppPalette.teal,
          foregroundColor: AppPalette.navy,
          disabledForegroundColor: AppPalette.navy,
          elevation: enabled ? AppProfileLayout.pillGlowElevation : 0,
          shadowColor: AppProfileLayout.pillGlow,
          shape: const StadiumBorder(),
          backgroundBuilder: (context, states, child) => DecoratedBox(
            decoration: const BoxDecoration(
              gradient: AppGradients.primaryButton,
              borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
            ),
            child: child,
          ),
        ),
        onPressed: onPressed,
        child: label,
      ),
    );
  }
}
