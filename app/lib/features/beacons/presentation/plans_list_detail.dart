import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import 'beacons_screen.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import 'bloc/plans_session.dart';

/// Plans list–detail on the tablet layout from 840dp (band B; tablet plan
/// section 3, code LD): `MainShell` shows the [PlansListPane] beside the
/// shell page on `/plans` and `/plans/:id`, and publishes that decision with
/// a [PlansMasterScope] around the page, so the page never decides it a
/// second time:
/// - `/plans` (`BeaconsScreen`) draws the [PlansDetailPlaceholder] instead
///   of its own list;
/// - `/plans/:id` (`BeaconScreen`) drops its back arrow (the list is beside
///   it) and has the list reload after a write.
/// Everywhere else (phones, band A, desktop, either shell flag off,
/// `beacons` off) the scope says no and the pages are today's.
class PlansMasterScope extends InheritedWidget {
  const PlansMasterScope({
    super.key,
    required this.shown,
    this.selectedId,
    required super.child,
  });

  /// The list pane is beside this page.
  final bool shown;

  /// The plan open beside it (`/plans/:id`), or null.
  final String? selectedId;

  /// Whether the Plans list pane is beside [context]'s page; false without a
  /// scope.
  static bool shownOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlansMasterScope>()?.shown ??
      false;

  @override
  bool updateShouldNotify(PlansMasterScope oldWidget) =>
      shown != oldWidget.shown || selectedId != oldWidget.selectedId;
}

/// Band B's list pane of Plans (built by `MainShell`): the same list as band
/// A's `/plans`, over the hoisted [PlansSession], with "Your plans" on top,
/// rows that replace the detail (`go`) and the open plan ([selectedId])
/// highlighted. It only makes sure the list was loaded: the route's open
/// (`/plans`) or a write in the detail reloads it, and crossing 840dp sends
/// nothing.
class PlansListPane extends StatefulWidget {
  const PlansListPane({super.key, this.selectedId});

  final String? selectedId;

  @override
  State<PlansListPane> createState() => _PlansListPaneState();
}

class _PlansListPaneState extends State<PlansListPane> {
  late final PlansSession _session = context.read<PlansSession>();

  @override
  void initState() {
    super.initState();
    unawaited(_session.list.ensureLoaded());
    unawaited(_session.yourPlans.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: PlansList(
          session: _session,
          split: true,
          yourPlans: true,
          selectedId: widget.selectedId,
        ),
      ),
    );
  }
}

/// The band B detail of `/plans` when no plan is open (tablet plan section
/// 3: "icon, one line, and a primary action where one exists"): New plan.
class PlansDetailPlaceholder extends StatelessWidget {
  const PlansDetailPlaceholder({super.key, required this.onNewPlan});

  final VoidCallback onNewPlan;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.event_outlined,
                    size: AppSpacing.xxl,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                const Text(kPickAPlan, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.md),
                // Content-sized like the other pill buttons (the theme's
                // FilledButton stretches to the full width).
                AppPillButton(
                  label: 'New plan',
                  icon: Icons.add,
                  compact: true,
                  onPressed: onNewPlan,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The placeholder's line (tablet plan section 6.8).
const kPickAPlan = 'Pick a plan';
