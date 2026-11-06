import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_avatar.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_notice_banner.dart';
import '../../../shared/widgets/primitives/app_tile_icon.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../data/beacons_repository.dart';
import '../domain/beacon_labels.dart';
import 'beacons_error_messages.dart';
import 'bloc/beacon_detail_cubit.dart';
import 'bloc/beacon_detail_state.dart';
import 'widgets/beacon_status_pill.dart';

/// `/plans/:id` (R32): the server's view of one plan. The organiser sees
/// Cancel while the plan is OPEN or FULL; participation controls are PR 7's.
class BeaconScreen extends StatefulWidget {
  const BeaconScreen({super.key, required this.beaconId});

  final String beaconId;

  @override
  State<BeaconScreen> createState() => _BeaconScreenState();
}

class _BeaconScreenState extends State<BeaconScreen> {
  late final BeaconDetailCubit _cubit = BeaconDetailCubit(
    repository: context.read<BeaconsRepository>(),
    beaconId: widget.beaconId,
  )..load();

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.plansPath);
    }
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this plan?'),
        content: const Text('Everyone who joined will be told.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel plan'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _cubit.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocConsumer<BeaconDetailCubit, BeaconDetailState>(
            bloc: _cubit,
            listenWhen: (a, b) =>
                b.actionError != null && a.actionError != b.actionError,
            listener: (context, state) => ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(state.actionError!))),
            builder: (context, state) => Column(
              children: [
                AppBackHeader(title: 'Plan', onBack: _back),
                Expanded(child: _body(context, state)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, BeaconDetailState state) {
    switch (state.status) {
      case BeaconDetailStatus.loading:
        return const UserListSkeleton(rows: 2, semanticsLabel: 'Loading plan');
      case BeaconDetailStatus.error:
        final error = state.error!;
        if (error is NotFoundException) {
          return const Center(
            child: AppEmptyView(
              icon: Icons.event_busy_outlined,
              title: 'This plan is unavailable.',
            ),
          );
        }
        return Center(
          child: AppEmptyView(
            icon: Icons.error_outline,
            title: beaconsErrorMessage(error),
            action: TextButton(
              onPressed: _cubit.load,
              child: const Text('Try again'),
            ),
          ),
        );
      case BeaconDetailStatus.ready:
        return RefreshIndicator(
          onRefresh: _cubit.load,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            child: _Details(
              view: state.view!,
              cancelBusy: state.cancelBusy,
              onCancel: _cancel,
            ),
          ),
        );
    }
  }
}

class _Details extends StatelessWidget {
  const _Details({
    required this.view,
    required this.cancelBusy,
    required this.onCancel,
  });

  final pb.BeaconView view;
  final bool cancelBusy;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final b = view.beacon;
    final canCancel =
        view.viewer.canManage &&
        (b.status == pb.BeaconStatus.BEACON_STATUS_OPEN ||
            b.status == pb.BeaconStatus.BEACON_STATUS_FULL);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (b.hidden) ...[
          const AppNoticeBanner(
            message: 'Hidden by moderation: only you can see this plan.',
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppTileIcon(icon: activityIcon(b.activity)),
            const SizedBox(width: AppSpacing.smd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(b.title, style: theme.textTheme.titleLarge),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  BeaconStatusPill(status: b.status),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _Line(icon: Icons.schedule_outlined, text: beaconWhenText(b)),
        _Line(icon: Icons.place_outlined, text: b.venue),
        _Line(icon: Icons.people_outline, text: beaconSeatsText(b)),
        _Line(
          icon: Icons.payments_outlined,
          text: 'Cost: ${costLabel(b.cost)}',
        ),
        _Line(
          icon: Icons.chat_bubble_outline,
          text: 'Chat: ${chatPreferenceLabel(b.chatPreference)}',
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            AppAvatar(url: b.organiser.avatarUrl, radius: 20),
            const SizedBox(width: AppSpacing.smd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.organiser.displayName.isEmpty
                        ? b.organiser.handle
                        : b.organiser.displayName,
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    '@${b.organiser.handle}',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            Text(
              'Organiser',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
        if (b.details.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text(b.details, style: theme.textTheme.bodyMedium),
        ],
        if (canCancel) ...[
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: cancelBusy ? null : onCancel,
            icon: cancelBusy
                ? const SizedBox(
                    width: AppIconSize.sm,
                    height: AppIconSize.sm,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.event_busy_outlined),
            label: const Text('Cancel plan'),
          ),
        ],
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppIconSize.md, color: muted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
