import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/close_routes_above.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/telemetry/usage_reporter.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../shared/widgets/post/conversation_row.dart';
import '../../../shared/widgets/post/post_card.dart';
import '../../../shared/widgets/primitives/app_avatar.dart';
import '../../../shared/widgets/primitives/character_counter.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/posts_repository.dart';
import '../domain/posts_feature_flag.dart';
import '../domain/reply_audience.dart';
import '../domain/viewer_author_snapshot.dart';
import 'bloc/composer_cubit.dart';
import 'composer_screen.dart';
import 'post_error_messages.dart';
import 'widgets/draft_problem_hint.dart';
import 'widgets/loaded_post.dart';

class ReplyComposerScreen extends StatelessWidget {
  const ReplyComposerScreen({super.key, required this.postId});
  final String postId;

  @override
  Widget build(BuildContext context) => LoadedPost(
    postId: postId,
    loadingFrame: (child) => Scaffold(
      appBar: AppBar(
        title: const Text('Reply'),
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go(AppRouter.postPath(postId)),
        ),
      ),
      body: child,
    ),
    builder: (context, view) => BlocProvider(
      create: (context) => ComposerCubit.reply(
        postsRepository: context.read<PostsRepository>(),
        replyToPostId: postId,
        usage: UsageScope.of(context),
        // Bound to the session it was opened in: after a sign-out or an
        // account switch nothing typed here is sent, and the screen leaves.
        sessionEpoch: context.read<AppDatabase?>()?.sessionEpoch,
      ),
      child: _ReplyEditor(parent: view),
    ),
  );
}

class _ReplyEditor extends StatefulWidget {
  const _ReplyEditor({required this.parent});
  final pb.PostView parent;
  @override
  State<_ReplyEditor> createState() => _ReplyEditorState();
}

class _ReplyEditorState extends State<_ReplyEditor> {
  bool _leaving = false;
  bool _asking = false;

  /// Set by the first [_leaveOnce]: the screen pops once, whatever the cubit
  /// emits until the route is gone.
  bool _left = false;

  /// Leaves after this frame (so [PopScope] lets it), closing first any
  /// dialog open over the screen. Once only.
  void _leaveOnce([pb.PostView? result]) {
    if (_left) return;
    _left = true;
    setState(() => _leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Already off the stack (a sign-out redirect replaced it): a pop or a
      // `go` now would take the new stack's page.
      if (!mounted || !closeRoutesAbove(context)) return;
      _pop(result);
    });
  }

  void _pop([pb.PostView? result]) {
    if (context.canPop()) {
      context.pop(result);
    } else {
      context.go(AppRouter.postPath(widget.parent.post.postId));
    }
  }

  Future<void> _close() async {
    final state = context.read<ComposerCubit>().state;
    if (_asking || state.isSubmitting) return;
    if (state.draft.text.isNotEmpty) {
      _asking = true;
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard reply?'),
          content: const Text('Your reply will be lost.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      _asking = false;
      if (!mounted || discard != true) return;
    }
    _leaveOnce();
  }

  @override
  Widget build(BuildContext context) {
    final repliesOn = isFeatureEnabled(context, kPostsSubFeatureReplies);
    final blocked = !repliesOn || replyKnownNotAllowed(widget.parent);
    return BlocConsumer<ComposerCubit, ComposerState>(
      listener: (context, state) {
        if (_left) return;
        if (state.sessionEnded) {
          // Signed out, or another account: leave, asking nothing.
          _leaveOnce();
        } else if (state.status == ComposerStatus.posted) {
          _leaveOnce(state.created);
        } else if (state.error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(replyErrorMessage(state.error!))),
          );
          context.read<ComposerCubit>().errorShown();
        }
      },
      builder: (context, state) => PopScope(
        canPop: _leaving || (!state.isSubmitting && state.draft.text.isEmpty),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Close',
              onPressed: state.isSubmitting ? null : _close,
              icon: const Icon(Icons.close),
            ),
            title: const Text('Reply'),
          ),
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConversationRow(
                  connectAfter: true,
                  child: PostCard(
                    view: widget.parent,
                    graphActionsEnabled: false,
                  ),
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 72,
                    end: 16,
                    bottom: 12,
                  ),
                  child: Text(
                    'Replying to @${widget.parent.post.author.handle}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppAvatar(
                        url: viewerAuthorSnapshot(
                          context.read<OnboardingBloc>().state.profile,
                        ).avatarUrl,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          autofocus: !blocked,
                          enabled: !blocked && !state.isSubmitting,
                          minLines: 4,
                          maxLines: null,
                          maxLengthEnforcement: MaxLengthEnforcement.none,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(kComposerInputCap),
                          ],
                          decoration: const InputDecoration(
                            hintText: 'Post your reply',
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                          ),
                          onChanged: context.read<ComposerCubit>().textChanged,
                        ),
                      ),
                    ],
                  ),
                ),
                if (blocked)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      repliesOn
                          ? replyNotAllowedHint(widget.parent)
                          : 'Replies are not available.',
                    ),
                  ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: DraftProblemHint(problem: state.draft.problem),
                      ),
                      CharacterCounter(remaining: state.draft.remaining),
                      const SizedBox(width: 12),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: !blocked && state.canSubmit
                            ? context.read<ComposerCubit>().submit
                            : null,
                        child: Text(state.isSubmitting ? 'Sending…' : 'Reply'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
