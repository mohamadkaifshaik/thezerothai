import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../data/lists_repository.dart';
import '../../domain/list_follow_rules.dart';
import '../../domain/lists_feature_flag.dart';
import '../bloc/list_feed_cubit.dart';
import '../bloc/list_feed_state.dart';
import '../lists_error_messages.dart';
import 'list_follow_button.dart';
import 'list_row.dart';

/// How many Lists the card shows.
const kDiscoverListsRows = 3;

/// The card's title (the desktop Lists mock).
const kDiscoverListsTitle = 'Discover new Lists';

/// The desktop side column's "Discover new Lists" card (the Lists mock): the
/// first Lists of `DiscoverLists` (most followed first) with a Follow toggle,
/// and "See all" to `/lists/discover`. One `DiscoverLists` call (page size
/// [kDiscoverListsRows]) when the card mounts.
///
/// Draws nothing without `lists` and `list_follows`, while loading, empty or
/// failed. A failed Follow says why in a snackbar.
class DiscoverListsCard extends StatefulWidget {
  const DiscoverListsCard({
    super.key,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.md),
  });

  final EdgeInsetsGeometry margin;

  @override
  State<DiscoverListsCard> createState() => _DiscoverListsCardState();
}

class _DiscoverListsCardState extends State<DiscoverListsCard> {
  ListFeedCubit? _cubit;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final on =
        featureEnabledSnapshot(context, kFeatureLists) &&
        featureEnabledSnapshot(context, kFeatureListFollows);
    if (on && _cubit == null) {
      final repository = context.read<ListsRepository>();
      _cubit = ListFeedCubit(
        repository: repository,
        fetch: (token) => repository.discoverLists(
          pageSize: kDiscoverListsRows,
          pageToken: token,
        ),
      )..load();
    } else if (!on && _cubit != null) {
      _cubit!.close();
      _cubit = null;
    }
  }

  @override
  void dispose() {
    _cubit?.close();
    super.dispose();
  }

  Future<void> _toggle(String listId) async {
    final error = await _cubit?.toggleFollow(listId);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(listsErrorMessage(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = _cubit;
    if (cubit == null) return const SizedBox.shrink();
    final viewer = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    return BlocBuilder<ListFeedCubit, ListFeedState>(
      bloc: cubit,
      builder: (context, state) {
        if (state.status != ListFeedStatus.ready || state.lists.isEmpty) {
          return const SizedBox.shrink();
        }
        return ContextPaneCard(
          key: const ValueKey('discover-lists'),
          title: kDiscoverListsTitle,
          margin: widget.margin,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final list in state.lists.take(kDiscoverListsRows))
                ListRow(
                  key: ValueKey(list.listId),
                  list: list,
                  onTap: () => context.push(AppRouter.listPath(list.listId)),
                  trailing: canFollowList(list, viewer)
                      ? Padding(
                          padding: const EdgeInsetsDirectional.only(
                            end: AppSpacing.md,
                          ),
                          child: ListFollowButton(
                            listName: list.name,
                            following: list.followedByViewer,
                            busy: state.busyIds.contains(list.listId),
                            onToggle: () => _toggle(list.listId),
                          ),
                        )
                      : null,
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, AppSpacing.minTapTarget),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    textStyle: Theme.of(context).textTheme.bodyMedium,
                  ),
                  onPressed: () => context.push(AppRouter.discoverListsPath),
                  child: const Text('See all'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
