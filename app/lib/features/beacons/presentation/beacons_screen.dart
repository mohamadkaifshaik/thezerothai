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
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
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

/// The page header, shared by the list and the paused state.
class _PlansHeader extends StatelessWidget {
  const _PlansHeader({this.actions = const [], this.split = false});

  final List<Widget> actions;

  /// Band B's list pane: no back arrow (it sits beside the detail; the rail
  /// has Home), the title where the rows' text starts.
  final bool split;

  @override
  Widget build(BuildContext context) {
    if (split) {
      return AppBackHeader(
        title: 'Plans',
        onBack: () {},
        leading: const SizedBox(width: AppSpacing.sm),
        actions: actions,
      );
    }
    return AppBackHeader(
      title: 'Plans',
      onBack: () {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(AppRouter.homePath);
        }
      },
      // A primary destination: at the root of a phone shell it leads with the
      // avatar (drawer, Profile) instead of Back; when something can be
      // popped, Back stays.
      leading:
          MediaQuery.sizeOf(context).width < AppBreakpoints.mobile &&
              AppShellScope.maybeOf(context) != null &&
              !context.canPop()
          ? const AppAvatarButton()
          : null,
      actions: actions,
    );
  }
}

/// `beacons` is off for the caller: the header and the notice, nothing else.
/// It builds no cubit, so it sends nothing.
class _PlansPaused extends StatelessWidget {
  const _PlansPaused();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(child: AppMainColumn(child: _PlansPausedColumn())),
    );
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
        _PlansHeader(split: split),
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
      body: SafeArea(
        child: AppMainColumn(
          child: PlansList(
            session: _session,
            yourPlans: _showsYourPlans(context),
          ),
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
            // The phone's floating button starts a new plan (not while
            // the feature is paused).
            return ShellFab(
              action: ShellFabAction(
                tooltip: 'New plan',
                icon: Icons.add,
                onPressed: () => _push(context, AppRouter.planNewPath),
              ),
              child: Column(
                children: [
                  _PlansHeader(
                    split: split,
                    actions: pills
                        ? const []
                        : [
                            IconButton(
                              tooltip: 'My plans',
                              icon: const Icon(Icons.event_available_outlined),
                              onPressed: () =>
                                  _push(context, AppRouter.plansMinePath),
                            ),
                            // A phone: the floating button starts one.
                            if (!shellFabCovers(context))
                              IconButton(
                                tooltip: 'New plan',
                                icon: const Icon(Icons.add_circle_outline),
                                onPressed: () =>
                                    _push(context, AppRouter.planNewPath),
                              ),
                          ],
                  ),
                  if (state.audiences.length > 1)
                    _AudienceChips(state: state, onSelect: cubit.select),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () {
                        if (yourPlans) unawaited(session.yourPlans.refresh());
                        return cubit.load();
                      },
                      child: _body(
                        context,
                        cubit,
                        state,
                        _top(
                          context,
                          split
                              ? null
                              : PlansHeadline(
                                  actions: pills
                                      ? _HeadlineActions(
                                          onMyPlans: () => _push(
                                            context,
                                            AppRouter.plansMinePath,
                                          ),
                                          onNewPlan: () => _push(
                                            context,
                                            AppRouter.planNewPath,
                                          ),
                                        )
                                      : null,
                                ),
                          [
                            // F29: after the headline, before the cards (the
                            // designs' order), on every state but paused, so a
                            // filter with no plans or a failed one is one tap
                            // from another activity.
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.xs,
                              ),
                              child: PlansActivityFilter(
                                selected: state.activity,
                                onSelected: cubit.selectActivity,
                              ),
                            ),
                            if (yourPlans)
                              YourPlansSection(
                                session: session,
                                selectedId: split ? selectedId : null,
                                onOpenPlan: (id) => _openPlan(context, id),
                                onSeeAll: () =>
                                    _push(context, AppRouter.plansMinePath),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// What scrolls above the rows: the headline (the page), then "Your
  /// plans" (the tablet layout).
  Widget? _top(BuildContext context, Widget? headline, List<Widget> rest) {
    final all = [?headline, ...rest];
    if (all.isEmpty) return null;
    if (all.length == 1) return all.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: all,
    );
  }

  /// The rows, or the loading, error and empty states. [top] (the headline,
  /// "Your plans") scrolls with them.
  Widget _body(
    BuildContext context,
    BeaconsCubit cubit,
    BeaconsState state,
    Widget? top,
  ) {
    switch (state.status) {
      case BeaconsLoad.loading:
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: top == null
              ? const PlanCardListSkeleton()
              : Column(children: [top, const PlanCardListSkeleton()]),
        );
      case BeaconsLoad.error:
        return _scrollable(
          AppEmptyView(
            icon: Icons.error_outline,
            title: beaconsErrorMessage(state.error!),
            action: TextButton(
              onPressed: cubit.load,
              child: const Text('Try again'),
            ),
          ),
          top,
        );
      case BeaconsLoad.ready:
        // A filtered page an older server left empty still has its token:
        // Load more, not the empty state.
        if (state.views.isEmpty && !state.hasMore) {
          return _scrollable(
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
            top,
          );
        }
        final offset = top == null ? 0 : 1;
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: offset + state.views.length + (state.hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (top != null && index == 0) return top;
            final i = index - offset;
            if (i == state.views.length) {
              return _LoadMore(state: state, onLoadMore: cubit.loadMore);
            }
            final view = state.views[i];
            return BeaconRow(
              view: view,
              selected: split && view.beacon.beaconId == selectedId,
              onTap: () => _openPlan(context, view.beacon.beaconId),
            );
          },
        );
    }
  }

  /// A pull-to-refresh needs a scrollable even around a static view. With
  /// [top], it sits above the view, which keeps the rest of the height.
  Widget _scrollable(Widget child, Widget? top) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: top == null
          ? ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(child: child),
            )
          : Column(
              children: [
                top,
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  child: Center(child: child),
                ),
              ],
            ),
    ),
  );
}

class _AudienceChips extends StatelessWidget {
  const _AudienceChips({required this.state, required this.onSelect});

  final BeaconsState state;
  final ValueChanged<BeaconsAudience> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        0,
      ),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: 'Who can see them',
        child: Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            for (final a in state.audiences)
              AppFilterPill(
                label: a.name,
                selected: a == state.selected,
                onPressed: () => onSelect(a),
              ),
          ],
        ),
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

/// My plans (outline) and New plan (primary) beside the headline.
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

class _LoadMore extends StatelessWidget {
  const _LoadMore({required this.state, required this.onLoadMore});

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
