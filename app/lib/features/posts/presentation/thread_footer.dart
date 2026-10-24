part of 'thread_screen.dart';

/// Below the replies: the viewer's reply in flight, then the page state
/// (spinner / inline retry / "Show more replies" / empty guidance).
class _Footer extends StatelessWidget {
  const _Footer({required this.state, required this.empty});

  final ThreadState state;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cubit = context.read<ThreadCubit>();
    final Widget page;
    if (state.loadingMore) {
      page = const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (state.loadMoreError != null) {
      page = Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                "Couldn't load more replies.",
                style: theme.textTheme.bodyMedium,
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, AppSpacing.minTapTarget),
              ),
              onPressed: cubit.retryLoadMore,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    } else if (state.hasMore) {
      // Pages can come back short; the button always makes progress.
      page = Center(
        child: TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, AppSpacing.minTapTarget),
          ),
          onPressed: cubit.loadMore,
          child: const Text('Show more replies'),
        ),
      );
    } else if (empty) {
      page = const AppEmptyView(
        icon: Icons.chat_bubble_outline,
        title: 'No replies yet',
        subtitle: 'Start the conversation below.',
      );
    } else {
      page = const SizedBox.shrink();
    }
    return Column(
      children: [
        BlocBuilder<ComposerCubit, ComposerState>(
          buildWhen: (a, b) => a.isSubmitting != b.isSubmitting,
          builder: (context, composer) => composer.isSubmitting
              ? Column(
                  children: [
                    PendingPostRow(
                      text: composer.draft.text,
                      author: viewerAuthorSnapshot(
                        context.read<OnboardingBloc>().state.profile,
                      ),
                      // The spinner on the button is the one live
                      // announcement ("Sending reply").
                      semanticsLabel: null,
                    ),
                    const Divider(height: 1),
                  ],
                )
              : const SizedBox.shrink(),
        ),
        page,
      ],
    );
  }
}

/// Inline composer docked under the thread: replies to the open post. The
/// same 280 code-point rules and counter as the main composer.
class _ReplyComposer extends StatefulWidget {
  const _ReplyComposer({this.blocked = false});

  /// The viewer may not reply to the open post: the field and Reply are
  /// disabled, with a why-less hint.
  final bool blocked;

  @override
  State<_ReplyComposer> createState() => _ReplyComposerState();
}

class _ReplyComposerState extends State<_ReplyComposer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cubit = context.read<ComposerCubit>();
    return BlocConsumer<ComposerCubit, ComposerState>(
      listenWhen: (before, after) =>
          after.status == ComposerStatus.posted &&
          before.status != ComposerStatus.posted,
      listener: (context, state) {
        _controller.clear();
        cubit.textChanged('');
      },
      builder: (context, state) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(top: BorderSide(color: theme.dividerColor)),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: AppSpacing.xs,
                        right: AppSpacing.sm,
                      ),
                      child: ExcludeSemantics(
                        child: AppAvatar(
                          url: viewerAuthorSnapshot(
                            context.read<OnboardingBloc>().state.profile,
                          ).avatarUrl,
                        ),
                      ),
                    ),
                    Expanded(
                      child: AppSurface(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                        ),
                        child: TextField(
                          controller: _controller,
                          enabled: !state.isSubmitting && !widget.blocked,
                          minLines: 1,
                          maxLines: 5,
                          keyboardType: TextInputType.multiline,
                          textCapitalization: TextCapitalization.sentences,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(kComposerInputCap),
                          ],
                          style: theme.textTheme.bodyLarge,
                          decoration: InputDecoration(
                            hintText: widget.blocked
                                ? kReplyNotAllowedHint
                                : 'Post your reply',
                            hintStyle: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                          ),
                          onChanged: cubit.textChanged,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    AppPillButton(
                      label: 'Reply',
                      busy: state.isSubmitting,
                      busySemanticsLabel: 'Sending reply',
                      onPressed: state.canSubmit && !widget.blocked
                          ? cubit.submit
                          : null,
                    ),
                  ],
                ),
                if (state.draft.text.isNotEmpty)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      DraftProblemHint(problem: state.draft.problem),
                      CharacterCounter(remaining: state.draft.remaining),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
