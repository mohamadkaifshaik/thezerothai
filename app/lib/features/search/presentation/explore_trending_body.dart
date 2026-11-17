import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/explore_retap_signal.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/app_tab_bar.dart';
import 'bloc/trending_paged_cubit.dart';
import 'bloc/trends_cubit.dart';
import 'trending_sections_model.dart';
import 'widgets/trending_media_section.dart';
import 'widgets/trending_posts_section.dart';
import 'widgets/explore_subsection_heading.dart' show ExploreSubsectionHeading;
import 'widgets/trending_section_scroll.dart';
import 'widgets/trending_sliver_marker.dart';
import 'widgets/trending_tag_header.dart';

/// The spoken name of the Posts | Media control.
const kTrendingSectionsLabel = 'Trending sections';

/// The Trending tab of Explore with Posts and/or Media sections (the
/// `trending_posts` and `trending_media` flags). Layout by window width:
///
/// - Phone and tablet: one scroll view, the header (the top bar, Explore's
///   tab bar, the "Popular" heading with its hashtag chips) and the section
///   control `Posts | Media` pinned under it, then the section shown. The
///   control only exists when both sections are on; switching keeps each
///   section's list (its cubit lives in [model]) and its offset.
/// - Desktop (1200 and up): the header fixed, then Posts and Media side by
///   side, each scrolling on its own.
///
/// Pull to refresh refreshes the section on screen and the hashtag list
/// together; the other section is left alone (they share a rate limit).
class ExploreTrendingBody extends StatefulWidget {
  const ExploreTrendingBody({
    super.key,
    required this.model,
    required this.topBar,
    required this.topBarBox,
    required this.exploreTabBar,
    required this.trendsOn,
    required this.postsOn,
    required this.mediaOn,
  });

  final TrendingSectionsModel model;

  /// Explore's floating top bar sliver (the search field and Settings), and
  /// the same bar as a box (the desktop header does not scroll).
  final Widget topBar;
  final PreferredSizeWidget topBarBox;

  /// Explore's tab bar, null when Trending is the only tab.
  final Widget? exploreTabBar;

  /// `trends` is on: the Popular heading and the hashtag chips show.
  final bool trendsOn;
  final bool postsOn;
  final bool mediaOn;

  @override
  State<ExploreTrendingBody> createState() => _ExploreTrendingBodyState();
}

class _ExploreTrendingBodyState extends State<ExploreTrendingBody> {
  final ScrollController _scroll = ScrollController();
  final ScrollController _postsScroll = ScrollController();
  final ScrollController _mediaScroll = ScrollController();

  /// Where the content of each section starts, in scroll offset terms
  /// (the header's end under the pinned bars), as laid out last.
  double _listTop = 0;

  /// The offset into each section's own list when it was last on screen.
  final Map<TrendingSection, double> _inner = {};

  ExploreRetapSignal? _retap;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModel);
    _retap = context.read<ExploreRetapSignal?>()?..addListener(_onRetap);
  }

  @override
  void didUpdateWidget(ExploreTrendingBody old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model.removeListener(_onModel);
      widget.model.addListener(_onModel);
    }
  }

  @override
  void dispose() {
    _retap?.removeListener(_onRetap);
    widget.model.removeListener(_onModel);
    _scroll.dispose();
    _postsScroll.dispose();
    _mediaScroll.dispose();
    super.dispose();
  }

  void _onModel() {
    if (mounted) setState(() {});
  }

  /// Explore tapped again while it is on top: each list on screen scrolls to
  /// its top, or, when it is there already, refreshes as a pull does.
  void _onRetap() {
    if (!mounted) return;
    final desktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;
    if (!desktop) {
      if (!_toTop(_scroll)) unawaited(_refresh(_section));
      return;
    }
    final refreshed = <Future<void>>[];
    if (widget.postsOn && !_toTop(_postsScroll)) {
      refreshed.add(widget.model.posts().refresh());
    }
    if (widget.mediaOn && !_toTop(_mediaScroll)) {
      refreshed.add(widget.model.media().refresh());
    }
    if (refreshed.isNotEmpty && widget.trendsOn) {
      refreshed.add(context.read<TrendsCubit>().ensureLoaded(force: true));
    }
    unawaited(Future.wait(refreshed));
  }

  /// Scrolls [controller] to the top (a jump with reduced motion) and says
  /// so; false when it is at the top already.
  bool _toTop(ScrollController controller) {
    if (!controller.hasClients || controller.offset <= 1) return false;
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.jumpTo(0);
    } else {
      unawaited(
        controller.animateTo(
          0,
          duration: AppMotion.expoOutShort,
          curve: Curves.easeOutCubic,
        ),
      );
    }
    return true;
  }

  /// The section to show: the model's, or the one that remains.
  TrendingSection get _section {
    final wanted = widget.model.section;
    if (wanted == TrendingSection.posts && !widget.postsOn) {
      return TrendingSection.media;
    }
    if (wanted == TrendingSection.media && !widget.mediaOn) {
      return TrendingSection.posts;
    }
    return wanted;
  }

  void _selectTag(String tag) {
    final clearing = widget.model.tag == tag;
    widget.model.selectTag(tag);
    // A new list starts at its top, under the pinned bars.
    _toListTop();
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        clearing ? 'Filter cleared' : 'Showing #$tag',
        Directionality.of(context),
      ),
    );
  }

  void _clearFilter() {
    if (widget.model.tag == null) return;
    _selectTag(widget.model.tag!);
  }

  void _toListTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = math.min(_scroll.offset, _listTop);
      if (target != _scroll.offset) _scroll.jumpTo(target);
      _postsScroll.hasClients ? _postsScroll.jumpTo(0) : null;
      _mediaScroll.hasClients ? _mediaScroll.jumpTo(0) : null;
    });
  }

  void _switchTo(TrendingSection next) {
    final current = _section;
    if (next == current) return;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    _inner[current] = math.max(0.0, offset - _listTop);
    final header = math.min(offset, _listTop);
    widget.model.section = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = header + (_inner[next] ?? 0);
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  Future<void> _refresh(TrendingSection section) {
    final model = widget.model;
    return Future.wait([
      if (section == TrendingSection.posts)
        model.posts().refresh()
      else
        model.media().refresh(),
      if (widget.trendsOn)
        context.read<TrendsCubit>().ensureLoaded(force: true),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;
    return desktop ? _desktop(context) : _narrow(context);
  }

  Widget _header() => widget.trendsOn
      ? TrendingTagHeader(selected: widget.model.tag, onSelected: _selectTag)
      : const SliverToBoxAdapter(child: SizedBox.shrink());

  // ---- phone and tablet ----------------------------------------------------

  Widget _narrow(BuildContext context) {
    final model = widget.model;
    final section = _section;
    final both = widget.postsOn && widget.mediaOn;
    final posts = section == TrendingSection.posts
        ? TrendingPostsSection(
            cubit: model.posts(),
            tag: model.tag,
            onClearFilter: _clearFilter,
          )
        : null;
    final media = section == TrendingSection.media
        ? TrendingMediaSection(
            cubit: model.media(),
            tag: model.tag,
            onClearFilter: _clearFilter,
          )
        : null;
    final PagedTrendingCubit<Object?> cubit = posts?.cubit ?? media!.cubit;
    final pinnedAbove = widget.exploreTabBar == null
        ? 0.0
        : AppTabBar.heightFor(context);
    return RefreshIndicator(
      onRefresh: () => _refresh(section),
      child: TrendingSectionScroll(
        cubit: cubit,
        controller: _scroll,
        leading: [
          widget.topBar,
          if (widget.exploreTabBar != null)
            AppPinnedTabBarSliver(child: widget.exploreTabBar!),
          _headerInColumn(context),
          TrendingSliverMarker(
            onOffset: (extent) => _listTop = math.max(0, extent - pinnedAbove),
          ),
          if (both)
            AppPinnedTabBarSliver(
              child: AppTabBar(
                tabs: const [
                  AppTab(label: 'Posts'),
                  AppTab(label: 'Media'),
                ],
                selectedIndex: section == TrendingSection.posts ? 0 : 1,
                onChanged: (i) => _switchTo(
                  i == 0 ? TrendingSection.posts : TrendingSection.media,
                ),
                equalWidth: true,
                semanticLabel: kTrendingSectionsLabel,
              ),
            ),
        ],
        slivers: (context, wrap) => posts != null
            ? posts.slivers(context, wrap)
            : media!.slivers(context, wrap),
      ),
    );
  }

  /// The header in the reading column (a tablet's 680; a phone's own width).
  Widget _headerInColumn(BuildContext context) {
    // Read here: a sliver layout builder cannot depend on inherited widgets.
    final column = ShellGeometry.readableMaxWidth(
      context,
      otherwise: AppBreakpoints.mobile,
    );
    return SliverLayoutBuilder(
      builder: (context, constraints) => SliverPadding(
        padding: EdgeInsets.symmetric(
          horizontal: math.max(0.0, (constraints.crossAxisExtent - column) / 2),
        ),
        sliver: _header(),
      ),
    );
  }

  // ---- desktop ---------------------------------------------------------------

  Widget _desktop(BuildContext context) {
    final model = widget.model;
    final posts = widget.postsOn
        ? TrendingPostsSection(
            cubit: model.posts(),
            tag: model.tag,
            onClearFilter: _clearFilter,
          )
        : null;
    final media = widget.mediaOn
        ? TrendingMediaSection(
            cubit: model.media(),
            tag: model.tag,
            onClearFilter: _clearFilter,
          )
        : null;
    final both = posts != null && media != null;
    Widget pane(
      String title,
      TrendingSectionScroll scroll,
      TrendingSection section,
    ) => FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (both) ExploreSubsectionHeading(title),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _refresh(section),
              child: scroll,
            ),
          ),
        ],
      ),
    );
    final panes = <Widget>[
      if (posts != null)
        pane(
          'Posts',
          TrendingSectionScroll(
            cubit: posts.cubit,
            controller: _postsScroll,
            slivers: posts.slivers,
          ),
          TrendingSection.posts,
        ),
      if (media != null)
        pane(
          'Media',
          TrendingSectionScroll(
            cubit: media.cubit,
            controller: _mediaScroll,
            slivers: media.slivers,
          ),
          TrendingSection.media,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The header never scrolls here: the bars as boxes and the hashtag
        // chips as a shrink-wrapped view of their slivers.
        SizedBox(
          height: widget.topBarBox.preferredSize.height,
          child: widget.topBarBox,
        ),
        ?widget.exploreTabBar,
        Flexible(
          flex: 0,
          child: CustomScrollView(
            shrinkWrap: true,
            primary: false,
            physics: const NeverScrollableScrollPhysics(),
            slivers: [_header(), const ShellBottomInsetSliver()],
          ),
        ),
        Expanded(
          child: both
              ? Row(
                  children: [
                    Expanded(child: panes[0]),
                    VerticalDivider(
                      width: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    Expanded(child: panes[1]),
                  ],
                )
              : panes.first,
        ),
      ],
    );
  }
}
