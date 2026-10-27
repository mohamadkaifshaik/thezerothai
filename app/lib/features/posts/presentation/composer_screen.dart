import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/app_form_header.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/character_counter.dart';
import '../../../shared/widgets/embedded_post_card.dart';
import '../../auth/presentation/widgets/verify_email_view.dart';
import '../../media/data/image_picker_service.dart';
import '../../media/data/media_repository.dart';
import '../../media/data/media_uploader.dart';
import '../../media/domain/image_processor.dart';
import '../../media/domain/media_feature_flag.dart';
import '../../media/presentation/bloc/attachments_cubit.dart';
import '../../media/presentation/media_error_messages.dart';
import '../../media/presentation/widgets/attachment_grid.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/posts_repository.dart';
import '../domain/posts_feature_flag.dart';
import '../domain/reply_audience.dart';
import '../domain/viewer_author_snapshot.dart';
import 'bloc/composer_cubit.dart';
import 'bloc/pending_posts_cubit.dart';
import 'post_error_messages.dart';
import 'quote_gate.dart';
import 'widgets/draft_problem_hint.dart';
import 'widgets/reply_audience_sheet.dart';
import 'widgets/schedule_controls.dart';
import 'widgets/schedule_dialog.dart';

/// Upper bound on what the field accepts. It is far above the 280 limit so
/// the counter can go negative (the user sees how much to cut), while a huge
/// paste never makes every keystroke expensive.
const kComposerInputCap = 1000;

/// `/compose` (T16): write a text post. 280 code points counted after NFC
/// (ADR-0010 D9), at most 10 lines; Post is disabled otherwise. The server
/// stays authoritative.
///
/// With [quoteOfPostId] (`/compose?quote=<id>`, P5) it is the quote
/// composer: the same screen and the same 280 limit, with a preview of the
/// quoted post ([quotePreview], a frozen snapshot passed by the router; null
/// after a page reload) under the text field. It needs the `engagement` flag
/// and the `quotes` flag (see [quoteCreationAllowed]); without them it shows
/// "not available" instead of a composer that could only fail.
class ComposerScreen extends StatelessWidget {
  const ComposerScreen({
    super.key,
    this.quoteOfPostId = '',
    this.quotePreview,
    @visibleForTesting this.scheduleClock,
  });

  final String quoteOfPostId;
  final pb.EmbeddedPost? quotePreview;

  /// The clock the Schedule dialog reads, both for the time it opens on and
  /// for the check on Confirm (null: the device clock). A seam for tests: the
  /// check moves with the real clock, so a test that opens the dialog and
  /// presses Confirm either side of a minute boundary would be refused.
  final DateTime Function()? scheduleClock;

  @override
  Widget build(BuildContext context) {
    if (quoteOfPostId.isNotEmpty && !quoteCreationAllowed(context)) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => context.canPop()
                ? context.pop()
                : context.go(AppRouter.homePath),
          ),
          title: const Text('Quote'),
        ),
        body: const SafeArea(
          child: AppErrorView(
            error: FeatureDisabledException('Quotes are not available.'),
          ),
        ),
      );
    }
    final profile = context.read<OnboardingBloc>().state.profile;
    // The photo button exists only with FEATURE_MEDIA on (P4 plan D3); with
    // it off nothing media-related is created or read from the tree.
    // The posts gate may already know the media sub-feature is off (a
    // FEATURE_DISABLED earlier this session): then no photo button either.
    final mediaEnabled =
        featureEnabledSnapshot(context, kFeatureMedia) &&
        context.read<PostsRepository>().subFeatureEnabled(
          kPostsSubFeatureMedia,
        );
    return MultiBlocProvider(
      providers: [
        if (mediaEnabled)
          BlocProvider<AttachmentsCubit>(
            create: (context) => AttachmentsCubit(
              picker: context.read<ImagePickerService>(),
              processor: context.read<ImageProcessor>(),
              uploader: MediaUploader(
                repository: context.read<MediaRepository>(),
                onUnexpectedError: context.read<UnexpectedErrorReporter>(),
              ),
            ),
          ),
        BlocProvider<ComposerCubit>(
          create: (context) => ComposerCubit(
            postsRepository: context.read<PostsRepository>(),
            pending: context.read<PendingPostsCubit>(),
            author: viewerAuthorSnapshot(profile),
            quoteOfPostId: quoteOfPostId,
            attachments: mediaEnabled ? context.read<AttachmentsCubit>() : null,
            // Setting an audience needs the flag; a quote is a root post, so
            // it may (a reply never uses this screen).
            replyAudienceEnabled: featureEnabledSnapshot(
              context,
              kFeatureReplyAudience,
            ),
            // Scheduling needs both flags; the cubit also refuses it for a
            // quote (a reply never uses this screen).
            scheduleEnabled:
                featureEnabledSnapshot(context, kFeaturePosts) &&
                featureEnabledSnapshot(context, kFeatureScheduledPosts),
            onUnexpectedError: context.read<UnexpectedErrorReporter>(),
          ),
        ),
      ],
      child: mediaEnabled
          ? BlocListener<AttachmentsCubit, AttachmentsState>(
              listenWhen: (prev, curr) => curr.pickFailed && !prev.pickFailed,
              listener: (context, _) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(content: Text(kPickFailedMessage)),
                  );
                context.read<AttachmentsCubit>().pickFailureShown();
              },
              child: _ComposerView(
                mediaEnabled: mediaEnabled,
                quotePreview: quotePreview,
                avatarUrl: viewerAuthorSnapshot(profile).avatarUrl,
                scheduleClock: scheduleClock,
              ),
            )
          : _ComposerView(
              mediaEnabled: mediaEnabled,
              quotePreview: quotePreview,
              avatarUrl: viewerAuthorSnapshot(profile).avatarUrl,
              scheduleClock: scheduleClock,
            ),
    );
  }
}

class _ComposerView extends StatefulWidget {
  const _ComposerView({
    required this.mediaEnabled,
    required this.avatarUrl,
    this.quotePreview,
    this.scheduleClock,
  });

  final bool mediaEnabled;
  final pb.EmbeddedPost? quotePreview;

  /// The viewer's avatar (empty: the person icon).
  final String avatarUrl;

  /// [ComposerScreen.scheduleClock].
  final DateTime Function()? scheduleClock;

  @override
  State<_ComposerView> createState() => _ComposerViewState();
}

class _ComposerViewState extends State<_ComposerView> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The server turned scheduling off: the cubit has already dropped the
  /// schedule, but the error is still about scheduling.
  bool _refusedScheduling(AppException error) =>
      error is FeatureDisabledException &&
      error.feature == kFeatureScheduledPosts;

  /// SchedulePost succeeded: the cubit has reset the composer, so clear the
  /// field, and say when the post will go out (the time the server stored).
  /// The messenger is app-level; "View" opens the Scheduled list.
  void _onScheduled(BuildContext context, pb.ScheduledPost scheduled) {
    _controller.clear();
    final router = GoRouter.of(context);
    final cubit = context.read<ComposerCubit>();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            scheduledToastText(
              scheduled,
              use24Hour: MediaQuery.alwaysUse24HourFormatOf(context),
            ),
          ),
          action: scheduledToastHasView(scheduled)
              ? SnackBarAction(
                  label: 'View',
                  onPressed: () => unawaited(
                    router
                        .push(AppRouter.scheduledPostsPath)
                        .then(
                          (_) => _scheduleAvailabilityMayHaveChanged(cubit),
                        ),
                  ),
                )
              : null,
        ),
      );
    cubit.scheduledNoticeShown();
  }

  /// Back from the Scheduled list (or a tap on a control that went stale),
  /// which may have learned that scheduling is switched off
  /// (FEATURE_DISABLED): drop a time that can no longer be sent, so "Post"
  /// means what it says, and rebuild, because `canSchedule` reads the gate
  /// and nothing in the cubit state changes when only the gate does.
  void _scheduleAvailabilityMayHaveChanged(ComposerCubit cubit) {
    if (!mounted || cubit.isClosed) return;
    cubit.scheduleAvailabilityChecked();
    setState(() {});
  }

  /// Opens the Schedule dialog and applies its answer. [notice] is a server
  /// refusal of the time, shown under the pickers.
  Future<void> _openSchedule(BuildContext context, {String? notice}) async {
    final cubit = context.read<ComposerCubit>();
    if (!cubit.canSchedule) {
      // Scheduling went off since this page was built.
      _scheduleAvailabilityMayHaveChanged(cubit);
      return;
    }
    final result = await showScheduleDialog(
      context,
      initial: cubit.state.scheduledAt,
      hasMedia: cubit.state.hasAttachments,
      notice: notice,
      clock: widget.scheduleClock,
    );
    if (!context.mounted) return;
    switch (result) {
      case ScheduleChosen(:final publishAt):
        cubit.scheduleChanged(publishAt);
      case ScheduleRemoved():
        cubit.scheduleChanged(null);
      case ScheduleOpenList():
        // push, never go: the draft stays here underneath.
        await context.push(AppRouter.scheduledPostsPath);
        _scheduleAvailabilityMayHaveChanged(cubit);
      case null:
        break;
    }
  }

  void _onState(BuildContext context, ComposerState state) {
    final scheduled = state.scheduledNotice;
    if (scheduled != null) {
      _onScheduled(context, scheduled);
      return;
    }
    if (state.status == ComposerStatus.posted) {
      // ADR-0021 L-1: the server echoed another audience than the one sent.
      // The messenger is app-level, so the snackbar outlives this screen.
      if (state.replyPolicyNotApplied) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text(kReplyPolicyNotAppliedMessage)),
          );
      }
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRouter.homePath);
      }
      return;
    }
    final error = state.error;
    // The server refused the time (too soon, too far): reopen the dialog
    // with the reason instead of a snackbar.
    if (error is ValidationException &&
        error.field == 'publish_at' &&
        state.isScheduling) {
      context.read<ComposerCubit>().errorShown();
      unawaited(_openSchedule(context, notice: scheduleErrorMessage(error)));
      return;
    }
    // EmailNotVerified swaps in VerifyEmailView (see build); everything else
    // is a snackbar, once.
    if (error != null && error is! EmailNotVerifiedException) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              state.uploadFailed
                  ? uploadErrorMessage(error)
                  : state.isScheduling || _refusedScheduling(error)
                  ? scheduleErrorMessage(error)
                  : context.read<ComposerCubit>().quoteOfPostId.isNotEmpty
                  ? quoteErrorMessage(error)
                  : createPostErrorMessage(error),
            ),
          ),
        );
      context.read<ComposerCubit>().errorShown();
    }
  }

  /// Leaves the screen; with photos attached it asks first (they are not
  /// saved anywhere). Never while the post is being sent.
  Future<void> _requestClose(BuildContext context, ComposerState state) async {
    if (state.isSubmitting) return;
    if (state.hasAttachments) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard this post?'),
          content: const Text('Your photos will not be saved.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true || !context.mounted) return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ComposerCubit, ComposerState>(
      // Attachment progress re-emits the state many times; side effects
      // (pop, snackbar) must run once per status or error change only.
      listenWhen: (prev, curr) =>
          prev.status != curr.status ||
          !identical(prev.error, curr.error) ||
          !identical(prev.scheduledNotice, curr.scheduledNotice),
      listener: _onState,
      builder: (context, state) {
        final cubit = context.read<ComposerCubit>();
        final isQuote = cubit.quoteOfPostId.isNotEmpty;
        // A time is only shown (and "Schedule" only written) while the
        // composer can still schedule: never a line the button cannot honour.
        final scheduling = state.isScheduling && cubit.canSchedule;
        // Back (system gesture, browser) is blocked while the post is being
        // sent, and asks first when photos are attached. There is no cancel
        // for an upload in flight. Applies to the verify-email view too: it
        // replaces the composer, but the attachments are still held.
        final canLeaveFreely =
            state.status == ComposerStatus.posted ||
            (!state.isSubmitting && !state.hasAttachments);
        if (state.error is EmailNotVerifiedException) {
          return PopScope(
            canPop: canLeaveFreely,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _requestClose(context, state);
            },
            child: VerifyEmailView(
              banner: createPostErrorMessage(state.error!),
              onBack: cubit.errorShown,
            ),
          );
        }
        return PopScope(
          canPop: canLeaveFreely,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _requestClose(context, state);
          },
          child: Scaffold(
            // The keyboard shrinks the body, so the field and the bottom bar
            // (photos, counter) stay above it.
            body: SafeArea(
              child: AppMainColumn(
                child: Column(
                  children: [
                    AppFormHeader(
                      title: isQuote ? 'Quote' : 'New post',
                      busy: state.isSubmitting,
                      busySemanticsLabel: scheduling ? 'Scheduling post' : null,
                      onCancel: () => _requestClose(context, state),
                      actionLabel: scheduling ? 'Schedule' : 'Post',
                      onAction: state.canSubmit ? cubit.submit : null,
                    ),
                    // The header announces "Scheduling post"; this bar is
                    // only the picture of it.
                    if (state.isSubmitting && scheduling)
                      const ExcludeSemantics(
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    if (scheduling)
                      ScheduleLine(
                        publishAt: state.scheduledAt!,
                        enabled: !state.isSubmitting,
                        onTap: () => _openSchedule(context),
                      ),
                    // L-9: the photos are reachable by link before the post
                    // goes out. The dialog says so too, but photos can be
                    // added after the time was set.
                    if (scheduling && state.hasAttachments)
                      const _ScheduleImagesNoteBox(),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ExcludeSemantics(
                              child: AppAvatar(url: widget.avatarUrl),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: TextField(
                                controller: _controller,
                                autofocus: true,
                                enabled: !state.isSubmitting,
                                expands: true,
                                maxLines: null,
                                minLines: null,
                                textAlignVertical: TextAlignVertical.top,
                                keyboardType: TextInputType.multiline,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                inputFormatters: [
                                  LengthLimitingTextInputFormatter(
                                    kComposerInputCap,
                                  ),
                                ],
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(fontSize: 18),
                                decoration: InputDecoration(
                                  hintText: isQuote
                                      ? 'Add a comment'
                                      : "What's happening?",
                                  hintStyle: Theme.of(context)
                                      .textTheme
                                      .bodyLarge
                                      ?.copyWith(
                                        fontSize: 18,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
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
                          ],
                        ),
                      ),
                    ),
                    if (isQuote) _QuotePreview(preview: widget.quotePreview),
                    if (widget.mediaEnabled)
                      AttachmentGrid(enabled: !state.isSubmitting),
                    if (cubit.canChooseReplyAudience)
                      _ReplyAudienceLink(
                        audience: state.replyAudience,
                        enabled: !state.isSubmitting,
                        onChanged: cubit.replyAudienceChanged,
                      ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        AppSpacing.sm,
                        AppSpacing.xs,
                        AppSpacing.md,
                        AppSpacing.xs,
                      ),
                      // Photos at the start, the counter at the end; the hint
                      // (when there is one) takes the space between.
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.mediaEnabled) const _AddPhotoButton(),
                              if (cubit.canSchedule)
                                ScheduleButton(
                                  scheduled: scheduling,
                                  enabled: !state.isSubmitting,
                                  onPressed: () => _openSchedule(context),
                                ),
                            ],
                          ),
                          DraftProblemHint(problem: state.draft.problem),
                          CharacterCounter(remaining: state.draft.remaining),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The L-9 note under the "Will send on" line, at most two tap targets high:
/// at very large text on a small phone it scrolls inside that box, so it can
/// never push the text field and the bottom bar off the screen.
class _ScheduleImagesNoteBox extends StatelessWidget {
  const _ScheduleImagesNoteBox();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxHeight: AppSpacing.minTapTarget * 2,
        ),
        child: const SingleChildScrollView(
          child: ScheduleImagesNote(compact: true),
        ),
      ),
    );
  }
}

/// The "Add photos" action in the composer's bottom bar. Disabled while the
/// post is sending or when four photos are attached.
class _AddPhotoButton extends StatelessWidget {
  const _AddPhotoButton();

  @override
  Widget build(BuildContext context) {
    final submitting = context.select(
      (ComposerCubit c) => c.state.isSubmitting,
    );
    // Also off while photos are being prepared/uploaded: a second pick
    // would race the first one's processing queue.
    return BlocSelector<AttachmentsCubit, AttachmentsState, (bool, bool)>(
      selector: (state) => (state.isFull, state.isBusy),
      builder: (context, flags) {
        final (full, busy) = flags;
        return IconButton(
          tooltip: full ? 'Four photos is the limit' : 'Add photos',
          icon: const Icon(Icons.image_outlined),
          onPressed: submitting || full || busy
              ? null
              : () => context.read<AttachmentsCubit>().pick(),
        );
      },
    );
  }
}

/// "Everyone can reply" under the text (ADR-0021 D2): the current audience in
/// the accent colour with its icon, opening the "Who can reply?" sheet. A
/// 48dp-high target; the label follows the choice.
class _ReplyAudienceLink extends StatelessWidget {
  const _ReplyAudienceLink({
    required this.audience,
    required this.enabled,
    required this.onChanged,
  });

  final ReplyAudience audience;
  final bool enabled;
  final ValueChanged<ReplyAudience> onChanged;

  Future<void> _open(BuildContext context) async {
    final picked = await showReplyAudienceSheet(context, selected: audience);
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = enabled
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: audience.linkLabel,
        hint: 'Choose who can reply',
        excludeSemantics: true,
        onTap: enabled ? () => _open(context) : null,
        child: InkWell(
          onTap: enabled ? () => _open(context) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSpacing.xxl),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    replyAudienceIcon(audience),
                    size: AppIconSize.sm,
                    color: color,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: Text(
                      audience.linkLabel,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The quoted post under the text field: the frozen snapshot the router
/// passed, or a plain line after a page reload (the server still embeds the
/// original). Capped in height so a long quote never squeezes the field.
class _QuotePreview extends StatelessWidget {
  const _QuotePreview({required this.preview});

  final pb.EmbeddedPost? preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quoted = preview;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.3,
        ),
        child: quoted == null
            ? Text(
                'Quoting a post',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : SingleChildScrollView(
                child: EmbeddedPostCard(embedded: quoted, maxTextLines: 4),
              ),
      ),
    );
  }
}
