import 'dart:math' as math;

import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart'
    show ReportTargetType;
import '../../../../shared/format/joined_date.dart';
import '../../../../shared/format/profile_website.dart';
import '../../../../shared/widgets/app_avatar.dart';
import '../../../../shared/widgets/app_surface.dart';
import '../../../../shared/widgets/follow_button.dart';
import '../../../../shared/widgets/post_card.dart' show launchPostLink;
import '../../../graph/data/graph_repository.dart';
import '../../../graph/presentation/bloc/relationship_cubit.dart';
import '../../../graph/presentation/bloc/relationship_state.dart';
import '../../../graph/presentation/graph_error_messages.dart';
import '../../../moderation/presentation/report_sheet.dart';
import 'block_confirmation_dialog.dart';
import 'profile_cover_band.dart';

/// The profile header: avatar, display name, `@handle`, bio, follower/
/// following counts, and (for other users, when the graph flag is on) a
/// [FollowButton] plus a block/mute overflow menu.
///
/// Owned by the graph plan (ADR-0008 D13); the posts/profile-timeline plan
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
  });

  final identity.Profile profile;
  final bool isOwnProfile;

  /// The profile follows the viewer (`GetProfileRelationship.followed_by`,
  /// ADR-0024 D7): shows the "Follows you" chip next to the handle and turns
  /// Follow into "Follow back". Only read with the graph flag on, on another
  /// user's profile, and not while the viewer blocks them.
  final bool followedBy;

  /// Opens the profile's website. Defaults to [launchPostLink] (external
  /// browser, a new tab on web) plus a "Couldn't open link." snackbar.
  final void Function(Uri uri)? onOpenWebsite;

  /// Put on the display name so the profile screen can tell when it scrolls
  /// under the app bar (the app-bar name fades in then, W3-13).
  final Key? nameKey;

  /// Offers "Report @handle" on other people's profiles (the `reports` flag,
  /// ADR-0016). Works with or without the graph menu.
  final bool reportsEnabled;

  /// Shows an "Edit profile" button on the viewer's own profile (P2-T5, only
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
      );
    }
    return BlocProvider(
      create: (context) => RelationshipCubit(
        graphRepository: context.read<GraphRepository>(),
        userId: profile.userId,
        initial: relationship!,
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
  });

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
        // banner).
        const actionsTop = AppSpacing.smd;
        final strip = math.max(
          overlap + AppSpacing.sm,
          actionsTop + AppSpacing.minTapTarget,
        );
        // Stack order is reading order: the identity first, then the actions.
        return Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: bannerHeight,
                  child: ProfileCoverBand(
                    url: _bannerUrlFor(profile, fullSize: !narrow),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    strip,
                    AppSpacing.md,
                    AppSpacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.displayName,
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
                                onTap: () => _openWebsite(
                                  context,
                                  website.uri,
                                  onOpenWebsite,
                                ),
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
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              left: AppSpacing.md,
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
                  ),
                ),
              ),
            ),
            if (actions != null)
              Positioned(
                top: bannerHeight + actionsTop,
                left: AppSpacing.md + outer + AppSpacing.sm,
                right: AppSpacing.md,
                child: Align(alignment: Alignment.topRight, child: actions),
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
          _OverflowMenu(profile: profile, canReport: canReport),
          const SizedBox(width: AppSpacing.xs),
          Flexible(child: FollowButton(followedBy: followedBy)),
        ],
      );
    }
    if (showActions) {
      return _OverflowMenu(profile: profile, canReport: canReport);
    }
    if (canReport) return _ReportOnlyMenu(profile: profile);
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
/// full image at 600 dp and above (ADR-0024 D1), whichever exists when only one
/// does. Empty = no banner. Both sizes are 3:1, so neither changes the layout.
String _bannerUrlFor(identity.Profile profile, {required bool fullSize}) {
  final full = profile.bannerUrl;
  final thumb = profile.bannerThumbUrl;
  final wanted = fullSize ? full : thumb;
  return wanted.isNotEmpty ? wanted : (fullSize ? thumb : full);
}

/// "Follows you", beside the handle: a small muted label on a raised surface
/// (X's own treatment). It is read as it is written, after the handle.
class _FollowsYouChip extends StatelessWidget {
  const _FollowsYouChip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
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
            color: context.appColors.secondaryOnRaised,
          ),
        ),
      ),
    );
  }
}

/// Opens a profile website outside the app (never fetched by us, ADR-0024 D2).
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
  const _CountsRow({required this.profile, required this.showPostsCount});

  final identity.Profile profile;
  final bool showPostsCount;

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
          onTap: () => context.push(
            AppRouter.followingPath(profile.handle),
            extra: profile.userId,
          ),
        ),
        _CountLink(
          count: profile.followersCount.toInt(),
          label: 'Followers',
          onTap: () => context.push(
            AppRouter.followersPath(profile.handle),
            extra: profile.userId,
          ),
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
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
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
/// (ADR-0008: "hides counts links"). The overflow menu (Mute/Unmute,
/// Block/Unblock) stays available up in the header row regardless.
class _BlockedBanner extends StatelessWidget {
  const _BlockedBanner({required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RelationshipCubit, RelationshipState>(
      builder: (context, state) {
        return AppSurface(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'You blocked @$handle',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              TextButton(
                onPressed: state.isUpdating
                    ? null
                    : () => context.read<RelationshipCubit>().unblock(),
                child: const Text('Unblock'),
              ),
            ],
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

/// "Report" alone, for a profile with the graph flag off (no Block/Mute).
class _ReportOnlyMenu extends StatelessWidget {
  const _ReportOnlyMenu({required this.profile});

  final identity.Profile profile;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'More options',
      child: PopupMenuButton<String>(
        icon: Icon(
          Icons.more_horiz,
          size: AppIconSize.lg,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        padding: const EdgeInsets.all(AppSpacing.md - AppSpacing.xs),
        onSelected: (_) => _reportAccount(context, profile, offerBlock: false),
        itemBuilder: (context) => [
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
  const _OverflowMenu({required this.profile, required this.canReport});

  final identity.Profile profile;
  final bool canReport;

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
              size: AppIconSize.lg,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            padding: const EdgeInsets.all(AppSpacing.md - AppSpacing.xs),
            onSelected: (value) async {
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
  });

  final IconData icon;
  final String text;
  final String? semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final link = onTap != null;
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: link ? context.appColors.accentText : muted,
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
      return Semantics(
        link: true,
        label: semanticLabel ?? text,
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
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              child: row,
            ),
          ),
        ),
      );
    }
    final label = semanticLabel;
    if (label == null) return row;
    return Semantics(label: label, excludeSemantics: true, child: row);
  }
}
