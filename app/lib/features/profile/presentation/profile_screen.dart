import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/context_pane.dart';
import '../../../core/widgets/context_pane_slots.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/primitives/app_tab_bar.dart';
import '../../../core/router/compose_gate.dart';
import '../../../core/feature_flags/feature_flags.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../shared/widgets/post/post_pin_control.dart';
import '../../graph/data/graph_repository.dart';
import '../../lists/domain/lists_feature_flag.dart';
import '../../messages/domain/messaging_feature_flag.dart';
import '../../messages/presentation/open_conversation.dart';
import '../../graph/presentation/graph_feature_flags.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../../engagement/presentation/bloc/engagement_cubit.dart';
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
import 'widgets/profile_media_strip.dart';
import '../../../shared/widgets/post/protected_posts_view.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/widgets/shell_geometry.dart';

/// `GetProfile(handle | user_id)` + (when the graph flag is on) the viewer's
/// relationship, rendered as [ProfileHeader], then (posts flag on) the Posts
/// tab (the posts plan owns the body below the header).
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
      child: _ProfileView(
        location: handle != null
            ? AppRouter.profilePath(handle!)
            : AppRouter.profileByIdPath(userId!),
      ),
    );
  }
}

class _ProfileView extends StatefulWidget {
  const _ProfileView({required this.location});

  /// This page's route: the context pane's sections are lent under it.
  final String location;

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

  /// Band B's media strip until the posts below take over (T8c): its
  /// placeholder while the profile loads, nothing once it cannot show
  /// (failed, not found). The posts lend the strip itself (a later lease of
  /// the same location wins), over the page's own Media tab feed.
  final _paneLease = ContextPaneLease();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final profile = context.read<ProfileCubit>();
    _paneLease.attach(context, widget.location, {
      ContextSectionKind.profileMedia: (context) =>
          BlocBuilder<ProfileCubit, ProfileState>(
            bloc: profile,
            buildWhen: (a, b) => a.status != b.status,
            builder: (context, state) => switch (state.status) {
              ProfileStatus.loading ||
              ProfileStatus.ready => const ProfileMediaStripPlaceholder(),
              ProfileStatus.notFound ||
              ProfileStatus.error => const SizedBox.shrink(),
            },
          ),
    });
  }

  @override
  void dispose() {
    _paneLease.dispose();
    _outer
      ..removeListener(_onScroll)
      ..dispose();
    _nameFade.dispose();
    super.dispose();
  }

  bool _fadeScheduled = false;

  /// Where the app bar ends, from the top of the screen (set by `build`).
  double _barBottom = kToolbarHeight;

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
      // The body starts at the top of the screen, behind the app bar: the
      // bar's bottom edge is the status bar plus the toolbar below it.
      final barBottom = body.localToGlobal(Offset.zero).dy + _barBottom;
      return profileNameFade(distanceUnderBar: barBottom - nameBottom);
    }
    // The name is not built (no header yet): fall back to the scroll extent.
    final position = _outer.position;
    if (position.maxScrollExtent <= 0) return 0;
    return (position.pixels / position.maxScrollExtent).clamp(0.0, 1.0);
  }

  /// The app bar over the hero: the hero starts at the very top of the screen
  /// (the mocks), so while the header's own name is on screen the bar is
  /// clear with pearl icons over the navy; as the name slips under it the bar
  /// fills with the page surface and the name fades in (one scroll-linked
  /// value). A pushed profile has its Back in the hero's top row until then.
  PreferredSizeWidget _appBar(BuildContext context) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: BlocBuilder<ProfileCubit, ProfileState>(
        buildWhen: (a, b) =>
            a.status != b.status ||
            a.profile?.handle != b.profile?.handle ||
            a.profile?.displayName != b.profile?.displayName ||
            a.profile?.postsCount != b.profile?.postsCount,
        builder: (context, state) {
          final heroShown = state.status == ProfileStatus.ready;
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final profile = state.profile;
          final Widget title;
          if (profile == null || profile.displayName.isEmpty) {
            final handle =
                profile?.handle ?? context.read<ProfileCubit>().requestedHandle;
            title = Text(handle == null || handle.isEmpty ? '' : '@$handle');
          } else {
            final showCount = isFeatureEnabled(context, kFeaturePosts);
            final count = profile.postsCount.toInt();
            title = Column(
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
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            );
          }
          return ValueListenableBuilder<double>(
            valueListenable: _nameFade,
            builder: (context, fade, _) {
              // Reduced motion: no fade, the bar switches on at the halfway
              // point.
              final value = MediaQuery.disableAnimationsOf(context)
                  ? (fade >= 0.5 ? 1.0 : 0.0)
                  : fade;
              // The name is the one widget whose semantics never change with
              // the scroll: it stays the screen's title for assistive
              // technology (the route name) at any opacity, and there is no
              // second copy to read.
              final named = profile == null || profile.displayName.isEmpty
                  ? title
                  : Opacity(
                      key: const ValueKey('profile-appbar-name'),
                      opacity: value,
                      alwaysIncludeSemantics: true,
                      child: title,
                    );
              final bar = AppBar(
                backgroundColor: heroShown
                    ? scheme.surface.withValues(alpha: value)
                    : Colors.transparent,
                foregroundColor: heroShown
                    ? Color.lerp(AppPalette.pearl, scheme.onSurface, value)
                    : scheme.onSurface,
                elevation: 0,
                scrolledUnderElevation: 0,
                surfaceTintColor: Colors.transparent,
                // Light status-bar icons over the navy hero.
                systemOverlayStyle: heroShown && value < 0.5
                    ? SystemUiOverlayStyle.light
                    : null,
                // Back lives in the hero's top row while the hero shows.
                automaticallyImplyLeading: !heroShown || value > 0,
                title: named,
              );
              // Over the hero the bar has nothing to tap: let the hero's own
              // buttons take the touches.
              return IgnorePointer(
                ignoring: heroShown && value == 0,
                child: bar,
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    _barBottom = topInset + kToolbarHeight;
    return _ProfileChrome(
      topInset: topInset,
      barBottom: _barBottom,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: _appBar(context),
        body: SafeArea(
          top: false,
          child: SizedBox.expand(
            key: _bodyKey,
            child: BlocBuilder<ProfileCubit, ProfileState>(
              builder: (context, state) {
                // The states without a hero start under the app bar.
                Widget belowBar(Widget child) => Padding(
                  padding: EdgeInsets.only(top: _barBottom),
                  child: child,
                );
                return switch (state.status) {
                  ProfileStatus.loading => belowBar(
                    const Center(child: CircularProgressIndicator()),
                  ),
                  ProfileStatus.notFound => belowBar(
                    const AppErrorView(
                      error: NotFoundException("This account doesn't exist."),
                    ),
                  ),
                  ProfileStatus.error => belowBar(
                    AppErrorView(
                      error: state.error!,
                      onRetry: () => context.read<ProfileCubit>().load(),
                    ),
                  ),
                  ProfileStatus.ready => _ReadyProfile(
                    state: state,
                    outer: _outer,
                    nameKey: _nameKey,
                    location: widget.location,
                  ),
                };
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// What the profile's chrome gives the body: the status-bar inset the hero
/// draws under and where the app bar ends (the pinned tabs stop there).
class _ProfileChrome extends InheritedWidget {
  const _ProfileChrome({
    required this.topInset,
    required this.barBottom,
    required super.child,
  });

  final double topInset;
  final double barBottom;

  static _ProfileChrome of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ProfileChrome>()!;

  @override
  bool updateShouldNotify(_ProfileChrome old) =>
      topInset != old.topInset || barBottom != old.barBottom;
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
    required this.location,
  });

  final ProfileState state;
  final ScrollController outer;
  final Key nameKey;
  final String location;

  @override
  Widget build(BuildContext context) {
    if (isFeatureEnabled(context, kFeaturePosts)) {
      return _ProfilePosts(
        state: state,
        outer: outer,
        nameKey: nameKey,
        location: location,
      );
    }
    // Posts flag off: the Phase 0 body.
    return _ScrollColumn(
      controller: outer,
      children: [
        _header(context, state, showPostsCount: false, nameKey: nameKey),
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
    // The navy hero of the Profile mocks, at every width, from the top of
    // the screen (under the status bar and the clear app bar).
    style: ProfileHeaderStyle.hero,
    topInset: _ProfileChrome.of(context).topInset,
    // A pushed profile has Back in the hero's top row.
    onBack: _backAction(context),
    reportsEnabled: isFeatureEnabled(context, kFeatureReports),
    // The Lists rows of the overflow menu.
    listsEnabled: isFeatureEnabled(context, kFeatureLists),
    // The envelope button, only with `messaging` on for the caller.
    onMessage:
        !state.isOwnProfile && isFeatureEnabled(context, kFeatureMessaging)
        ? () => unawaited(
            openConversationWith(context, _messageRecipient(state.profile!)),
          )
        : null,
    onRelationshipChanged: (relationship) =>
        context.read<ProfileCubit>().relationshipChanged(relationship),
    onEditProfile:
        state.isOwnProfile && isFeatureEnabled(context, kFeatureProfileSnapshot)
        ? () => _editProfile(context)
        : null,
  );
}

/// Back for a pushed profile, or null at the root of a navigator (the shell's
/// own page has nothing to go back to). Works without a router (a profile
/// shown by itself in a test).
VoidCallback? _backAction(BuildContext context) {
  final router = GoRouter.maybeOf(context);
  if (router != null) return router.canPop() ? router.pop : null;
  return Navigator.canPop(context) ? () => Navigator.of(context).pop() : null;
}

/// The person a Message button on [profile] writes to.
common.AuthorSnapshot _messageRecipient(identity.Profile profile) =>
    common.AuthorSnapshot(
      userId: profile.userId,
      handle: profile.handle,
      displayName: profile.displayName,
      avatarUrl: profile.avatarThumbUrl.isNotEmpty
          ? profile.avatarThumbUrl
          : profile.avatarUrl,
      verified: profile.verified,
      isPrivate: profile.isPrivate,
    );

/// A column that is centered and capped to the mobile width on wide screens,
/// so the header never stretches edge to edge on tablet/desktop
/// (LayoutBuilder breakpoints).
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
/// the Pinned row filters.
const _postsTabId = 'posts';

/// The id of the Media tab, whose feed band B's media strip shows (T8c).
const _mediaTabId = 'media';

/// One tab of the profile: everything the scroll scaffold needs to show it.
/// The tab list is data, so another tab is one more entry in
/// [_profileTabSpecs], with no change to the scroll structure (added
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
    this.fillViewport = false,
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

  /// The Pinned row sits above this tab's posts, and the post it shows
  /// is left out of them.
  final bool showsPinned;

  /// A tab the server serves only while `profile_tabs` is on for the caller
  /// (Reposts, Media). It is listed only with the flag, and a FEATURE_DISABLED
  /// answer for it drops every such tab (see [_ProfilePostsState]). Its pages
  /// can be short or empty while a next page exists, so its feed follows the
  /// token (`TimelineFeedView.fillViewport`).
  final bool requiresProfileTabs;

  /// Filtered timelines can return a short or empty page with more results.
  final bool fillViewport;
}

/// The tabs for the enabled sub-features, in display order: Posts,
/// Reposts and Media (`profile_tabs`),
/// then Articles (the base `posts` capability).
List<_ProfileTabSpec> _profileTabSpecs({required bool showProfileTabs}) => [
  _ProfileTabSpec(
    id: _postsTabId,
    label: 'Posts',
    feedFor: (userId) => FeedKey.user(userId),
    emptyTitle: ({required own, required handle}) =>
        own ? "You haven't posted yet" : "@$handle hasn't posted yet",
    ownPosts: true,
    showsPinned: true,
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
      fillViewport: true,
    ),
    _ProfileTabSpec(
      id: _mediaTabId,
      label: 'Media',
      feedFor: (userId) => FeedKey.user(userId, tab: UserFeedTab.media),
      emptyTitle: ({required own, required handle}) => own
          ? "You haven't shared any images yet"
          : "@$handle hasn't shared any images yet",
      emptySubtitle: ({required own, required handle}) => own
          ? 'Posts with your images will be listed here.'
          : 'Posts with their images will be listed here.',
      requiresProfileTabs: true,
      fillViewport: true,
    ),
  ],
  _ProfileTabSpec(
    id: 'articles',
    label: 'Articles',
    fillViewport: true,
    feedFor: (userId) => FeedKey.user(userId, tab: UserFeedTab.articles),
    emptyTitle: ({required own, required handle}) => own
        ? "You haven't published any articles yet"
        : "@$handle hasn't published any articles yet",
    emptySubtitle: ({required own, required handle}) => own
        ? 'Articles you publish will be listed here.'
        : 'Articles they publish will be listed here.',
  ),
];

/// Header + Posts, Reposts, Media and Articles. Reposts and Media require
/// `profile_tabs`. Each tab is its own cached
/// feed (`FeedKey.user(uid, tab: ...)`) with its own cursor and tokens, so a
/// token never travels to another tab. When the
/// viewer blocks the author the feed is not even requested: a banner offers
/// "Show posts" (computed from the local relationship).
///
/// If the server still answers a Reposts or Media call with FEATURE_DISABLED
/// `profile_tabs` (the flag turned off since `GetMe`), the screen drops those
/// tabs and shows Posts and Articles; the repository sends nothing more for
/// them until the next `GetMe`.
///
/// Scrolling: one `NestedScrollView`. The header scrolls away, the
/// tab bar pins under the app bar, and a TabBarView supports swiping.
/// Unopened tabs load on selection; each tab keeps its own offset and its own
/// cubit, which this state holds, so switching back shows the same rows
/// without a request.
class _ProfilePosts extends StatefulWidget {
  const _ProfilePosts({
    required this.state,
    required this.outer,
    required this.nameKey,
    required this.location,
  });

  final ProfileState state;
  final ScrollController outer;
  final Key nameKey;

  /// The page's route, for the context pane's lease.
  final String location;

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

  /// The profile's Pinned row, created on the first build that shows
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

  /// Band B's media strip (T8c), lent to the context pane over this
  /// state's own Media tab feed: the pane sends no call of its own, and the
  /// Media tab opened later (or before) reuses the same feed.
  final _paneLease = ContextPaneLease();

  /// Bumped when something the strip reads changes outside a cubit (the
  /// blocked banner's Show posts, a refused `profile_tabs`): the page's own
  /// `setState` does not rebuild the pane.
  final _paneGate = ValueNotifier<int>(0);

  /// The page's profile, read once for the pane (which builds outside this
  /// page, possibly after it is gone).
  late ProfileCubit _profileCubit;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _profileCubit = context.read<ProfileCubit>();
    _paneLease.attach(context, widget.location, {
      ContextSectionKind.profileMedia: _mediaStrip,
    });
  }

  /// The strip, or nothing when it cannot show: Reposts and Media off or
  /// refused, the posts hidden behind the blocked banner, or (another
  /// person's profile) protected posts. Their Media feed is asked for only
  /// once none of these holds.
  Widget _mediaStrip(BuildContext _) => ValueListenableBuilder<int>(
    valueListenable: _paneGate,
    builder: (_, _, _) => BlocBuilder<ProfileCubit, ProfileState>(
      bloc: _profileCubit,
      builder: (paneContext, state) {
        final profile = state.profile;
        if (!mounted ||
            profile == null ||
            _profileTabsRefused ||
            !isFeatureEnabled(paneContext, kFeatureProfileTabs)) {
          return const SizedBox.shrink();
        }
        if ((state.relationship?.blocking ?? false) && !_showBlockedPosts) {
          return const SizedBox.shrink();
        }
        final posts = _cubits[_postsTabId];
        if (state.isOwnProfile || posts == null) return _strip(profile);
        // Another person's posts may be protected from the viewer: the
        // Posts feed says so first, and then there is nothing to ask.
        return BlocBuilder<TimelineCubit, TimelineState>(
          bloc: posts,
          buildWhen: (a, b) =>
              a.authorProtected != b.authorProtected ||
              (a.status == TimelineStatus.loading) !=
                  (b.status == TimelineStatus.loading),
          builder: (paneContext, timeline) {
            if (timeline.authorProtected) return const SizedBox.shrink();
            if (timeline.status == TimelineStatus.loading) {
              return const ProfileMediaStripPlaceholder();
            }
            return _strip(profile);
          },
        );
      },
    ),
  );

  Widget _strip(identity.Profile profile) {
    final media = _cubitFor(
      context,
      _profileTabSpecs(showProfileTabs: true)
          .firstWhere((spec) => spec.id == _mediaTabId),
      userId: profile.userId,
      viewerUserId: context.read<OnboardingBloc>().state.profile?.userId,
    );
    return BlocConsumer<TimelineCubit, TimelineState>(
      bloc: media,
      listenWhen: (_, after) => _refusedProfileTabs(after),
      listener: (_, _) => _dropProfileTabs(),
      builder: (paneContext, timeline) => ProfileMediaStrip(
        state: timeline,
        onOpen: (tile) => paneContext.push(
          AppRouter.postPhotoPath(tile.postId, tile.index + 1),
        ),
        // Hidden while Media is the tab shown (it would do nothing there).
        onSeeAll: _tabId == _mediaTabId ? null : () => _selectTab(_mediaTabId),
      ),
    );
  }

  /// Selects the tab [id] (from the tab bar, or See all in the pane); the
  /// pane hears of it, since its See all follows the selection.
  void _selectTab(String id) {
    if (!mounted || id == _tabId) return;
    setState(() => _tabId = id);
    _paneGate.value++;
  }

  /// The server refused a `profile_tabs` tab: Reposts and Media go for the
  /// rest of this screen, from the tabs and the pane.
  void _dropProfileTabs() {
    if (!mounted || _profileTabsRefused) return;
    setState(() {
      _profileTabsRefused = true;
      _tabId = _postsTabId;
    });
    _paneGate.value++;
  }

  @override
  void dispose() {
    _paneLease.dispose();
    _paneGate.dispose();
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
              // An undone repost leaves the tab.
              engagement: _engagementOrNull(context),
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
      showProfileTabs:
          isFeatureEnabled(context, kFeatureProfileTabs) &&
          !_profileTabsRefused,
    );
    final tab = math.max(0, specs.indexWhere((s) => s.id == _tabId));
    final spec = specs[tab];
    final canCompose = canComposeAt(context, AppRouter.homePath);
    Widget pager({
      required Widget Function(BuildContext context, _ProfileTabSpec tab)
      bodyBuilder,
      Future<void> Function()? onRefresh,
    }) => _ProfileTabPager(
      key: ValueKey(specs.map((tab) => tab.id).join(',')),
      specs: specs,
      selectedId: spec.id,
      outer: widget.outer,
      header: header,
      onChanged: _selectTab,
      hasOpened: _cubits.containsKey,
      bodyBuilder: bodyBuilder,
      onRefresh: onRefresh,
    );

    if (blocked && !_showBlockedPosts) {
      return pager(
        bodyBuilder: (context, page) => CustomScrollView(
          key: PageStorageKey('profile-${profile.userId}-${page.id}'),
          slivers: [
            SliverOverlapInjector(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            ),
            SliverToBoxAdapter(
              child: _BlockedPostsBanner(
                handle: profile.handle,
                onShow: () {
                  setState(() => _showBlockedPosts = true);
                  _paneGate.value++;
                },
              ),
            ),
            const ShellBottomInsetSliver(),
          ],
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
    // replaces the tabs, the pin and the cached feeds with one view.
    // Nothing below is built then, so a stale pinned id costs no GetPost.
    Widget tabbed() {
      final profileCubit = context.read<ProfileCubit>();
      final pinned = _pinnedFor(context, profile);
      // Pin / Unpin on the own profile. Unpin (a clear) is offered whatever the
      // flags are; Pin (a set) needs `profile_extras`
      // on for the viewer. The Pinned row itself renders whatever the flags are.
      final isOwn = state.isOwnProfile;
      final pinEnabled =
          isOwn && isFeatureEnabled(context, kFeatureProfileExtras);
      final postPin = _postPinFor(context);
      return BlocListener<TimelineCubit, TimelineState>(
        bloc: cubit,
        listenWhen: (before, after) =>
            spec.requiresProfileTabs && _refusedProfileTabs(after),
        listener: (context, _) => _dropProfileTabs(),
        child: pager(
          onRefresh: cubit.refresh,
          bodyBuilder: (context, page) {
            final pageCubit = _cubitFor(
              context,
              page,
              userId: profile.userId,
              viewerUserId: viewerUserId,
            );
            final ownPosts = state.isOwnProfile && page.ownPosts;
            final scrollKey = PageStorageKey<String>(
              'profile-${profile.userId}-${page.id}',
            );
            return BlocProvider<TimelineCubit>.value(
              key: ValueKey('profile-posts-${profile.userId}-${page.id}'),
              value: pageCubit,
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
                    fillViewport: page.fillViewport,
                    scrollViewKey: scrollKey,
                    newPostsPillTop: AppSpacing.sm,
                    viewerUserId: viewerUserId,
                    headerSlivers: [
                      if (page.showsPinned)
                        SliverToBoxAdapter(
                          child: PinnedPostSection(
                            cubit: pinned,
                            viewerUserId: viewerUserId,
                            onRelationshipChanged: onRelationshipChanged,
                            pinControl: pinControl,
                          ),
                        ),
                    ],
                    emptyTitle: page.emptyTitle(
                      own: state.isOwnProfile,
                      handle: profile.handle,
                    ),
                    emptySubtitle: page.emptySubtitle?.call(
                      own: state.isOwnProfile,
                      handle: profile.handle,
                    ),
                    emptyAction: ownPosts && canCompose
                        ? AppPillButton(
                            label: 'Write a post',
                            compact: true,
                            onPressed: () =>
                                context.push(AppRouter.composePath),
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

                  if (!page.showsPinned) return feed(pinCovered: false);
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
            );
          },
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
              const ShellBottomInsetSliver(),
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
  /// profile" never depends on them. The wrapper is
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

/// Owns the gesture-driven controller while the parent retains per-feed cubits.
/// Capability changes replace this widget by its stable tab-id key, keeping the
/// controller length aligned with the tabs the server currently supports.
class _ProfileTabPager extends StatefulWidget {
  const _ProfileTabPager({
    super.key,
    required this.specs,
    required this.selectedId,
    required this.outer,
    required this.header,
    required this.onChanged,
    required this.hasOpened,
    required this.bodyBuilder,
    this.onRefresh,
  });

  final List<_ProfileTabSpec> specs;
  final String selectedId;
  final ScrollController outer;
  final Widget header;
  final ValueChanged<String> onChanged;
  final bool Function(String id) hasOpened;
  final Widget Function(BuildContext context, _ProfileTabSpec tab) bodyBuilder;
  final Future<void> Function()? onRefresh;

  @override
  State<_ProfileTabPager> createState() => _ProfileTabPagerState();
}

class _ProfileTabPagerState extends State<_ProfileTabPager>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;
  final Map<String, GlobalKey> _tabKeys = {};

  @override
  void initState() {
    super.initState();
    _controller = TabController(
      length: widget.specs.length,
      initialIndex: math.max(
        0,
        widget.specs.indexWhere((tab) => tab.id == widget.selectedId),
      ),
      vsync: this,
    )..addListener(_selectionChanged);
  }

  void _selectionChanged() {
    final id = widget.specs[_controller.index].id;
    if (id == widget.selectedId) return;
    widget.onChanged(id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tabContext = _tabKeys[id]?.currentContext;
      final render = tabContext?.findRenderObject();
      if (tabContext == null || render == null) return;
      Scrollable.of(tabContext, axis: Axis.horizontal).position.ensureVisible(
        render,
        alignment: 0.5,
        duration: MediaQuery.disableAnimationsOf(tabContext)
            ? Duration.zero
            : kThemeAnimationDuration,
      );
    });
  }

  /// A tab selected from outside the bar (band B's media strip, "See all";
  /// T8c): the controller follows. A selection made in the bar already
  /// matches, so this does nothing for it.
  @override
  void didUpdateWidget(_ProfileTabPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = widget.specs.indexWhere((tab) => tab.id == widget.selectedId);
    if (index < 0 || index == _controller.index) return;
    _controller.animateTo(
      index,
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : null,
    );
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_selectionChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ProfileScrollScaffold(
    outer: widget.outer,
    header: widget.header,
    onRefresh: widget.onRefresh,
    tabBar: AppTabBar(
      equalWidth: false,
      semanticLabel: 'Profile timelines',
      selectedIndex: _controller.index,
      onChanged: (index) => _controller.animateTo(
        index,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : null,
      ),
      tabs: [
        for (final tab in widget.specs)
          AppTab(
            label: tab.label,
            key: _tabKeys.putIfAbsent(tab.id, GlobalKey.new),
          ),
      ],
    ),
    body: TabBarView(
      controller: _controller,
      children: [
        for (final tab in widget.specs)
          Builder(
            key: ValueKey(tab.id),
            builder: (context) {
              // A swipe may expose a neighbor before selection settles. Show
              // a loading affordance without prefetching a feed nobody opens.
              if (tab.id != widget.selectedId && !widget.hasOpened(tab.id)) {
                return const Center(child: CircularProgressIndicator());
              }
              return widget.bodyBuilder(context, tab);
            },
          ),
      ],
    ),
  );
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
    final barBottom = _ProfileChrome.of(context).barBottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = ShellGeometry.readableInset(
          context,
          constraints.maxWidth,
        );
        Widget centred(Widget sliver) => SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: sliver,
        );
        final view = NestedScrollView(
          controller: outer,
          physics: const AlwaysScrollableScrollPhysics(),
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            // The hero's rounded bottom is its own edge: no hairline under it.
            // With tabs, the bar's height of its bottom is laid out under the
            // pinned strip below, so the tabs pin under the app bar and sit
            // right under the hero at the top.
            centred(
              tabBar == null
                  ? SliverToBoxAdapter(child: header)
                  : _SliverUnderlap(underlap: barBottom, child: header),
            ),
            if (tabBar != null)
              SliverOverlapAbsorber(
                handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                  context,
                ),
                sliver: centred(
                  PinnedHeaderSliver(
                    // The tabs sit in the reading column; on the tablet
                    // layout their hairline spans the pane.
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Clear: the app bar's place (over the hero's
                        // bottom edge until the hero has scrolled away).
                        SizedBox(height: barBottom),
                        ColoredBox(
                          color: background,
                          child: AppMainColumnBleed(
                            bleed: inset,
                            child: tabBar!,
                          ),
                        ),
                      ],
                    ),
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
                // The pager adds one viewport between the nested scroll and
                // its vertical feed. Ignore deeper post content and all
                // horizontal notifications when starting a refresh.
                notificationPredicate: (notification) =>
                    notification.depth <= (body is TabBarView ? 2 : 1) &&
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

/// The session's engagement overlay, or null when no session is above (a
/// profile shown outside the app, as in some tests): then an undone repost is
/// only dropped by the next refresh, as before then.
EngagementCubit? _engagementOrNull(BuildContext context) {
  try {
    return context.read<EngagementCubit>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// A box sliver whose last [underlap] dp are laid out under the next sliver:
/// the next one starts [underlap] early, over the box's bottom. The hero uses
/// it so the pinned tab bar's clear strip (the app bar's place) lies over the
/// hero's bottom edge while the hero is on screen.
class _SliverUnderlap extends SingleChildRenderObjectWidget {
  const _SliverUnderlap({required this.underlap, super.child});

  final double underlap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSliverUnderlap(underlap);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSliverUnderlap renderObject,
  ) => renderObject.underlap = underlap;
}

class _RenderSliverUnderlap extends RenderSliverToBoxAdapter {
  _RenderSliverUnderlap(this._underlap);

  double _underlap;

  set underlap(double value) {
    if (value == _underlap) return;
    _underlap = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      geometry = SliverGeometry.zero;
      return;
    }
    final constraints = this.constraints;
    child.layout(constraints.asBoxConstraints(), parentUsesSize: true);
    final extent = child.size.height;
    final laidOut = math.max(0.0, extent - _underlap);
    // Paint extent = layout extent, so the next sliver sees no overlap and
    // starts at the laid-out end (a pinned header would otherwise be pushed
    // below the overlapped part). The box still paints in full while its
    // laid-out part is on screen, and takes touches over its whole height.
    final painted = calculatePaintOffset(constraints, from: 0, to: laidOut);
    geometry = SliverGeometry(
      scrollExtent: laidOut,
      paintExtent: painted,
      layoutExtent: painted,
      cacheExtent: calculateCacheOffset(constraints, from: 0, to: extent),
      maxPaintExtent: extent,
      hitTestExtent: calculatePaintOffset(constraints, from: 0, to: extent),
      hasVisualOverflow: true,
    );
    setChildParentData(child, constraints, geometry!);
  }
}
