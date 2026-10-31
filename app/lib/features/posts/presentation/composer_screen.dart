import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

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
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/widgets/verify_email_view.dart';
import '../../engagement/domain/engagement_feature_flag.dart';
import '../../media/data/gif_source.dart';
import '../../media/data/image_picker_service.dart';
import '../../media/data/media_repository.dart';
import '../../media/data/media_uploader.dart';
import '../../media/domain/image_processor.dart';
import '../../media/domain/media_feature_flag.dart';
import '../../media/presentation/bloc/attachments_cubit.dart';
import '../../media/presentation/media_error_messages.dart';
import '../../media/presentation/widgets/attachment_grid.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/drafts_repository.dart';
import '../data/posts_repository.dart';
import '../domain/composer_attachment_rules.dart';
import '../domain/composer_draft.dart';
import '../domain/posts_feature_flag.dart';
import '../domain/reply_audience.dart';
import '../domain/viewer_author_snapshot.dart';
import 'bloc/composer_cubit.dart';
import 'bloc/pending_posts_cubit.dart';
import 'post_error_messages.dart';
import 'quote_gate.dart';
import 'widgets/composer_extras_buttons.dart';
import 'widgets/composer_poll_builder.dart';
import 'widgets/draft_dialogs.dart';
import 'widgets/draft_problem_hint.dart';
import 'widgets/reply_audience_sheet.dart';
import 'widgets/schedule_controls.dart';
import 'widgets/schedule_dialog.dart';
import 'widgets/send_conflict_dialog.dart';

/// Shown when a picked draft could not be opened.
const kDraftGoneMessage = 'That draft is no longer available.';
const kDraftNeedsNoMediaMessage =
    'That draft has a poll. Remove your photos or GIF to open it.';

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
    this.draftId = '',
    @visibleForTesting this.scheduleClock,
  });

  final String quoteOfPostId;

  /// The saved draft to continue (`/compose?draft=<id>`, W6-15), or empty for
  /// a new post. Used only while `drafts` is on. A draft that is gone (or
  /// belongs to another account) opens a new post under a fresh id.
  final String draftId;
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
    // Unsent posts (W6-15): `drafts` on, a signed-in account, and a new root
    // post (a quote never has a draft). Nothing draft-related is read from
    // the tree otherwise.
    final uid =
        quoteOfPostId.isEmpty && featureEnabledSnapshot(context, kFeatureDrafts)
        ? (context.read<AuthBloc>().state.user?.uid ?? '')
        : '';
    if (uid.isNotEmpty && draftId.isNotEmpty) {
      return _DraftLoader(
        uid: uid,
        draftId: draftId,
        builder: (context, draft) =>
            _composer(context, uid: uid, initial: draft),
      );
    }
    return _composer(context, uid: uid);
  }

  Widget _composer(
    BuildContext context, {
    required String uid,
    ComposerDraft? initial,
  }) {
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
              // Only a composer that offers GIFs needs the GIF pieces.
              gifSource: featureEnabledSnapshot(context, kFeatureGif)
                  ? context.read<GifSource>()
                  : null,
              gifPreparer: featureEnabledSnapshot(context, kFeatureGif)
                  ? context.read<GifPreparer>()
                  : null,
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
            // The toolbar rules (W6-11) read these raw flags; the cubit adds
            // the gate's memory of a FEATURE_DISABLED (`ComposerCubit.rules`).
            pollsFlag: featureEnabledSnapshot(context, kFeaturePolls),
            engagementOn: featureEnabledSnapshot(context, kFeatureEngagement),
            gifFlag: featureEnabledSnapshot(context, kFeatureGif),
            mediaOn: mediaEnabled,
            onUnexpectedError: context.read<UnexpectedErrorReporter>(),
            drafts: uid.isEmpty ? null : context.read<DraftsRepository>(),
            uid: uid,
            initialDraft: initial,
          ),
        ),
      ],
      child: mediaEnabled
          ? BlocListener<AttachmentsCubit, AttachmentsState>(
              listenWhen: (prev, curr) =>
                  (curr.pickFailed && !prev.pickFailed) ||
                  (curr.refusal != null && prev.refusal == null),
              listener: (context, state) {
                final cubit = context.read<AttachmentsCubit>();
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(state.refusal ?? kPickFailedMessage),
                    ),
                  );
                if (state.refusal != null) {
                  cubit.refusalShown();
                } else {
                  cubit.pickFailureShown();
                }
              },
              child: _ComposerView(
                mediaEnabled: mediaEnabled,
                quotePreview: quotePreview,
                avatarUrl: viewerAuthorSnapshot(profile).avatarUrl,
                scheduleClock: scheduleClock,
                initialText: initial?.text ?? '',
              ),
            )
          : _ComposerView(
              mediaEnabled: mediaEnabled,
              quotePreview: quotePreview,
              avatarUrl: viewerAuthorSnapshot(profile).avatarUrl,
              scheduleClock: scheduleClock,
              initialText: initial?.text ?? '',
            ),
    );
  }
}

/// Reads the saved draft once, then builds the composer on it. The read is
/// local (drift): a blank frame at most. A missing draft builds with null.
class _DraftLoader extends StatefulWidget {
  const _DraftLoader({
    required this.uid,
    required this.draftId,
    required this.builder,
  });

  final String uid;
  final String draftId;
  final Widget Function(BuildContext context, ComposerDraft? draft) builder;

  @override
  State<_DraftLoader> createState() => _DraftLoaderState();
}

class _DraftLoaderState extends State<_DraftLoader> {
  late final Future<ComposerDraft?> _draft;

  @override
  void initState() {
    super.initState();
    _draft = context
        .read<DraftsRepository>()
        .read(widget.uid, widget.draftId)
        // A storage failure opens a new post rather than a dead screen.
        .then<ComposerDraft?>((d) => d, onError: (_) => null);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ComposerDraft?>(
      future: _draft,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: SizedBox.expand());
        }
        return widget.builder(context, snapshot.data);
      },
    );
  }
}

class _ComposerView extends StatefulWidget {
  const _ComposerView({
    required this.mediaEnabled,
    required this.avatarUrl,
    this.quotePreview,
    this.scheduleClock,
    this.initialText = '',
  });

  /// The text a continued draft starts with.
  final String initialText;

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
  late final _controller = TextEditingController(text: widget.initialText);
  final _questionFocus = FocusNode();

  @override
  void dispose() {
    _questionFocus.dispose();
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
                  onPressed: () => unawaited(_showScheduledList(router, cubit)),
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

  /// ADR-0029 L-1: the server posted the question without its poll. Tell the
  /// user once and offer Delete (the post is a bare question) or Keep. The
  /// messenger and the repository are taken before the screen pops, so the
  /// snackbar outlives it.
  void _warnPollNotAdded(BuildContext context, pb.PostView created) {
    final messenger = ScaffoldMessenger.of(context);
    final posts = context.read<PostsRepository>();
    final postId = created.post.postId;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 12),
          content: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(kPollNotAddedMessage),
              TextButton(
                onPressed: messenger.hideCurrentSnackBar,
                child: const Text('Keep'),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Delete',
            onPressed: () =>
                unawaited(_deleteBarePost(messenger, posts, postId)),
          ),
        ),
      );
  }

  Future<void> _deleteBarePost(
    ScaffoldMessengerState messenger,
    PostsRepository posts,
    String postId,
  ) async {
    try {
      await posts.deletePost(postId: postId, idempotencyKey: const Uuid().v4());
    } on Object {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text("Couldn't delete the post. Try again.")),
        );
    }
  }

  /// Pushes the Scheduled list over the composer. With unsent posts on it is
  /// the Drafts screen's Scheduled tab in pick mode, so a draft chosen from
  /// the Unsent tab comes back here and loads in place (never a second
  /// composer); otherwise the old Scheduled screen. Then re-checks that
  /// scheduling is still on.
  Future<void> _showScheduledList(GoRouter router, ComposerCubit cubit) async {
    if (cubit.draftsActive) {
      // Pick mode only while this composer is still there to receive it
      // (the toast's "View" can outlive the screen).
      final picked = await router.push<String>(
        AppRouter.scheduledTabPath,
        extra: mounted && !cubit.isClosed,
      );
      await _loadPicked(cubit, picked);
    } else {
      await router.push(AppRouter.scheduledPostsPath);
    }
    _scheduleAvailabilityMayHaveChanged(cubit);
  }

  /// The "Drafts" header button: keeps what was typed (so the list shows it),
  /// then opens the Drafts screen in pick mode. A chosen draft replaces the
  /// text, poll and audience here, under its own id.
  Future<void> _openDrafts(BuildContext context) async {
    final cubit = context.read<ComposerCubit>();
    if (cubit.state.isSubmitting) return;
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (cubit.hasUnsavedDraftChanges) {
      final result = await cubit.saveDraft();
      if (result == DraftSaveResult.savedDroppedOldest) {
        _droppedOldestNotice(messenger);
      }
    }
    if (!mounted || cubit.isClosed) return;
    final picked = await router.push<String>(AppRouter.draftsPath, extra: true);
    await _loadPicked(cubit, picked);
  }

  Future<void> _loadPicked(ComposerCubit cubit, String? draftId) async {
    if (draftId == null || !mounted || cubit.isClosed) return;
    final result = await cubit.loadSavedDraft(draftId);
    if (!mounted) return;
    switch (result) {
      case DraftLoadResult.loaded:
        _controller.text = cubit.state.draft.text;
      case DraftLoadResult.gone:
        _notice(kDraftGoneMessage);
      case DraftLoadResult.blockedByMedia:
        _notice(kDraftNeedsNoMediaMessage);
    }
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _droppedOldestNotice(ScaffoldMessengerState messenger) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'Saved. Your oldest unsent post was removed to make room (50 is '
            'the most).',
          ),
        ),
      );
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
        await _showScheduledList(GoRouter.of(context), cubit);
      case null:
        break;
    }
  }

  /// A draft send was stopped, or the server knew its key (W6-39): the user
  /// looks at what was sent, sends again on purpose, or keeps editing.
  Future<void> _askSendConflict(
    BuildContext context,
    SendConflict conflict,
  ) async {
    final cubit = context.read<ComposerCubit>();
    final handle = viewerAuthorSnapshot(
      context.read<OnboardingBloc>().state.profile,
    ).handle;
    final choice = await showSendConflictDialog(context, conflict);
    if (!context.mounted) return;
    switch (choice) {
      case SendConflictChoice.look:
        // The composer and its draft stay underneath; coming back is a tap.
        unawaited(
          context.push(
            conflict == SendConflict.pendingSchedule
                ? AppRouter.scheduledPostsPath
                : AppRouter.profilePath(handle),
          ),
        );
      case SendConflictChoice.sendAnyway:
        unawaited(cubit.sendAnyway());
      case null:
        break;
    }
  }

  void _onState(BuildContext context, ComposerState state) {
    final conflict = state.sendConflict;
    if (conflict != null) {
      context.read<ComposerCubit>().sendConflictShown();
      unawaited(_askSendConflict(context, conflict));
      return;
    }
    final scheduled = state.scheduledNotice;
    if (scheduled != null) {
      _onScheduled(context, scheduled);
      return;
    }
    if (state.status == ComposerStatus.posted) {
      if (state.pollNotAdded) _warnPollNotAdded(context, state.created!);
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
                  ? uploadErrorMessage(
                      error,
                      gif:
                          widget.mediaEnabled &&
                          context.read<AttachmentsCubit>().state.hasGif,
                    )
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

  /// The avatar and the post text. Fills the available height without a
  /// poll; with one it is the poll's question (two lines to start, growing),
  /// inside the scroll view that also holds the builder.
  Widget _questionArea(
    BuildContext context,
    ComposerState state,
    bool isQuote,
  ) {
    final cubit = context.read<ComposerCubit>();
    final hasPoll = state.hasPoll;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: AppAvatar(url: widget.avatarUrl)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _questionFocus,
              autofocus: true,
              enabled: !state.isSubmitting,
              expands: !hasPoll,
              maxLines: null,
              minLines: hasPoll ? 2 : null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: [
                LengthLimitingTextInputFormatter(kComposerInputCap),
              ],
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(fontSize: 18),
              decoration: InputDecoration(
                hintText: hasPoll
                    ? kPollQuestionHint
                    : isQuote
                    ? 'Add a comment'
                    : "What's happening?",
                hintStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontSize: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    );
  }

  /// Leaves the screen. What it asks depends on [ComposerCubit.leaveAction]:
  /// with unsent posts on and something typed, "Save post?" (Save keeps the
  /// row, Discard deletes it); with only media attached (or unsent posts off)
  /// the old "Discard this post?" because media is never kept. Never while the
  /// post is being sent.
  Future<void> _requestClose(BuildContext context, ComposerState state) async {
    if (state.isSubmitting) return;
    final cubit = context.read<ComposerCubit>();
    final gif =
        widget.mediaEnabled && context.read<AttachmentsCubit>().state.hasGif;
    switch (cubit.leaveAction) {
      case LeaveAction.none:
        break;
      case LeaveAction.discardMedia:
        final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard this post?'),
            content: Text(
              gif
                  ? 'Your GIF will not be saved.'
                  : 'Your photos will not be saved.',
            ),
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
        await cubit.discardDraft();
      case LeaveAction.savePrompt:
        final choice = await showSavePostDialog(
          context,
          mediaNote: !state.hasAttachments
              ? null
              : gif
              ? kDraftsGifNote
              : kDraftsPhotosNote,
        );
        if (choice == null || !context.mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        if (choice == SavePostChoice.save) {
          final result = await cubit.saveDraft();
          if (result == DraftSaveResult.savedDroppedOldest) {
            _droppedOldestNotice(messenger);
          }
        } else {
          await cubit.discardDraft();
        }
    }
    if (!context.mounted) return;
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
          prev.sendConflict != curr.sendConflict ||
          !identical(prev.scheduledNotice, curr.scheduledNotice),
      listener: _onState,
      builder: (context, state) {
        final cubit = context.read<ComposerCubit>();
        final isQuote = cubit.quoteOfPostId.isNotEmpty;
        // A time is only shown (and "Schedule" only written) while the
        // composer can still schedule: never a line the button cannot honour.
        final scheduling = state.isScheduling && cubit.canSchedule;
        // A GIF is held by the AttachmentsCubit like photos; the composer
        // state only knows "something is attached", so split it here.
        final (_, attachBusy) = widget.mediaEnabled
            ? context.select<AttachmentsCubit, (bool, bool)>(
                (c) => (c.state.hasGif, c.state.isBusy),
              )
            : (false, false);
        // One rule decides which toolbar buttons are on (W6-11); the cubit
        // owns it so its own guards read the same answer.
        final rules = cubit.rules;
        final poll = state.poll;
        // Back (system gesture, browser) is blocked while the post is being
        // sent, and asks first when photos are attached. There is no cancel
        // for an upload in flight. Applies to the verify-email view too: it
        // replaces the composer, but the attachments are still held.
        final canLeaveFreely =
            state.status == ComposerStatus.posted ||
            (!state.isSubmitting && cubit.leaveAction == LeaveAction.none);
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
                      secondaryLabel: cubit.draftsActive ? 'Drafts' : null,
                      onSecondary: () => _openDrafts(context),
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
                      child: poll == null
                          ? _questionArea(context, state, isQuote)
                          // With a poll the question and the builder scroll
                          // together: four choices and the length do not fit
                          // above the keyboard on a phone.
                          : SingleChildScrollView(
                              child: Column(
                                children: [
                                  _questionArea(context, state, isQuote),
                                  Padding(
                                    padding:
                                        const EdgeInsetsDirectional.fromSTEB(
                                          AppSpacing.md,
                                          0,
                                          AppSpacing.md,
                                          AppSpacing.md,
                                        ),
                                    child: ComposerPollBuilder(
                                      poll: poll,
                                      durationClamped:
                                          state.pollDurationClamped,
                                      enabled: !state.isSubmitting,
                                      onChoiceChanged: cubit.pollChoiceChanged,
                                      onChoiceAdded: cubit.pollChoiceAdded,
                                      onChoiceRemoved: cubit.pollChoiceRemoved,
                                      onLengthChanged:
                                          cubit.pollDurationChanged,
                                      onRemove: cubit.pollRemoved,
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
                              if (widget.mediaEnabled)
                                _AddPhotoButton(block: rules.photo),
                              if (rules.showGif)
                                ComposerGifButton(
                                  block: rules.gif,
                                  enabled: !state.isSubmitting && !attachBusy,
                                  onPressed: () => context
                                      .read<AttachmentsCubit>()
                                      .pickGif(),
                                ),
                              if (rules.showPoll)
                                ComposerPollButton(
                                  block: rules.poll,
                                  enabled: !state.isSubmitting,
                                  selected: state.hasPoll,
                                  // Open: it only takes you back to the
                                  // question (Remove poll is in the builder).
                                  onPressed: state.hasPoll
                                      ? _questionFocus.requestFocus
                                      : cubit.pollAdded,
                                ),
                              if (cubit.canSchedule)
                                ScheduleButton(
                                  scheduled: scheduling,
                                  enabled:
                                      !state.isSubmitting &&
                                      rules.schedule == ComposerBlock.none,
                                  tooltip: rules.schedule.scheduleTooltip,
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
  const _AddPhotoButton({required this.block});

  /// Why photos are off for a rule (a poll or a GIF), or none.
  final ComposerBlock block;

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
          tooltip: block != ComposerBlock.none
              ? block.photoTooltip
              : full
              ? 'Four photos is the limit'
              : 'Add photos',
          icon: const Icon(Icons.image_outlined),
          onPressed: submitting || full || busy || block != ComposerBlock.none
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
