import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/feature_flags/ui_shell_feature_flag.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_shell_scope.dart';
import '../../../core/widgets/app_state_view.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/app_chip.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../communities/data/communities_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/beacons_repository.dart';
import '../domain/beacon_labels.dart';
import '../domain/beacons_feature_flag.dart';
import 'beacons_error_messages.dart';
import 'bloc/beacons_cubit.dart';
import 'bloc/beacons_state.dart';
import 'bloc/plans_session.dart';
import 'plans_list_detail.dart';
import 'widgets/beacon_row.dart';
import 'widgets/plan_skeletons.dart';
import 'widgets/plans_activity_filter.dart';
import 'widgets/your_plans_section.dart';
import '../../../core/widgets/shell_fab.dart';

/// `/plans`: the selected audience's upcoming plans (R30). The audience chips
/// show only when the caller has joined communities to choose from.
///
/// Plans is never turned off (ADR-0034 section 4): with `beacons` off for the
/// caller the page stays and shows [kPlansPausedTitle] instead of the list,
/// with no create action and no RPC. A kill switch in mid-session gets there
/// by itself: the list shows the same paused page as soon as the server
/// answers FEATURE_DISABLED (also when the `GetMe` the gate then asks for
/// fails), and once the flag leaves `enabled_features` this widget rebuilds
/// into the paused state.
class BeaconsScreen extends StatelessWidget {
  const BeaconsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return isFeatureEnabled(context, kFeatureBeacons)
        ? const _PlansRoute()
        : const _PlansPaused();
  }
}

/// The empty state of an activity chip with no plans (F29): "No walk plans
/// yet".
String plansFilteredEmptyTitle(pb.BeaconActivity activity) =>
    'No ${activityLabel(activity).toLowerCase()} plans yet';

/// The paused copy (accepted, ADR-0034 section 4).
const kPlansPausedTitle = 'Plans are paused';
const kPlansPausedBody =
    'Your plans and requests are safe. They will show again when Plans is '
    'back.';

/// Back for Plans opened over something (pop) or outside the shell on a phone
/// (home); null at the root of the shell, where the avatar leads on a phone
/// and the rail on wider layouts, like the other tab screens.
VoidCallback? _plansBack(BuildContext context, {required bool split}) {
  final router = GoRouter.maybeOf(context);
  if (split || router == null) return null;
  if (router.canPop()) return router.pop;
  // The shell's root: the avatar on a phone, the rail from 600dp.
  if (AppShellScope.maybeOf(context) != null ||
      MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile) {
    return null;
  }
  return () => router.go(AppRouter.homePath);
}

/// The page header, one with the other tab screens: [AppTopBar] with the
/// title "Plans" and round [AppTopBarAction]s. [split] is band B's list
/// pane (no avatar, no Back: it sits beside the detail).
Widget _plansTopBar(
  BuildContext context, {
  List<Widget>? actions,
  bool split = false,
}) => AppTopBar.sliver(
  title: 'Plans',
  actions: actions,
  showAccountAvatar: !split,
  onBack: _plansBack(context, split: split),
);

/// `beacons` is off for the caller: the header and the notice, nothing else.
/// It builds no cubit, so it sends nothing.
class _PlansPaused extends StatelessWidget {
  const _PlansPaused();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: AppMainColumn(child: _PlansPausedColumn()));
  }
}

/// The paused page content: the header with no action, and the notice.
class _PlansPausedColumn extends StatelessWidget {
  const _PlansPausedColumn({this.split = false});

  final bool split;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppTopBar.of(
          context,
          title: 'Plans',
          showAccountAvatar: !split,
          onBack: _plansBack(context, split: split),
        ),
        const Expanded(
          child: AppStateView(
            icon: Icons.event_outlined,
            title: kPlansPausedTitle,
            body: kPlansPausedBody,
          ),
        ),
      ],
    );
  }
}

/// `/plans` with `beacons` on: the route's open of the list. It loads the
/// list (and, on the tablet layout, "Your plans") once per open, over the
/// app-level [PlansSession] (tablet plan section 5.2; a session of its own
/// when none is provided, which is then closed with the page). In band B the
/// shell shows the list beside this page ([PlansMasterScope]), so the page
/// is the detail placeholder; everywhere else it is the list.
class _PlansRoute extends StatefulWidget {
  const _PlansRoute();

  @override
  State<_PlansRoute> createState() => _PlansRouteState();
}

class _PlansRouteState extends State<_PlansRoute> {
  PlansSession? _own;
  late final PlansSession _session;
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    final hoisted = context.read<PlansSession?>();
    _session =
        hoisted ??
        (_own = PlansSession(
          repository: context.read<BeaconsRepository>(),
          communities: context.read<CommunitiesRepository?>(),
        ));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_opened) return;
    _opened = true;
    // One open, one load (a refresh never doubles one the list pane already
    // started); the rows of an earlier visit stay on screen meanwhile.
    unawaited(_session.list.refresh());
    if (_showsYourPlans(context)) unawaited(_session.yourPlans.refresh());
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  Future<void> _newPlan() async {
    await context.push(AppRouter.planNewPath);
    if (mounted) _session.refreshAfterWrite();
  }

  @override
  Widget build(BuildContext context) {
    if (PlansMasterScope.shownOf(context)) {
      return PlansDetailPlaceholder(onNewPlan: _newPlan);
    }
    return Scaffold(
      // The floating bar overlays the page: the scroll view runs behind it
      // and ends with the bar's inset. The top bar handles the top safe area.
      body: AppMainColumn(
        child: PlansList(
          session: _session,
          yourPlans: _showsYourPlans(context),
        ),
      ),
    );
  }
}

/// Whether the list carries "Your plans" on top: on the tablet shell's panes
/// (`ui_shell` + `ui_tablet`, 600-1199dp) and on the desktop of the new shell
/// (`ui_shell`; the desktop design has them beside the list, and the shell's
/// side column is not the page's to fill, so they sit inline).
bool _showsYourPlans(BuildContext context) =>
    (ShellGeometry.maybeOf(context)?.tablet ?? false) ||
    ((context.read<OnboardingBloc?>()?.state.enabledFeatures.contains(
              kFeatureUiShell,
            ) ??
            false) &&
        MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet);

/// The Plans list: the header (My plans, New plan), the audience chips and
/// the rows, over [session]'s hoisted list. Two placements: the `/plans`
/// page (band A, phones, desktop) and band B's list pane ([split]).
/// - [split]: no back arrow (the list sits beside the detail), a row
///   replaces the detail (`go`), and [selectedId] is highlighted.
/// - Otherwise a row is pushed and the list reloads on return, as before.
/// - [yourPlans]: the "Your plans" section on top (tablet layout and desktop).
/// - From 600dp the page ([split] false) has My plans and New plan as pills
///   beside the headline (the tablet and desktop designs); the phone and the
///   list pane keep them as header icons.
class PlansList extends StatelessWidget {
  const PlansList({
    super.key,
    required this.session,
    this.split = false,
    this.selectedId,
    this.yourPlans = false,
  });

  final PlansSession session;
  final bool split;
  final String? selectedId;
  final bool yourPlans;

  /// Opens [path] and reloads the list when it comes back: a plan created
  /// there, or one cancelled there, is shown on return (one ListBeacons; the
  /// chips are cached).
  Future<void> _push(BuildContext context, String path) async {
    await context.push(path);
    if (split) {
      // The list pane steps aside while a page is pushed over it, so this
      // context is usually gone by now: the session reloads what it holds.
      session.refreshAfterWrite();
      return;
    }
    if (!context.mounted) return;
    if (yourPlans) unawaited(session.yourPlans.refresh());
    await session.list.load();
  }

  void _openPlan(BuildContext context, String beaconId) {
    final path = AppRouter.planPath(beaconId);
    if (split) {
      context.go(path);
    } else {
      unawaited(_push(context, path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pills =
        !split && MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
    return ListenableBuilder(
      listenable: session.changes,
      builder: (context, _) {
        final cubit = session.list;
        return BlocBuilder<BeaconsCubit, BeaconsState>(
          bloc: cubit,
          builder: (context, state) {
            // The server said the feature is off while the flag still
            // lists it (a kill switch before the next `GetMe`, or that
            // `GetMe` failing): the same paused page, with no action and
            // no retry, so nothing more is sent from here.
            // Whatever the status: a first load (error) and a Load more
            // (ready, rows kept) end the same way.
            if (state.error is FeatureDisabledException) {
              return _PlansPausedColumn(split: split);
            }
            final headline = split
                ? null
                : PlansHeadline(
                    // From 600dp My plans and New plan are pills beside the
                    // headline (the designs).
                    actions: pills
                        ? _HeadlineActions(
                            onMyPlans: () =>
                                _push(context, AppRouter.plansMinePath),
                            onNewPlan: () =>
                                _push(context, AppRouter.planNewPath),
                          )
                        : null,
                  );
            // The phone's floating button starts a new plan (not while
            // the feature is paused).
            return ShellFab(
              action: ShellFabAction(
                tooltip: 'New plan',
                icon: Icons.add,
                onPressed: () => _push(context, AppRouter.planNewPath),
              ),
              child: RefreshIndicator(
                onRefresh: () {
                  if (yourPlans) unawaited(session.yourPlans.refresh());
                  return cubit.load();
                },
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    _plansTopBar(
                      context,
                      split: split,
                      actions: [
                        AppTopBarAction(
                          icon: Icons.event_available_outlined,
                          tooltip: 'My plans',
                          onPressed: () =>
                              _push(context, AppRouter.plansMinePath),
                        ),
                        // A phone: the floating button starts one; from
                        // 600dp the pill beside the headline does.
                        if (!pills && !shellFabCovers(context))
                          AppTopBarAction(
                            icon: Icons.add_circle_outline,
                            tooltip: 'New plan',
                            onPressed: () =>
                                _push(context, AppRouter.planNewPath),
                          ),
                      ],
                    ),
                    if (state.audiences.length > 1)
                      SliverToBoxAdapter(
                        child: _AudienceChips(
                          state: state,
                          onSelect: cubit.select,
                        ),
                      ),
                    if (headline != null) SliverToBoxAdapter(child: headline),
                    // F29: after the headline, before the cards (the
                    // designs' order), on every state but paused, so a
                    // filter with no plans or a failed one is one tap
                    // from another activity.
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xs,
                        ),
                        child: PlansActivityFilter(
                          selected: state.activity,
                          onSelected: cubit.selectActivity,
                        ),
                      ),
                    ),
                    if (yourPlans)
                      SliverToBoxAdapter(
                        child: YourPlansSection(
                          session: session,
                          selectedId: split ? selectedId : null,
                          onOpenPlan: (id) => _openPlan(context, id),
                          onSeeAll: () =>
                              _push(context, AppRouter.plansMinePath),
                        ),
                      ),
                    ..._body(context, cubit, state),
                    const ShellBottomInsetSliver(),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// The rows, or the loading, error and empty states, as slivers (a
  /// pull-to-refresh needs the scroll view around a static view too).
  List<Widget> _body(
    BuildContext context,
    BeaconsCubit cubit,
    BeaconsState state,
  ) {
    Widget fill(Widget child) => SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Center(child: child),
      ),
    );
    switch (state.status) {
      case BeaconsLoad.loading:
        return const [SliverToBoxAdapter(child: PlanCardListSkeleton())];
      case BeaconsLoad.error:
        return [
          fill(
            AppEmptyView(
              icon: Icons.error_outline,
              title: beaconsErrorMessage(state.error!),
              action: TextButton(
                onPressed: cubit.load,
                child: const Text('Try again'),
              ),
            ),
          ),
        ];
      case BeaconsLoad.ready:
        // A filtered page an older server left empty still has its token:
        // Load more, not the empty state.
        if (state.views.isEmpty && !state.hasMore) {
          return [
            fill(
              state.filtered
                  ? AppEmptyView(
                      icon: Icons.event_outlined,
                      title: plansFilteredEmptyTitle(state.activity),
                      subtitle: 'Try another activity, or create one.',
                      action: TextButton(
                        onPressed: () => cubit.selectActivity(
                          pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED,
                        ),
                        child: const Text('See all plans'),
                      ),
                    )
                  : const AppEmptyView(
                      icon: Icons.event_outlined,
                      title: 'No plans yet',
                      subtitle: 'Create one and invite people along.',
                    ),
            ),
          ];
        }
        return [
          SliverList.builder(
            itemCount: state.views.length + (state.hasMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == state.views.length) {
                return PlansLoadMore(state: state, onLoadMore: cubit.loadMore);
              }
              final view = state.views[i];
              return BeaconRow(
                view: view,
                selected: split && view.beacon.beaconId == selectedId,
                onTap: () => _openPlan(context, view.beacon.beaconId),
              );
            },
          ),
        ];
    }
  }
}

/// The community chips (Public, then the communities): one row that scrolls
/// sideways, never wrapping, with the activity chips' style and padding.
class _AudienceChips extends StatelessWidget {
  const _AudienceChips({required this.state, required this.onSelect});

  final BeaconsState state;
  final ValueChanged<BeaconsAudience> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: PlansChipRow(
        label: 'Who can see them',
        chips: [
          for (final a in state.audiences)
            AppFilterPill(
              label: a.name,
              selected: a == state.selected,
              onPressed: () => onSelect(a),
            ),
        ],
      ),
    );
  }
}

/// The designs' headline over the Plans list: "What's your plan?", with
/// "plan" in the accent colour, and [actions] (My plans, New plan) at its
/// end from 600dp. On the page only (not in band B's narrow list pane, whose
/// header already says Plans); it scrolls with the rows.
class PlansHeadline extends StatelessWidget {
  const PlansHeadline({super.key, this.actions});

  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.displaySmall;
    final headline = Semantics(
      header: true,
      child: Text.rich(
        TextSpan(
          style: base,
          children: [
            const TextSpan(text: "What's your "),
            TextSpan(text: 'plan', style: AppTextStyles.displayAccent(theme)),
            const TextSpan(text: '?'),
          ],
        ),
      ),
    );
    return Padding(
      key: const ValueKey('plans-headline'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      // The actions sit at the end of the headline's line when both fit,
      // and drop under it (large text, a narrow column) rather than squeeze.
      child: actions == null
          ? headline
          : Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.sm,
              children: [headline, actions!],
            ),
    );
  }
}

/// My plans (outline) and New plan (primary) beside the headline (the
/// tablet and desktop designs); the header keeps its round My plans action
/// at every width.
class _HeadlineActions extends StatelessWidget {
  const _HeadlineActions({required this.onMyPlans, required this.onNewPlan});

  final VoidCallback onMyPlans;
  final VoidCallback onNewPlan;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.end,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: AppSpacing.sm,
    children: [
      AppPillButton(
        label: 'My plans',
        variant: AppButtonVariant.outline,
        compact: true,
        onPressed: onMyPlans,
      ),
      AppPillButton(
        label: 'New plan',
        icon: Icons.add,
        compact: true,
        onPressed: onNewPlan,
      ),
    ],
  );
}

/// The end of a plans list: "Load more", its spinner, or the failed page's
/// message (shared with Explore's Plans tab).
class PlansLoadMore extends StatelessWidget {
  const PlansLoadMore({
    super.key,
    required this.state,
    required this.onLoadMore,
  });

  final BeaconsState state;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: [
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                beaconsErrorMessage(state.error!),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          if (state.loadingMore)
            Semantics(
              label: 'Loading more plans',
              child: SizedBox(
                width: AppIconSize.lg,
                height: AppIconSize.lg,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(onPressed: onLoadMore, child: const Text('Load more')),
        ],
      ),
    );
  }
}
