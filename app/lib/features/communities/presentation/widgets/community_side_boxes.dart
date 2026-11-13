import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../graph/presentation/widgets/user_list_row.dart';
import '../bloc/community_detail_cubit.dart';
import '../bloc/community_detail_state.dart';
import 'community_about.dart';

/// The desktop Community mock's side boxes: Rules and Moderators, built from
/// the one `GetCommunity` the page already made (no call of its own). Lent
/// to the shell's side column by `CommunityScreen`, so it takes the page's
/// [detail] cubit by closure.
class CommunitySideBoxes extends StatelessWidget {
  const CommunitySideBoxes({super.key, required this.detail});

  final CommunityDetailCubit detail;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CommunityDetailCubit, CommunityDetailState>(
      bloc: detail,
      builder: (context, state) {
        if (state.status != CommunityDetailStatus.ready ||
            state.community == null) {
          return const SizedBox.shrink();
        }
        final people = communityModeratorsOf(state);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ContextPaneCard(
              title: 'Rules',
              child: state.rules.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.only(bottom: AppSpacing.sm),
                      child: CommunityNoRules(),
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < state.rules.length; i++)
                          CommunityRuleRow(
                            key: ValueKey('side-rule-$i'),
                            number: i + 1,
                            title: state.rules[i].title,
                            text: state.rules[i].text,
                          ),
                      ],
                    ),
            ),
            if (people.isNotEmpty)
              ContextPaneCard(
                title: 'Moderators',
                child: Column(
                  children: [
                    for (final person in people)
                      UserListRow(
                        key: ValueKey('side-mod-${person.user.userId}'),
                        item: person,
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
