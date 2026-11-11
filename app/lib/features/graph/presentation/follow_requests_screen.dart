import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_drawer.dart' show followRequestBadgeSpoken;
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../shared/widgets/post/post_card.dart' show postCardGutterOf;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../data/graph_repository.dart';
import 'bloc/user_list_cubit.dart';
import 'bloc/user_list_state.dart';
import 'graph_error_messages.dart';
import 'widgets/paged_user_list.dart';
import 'widgets/user_list_row.dart';

/// `/follow-requests`: the people who asked to follow a protected
/// account, newest first, 20 per page, each with Accept and Decline.
///
/// - One `ListFollowRequests` per open and one `RespondToFollowRequest` per
///   tap; the badge count comes from `GetMe`, not from here.
/// - The row leaves at the tap and comes back, with a message, if the call
///   fails. There is no undo (founder answer B3): the server has none.
/// - After an Accept the snackbar offers "Follow back" when the caller does
///   not follow the requester yet.
/// - Never flag-gated for a protected caller (the undo rule). FEATURE_DISABLED
///   or UNIMPLEMENTED shows a calm "not available" state; the repository then
///   sends no request for 10 minutes.
class FollowRequestsScreen extends StatefulWidget {
  const FollowRequestsScreen({super.key});

  @override
  State<FollowRequestsScreen> createState() => _FollowRequestsScreenState();
}

class _FollowRequestsScreenState extends State<FollowRequestsScreen> {
  static const _uuid = Uuid();

  late final GraphRepository _graph = context.read<GraphRepository>();
  late final UserListCubit _cubit = UserListCubit(
    fetchPage: _graph.listFollowRequests,
  )..loadFirstPage();

  /// One idempotency key per (requester, answer), reused when the same answer
  /// is retried after a failure and dropped once the server took it.
  final Map<String, String> _keys = {};

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  void _say(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  Future<void> _respond(graph.UserListItem item, {required bool accept}) async {
    final userId = item.user.userId;
    final removed = _cubit.removeUser(userId);
    if (removed == null) return;
    final (removedItem, index) = removed;
    final keyName = '$userId:$accept';
    final key = _keys[keyName] ??= _uuid.v4();
    final onboarding = context.read<OnboardingBloc>();
    try {
      final relationship = await _graph.respondToFollowRequest(
        requesterUserId: userId,
        accept: accept,
        idempotencyKey: key,
      );
      _keys.remove(keyName);
      onboarding.add(const OnboardingFollowRequestAnswered());
      if (!mounted) return;
      final handle = item.user.handle;
      final followsAlready =
          relationship.followState ==
              graph.FollowState.FOLLOW_STATE_FOLLOWING ||
          relationship.followState == graph.FollowState.FOLLOW_STATE_REQUESTED;
      if (accept && !followsAlready) {
        _say(
          '@$handle can now see your posts.',
          action: SnackBarAction(
            label: 'Follow back',
            onPressed: () => _followBack(userId),
          ),
        );
      } else {
        _say(accept ? 'Accepted @$handle.' : 'Declined @$handle.');
      }
    } on AppException catch (e) {
      _cubit.restoreItem(removedItem, index);
      if (!mounted) return;
      _say(followRequestErrorMessage(e, handle: item.user.handle));
    }
  }

  Future<void> _followBack(String userId) async {
    try {
      await _graph.follow(userId: userId, idempotencyKey: _uuid.v4());
    } on AppException catch (e) {
      if (!mounted) return;
      _say(relationshipErrorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              _Header(onBack: _back),
              Expanded(
                child: BlocBuilder<UserListCubit, UserListState>(
                  bloc: _cubit,
                  buildWhen: (a, b) =>
                      (a.error is FeatureDisabledException) !=
                      (b.error is FeatureDisabledException),
                  builder: (context, state) {
                    if (state.error is FeatureDisabledException) {
                      return const Center(
                        child: SingleChildScrollView(
                          child: AppEmptyView(
                            icon: Icons.person_add_alt_outlined,
                            title: "Follow requests aren't available right now",
                            subtitle: 'Please try again in a little while.',
                          ),
                        ),
                      );
                    }
                    return PagedUserList(
                      cubit: _cubit,
                      emptyMessage: 'No follow requests',
                      emptyIcon: Icons.person_add_alt_outlined,
                      rowBuilder: (context, item) => UserListRow(
                        key: ValueKey(item.user.userId),
                        item: item,
                        // The FollowRequests design's rows: the post gutter
                        // and 12 dp padding, a 46 dp avatar and a 12 dp gap,
                        // a 13 sp handle, no dividers.
                        avatarRadius: 23,
                        avatarGap: AppSpacing.smd,
                        horizontalInset: postCardGutterOf(context),
                        verticalInset: AppSpacing.smd,
                        showDivider: false,
                        handleStyle: Theme.of(context).textTheme.bodySmall,
                        trailing: _AnswerButtons(
                          handle: item.user.handle,
                          onAccept: () => _respond(item, accept: true),
                          onDecline: () => _respond(item, accept: false),
                        ),
                      ),
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

/// The page header (dz.css `.bar` with `.sub`): "Follow requests" and,
/// while there are any, "N pending" from `GetMe` under it (0 RPCs). Spoken
/// as one heading.
class _Header extends StatelessWidget {
  const _Header({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final count = context.select(
      (OnboardingBloc bloc) => bloc.state.pendingFollowRequestCount,
    );
    if (count <= 0) {
      return AppBackHeader(title: _title, onBack: onBack);
    }
    final theme = Theme.of(context);
    return AppBackHeader(
      title: _title,
      onBack: onBack,
      titleContent: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge,
          ),
          Text(
            followRequestBadgeSpoken(count),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static const _title = 'Follow requests';
}

/// Decline (an outline pill) and Accept (the primary pill), dz.css
/// `.btn.sm.outline` / `.btn.sm.primary`: compact 36 dp pills inside 48 dp
/// targets. The row measures this at its natural width and moves it under
/// the name when the name column would get too narrow, so it never pushes
/// the name out at a large text scale; the labels wrap, never ellipsize.
class _AnswerButtons extends StatelessWidget {
  const _AnswerButtons({
    required this.handle,
    required this.onAccept,
    required this.onDecline,
  });

  final String handle;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    // The row gives its actions an unbounded width, so the cap comes from the
    // screen: at a large text scale the two buttons stack instead of running
    // off the row.
    final maxWidth = MediaQuery.sizeOf(context).width - 2 * AppSpacing.md;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        alignment: WrapAlignment.end,
        children: [
          Semantics(
            button: true,
            label: 'Decline follow request from @$handle',
            excludeSemantics: true,
            onTap: onDecline,
            child: AppPillButton(
              label: 'Decline',
              variant: AppButtonVariant.outline,
              compact: true,
              onPressed: onDecline,
            ),
          ),
          Semantics(
            button: true,
            label: 'Accept follow request from @$handle',
            excludeSemantics: true,
            onTap: onAccept,
            child: AppPillButton(
              label: 'Accept',
              compact: true,
              onPressed: onAccept,
            ),
          ),
        ],
      ),
    );
  }
}
