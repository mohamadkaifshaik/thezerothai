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

/// Composer that replies to the open post: the row right under it in the
/// thread list at every width (the PostDetail designs), [compact] below the
/// mobile breakpoint. The same 280 code-point rules and counter as the main
/// composer.
class _ReplyComposer extends StatefulWidget {
  const _ReplyComposer({
    required this.focusNode,
    this.blocked = false,
    this.blockedHint = kReplyNotAllowedHint,
    this.compact = false,
  });

  /// The viewer may not reply to the open post: the field and Reply are
  /// disabled, with [blockedHint] ("Only members of `<name>` can reply" for a
  /// post in a community, else a why-less one).
  final bool blocked;
  final String blockedHint;

  /// Focused by Reply on the open post.
  final FocusNode focusNode;

  /// The phone row (below 600 dp): a 36 dp avatar, the 15 sp prompt and the
  /// compact Reply, at the design's 12 / 20 padding. Wider keeps the 48 dp
  /// avatar column and the 20 sp prompt.
  final bool compact;

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
        final compact = widget.compact;
        final viewer = viewerAuthorSnapshot(
          context.read<OnboardingBloc>().state.profile,
        );
        final avatarUrl = viewer.avatarUrl;
        // Phones: the design's 15 sp / 500 prompt. Wider: X's inline prompt,
        // the 20 dp title size at regular weight.
        final textStyle = compact
            ? theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)
            : theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w400);
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
        final gutter = postCardGutterOf(context);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              gutter,
              AppSpacing.smd,
              gutter,
              AppSpacing.smd,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // Wide: in line with the post avatars above it (the
                    // 48 dp column, the 12 dp gap). Phones: the 36 dp avatar
                    // and a 12 dp gap. The gap is on the end side, so it
                    // mirrors in RTL.
                    Padding(
                      padding: EdgeInsetsDirectional.only(
                        end: compact ? AppSpacing.smd : kPostAvatarGap,
                      ),
                      child: ExcludeSemantics(
                        child: compact
                            ? AppAvatar(
                                url: avatarUrl,
                                radius: 36 / 2,
                                name: viewer.displayName,
                              )
                            : SizedBox(
                                width: AppSpacing.minTapTarget,
                                child: Center(
                                  child: AppAvatar.sized(
                                    url: avatarUrl,
                                    size: AppAvatarSize.post,
                                    name: viewer.displayName,
                                  ),
                                ),
                              ),
                      ),
                    ),
                    Expanded(child: field),
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
