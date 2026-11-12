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

  /// By the window's width, as the app's other three-device screens: the
  /// hero's own width follows the pane it sits in, its look follows the device.
  static _HeroMetrics of(BuildContext context) =>
      MediaQuery.sizeOf(context).width < AppBreakpoints.mobile ? _phone : _wide;

  final bool phone;
  final double paddingH;
  final double paddingTop;
  final double paddingBottom;
  final double gap;
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
    required this.bannerBytes,
    required this.website,
    required this.joined,
  });

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
  final Uint8List? bannerBytes;
  final ProfileWebsite? website;
  final String? joined;

  @override
  Widget build(BuildContext context) {
    final m = _HeroMetrics.of(context);
    final theme = Theme.of(context);
    final bannerUrl = _bannerUrlFor(profile, fullSize: !m.phone);
    final hasBanner = bannerBytes != null || bannerUrl.isNotEmpty;
    final location = profile.location.trim();
    final canShare = interactive && ShareLinksScope.maybeOf(context) != null;
    final look = _HeroButtonLook(m.iconButton);

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
        m.paddingTop,
        m.paddingH,
        m.paddingBottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
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
                        letterSpacing:
                            AppTypeTokens.displayTracking * m.nameSize,
                        color: AppPalette.pearl,
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
                      const SizedBox(height: AppSpacing.sm),
                      _LocationChip(text: location),
                    ],
                  ],
                ),
              ),
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
        child: Stack(
          children: [
            // A saved banner (or the unsaved one of a preview) shows through
            // the hero under a navy wash, so the text stays legible.
            if (hasBanner) ...[
              Positioned.fill(
                child: ProfileCoverBand(
                  url: bannerUrl,
                  bytes: bannerBytes,
                  placeholder: Colors.transparent,
                ),
              ),
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: AppGradients.profileBannerScrim,
                  ),
                ),
              ),
            ],
            Positioned.fill(
              child: AppRings(
                rings: m.rings,
                color: AppPalette.tealElectric,
                centre: (size) => Offset(
                  size.width - m.ringsFromTopEnd.dx,
                  m.ringsFromTopEnd.dy,
                ),
              ),
            ),
            content,
          ],
        ),
      ),
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
            spreadRadius: AppProfileLayout.phoneAvatarOuterRing,
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

/// The teal-outlined location chip: a glowing dot and the profile's location.
class _LocationChip extends StatelessWidget {
  const _LocationChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: 'Location: $text',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: AppPalette.tealElectric,
            width: AppSize.componentBorder,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: AppProfileLayout.chipHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.smd),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppPalette.tealElectric,
                    boxShadow: [
                      BoxShadow(
                        color: AppProfileLayout.chipDotGlow,
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: SizedBox.square(dimension: 6),
                ),
                const SizedBox(width: AppSpacing.sm - 2),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppPalette.tealElectric,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
  });

  final identity.Profile profile;
  final bool showPostsCount;
  final bool interactive;
  final _HeroMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final stats = <Widget>[
      if (showPostsCount)
        _HeroStat(
          key: const ValueKey('profile-stat-posts'),
          count: profile.postsCount.toInt(),
          label: profile.postsCount == Int64.ONE ? 'Post' : 'Posts',
          metrics: metrics,
        ),
      _HeroStat(
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
        color: AppProfileLayout.onDarkStatsFill,
        borderRadius: BorderRadius.circular(AppProfileLayout.statsRadius),
        border: Border.all(color: AppProfileLayout.onDarkStatsBorder),
      ),
      child: IntrinsicHeight(
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
                  color: AppProfileLayout.onDarkDivider,
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
    this.onTap,
  });

  final int count;
  final String label;
  final _HeroMetrics metrics;

  /// Null: the same look, not a button (Posts, a preview).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: onTap != null,
      label: '$count $label',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppProfileLayout.statsRadius),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: metrics.statsPaddingV),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: metrics.statValueSize,
                    letterSpacing: -0.02 * metrics.statValueSize,
                    color: AppPalette.pearl,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontSize: metrics.statLabelSize,
                    color: AppPalette.mutedOnDark,
                  ),
                ),
              ],
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
        child: child,
      );
    }
    return Opacity(
      opacity: enabled ? 1 : AppProfileLayout.disabledOpacity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppGradients.primaryButton,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          boxShadow: enabled ? AppShadows.primaryGlow : null,
        ),
        child: FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: size,
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            foregroundColor: AppPalette.navy,
            disabledForegroundColor: AppPalette.navy,
            shadowColor: Colors.transparent,
            elevation: 0,
            shape: const StadiumBorder(),
          ),
          onPressed: onPressed,
          child: child,
        ),
      ),
    );
  }
}
