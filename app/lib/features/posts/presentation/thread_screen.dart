import 'post_subscription_policy.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/telemetry/usage_reporter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../core/widgets/scroll_constants.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../engagement/presentation/post_open_recorder.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_avatar.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/post/blocked_post_gate.dart';
import '../../../shared/widgets/post/conversation_row.dart';
import '../../../shared/widgets/primitives/character_counter.dart';
import '../../../shared/widgets/post/pending_post_row.dart';
import '../../../shared/widgets/post/post_card.dart';
import '../../../shared/widgets/post/post_moderation_control.dart';
import '../../../shared/widgets/post/post_list_skeleton.dart';
import '../../../shared/widgets/post/unavailable_post_box.dart';
import '../../communities/data/communities_repository.dart';
import '../../communities/domain/communities_feature_flag.dart';
import '../../engagement/domain/engagement_feature_flag.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../moderation/domain/reports_feature_flag.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/posts_repository.dart';
import '../domain/reply_audience.dart';
import '../domain/viewer_author_snapshot.dart';
import 'bloc/composer_cubit.dart';
import 'bloc/thread_cubit.dart';
import 'bloc/thread_moderation_cubit.dart';
import 'composer_screen.dart';
import 'post_error_messages.dart';
import 'widgets/draft_problem_hint.dart';
import 'widgets/post_unavailable_view.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';

part 'thread_context.dart';
part 'thread_footer.dart';
part 'thread_list.dart';
part 'thread_view.dart';

/// `/post/:id` with FEATURE_REPLIES on: the post, its parent/root context
/// (or "This post is unavailable" tombstones), its replies and an inline
/// reply composer (replies-and-threads).
///
/// - One `GetThread` per open (default page of 10), more replies on demand
///   (scroll near the end or "Show more replies"), pull-to-refresh; no
///   polling.
/// - FEATURE_DISABLED from the server (flag turned off under us) renders
///   [fallbackBuilder], the plain post view, instead of an error.
/// - A new reply is appended from the CreatePost response (no refetch);
///   a failed one keeps its text and shows a snackbar.
/// The communities repository while `communities` is on, else null:
/// a thread never reads it for a caller who cannot see Communities.
CommunitiesRepository? _communitiesRepositoryIfOn(BuildContext context) {
  if (!featureEnabledSnapshot(context, kFeatureCommunities)) return null;
  try {
    return context.read<CommunitiesRepository>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Back from a post page: the previous page, or Home when there is none (a
/// deep link).
void leavePostScreen(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRouter.homePath);
  }
}

class ThreadScreen extends StatelessWidget {
  const ThreadScreen({
    super.key,
    required this.postId,
    required this.fallbackBuilder,
  });

  final String postId;

  /// The pre-replies post screen, used when replies are unavailable.
  final WidgetBuilder fallbackBuilder;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      key: ValueKey('thread-$postId'),
      providers: [
        BlocProvider<ThreadCubit>(
          create: (context) => ThreadCubit(
            postsRepository: context.read<PostsRepository>(),
            postId: postId,
            onOpened: postOpenRecorder(context),
          )..load(),
        ),
        BlocProvider<ThreadModerationCubit>(
          create: (context) => ThreadModerationCubit(
            communities: _communitiesRepositoryIfOn(context),
          ),
        ),
        BlocProvider<ComposerCubit>(
          create: (context) => ComposerCubit.reply(
            postTextLimit: () => subscriptionPostLimit(context),
            postPolicyChanges: subscriptionPostChanges(context),
            postsRepository: context.read<PostsRepository>(),
            replyToPostId: postId,
            usage: UsageScope.of(context),
            // Bound to the session the thread was opened in: after a
            // sign-out or an account switch the reply bar empties and sends
            // nothing (the thread page itself stays).
            sessionEpoch: context.read<AppDatabase?>()?.sessionEpoch,
          ),
        ),
      ],
      child: _ThreadView(fallbackBuilder: fallbackBuilder),
    );
  }
}
