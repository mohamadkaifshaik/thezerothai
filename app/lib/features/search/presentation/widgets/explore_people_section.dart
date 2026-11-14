import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/telemetry/analytics_event.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../../shared/widgets/user/user_list_skeleton.dart';
import '../../../graph/presentation/bloc/suggestions_cubit.dart';
import '../../../graph/presentation/bloc/suggestions_state.dart';
import '../../../graph/presentation/widgets/user_list_row.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';

/// The People tab of Explore, as a sliver: the shared "Who to follow" list
/// ([SuggestionsCubit], at most 5, no cursor: `ListSuggestedUsers` has no
/// pages) as [UserListRow]s with follow buttons. It asks the cubit once per
/// mount (a warm call reads memory) and shows [UserListSkeleton] until that
/// answers; the cubit cannot tell "failed" from "nothing to suggest", so both
/// read as the empty state. Mount it only with `graph` and
/// `follow_suggestions` on.
class ExplorePeopleSection extends StatefulWidget {
  const ExplorePeopleSection({super.key});

  /// Loads the list for the signed-in viewer (a warm call reads memory); also
  /// the screen's pull to refresh.
  static Future<void> reload(BuildContext context) async {
    final uid = context.read<OnboardingBloc>().state.profile?.userId;
    if (uid == null || uid.isEmpty) return;
    await context.read<SuggestionsCubit>().ensureLoaded(uid);
  }

  @override
  State<ExplorePeopleSection> createState() => _ExplorePeopleSectionState();
}

class _ExplorePeopleSectionState extends State<ExplorePeopleSection> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    // After the first frame: an emit while the tree is building would mark
    // the other surfaces dirty mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    await ExplorePeopleSection.reload(context);
    if (mounted) setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SuggestionsCubit>();
    return BlocBuilder<SuggestionsCubit, SuggestionsState>(
      builder: (context, state) {
        final items = state.items;
        if (items.isEmpty) {
          return SliverToBoxAdapter(
            child: _loaded
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: AppEmptyView(
                      icon: Icons.people_outline,
                      title: 'No suggestions right now',
                      subtitle: 'Check back later for people to follow.',
                    ),
                  )
                : const UserListSkeleton(rows: 5),
          );
        }
        return SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            return UserListRow(
              // A stable key per account: each row owns its follow cubit.
              key: ValueKey(item.user.userId),
              followSource: FollowSource.suggestions,
              item: item,
              onProfileTap: item.user.userId.isEmpty
                  ? null
                  : () => context.push(
                      AppRouter.profileByIdPath(item.user.userId),
                    ),
              showDivider: i < items.length - 1,
              onFollowed: () => unawaited(cubit.followed(item.user.userId)),
              onGone: () => cubit.drop(item.user.userId),
              onDismiss: () => cubit.hide(item.user.userId),
            );
          },
        );
      },
    );
  }
}
