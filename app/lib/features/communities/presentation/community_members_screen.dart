import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_status_pill.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/presentation/bloc/user_list_cubit.dart';
import '../../graph/presentation/bloc/user_list_state.dart';
import '../../graph/presentation/widgets/paged_user_list.dart';
import '../../graph/presentation/widgets/user_list_row.dart';
import '../data/communities_repository.dart';
import '../domain/community_role.dart';
import 'widgets/community_row.dart';
import 'widgets/community_unavailable_view.dart';

/// `/communities/:id/members` (W5-32): the joined members, 1
/// `ListCommunityMembers` per page, each with a Follow button; the owner and
/// moderators carry a role badge. NOT_FOUND shows the same "This Community is
/// unavailable" as the page; FEATURE_DISABLED / UNIMPLEMENTED shows "not
/// available yet". Moderation actions (ban, roles) arrive with W5-35.
class CommunityMembersScreen extends StatefulWidget {
  const CommunityMembersScreen({super.key, required this.communityId});

  final String communityId;

  @override
  State<CommunityMembersScreen> createState() => _CommunityMembersScreenState();
}

class _CommunityMembersScreenState extends State<CommunityMembersScreen> {
  late final CommunitiesRepository _communities = context
      .read<CommunitiesRepository>();
  late final UserListCubit _cubit = UserListCubit(fetchPage: _fetch)
    ..loadFirstPage();

  /// Role of each member seen so far (the badge), by user id.
  final Map<String, CommunityRole> _roles = {};

  Future<GraphPage> _fetch({
    required int pageSize,
    required String pageToken,
  }) async {
    final page = await _communities.listMembers(
      communityId: widget.communityId,
      pageSize: pageSize,
      pageToken: pageToken,
    );
    for (final m in page.members) {
      _roles[m.user.user.userId] = m.memberRole;
    }
    return GraphPage(
      items: page.members.map((m) => m.user).toList(),
      nextPageToken: page.nextPageToken,
    );
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.communityPath(widget.communityId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(title: 'Members', onBack: _back),
              Expanded(
                child: BlocBuilder<UserListCubit, UserListState>(
                  bloc: _cubit,
                  buildWhen: (a, b) =>
                      a.error.runtimeType != b.error.runtimeType,
                  builder: (context, state) {
                    final error = state.error;
                    if (error is NotFoundException) {
                      return const Center(
                        child: SingleChildScrollView(
                          child: CommunityUnavailableView(),
                        ),
                      );
                    }
                    if (error is FeatureDisabledException) {
                      return const Center(
                        child: SingleChildScrollView(
                          child: AppEmptyView(
                            icon: Icons.groups_outlined,
                            title: "Communities aren't available right now",
                            subtitle: 'Please try again in a little while.',
                          ),
                        ),
                      );
                    }
                    return PagedUserList(
                      cubit: _cubit,
                      emptyMessage: 'No members yet',
                      emptyIcon: Icons.groups_outlined,
                      rowBuilder: (context, item) {
                        final badge = communityRoleBadge(
                          _roles[item.user.userId] ?? CommunityRole.none,
                        );
                        return UserListRow(
                          key: ValueKey(item.user.userId),
                          item: item,
                          extraAction: badge == null
                              ? null
                              : AppStatusPill(label: badge),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
