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

/// Composer that replies to the open post: docked under the thread on
/// phones, or [inline] right under the open post on wider screens (X's post
/// page, captured 2026-11-02). The same 280 code-point rules and counter as
/// the main composer.
class _ReplyComposer extends StatefulWidget {
  const _ReplyComposer({
    required this.focusNode,
    this.blocked = false,
    this.blockedHint = kReplyNotAllowedHint,
    this.inline = false,
  });

  /// The viewer may not reply to the open post: the field and Reply are
  /// disabled, with [blockedHint] ("Only members of `<name>` can reply" for a
  /// post in a community, else a why-less one).
  final bool blocked;
  final String blockedHint;

  /// Focused by Reply on the open post.
  final FocusNode focusNode;

  /// Part of the thread list: no docked surface, a larger prompt and a rule
  /// below instead of above.
  final bool inline;

  @override
  State<_ReplyComposer> createState() => _ReplyComposerState();
}

class _ReplyComposerState extends State<_ReplyComposer> {
  // Starts from the cubit's text: the composer is rebuilt when the window
  // crosses the inline / docked width, and the draft must survive it.
  late final _controller = TextEditingController(
    text: context.read<ComposerCubit>().state.draft.text,
  );

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
          (after.status == ComposerStatus.posted &&
              before.status != ComposerStatus.posted) ||
          (after.sessionEnded && !before.sessionEnded),
      // The thread screen clears the cubit's draft on a post, the cubit itself
      // when the session ended (the old account's text goes); this clears the
      // field.
      listener: (context, state) => _controller.clear(),
      builder: (context, state) {
        final inline = widget.inline;
        final avatarUrl = viewerAuthorSnapshot(
          context.read<OnboardingBloc>().state.profile,
        ).avatarUrl;
        // X's inline prompt is the 20dp title size at regular weight.
        final textStyle = inline
            ? theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w400)
            : theme.textTheme.bodyLarge;
        final field = TextField(
          controller: _controller,
          focusNode: widget.focusNode,
          // Opened in a session that has ended: nothing more can be sent.
          enabled:
              !state.isSubmitting && !widget.blocked && !state.sessionEnded,
          minLines: 1,
          maxLines: 5,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [
            LengthLimitingTextInputFormatter(kComposerInputCap),
          ],
          style: textStyle,
          decoration: InputDecoration(
            hintText: widget.blocked ? widget.blockedHint : 'Post your reply',
            hintStyle: textStyle?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
          ),
          onChanged: cubit.textChanged,
        );
        final side = BorderSide(color: theme.dividerColor);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: inline ? Border(bottom: side) : Border(top: side),
          ),
          child: Padding(
            padding: inline
                ? EdgeInsetsDirectional.fromSTEB(
                    postCardGutterOf(context),
                    AppSpacing.smd,
                    postCardGutterOf(context),
                    AppSpacing.smd,
                  )
                : const EdgeInsetsDirectional.fromSTEB(
                    AppSpacing.md,
                    AppSpacing.sm,
                    AppSpacing.sm,
                    AppSpacing.sm,
                  ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: inline
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.end,
                  children: [
                    // In line with the post avatars above it on wide screens
                    // (the 48 dp column, the 12 dp gap). The gap is on the
                    // end side, so it mirrors in RTL.
                    Padding(
                      padding: EdgeInsetsDirectional.only(
                        bottom: inline ? 0 : AppSpacing.xs,
                        end: inline ? kPostAvatarGap : AppSpacing.sm,
                      ),
                      child: ExcludeSemantics(
                        child: inline
                            ? SizedBox(
                                width: AppSpacing.minTapTarget,
                                child: Center(
                                  child: AppAvatar.sized(
                                    url: avatarUrl,
                                    size: AppAvatarSize.post,
                                  ),
                                ),
                              )
                            : AppAvatar(url: avatarUrl),
                      ),
                    ),
                    Expanded(
                      child: inline
                          ? field
                          : AppSurface(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.md,
                              ),
                              child: field,
                            ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    // The designs' `.btn.primary.sm`: a 36 dp pill in the
                    // 48 dp target.
                    AppPillButton(
                      label: 'Reply',
                      compact: true,
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
