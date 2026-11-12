import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show OrdinalSortKey;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/telemetry/analytics_event.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart'
    show ReportTargetType;
import '../../../../shared/format/joined_date.dart';
import '../../../../shared/format/profile_website.dart';
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_surface.dart';
import '../../../../shared/widgets/user/follow_button.dart';
import '../../../../shared/widgets/post/post_card.dart' show launchPostLink;
import '../../../graph/data/graph_repository.dart';
import '../../../graph/presentation/bloc/relationship_cubit.dart';
import '../../../graph/presentation/bloc/relationship_state.dart';
import '../../../graph/presentation/graph_error_messages.dart';
import '../../../lists/data/lists_repository.dart';
import '../../../lists/presentation/widgets/add_to_lists_sheet.dart';
import '../../../moderation/presentation/report_sheet.dart';
import '../../../../shared/widgets/user/protected_badge.dart';
import '../../../../core/share/share_links.dart';
import '../../../../shared/widgets/post/post_share_menu.dart';
import '../../../../shared/widgets/primitives/app_rings.dart';
import 'block_confirmation_dialog.dart';
import 'profile_cover_band.dart';

part 'profile_hero.dart';

/// How [ProfileHeader] draws itself. [classic] is the banner, the avatar
/// ring and the plain counts (the Edit profile preview keeps it); [hero] is
/// the navy hero of the Profile mocks (the screen opts in).
enum ProfileHeaderStyle { classic, hero }

/// The profile header: avatar, display name, `@handle`, bio, follower/
/// following counts, and (for other users, when the graph flag is on) a
/// [FollowButton] plus a block/mute overflow menu.
///
/// Owned by the graph plan; the posts/profile-timeline plan
/// adds the tabs and body below it — this widget never grows to include
/// them, so the two plans don't edit the same widget at once.
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    required this.profile,
    required this.isOwnProfile,
    required this.graphEnabled,
    this.relationship,
    this.onRelationshipChanged,
    this.showPostsCount = false,
    this.onEditProfile,
    this.reportsEnabled = false,
    this.nameKey,
    this.followedBy = false,
    this.onOpenWebsite,
    this.onMessage,
    this.listsEnabled = false,
    this.interactive = true,
    this.avatarBytes,
    this.bannerBytes,
    this.style = ProfileHeaderStyle.classic,
  });

  final identity.Profile profile;
  final bool isOwnProfile;

  /// The look; the data, actions and gates are the same in both.
  final ProfileHeaderStyle style;

  /// False draws the header inert, for a preview ("How others see you" on
  /// Edit profile): the counts and the website look the same but are not
  /// links, so nothing in it can be tapped or activated.
  final bool interactive;

  /// An unsaved photo or banner (Edit profile's on-device preview), drawn
  /// over the saved one. Null draws the saved images.
  final Uint8List? avatarBytes;
  final Uint8List? bannerBytes;

  /// Adds "Add or remove from Lists" and "View Lists" to the overflow menu of
  /// another user's profile. Only given when `lists` is on.
  final bool listsEnabled;

  /// Shows the round "Message" (envelope) button left of Follow on another
  /// user's profile and calls this when it is tapped. Only given when
  /// `messaging` is on for the caller. The button is still left out while the
  /// viewer blocks the profile (a profile that blocks the viewer is never
  /// loaded: the server answers NOT_FOUND). Null hides it.
  final VoidCallback? onMessage;

  /// The profile follows the viewer (`GetProfileRelationship.followed_by`): shows the "Follows you" chip next to the handle and turns
  /// Follow into "Follow back". Only read with the graph flag on, on another
  /// user's profile, and not while the viewer blocks them.
  final bool followedBy;

  /// Opens the profile's website. Defaults to [launchPostLink] (external
  /// browser, a new tab on web) plus a "Couldn't open link." snackbar.
  final void Function(Uri uri)? onOpenWebsite;

  /// Put on the display name so the profile screen can tell when it scrolls
  /// under the app bar (the app-bar name fades in then).
  final Key? nameKey;

  /// Offers "Report @handle" on other people's profiles (the `reports` flag). Works with or without the graph menu.
  final bool reportsEnabled;

  /// Shows an "Edit profile" button on the viewer's own profile (only
  /// given when the `profile_snapshot` flag is on). Null hides it.
  final VoidCallback? onEditProfile;
  final bool graphEnabled;

  /// The viewer's relationship to [profile], if known. Null for the
  /// viewer's own profile, when the graph flag is off, or if the fetch
  /// failed — in every case, no follow/block/mute affordance is shown.
  final graph.Relationship? relationship;
  final ValueChanged<graph.Relationship>? onRelationshipChanged;

  /// Adds the post count next to Following/Followers (only with the posts
  /// flag on).
  final bool showPostsCount;

  bool get _showGraphActions =>
      !isOwnProfile && graphEnabled && relationship != null;

  @override
  Widget build(BuildContext context) {
    if (!_showGraphActions) {
      return _ProfileHeaderBody(
        profile: profile,
        showActions: false,
        showPostsCount: showPostsCount,
        onEditProfile: isOwnProfile ? onEditProfile : null,
        canReport: reportsEnabled && !isOwnProfile,
        nameKey: nameKey,
        onOpenWebsite: onOpenWebsite,
        onMessage: isOwnProfile ? null : onMessage,
        listsEnabled: listsEnabled && !isOwnProfile,
        interactive: interactive,
        avatarBytes: avatarBytes,
        bannerBytes: bannerBytes,
        style: style,
        isOwnProfile: isOwnProfile,
      );
    }
    return BlocProvider(
      create: (context) => RelationshipCubit(
        graphRepository: context.read<GraphRepository>(),
        userId: profile.userId,
        initial: relationship!,
        targetIsPrivate: profile.isPrivate,
      ),
      child: BlocListener<RelationshipCubit, RelationshipState>(
        listener: (context, state) {
          onRelationshipChanged?.call(state.relationship);
          final error = state.error;
          if (error != null) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(content: Text(relationshipErrorMessage(error))),
              );
          }
        },
        child: _ProfileHeaderBody(
          profile: profile,
          showActions: true,
          showPostsCount: showPostsCount,
          canReport: reportsEnabled,
          nameKey: nameKey,
          followedBy: followedBy,
          onOpenWebsite: onOpenWebsite,
          onMessage: onMessage,
          listsEnabled: listsEnabled,
          interactive: interactive,
          avatarBytes: avatarBytes,
          bannerBytes: bannerBytes,
          style: style,
          isOwnProfile: isOwnProfile,
        ),
      ),
    );
  }
}

class _ProfileHeaderBody extends StatelessWidget {
  const _ProfileHeaderBody({
    required this.profile,
    required this.showActions,
    required this.showPostsCount,
    this.onEditProfile,
    this.canReport = false,
    this.nameKey,
    this.followedBy = false,
    this.onOpenWebsite,
    this.onMessage,
    this.listsEnabled = false,
    this.interactive = true,
    this.avatarBytes,
    this.bannerBytes,
    this.style = ProfileHeaderStyle.classic,
    this.isOwnProfile = false,
  });

  final bool isOwnProfile;
  final ProfileHeaderStyle style;
  final bool listsEnabled;
  final bool interactive;
  final Uint8List? avatarBytes;
  final Uint8List? bannerBytes;
  final VoidCallback? onMessage;
  final Key? nameKey;
  final identity.Profile profile;
  final bool showActions;
  final bool showPostsCount;
  final bool canReport;
  final VoidCallback? onEditProfile;
  final bool followedBy;
  final void Function(Uri uri)? onOpenWebsite;

  @override
  Widget build(BuildContext context) {
    final isBlocking =
        showActions &&
        context.select((RelationshipCubit c) => c.state.relationship.blocking);

    final theme = Theme.of(context);
    final actions = _actions(context, isBlocking: isBlocking);
    // Meta row, in X's order: location, website, Joined. Each is left out when
    // the profile does not carry it (the server omits the fields while
    // `profile_extras` is off, so nothing here is gated).
    final location = profile.location.trim();
    final website = profile.website.isEmpty
        ? null
        : parseProfileWebsite(profile.website);
    final joined = joinedText(
      profile.hasCreatedAt() ? profile.createdAt : null,
    );
    final showFollowsYou = showActions && followedBy && !isBlocking;

    if (style == ProfileHeaderStyle.hero) {
      return _ProfileHero(
        profile: profile,
        isBlocking: isBlocking,
        showActions: showActions,
        showFollowsYou: showFollowsYou,
        showPostsCount: showPostsCount,
        canReport: canReport,
        listsEnabled: listsEnabled,
        followedBy: followedBy,
        interactive: interactive,
        isOwnProfile: isOwnProfile,
        nameKey: nameKey,
        onEditProfile: onEditProfile,
        onMessage: onMessage,
        onOpenWebsite: onOpenWebsite,
        avatarBytes: avatarBytes,
        bannerBytes: bannerBytes,
        website: website,
        joined: joined,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // X's profile: a 3:1 banner, the avatar (133dp, 88dp on phones) in a
        // surface-coloured ring hanging half over the banner's bottom edge,
        // the actions on the right of the strip below the banner.
        final narrow = width < AppBreakpoints.mobile;
        final diameter = narrow
            ? AppSize.avatarProfileNarrow
            : AppSize.avatarProfileWide;
        final outer = diameter + 2 * AppSpacing.xs;
        final overlap = outer / 2;
        final bannerHeight = width / 3;
        // The strip between the banner and the name holds the avatar's lower
        // half and the actions (36dp pill in a 48dp target, 12dp below the
        // banner). It is at least tall enough for both, and it grows with the
        // actions: at a large text scale a button wraps to two or three lines,
        // and a fixed 60dp strip let it paint over the name (D-1). The
        // actions are laid out in the strip, in the same pass as everything
        // else, so nothing moves after the first frame.
        const actionsTop = AppSpacing.smd;
        final minStrip = math.max(
          overlap + AppSpacing.sm,
          actionsTop + AppSpacing.minTapTarget,
        );
        return Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: bannerHeight,
                  child: ProfileCoverBand(
                    url: _bannerUrlFor(profile, fullSize: !narrow),
                    bytes: bannerBytes,
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minStrip),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(
                      top: actionsTop,
                      end: AppSpacing.md,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Under the avatar (it hangs over the banner's edge).
                        SizedBox(width: AppSpacing.md + outer + AppSpacing.sm),
                        Expanded(
                          child: Align(
                            alignment: AlignmentDirectional.topEnd,
                            child: actions == null
                                ? null
                                : Semantics(
                                    container: true,
                                    explicitChildNodes: true,
                                    sortKey: const OrdinalSortKey(1),
                                    child: actions,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Reading order is the identity first, then the actions, which
                // sit above it in the strip: the sort keys say so.
                Semantics(
                  container: true,
                  explicitChildNodes: true,
                  sortKey: const OrdinalSortKey(0),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      0,
                      AppSpacing.md,
                      AppSpacing.md,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The lock sits in the name's own text flow, so at a large
                        // text scale it wraps with the last word and cannot
                        // overlap the name (D-1).
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
                                    child: Icon(
                                      Icons.verified,
                                      size: AppIconSize.sm,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ],
                              if (profile.isPrivate) ...[
                                const TextSpan(text: ' '),
                                const WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: ProtectedBadge(),
                                ),
                              ],
                            ],
                          ),
                          key: nameKey,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        // The chip sits after the handle, and drops under it
                        // when the handle is long or the text is large.
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.xs,
                          children: [
                            Text(
                              '@${profile.handle}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (showFollowsYou) const _FollowsYouChip(),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        if (profile.bio.isNotEmpty) ...[
                          Text(profile.bio, style: theme.textTheme.bodyLarge),
                          const SizedBox(height: AppSpacing.md),
                        ],
                        if (location.isNotEmpty ||
                            website != null ||
                            joined != null) ...[
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: AppSpacing.md,
                            children: [
                              if (location.isNotEmpty)
                                _MetaRow(
                                  icon: Icons.location_on_outlined,
                                  text: location,
                                  semanticLabel: 'Location: $location',
                                ),
                              if (website != null)
                                _MetaRow(
                                  icon: Icons.link,
                                  text: website.host,
                                  semanticLabel: 'Website: ${website.host}',
                                  onTap: interactive
                                      ? () => _openWebsite(
                                          context,
                                          website.uri,
                                          onOpenWebsite,
                                        )
                                      : null,
                                  looksLikeLink: true,
                                ),
                              if (joined != null)
                                _MetaRow(
                                  icon: Icons.calendar_month_outlined,
                                  text: joined,
                                ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.sm),
                        ],
                        if (isBlocking)
                          _BlockedBanner(handle: profile.handle)
                        else
                          _CountsRow(
                            profile: profile,
                            showPostsCount: showPostsCount,
                            interactive: interactive,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            PositionedDirectional(
              start: AppSpacing.md,
              top: bannerHeight - overlap,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.surface,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  child: AppAvatar(
                    url: profile.avatarUrl,
                    radius: diameter / 2,
                    bytes: avatarBytes,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The controls on the right of the strip below the banner, or null.
  Widget? _actions(BuildContext context, {required bool isBlocking}) {
    if (showActions && !isBlocking) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _OverflowMenu(
            profile: profile,
            canReport: canReport,
            listsEnabled: listsEnabled,
          ),
          const SizedBox(width: AppSpacing.xs),
          if (onMessage != null) ...[
            MessageButton(handle: profile.handle, onPressed: onMessage!),
            const SizedBox(width: AppSpacing.xs),
          ],
          Flexible(
            child: FollowButton(
              followedBy: followedBy,
              source: FollowSource.profile,
            ),
          ),
        ],
      );
    }
    if (showActions) {
      return _OverflowMenu(
        profile: profile,
        canReport: canReport,
        listsEnabled: listsEnabled,
      );
    }
    // Graph off: no Follow, no block data; the Message button (when given)
    // sits after the Report menu.
    final message = onMessage;
    if (canReport || listsEnabled || message != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canReport || listsEnabled)
            _ReportOnlyMenu(
              profile: profile,
              canReport: canReport,
              listsEnabled: listsEnabled,
            ),
          if ((canReport || listsEnabled) && message != null)
            const SizedBox(width: AppSpacing.xs),
          if (message != null)
            MessageButton(handle: profile.handle, onPressed: message),
        ],
      );
    }
    if (onEditProfile != null) {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, AppSize.pillCompact),
          tapTargetSize: MaterialTapTargetSize.padded,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
        ),
        onPressed: onEditProfile,
        child: const Text('Edit profile'),
      );
    }
    return null;
  }
}

/// The banner URL for the header: the 600 px thumb below 600 dp, the 1500 px
/// full image at 600 dp and above, whichever exists when only one
/// does. Empty = no banner. Both sizes are 3:1, so neither changes the layout.
String _bannerUrlFor(identity.Profile profile, {required bool fullSize}) {
  final full = profile.bannerUrl;
  final thumb = profile.bannerThumbUrl;
  final wanted = fullSize ? full : thumb;
  return wanted.isNotEmpty ? wanted : (fullSize ? thumb : full);
}

/// The round "Message" (envelope) button of another user's profile:
/// a 36dp outlined circle in a 48dp target, left of Follow. Labelled for
/// screen readers ("Message @handle").
class MessageButton extends StatelessWidget {
  const MessageButton({
    super.key,
    required this.handle,
    required this.onPressed,
  });

  final String handle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: 'Message @$handle',
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(
        width: AppSpacing.minTapTarget,
        height: AppSpacing.minTapTarget,
      ),
      padding: EdgeInsets.zero,
      icon: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colors.outline),
        ),
        child: SizedBox(
          width: AppSize.pillCompact,
          height: AppSize.pillCompact,
          child: Icon(
            Icons.mail_outline,
            size: AppIconSize.md,
            color: colors.onSurface,
          ),
        ),
      ),
    );
  }
}

/// "Follows you", beside the handle: a small muted label on a raised surface
/// (X's own treatment). It is read as it is written, after the handle.
class _FollowsYouChip extends StatelessWidget {
  const _FollowsYouChip({this.onDark = false});

  /// On the navy hero: a pearl-tinted chip with pearl text.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: onDark
            ? AppProfileLayout.onDarkFill
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Text(
          'Follows you',
          style: theme.textTheme.labelMedium?.copyWith(
            color: onDark
                ? AppPalette.pearl
                : context.appColors.secondaryOnRaised,
          ),
        ),
      ),
    );
  }
}

/// Opens a profile website outside the app (never fetched by us).
Future<void> _openWebsite(
  BuildContext context,
  Uri uri,
  void Function(Uri uri)? override,
) async {
  if (override != null) {
    override(uri);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  if (!await launchPostLink(uri)) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text("Couldn't open link.")));
  }
}

class _CountsRow extends StatelessWidget {
  const _CountsRow({
    required this.profile,
    required this.showPostsCount,
    this.interactive = true,
  });

  final identity.Profile profile;
  final bool showPostsCount;

  /// False: the counts read the same but open nothing (a preview).
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.lg,
      children: [
        if (showPostsCount) _PostsCount(count: profile.postsCount),
        _CountLink(
          count: profile.followingCount.toInt(),
          label: 'Following',
          onTap: interactive
              ? () => context.push(
                  AppRouter.followingPath(profile.handle),
                  extra: profile.userId,
                )
              : null,
        ),
        _CountLink(
          count: profile.followersCount.toInt(),
          label: 'Followers',
          onTap: interactive
              ? () => context.push(
                  AppRouter.followersPath(profile.handle),
                  extra: profile.userId,
                )
              : null,
        ),
      ],
    );
  }
}

/// "12 Posts" (display only: the Posts tab below is the way in).
class _PostsCount extends StatelessWidget {
  const _PostsCount({required this.count});

  final Int64 count;

  @override
  Widget build(BuildContext context) {
    final label = count == Int64.ONE ? 'Post' : 'Posts';
    return Semantics(
      label: '$count $label',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$count ',
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: label, style: _mutedLabel(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Count labels ("Posts", "Followers") read secondary to the bold number.
TextStyle? _mutedLabel(BuildContext context) =>
    Theme.of(context).textTheme.bodyLarge
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

class _CountLink extends StatelessWidget {
  const _CountLink({
    required this.count,
    required this.label,
    required this.onTap,
  });

  final int count;
  final String label;

  /// Null: the same look, but not a button (a preview).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: '$count $label',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: AppSpacing.minTapTarget,
            minWidth: AppSpacing.minTapTarget,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$count ',
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(text: label, style: _mutedLabel(context)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the counts row when the viewer blocks this profile
/// ("hides counts links"). The overflow menu (Mute/Unmute,
/// Block/Unblock) stays available up in the header row regardless.
class _BlockedBanner extends StatelessWidget {
  const _BlockedBanner({required this.handle, this.onDark = false});

  final String handle;

  /// On the navy hero: a pearl-tinted box with pearl text, teal action.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RelationshipCubit, RelationshipState>(
      builder: (context, state) {
        final row = Row(
          children: [
            Expanded(
              child: Text(
                'You blocked @$handle',
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: onDark ? AppPalette.pearl : null),
              ),
            ),
            TextButton(
              style: onDark
                  ? TextButton.styleFrom(
                      foregroundColor: AppPalette.tealElectric,
                    )
                  : null,
              onPressed: state.isUpdating
                  ? null
                  : () => context.read<RelationshipCubit>().unblock(),
              child: const Text('Unblock'),
            ),
          ],
        );
        if (!onDark) return AppSurface(child: row);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: AppProfileLayout.onDarkStatsFill,
            borderRadius: BorderRadius.circular(AppProfileLayout.statsRadius),
            border: Border.all(color: AppProfileLayout.onDarkStatsBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            child: row,
          ),
        );
      },
    );
  }
}

/// Opens the report sheet for [profile]'s account.
Future<ReportOutcome> _reportAccount(
  BuildContext context,
  identity.Profile profile, {
  required bool offerBlock,
}) {
  return showReportSheet(
    context,
    targetType: ReportTargetType.REPORT_TARGET_TYPE_ACCOUNT,
    targetId: profile.userId,
    subject: '@${profile.handle}',
    blockLabel: offerBlock ? 'Block @${profile.handle}' : null,
  );
}

/// The Lists rows of the overflow menu: Add/remove and View.
const _addToListsValue = 'lists_add';
const _viewListsValue = 'lists_view';

/// "View Lists" is hidden on a protected profile the viewer does not
/// follow (the server answers PROTECTED_ACCOUNT / NOT_FOUND for its Lists).
/// [following] is null when the relationship is unknown (graph off): hidden
/// then too.
bool _canViewLists(identity.Profile profile, {required bool? following}) =>
    !profile.isPrivate || (following ?? false);

List<PopupMenuEntry<String>> _listsMenuItems({
  required bool canAdd,
  required bool canView,
}) => [
  if (canAdd)
    const PopupMenuItem(
      value: _addToListsValue,
      child: Text('Add or remove from Lists'),
    ),
  if (canView)
    const PopupMenuItem(value: _viewListsValue, child: Text('View Lists')),
];

/// Runs a Lists menu row; false when [value] is not one of them.
bool _handleListsValue(
  BuildContext context,
  String value,
  identity.Profile profile,
) {
  switch (value) {
    case _addToListsValue:
      unawaited(_addToLists(context, profile));
      return true;
    case _viewListsValue:
      unawaited(
        context.push(
          AppRouter.userListsPath(profile.userId),
          extra: profile.handle,
        ),
      );
      return true;
  }
  return false;
}

Future<void> _addToLists(BuildContext context, identity.Profile profile) async {
  final router = GoRouter.of(context);
  final result = await showAddToListsSheet(
    context,
    repository: context.read<ListsRepository>(),
    userId: profile.userId,
    handle: profile.handle,
  );
  if (result == AddToListsResult.createList) {
    unawaited(router.push(AppRouter.listsPath));
  }
}

/// "Report" and the Lists rows, for a profile with the graph flag off (no
/// Block/Mute).
class _ReportOnlyMenu extends StatelessWidget {
  const _ReportOnlyMenu({
    required this.profile,
    required this.canReport,
    required this.listsEnabled,
    this.hero,
  });

  /// The navy hero's round icon-button look; null is the plain icon.
  final _HeroButtonLook? hero;

  final identity.Profile profile;
  final bool canReport;
  final bool listsEnabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'More options',
      child: PopupMenuButton<String>(
        icon: Icon(
          Icons.more_horiz,
          size: hero == null ? AppIconSize.lg : AppIconSize.md,
          color: hero?.color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        style: hero?.iconStyle,
        padding: const EdgeInsets.all(AppSpacing.md - AppSpacing.xs),
        onSelected: (value) {
          if (listsEnabled && _handleListsValue(context, value, profile)) {
            return;
          }
          unawaited(_reportAccount(context, profile, offerBlock: false));
        },
        itemBuilder: (context) => [
          if (listsEnabled)
            ..._listsMenuItems(
              canAdd: true,
              canView: _canViewLists(profile, following: null),
            ),
          if (canReport)
            PopupMenuItem(
              value: 'report',
              child: Text('Report @${profile.handle}'),
            ),
        ],
      ),
    );
  }
}

class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({
    required this.profile,
    required this.canReport,
    required this.listsEnabled,
    this.hero,
  });

  /// The navy hero's round icon-button look; null is the plain icon.
  final _HeroButtonLook? hero;

  final identity.Profile profile;
  final bool canReport;
  final bool listsEnabled;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RelationshipCubit, RelationshipState>(
      builder: (context, state) {
        final cubit = context.read<RelationshipCubit>();
        final relationship = state.relationship;
        return Semantics(
          button: true,
          label: 'More options',
          child: PopupMenuButton<String>(
            icon: Icon(
              Icons.more_horiz,
              size: hero == null ? AppIconSize.lg : AppIconSize.md,
              color:
                  hero?.color ?? Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            style: hero?.iconStyle,
            padding: const EdgeInsets.all(AppSpacing.md - AppSpacing.xs),
            onSelected: (value) async {
              if (listsEnabled && _handleListsValue(context, value, profile)) {
                return;
              }
              switch (value) {
                case 'mute':
                  await cubit.mute();
                case 'unmute':
                  await cubit.unmute();
                case 'block':
                  final confirmed = await showBlockConfirmationDialog(context);
                  if (confirmed) await cubit.block();
                case 'unblock':
                  await cubit.unblock();
                case 'report':
                  final outcome = await _reportAccount(
                    context,
                    profile,
                    offerBlock: !relationship.blocking,
                  );
                  if (outcome == ReportOutcome.blockRequested &&
                      context.mounted) {
                    final confirmed = await showBlockConfirmationDialog(
                      context,
                    );
                    if (confirmed) await cubit.block();
                  }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: relationship.muting ? 'unmute' : 'mute',
                child: Text(relationship.muting ? 'Unmute' : 'Mute'),
              ),
              PopupMenuItem(
                value: relationship.blocking ? 'unblock' : 'block',
                child: Text(relationship.blocking ? 'Unblock' : 'Block'),
              ),
              if (listsEnabled)
                ..._listsMenuItems(
                  canAdd: !relationship.blocking,
                  canView: _canViewLists(
                    profile,
                    following:
                        relationship.followState ==
                        graph.FollowState.FOLLOW_STATE_FOLLOWING,
                  ),
                ),
              if (canReport)
                PopupMenuItem(
                  value: 'report',
                  child: Text('Report @${profile.handle}'),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// One icon + text item of the meta row under the bio ("Joined October 2026",
/// the location, the website host). The icon is decoration: the text alone is
/// spoken, or [semanticLabel] when the text needs a word before it ("Website:
/// example.com"). Wraps, so large text never overflows.
///
/// With [onTap] it is a link: accent text, one line, a 48dp target.
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.text,
    this.semanticLabel,
    this.onTap,
    this.looksLikeLink = false,
    this.onDark = false,
  });

  /// On the navy hero: muted-on-dark text, teal links.
  final bool onDark;
  final IconData icon;
  final String text;
  final String? semanticLabel;
  final VoidCallback? onTap;

  /// Draws the link look (accent, one line, a 48dp row) without [onTap]: an
  /// inert link in a preview, read as plain text.
  final bool looksLikeLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = onDark
        ? AppPalette.mutedOnDark
        : theme.colorScheme.onSurfaceVariant;
    final link = onTap != null || looksLikeLink;
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: link
          ? (onDark ? AppPalette.tealElectric : context.appColors.accentText)
          : muted,
    );
    // The icon is centred on the first text line, however far the text wraps.
    final line = MediaQuery.textScalerOf(context)
        .scale((style?.fontSize ?? 14) * (style?.height ?? 1.4));
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: link
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: SizedBox(
            height: line,
            child: Icon(icon, size: AppIconSize.sm, color: muted),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(
            text,
            style: style,
            maxLines: link ? 1 : null,
            overflow: link ? TextOverflow.ellipsis : null,
          ),
        ),
      ],
    );
    if (link) {
      final box = ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: AppSpacing.minTapTarget,
          minWidth: AppSpacing.minTapTarget,
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: 1,
          child: row,
        ),
      );
      final tap = onTap;
      if (tap == null) {
        return Semantics(
          label: semanticLabel ?? text,
          excludeSemantics: true,
          child: box,
        );
      }
      return Semantics(
        link: true,
        label: semanticLabel ?? text,
        onTap: tap,
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: tap,
          child: box,
        ),
      );
    }
    final label = semanticLabel;
    if (label == null) return row;
    return Semantics(label: label, excludeSemantics: true, child: row);
  }
}
