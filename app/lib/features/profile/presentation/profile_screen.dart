import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/app_pill_button.dart';
import '../../../shared/widgets/app_tab_bar.dart';
import '../../../core/router/compose_gate.dart';
import '../../../core/feature_flags/feature_flags.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../shared/widgets/post_pin_control.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/presentation/graph_feature_flags.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../../posts/data/posts_repository.dart';
import '../../posts/domain/posts_feature_flag.dart';
import '../../timeline/data/timeline_repository.dart';
import '../../timeline/domain/feed_key.dart';
import '../../timeline/domain/profile_tabs_feature_flag.dart';
import '../../timeline/presentation/bloc/timeline_cubit.dart';
import '../../timeline/presentation/bloc/timeline_state.dart';
import '../../timeline/presentation/timeline_feed_view.dart';
import '../../moderation/domain/reports_feature_flag.dart';
import '../domain/profile_edit_feature_flag.dart';
import 'bloc/pinned_post_cubit.dart';
import 'bloc/pinned_post_state.dart';
import 'bloc/post_pin_cubit.dart';
import 'bloc/profile_cubit.dart';
import 'bloc/profile_state.dart';
import 'widgets/pinned_post_section.dart';
import 'widgets/profile_header.dart';
import '../../../shared/widgets/protected_posts_view.dart';

/// `GetProfile(handle | user_id)` + (when the graph flag is on) the viewer's
/// relationship, rendered as [ProfileHeader], then (posts flag on) the Posts
/// tab (T18, ADR-0008 D13: the posts plan owns the body below the header).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, this.handle, this.userId})
    : assert(
        (handle == null) != (userId == null),
        'ProfileScreen takes exactly one of handle or userId',
      );

  /// Opens the profile by `@handle` (typed links, own profile tab).
  final String? handle;

  /// Opens the profile by id (post cards, mentions): immune to handle
  /// changes, since ChangeHandle frees old handles for others to claim.
  final String? userId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ProfileCubit>(
      key: ValueKey('profile-cubit-${userId ?? handle}'),
      create: (context) => ProfileCubit(
        identityRepository: context.read<IdentityRepository>(),
        graphRepository: context.read<GraphRepository>(),
        handle: handle,
        userId: userId,
        graphEnabled: graphEnabledSnapshot(context),
        ownUserId: context.read<OnboardingBloc>().state.profile?.userId,
      )..load(),
      child: const _ProfileView(),
    );
  }
}

class _ProfileView extends StatefulWidget {
  const _ProfileView();

  @override
  State<_ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<_ProfileView> {
  /// The one scroll position of the header (the outer view of the nested
  /// scroll, or the plain column): the app-bar name fades from it.
  final ScrollController _outer = ScrollController();
  final GlobalKey _bodyKey = GlobalKey();
  final GlobalKey _nameKey = GlobalKey();

  /// 0 while the header's own name is on screen, 1 once it has scrolled under
  /// the app bar. Scroll-linked (never timed), so it moves with the finger.
  final ValueNotifier<double> _nameFade = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _outer.addListener(_onScroll);
  }

  @override
  void dispose() {
    _outer
      ..removeListener(_onScroll)
      ..dispose();
    _nameFade.dispose();
    super.dispose();
  }

  bool _fadeScheduled = false;

  /// The scroll position moves before the header is laid out again, so the
  /// name's place is read after the frame, once the geometry is current.
  void _onScroll() {
    if (_fadeScheduled) return;
    _fadeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fadeScheduled = false;
      if (mounted) _nameFade.value = _fadeProgress();
    });
  }

  /// How much of the app-bar name to show: 0 until the header's name starts
  /// to slip under the app bar, 1 once it is under it, linear over
  /// [kProfileNameFadeDistance] in between.
  double _fadeProgress() {
    if (!_outer.hasClients) return 0;
    final name = _nameKey.currentContext?.findRenderObject();
    final body = _bodyKey.currentContext?.findRenderObject();
    if (name is RenderBox &&
        body is RenderBox &&
        name.attached &&
        body.attached &&
        name.hasSize &&
        body.hasSize) {
      final nameBottom = name.localToGlobal(Offset(0, name.size.height)).dy;
      final bodyTop = body.localToGlobal(Offset.zero).dy;
      return profileNameFade(distanceUnderBar: bodyTop - nameBottom);
    }
    // The name is not built (no header yet): fall back to the scroll extent.
    final position = _outer.position;
    if (position.maxScrollExtent <= 0) return 0;
    return (position.pixels / position.maxScrollExtent).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // The sticky header: the display name over the post count once the
        // profile is loaded (X), the requested @handle until then. The name
        // fades in only after the real one scrolls under the bar (B-05).
        title: BlocBuilder<ProfileCubit, ProfileState>(
          buildWhen: (a, b) =>
              a.profile?.handle != b.profile?.handle ||
              a.profile?.displayName != b.profile?.displayName ||
              a.profile?.postsCount != b.profile?.postsCount,
          builder: (context, state) {
            final profile = state.profile;
            if (profile == null || profile.displayName.isEmpty) {
              final handle =
                  profile?.handle ??
                  context.read<ProfileCubit>().requestedHandle;
              return Text(handle == null || handle.isEmpty ? '' : '@$handle');
            }
            final theme = Theme.of(context);
            final showCount = isFeatureEnabled(context, kFeaturePosts);
            final count = profile.postsCount.toInt();
            final title = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  profile.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (showCount)
                  Text(
                    count == 1 ? '1 post' : '$count posts',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            );
            return ValueListenableBuilder<double>(
              valueListenable: _nameFade,
              child: title,
              builder: (context, fade, child) {
                // Reduced motion: no fade, the name switches on at the
                // halfway point.
                final value = MediaQuery.disableAnimationsOf(context)
                    ? (fade >= 0.5 ? 1.0 : 0.0)
                    : fade;
                // One widget whose semantics never change with the scroll: it
                // stays the screen's title for assistive technology (the route
                // name) at any opacity, and there is no second copy to read.
                return Opacity(
                  key: const ValueKey('profile-appbar-name'),
                  opacity: value,
                  alwaysIncludeSemantics: true,
                  child: child,
                );
              },
            );
          },
        ),
      ),
      body: SafeArea(
        child: SizedBox.expand(
          key: _bodyKey,
          child: BlocBuilder<ProfileCubit, ProfileState>(
            builder: (context, state) {
              return switch (state.status) {
                ProfileStatus.loading => const Center(
                  child: CircularProgressIndicator(),
                ),
                ProfileStatus.notFound => const AppErrorView(
                  error: NotFoundException("This account doesn't exist."),
                ),
                ProfileStatus.error => AppErrorView(
                  error: state.error!,
                  onRetry: () => context.read<ProfileCubit>().load(),
                ),
                ProfileStatus.ready => _ReadyProfile(
                  state: state,
                  outer: _outer,
                  nameKey: _nameKey,
                ),
              };
            },
          ),
        ),
      ),
    );
  }
}

/// Distance (dp) over which the app-bar name fades in once the header's name
/// starts to slip under the app bar.
const double kProfileNameFadeDistance = AppSpacing.lg;

/// The app-bar name's opacity from how far the header's name has moved under
/// the app bar: [distanceUnderBar] is the bar's bottom edge minus the name's
/// bottom edge (at most -[kProfileNameFadeDistance] while the name is still
/// clear of the bar, 0 when its bottom touches the bar, positive once it is
/// gone). 0 at the top of the page, 1 once the name is under the bar.
double profileNameFade({required double distanceUnderBar}) =>
    (distanceUnderBar / kProfileNameFadeDistance + 1).clamp(0.0, 1.0);

class _ReadyProfile extends StatelessWidget {
  const _ReadyProfile({
    required this.state,
    required this.outer,
    required this.nameKey,
  });

  final ProfileState state;
  final ScrollController outer;
  final Key nameKey;

  @override
  Widget build(BuildContext context) {
    if (isFeatureEnabled(context, kFeaturePosts)) {
      return _ProfilePosts(state: state, outer: outer, nameKey: nameKey);
    }
    // Posts flag off: the Phase 0 body.
    return _ScrollColumn(
      controller: outer,
      children: [
        _header(context, state, showPostsCount: false, nameKey: nameKey),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(
            "This profile's posts are coming soon.",
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

/// Opens Edit profile; a saved edit pops with the server's profile, which the
/// header shows directly (no GetProfile re-read).
Future<void> _editProfile(BuildContext context) async {
  final cubit = context.read<ProfileCubit>();
  final saved = await context.push<identity.Profile>(AppRouter.editProfilePath);
  if (saved != null && !cubit.isClosed) cubit.profileUpdated(saved);
}

ProfileHeader _header(
  BuildContext context,
  ProfileState state, {
  required bool showPostsCount,
  required Key nameKey,
}) {
  return ProfileHeader(
    profile: state.profile!,
    isOwnProfile: state.isOwnProfile,
    graphEnabled: state.graphEnabled,
    relationship: state.relationship,
    followedBy: state.followedBy,
    showPostsCount: showPostsCount,
    nameKey: nameKey,
    reportsEnabled: isFeatureEnabled(context, kFeatureReports),
    onRelationshipChanged: (relationship) =>
        context.read<ProfileCubit>().relationshipChanged(relationship),
    onEditProfile:
        state.isOwnProfile && isFeatureEnabled(context, kFeatureProfileSnapshot)
        ? () => _editProfile(context)
        : null,
  );
}

/// A column that is centered and capped to the mobile width on wide screens,
/// so the header never stretches edge to edge on tablet/desktop
/// (`flutter-feature` skill: LayoutBuilder breakpoints).
class _ScrollColumn extends StatelessWidget {
  const _ScrollColumn({required this.children, required this.controller});

  final List<Widget> children;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppBreakpoints.mobile;
        return SingleChildScrollView(
          controller: controller,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isWide ? AppBreakpoints.mobile : double.infinity,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The id of the Posts tab: the default selection, and the tab whose cubit
/// the Pinned row filters (W3-17).
const _postsTabId = 'posts';

/// One tab of the profile: everything the scroll scaffold needs to show it.
/// The tab list is data, so another tab is one more entry in
/// [_profileTabSpecs], with no change to the scroll structure (W3-16 added
/// Reposts and Media that way).
@immutable
class _ProfileTabSpec {
  const _ProfileTabSpec({
    required this.id,
    required this.label,
    required this.feedFor,
    required this.emptyTitle,
    this.emptySubtitle,
    this.ownPosts = false,
    this.showsPinned = false,
    this.requiresProfileTabs = false,
  });

  /// Stable id: keys the tab's cubit, its scroll offset and its widgets.
  final String id;
  final String label;

  /// The cached feed this tab shows for a profile's user id.
  final FeedKey Function(String userId) feedFor;
  final String Function({required bool own, required String handle}) emptyTitle;

  /// One line of guidance under [emptyTitle]; null for none.
  final String Function({required bool own, required String handle})?
  emptySubtitle;

  /// The own profile's pending posts and "Write a post" belong to this tab.
  final bool ownPosts;

  /// The Pinned row (W3-17) sits above this tab's posts, and the post it shows
  /// is left out of them.
  final bool showsPinned;

  /// A tab the server serves only while `profile_tabs` is on for the caller
  /// (Reposts, Media). It is listed only with the flag, and a FEATURE_DISABLED
  /// answer for it drops every such tab (see [_ProfilePostsState]). Its pages
  /// can be short or empty while a next page exists, so its feed follows the
  /// token (`TimelineFeedView.fillViewport`).
  final bool requiresProfileTabs;
}

/// The tabs for the enabled sub-features, in display order: Posts,
/// Replies (the `replies` sub-feature), Reposts and Media (`profile_tabs`).
List<_ProfileTabSpec> _profileTabSpecs({
  required bool showReplies,
  required bool showProfileTabs,
}) => [
  _ProfileTabSpec(
    id: _postsTabId,
    label: 'Posts',
    feedFor: (userId) => FeedKey.user(userId),
    emptyTitle: ({required own, required handle}) =>
        own ? "You haven't posted yet" : "@$handle hasn't posted yet",
    ownPosts: true,
    showsPinned: true,
  ),
  if (showReplies)
    _ProfileTabSpec(
      id: 'replies',
      label: 'Replies',
      feedFor: (userId) => FeedKey.user(userId, includeReplies: true),
      emptyTitle: ({required own, required handle}) =>
          own ? "You haven't replied yet" : "@$handle hasn't replied yet",
    ),
  if (showProfileTabs) ...[
    _ProfileTabSpec(
      id: 'reposts',
      label: 'Reposts',
      feedFor: (userId) => FeedKey.user(userId, tab: UserFeedTab.reposts),
      emptyTitle: ({required own, required handle}) =>
          own ? "You haven't reposted yet" : "@$handle hasn't reposted yet",
      emptySubtitle: ({required own, required handle}) => own
          ? 'Posts you repost will be listed here.'
          : 'Posts they repost will be listed here.',
      requiresProfileTabs: true,
    ),
    _ProfileTabSpec(
      id: 'media',
      label: 'Media',
      feedFor: (userId) => FeedKey.user(userId, tab: UserFeedTab.media),
      emptyTitle: ({required own, required handle}) => own
          ? "You haven't shared any images yet"
          : "@$handle hasn't shared any images yet",
      emptySubtitle: ({required own, required handle}) => own
          ? 'Posts with your images will be listed here.'
          : 'Posts with their images will be listed here.',
      requiresProfileTabs: true,
    ),
  ],
];

/// Header + the Posts and Replies tabs (Replies only with the `replies`
/// sub-feature on: the same `GetUserTimeline` with `include_replies`, cursor
/// paged like Posts), then Reposts and Media (only with `profile_tabs` on:
/// the same call with its `tab`, ADR-0024 D5). Each tab is its own cached
/// feed (`FeedKey.user(uid, tab: ...)`) with its own cursor and tokens, so a
/// token never travels to another tab. When the
/// viewer blocks the author the feed is not even requested: a banner offers
/// "Show posts" (ADR-0010 D6, computed from the local relationship).
///
/// If the server still answers a Reposts or Media call with FEATURE_DISABLED
/// `profile_tabs` (the flag turned off since `GetMe`), the screen drops those
/// tabs and shows Posts and Replies; the repository sends nothing more for
/// them until the next `GetMe`.
///
/// Scrolling (W3-13): one `NestedScrollView`. The header scrolls away, the
/// tab bar pins under the app bar, and only the selected tab's list is
/// mounted; each tab keeps its own offset (a `PageStorageKey`) and its own
/// cubit, which this state holds, so switching back shows the same rows
/// without a request.
class _ProfilePosts extends StatefulWidget {
  const _ProfilePosts({
    required this.state,
    required this.outer,
    required this.nameKey,
  });

  final ProfileState state;
  final ScrollController outer;
  final Key nameKey;

  @override
  State<_ProfilePosts> createState() => _ProfilePostsState();
}

class _ProfilePostsState extends State<_ProfilePosts> {
  bool _showBlockedPosts = false;

  /// The selected tab, by [_ProfileTabSpec.id] and not by position: the tab
  /// list changes length with the flags, and a missing id falls back to the
  /// first tab (Posts).
  String _tabId = _postsTabId;

  /// The server refused a `profile_tabs` tab although `GetMe` listed the
  /// flag: Reposts and Media are left out for the rest of this screen.
  bool _profileTabsRefused = false;

  /// One cubit per tab that was opened, by tab id: created on first open
  /// (0 requests for a tab nobody opens), closed with the screen.
  final Map<String, TimelineCubit> _cubits = {};

  /// The profile's Pinned row (W3-17), created on the first build that shows
  /// posts (never while the blocked banner stands in for them) and told about
  /// every change of the profile's `pinned_post_id`.
  PinnedPostCubit? _pinned;
  StreamSubscription<PinnedPostState>? _pinnedSub;

  /// Pin / Unpin from the own profile's post menus.
  PostPinCubit? _postPin;

  @override
  void didUpdateWidget(_ProfilePosts oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pin = widget.state.profile?.pinnedPostId;
    if (pin != oldWidget.state.profile?.pinnedPostId) _pinned?.pinChanged(pin);
  }

  @override
  void dispose() {
    for (final cubit in _cubits.values) {
      unawaited(cubit.close());
    }
    unawaited(_pinnedSub?.cancel());
    unawaited(_pinned?.close());
    unawaited(_postPin?.close());
    super.dispose();
  }

  /// The one [PinnedPostCubit] of this profile. The post it covers (loading
  /// or shown) is kept out of the Posts tab's rows, so it is never repeated
  /// below the Pinned row.
  PinnedPostCubit _pinnedFor(BuildContext context, identity.Profile profile) {
    final existing = _pinned;
    if (existing != null) return existing;
    final profileCubit = context.read<ProfileCubit>();
    final cubit = PinnedPostCubit(
      posts: context.read<PostsRepository>(),
      // The deleted post can only be the viewer's own: the header's count
      // and pin follow at once (the server unpins in a job).
      onDeleted: () {
        if (!profileCubit.isClosed) profileCubit.pinnedPostDeleted();
      },
    );
    _pinnedSub = cubit.stream.listen(
      (pinned) => _cubits[_postsTabId]?.setExcludedPostId(pinned.coveredPostId),
    );
    cubit.pinChanged(profile.pinnedPostId);
    return _pinned = cubit;
  }

  /// The own profile's Pin / Unpin cubit; a saved change reaches the session's
  /// own profile (`OnboardingProfileUpdated`) and this profile's header.
  PostPinCubit _postPinFor(BuildContext context) {
    final existing = _postPin;
    if (existing != null) return existing;
    final profileCubit = context.read<ProfileCubit>();
    final onboarding = context.read<OnboardingBloc>();
    return _postPin = PostPinCubit(
      identityRepository: context.read<IdentityRepository>(),
      onProfileUpdated: (profile) {
        onboarding.add(OnboardingProfileUpdated(profile));
        if (!profileCubit.isClosed) profileCubit.profileUpdated(profile);
      },
    );
  }

  TimelineCubit _cubitFor(
    BuildContext context,
    _ProfileTabSpec spec, {
    required String userId,
    required String? viewerUserId,
  }) {
    final profileCubit = context.read<ProfileCubit>();
    return _cubits.putIfAbsent(
      spec.id,
      () =>
          TimelineCubit(
              feed: spec.feedFor(userId),
              timeline: context.read<TimelineRepository>(),
              posts: context.read<PostsRepository>(),
              viewerUserId: viewerUserId,
              // The header's post count follows a delete at once (a deleted post
              // can only be the viewer's own).
              onPostDeleted: (_) {
                if (!profileCubit.isClosed) profileCubit.postDeleted();
              },
            )
            ..setExcludedPostId(
              spec.showsPinned ? _pinned?.state.coveredPostId : null,
            )
            ..load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final profile = state.profile!;
    final viewerUserId = context.read<OnboardingBloc>().state.profile?.userId;
    final header = _header(
      context,
      state,
      showPostsCount: true,
      nameKey: widget.nameKey,
    );
    final blocked = state.relationship?.blocking ?? false;
    final specs = _profileTabSpecs(
      showReplies: isFeatureEnabled(context, kPostsSubFeatureReplies),
      showProfileTabs:
          isFeatureEnabled(context, kFeatureProfileTabs) &&
          !_profileTabsRefused,
    );
    final tab = math.max(0, specs.indexWhere((s) => s.id == _tabId));
    final spec = specs[tab];
    final canCompose = canComposeAt(context, AppRouter.homePath);
    final tabBar = AppTabBar(
      equalWidth: true,
      semanticLabel: 'Profile timelines',
      selectedIndex: tab,
      onChanged: (index) => setState(() => _tabId = specs[index].id),
      tabs: [for (final s in specs) AppTab(label: s.label)],
    );
    final scrollKey = PageStorageKey<String>(
      'profile-${profile.userId}-${spec.id}',
    );

    if (blocked && !_showBlockedPosts) {
      return _ProfileScrollScaffold(
        outer: widget.outer,
        header: header,
        tabBar: tabBar,
        // A Builder: the overlap handle lives inside the NestedScrollView.
        body: Builder(
          builder: (context) => CustomScrollView(
            key: scrollKey,
            slivers: [
              SliverOverlapInjector(
                handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                  context,
                ),
              ),
              SliverToBoxAdapter(
                child: _BlockedPostsBanner(
                  handle: profile.handle,
                  onShow: () => setState(() => _showBlockedPosts = true),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final cubit = _cubitFor(
      context,
      spec,
      userId: profile.userId,
      viewerUserId: viewerUserId,
    );
    // A protected account's posts: the server's `author_protected` answer
    // replaces the tabs, the pin and the cached feeds with one view (ADR-0025
    // D4). Nothing below is built then, so a stale pinned id costs no GetPost.
    Widget tabbed() {
      final profileCubit = context.read<ProfileCubit>();
      final ownPosts = state.isOwnProfile && spec.ownPosts;
      final pinned = _pinnedFor(context, profile);
      // Pin / Unpin on the own profile. Unpin (a clear) is offered whatever the
      // flags are (ADR-0024 Amendment 1 A2); Pin (a set) needs `profile_extras`
      // on for the viewer. The Pinned row itself renders whatever the flags are.
      final isOwn = state.isOwnProfile;
      final pinEnabled =
          isOwn && isFeatureEnabled(context, kFeatureProfileExtras);
      final postPin = _postPinFor(context);
      return _ProfileScrollScaffold(
        outer: widget.outer,
        header: header,
        tabBar: tabBar,
        onRefresh: cubit.refresh,
        body: BlocProvider<TimelineCubit>.value(
          key: ValueKey('profile-posts-${profile.userId}-${spec.id}'),
          value: cubit,
          child: BlocListener<TimelineCubit, TimelineState>(
            listenWhen: (before, after) =>
                spec.requiresProfileTabs && _refusedProfileTabs(after),
            listener: (context, _) => setState(() {
              _profileTabsRefused = true;
              _tabId = _postsTabId;
            }),
            child: _withPinControl(
              postPin,
              own: isOwn,
              canPin: pinEnabled,
              pinnedPostId: profile.pinnedPostId,
              builder: (pinControl) {
                // The request can outlive this screen: guard the cubit, not
                // context.
                void onRelationshipChanged(graph.Relationship relationship) {
                  if (!profileCubit.isClosed) {
                    profileCubit.relationshipChanged(relationship);
                  }
                }

                Widget feed({required bool pinCovered}) => TimelineFeedView(
                  nested: true,
                  fillViewport: spec.requiresProfileTabs,
                  scrollViewKey: scrollKey,
                  newPostsPillTop: AppSpacing.sm,
                  viewerUserId: viewerUserId,
                  headerSlivers: [
                    if (spec.showsPinned)
                      SliverToBoxAdapter(
                        child: PinnedPostSection(
                          cubit: pinned,
                          viewerUserId: viewerUserId,
                          onRelationshipChanged: onRelationshipChanged,
                          pinControl: pinControl,
                        ),
                      ),
                  ],
                  emptyTitle: spec.emptyTitle(
                    own: state.isOwnProfile,
                    handle: profile.handle,
                  ),
                  emptySubtitle: spec.emptySubtitle?.call(
                    own: state.isOwnProfile,
                    handle: profile.handle,
                  ),
                  emptyAction: ownPosts && canCompose
                      ? AppPillButton(
                          label: 'Write a post',
                          compact: true,
                          onPressed: () => context.push(AppRouter.composePath),
                        )
                      : null,
                  // Only post here is the one in the Pinned row above.
                  hideEmptyState: pinCovered,
                  showPending: ownPosts,
                  pendingAuthorId: viewerUserId,
                  hideAuthorsOnRelationship: false,
                  onRelationshipChanged: onRelationshipChanged,
                  pinControl: pinControl,
                );

                if (!spec.showsPinned) return feed(pinCovered: false);
                return BlocBuilder<PinnedPostCubit, PinnedPostState>(
                  bloc: pinned,
                  buildWhen: (before, after) =>
                      (before.coveredPostId != null) !=
                      (after.coveredPostId != null),
                  builder: (context, pinnedState) =>
                      feed(pinCovered: pinnedState.coveredPostId != null),
                );
              },
            ),
          ),
        ),
      );
    }

    if (state.isOwnProfile) return tabbed();
    return BlocBuilder<TimelineCubit, TimelineState>(
      bloc: cubit,
      buildWhen: (before, after) =>
          before.authorProtected != after.authorProtected,
      builder: (context, timeline) {
        if (!timeline.authorProtected) return tabbed();
        return _ProfileScrollScaffold(
          outer: widget.outer,
          header: header,
          tabBar: null,
          onRefresh: cubit.refresh,
          body: CustomScrollView(
            key: PageStorageKey<String>('profile-${profile.userId}-protected'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: ProtectedPostsView(handle: profile.handle),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The tab's cubit holds a FEATURE_DISABLED `profile_tabs` answer, as the
  /// blocking error (nothing cached) or as the notice over cached rows.
  static bool _refusedProfileTabs(TimelineState state) {
    bool refused(Object? error) =>
        error is FeatureDisabledException &&
        error.feature == kFeatureProfileTabs;
    return refused(state.error) || refused(state.notice);
  }

  /// Builds the tab body with the Pin / Unpin control of the own profile
  /// ([own]; the control is null on anyone else's profile, so the cards offer
  /// no pin rows). [canPin] (`profile_extras` on for the viewer) and no
  /// refusal by the server (this cubit's request, or an earlier one this
  /// session: `IdentityRepository.profileExtrasRefused`, read only when
  /// [canPin]) decide whether "Pin to your profile" is offered; "Unpin from
  /// profile" never depends on them (ADR-0024 Amendment 1 A2). The wrapper is
  /// always there, so the feed view keeps its state when the flag changes
  /// while the screen is open.
  Widget _withPinControl(
    PostPinCubit cubit, {
    required bool own,
    required bool canPin,
    required String pinnedPostId,
    required Widget Function(PostPinControl? control) builder,
  }) {
    return BlocBuilder<PostPinCubit, PostPinState>(
      bloc: cubit,
      builder: (context, pinState) => builder(
        own
            ? PostPinControl(
                pinnedPostId: pinnedPostId,
                onPin: cubit.pin,
                onUnpin: cubit.unpin,
                canPin:
                    canPin &&
                    !pinState.refused &&
                    !context.read<IdentityRepository>().profileExtrasRefused,
              )
            : null,
      ),
    );
  }
}

/// The profile's scroll structure, independent of what the tabs show: a
/// `NestedScrollView` whose outer slivers are the header and the tab bar
/// pinned under the app bar, and whose body is the selected tab's scroll view
/// (which must start with a `SliverOverlapInjector`). Wide screens centre the
/// header and tab bar in the same column the feed uses.
///
/// [onRefresh] (the selected tab's refresh) wraps the whole view: a body's own
/// indicator never sees the overscroll of a nested scroll (checked in
/// Flutter 3.47), the wrapper does. Null = no pull-to-refresh (nothing to
/// refresh).
class _ProfileScrollScaffold extends StatelessWidget {
  const _ProfileScrollScaffold({
    required this.outer,
    required this.header,
    required this.tabBar,
    required this.body,
    this.onRefresh,
  });

  final ScrollController outer;
  final Widget header;

  /// Null = no tab bar (a protected account's posts, one view for all tabs).
  final Widget? tabBar;
  final Widget body;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final background = Theme.of(context).scaffoldBackgroundColor;
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = math.max(
          0.0,
          (constraints.maxWidth - AppBreakpoints.mobile) / 2,
        );
        Widget centred(Widget sliver) => SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: sliver,
        );
        final view = NestedScrollView(
          controller: outer,
          physics: const AlwaysScrollableScrollPhysics(),
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            centred(SliverToBoxAdapter(child: header)),
            centred(const SliverToBoxAdapter(child: Divider(height: 1))),
            if (tabBar != null)
              SliverOverlapAbsorber(
                handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                  context,
                ),
                sliver: centred(
                  PinnedHeaderSliver(
                    child: ColoredBox(color: background, child: tabBar),
                  ),
                ),
              ),
          ],
          body: body,
        );
        final refresh = onRefresh;
        return refresh == null
            ? view
            : RefreshIndicator(
                onRefresh: refresh,
                // Overscroll arrives from the body (depth 1) or, over the
                // header, from the outer view (depth 0); nothing deeper
                // (a horizontal strip inside a post) may start a refresh.
                notificationPredicate: (notification) =>
                    notification.depth <= 1 &&
                    notification.metrics.axis == Axis.vertical,
                child: view,
              );
      },
    );
  }
}

/// "You blocked @x - Show posts": the posts stay unrequested until the user
/// asks.
class _BlockedPostsBanner extends StatelessWidget {
  const _BlockedPostsBanner({required this.handle, required this.onShow});

  final String handle;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'You blocked @$handle \u00B7',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
            ),
            onPressed: onShow,
            child: const Text('Show posts'),
          ),
        ],
      ),
    );
  }
}
