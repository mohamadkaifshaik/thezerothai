import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../shared/widgets/primitives/settings_group.dart';
import '../../../posts/data/posts_repository.dart';
import '../bloc/scheduled_waiting_cubit.dart';

/// The "Scheduled posts" row of Settings: opens the root `/scheduled` page
/// full screen (never a detail page, never a selection). With a
/// [PostsRepository] in the tree it loads its own "N posts waiting" subtitle
/// (F33, one `ListScheduledPosts` while the row is on screen; the list and the
/// tablet categories build the row in one place at a time). The Settings
/// list builds it only with `posts` and `scheduled_posts` on.
class ScheduledPostsRow extends StatelessWidget {
  const ScheduledPostsRow({super.key});

  static const title = 'Scheduled posts';

  @override
  Widget build(BuildContext context) {
    final repository = context.read<PostsRepository?>();
    if (repository == null) return const _Row(subtitle: null);
    return BlocProvider<ScheduledWaitingCubit>(
      create: (_) {
        final cubit = ScheduledWaitingCubit(repository: repository);
        unawaited(cubit.load());
        return cubit;
      },
      child: BlocBuilder<ScheduledWaitingCubit, ScheduledWaiting?>(
        builder: (context, waiting) => _Row(subtitle: waiting?.label),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.subtitle});

  final String? subtitle;

  @override
  Widget build(BuildContext context) => SettingsRow(
    icon: Icons.schedule_send_outlined,
    title: ScheduledPostsRow.title,
    subtitle: subtitle,
    onTap: () => context.push(AppRouter.scheduledPostsPath),
  );
}
