import 'dart:async';

import 'post_subscription_policy.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/close_routes_above.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/telemetry/usage_reporter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../shared/widgets/post/conversation_row.dart';
import '../../../shared/widgets/post/post_card.dart';
import '../../../shared/widgets/primitives/app_avatar.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/primitives/character_counter.dart';
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
import '../data/posts_repository.dart';
import '../domain/composer_attachment_rules.dart' show kFeatureGif;
import '../domain/post_text_rules.dart';
import '../domain/posts_feature_flag.dart';
import '../domain/reply_audience.dart';
import '../domain/reply_pickers.dart';
import '../domain/reply_start.dart';
import '../domain/viewer_author_snapshot.dart';
import 'bloc/composer_cubit.dart';
import 'widgets/composer_extras_buttons.dart' show ComposerGifButton;
import 'composer_route.dart';
import 'composer_screen.dart';
import 'post_error_messages.dart';
import 'widgets/draft_problem_hint.dart';
import 'widgets/loaded_post.dart';
import '../../../shared/widgets/primitives/submit_shortcut.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';

class ReplyComposerScreen extends StatelessWidget {
  const ReplyComposerScreen({
    super.key,
    required this.postId,
    this.start = ReplyStart.text,
  });
  final String postId;

  /// How the composer opens: the field focused, or a photo / GIF picker
  /// started (the photo viewer's reply bar). A picker needs `media` (and
  /// `gif`), else it opens as [ReplyStart.text].
  final ReplyStart start;

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
    builder: (context, view) {
      // No composer tools (and no picker) while replying is not allowed.
      final blocked =
          !featureEnabledSnapshot(context, kPostsSubFeatureReplies) ||
          replyKnownNotAllowed(view);
      final posts = context.read<PostsRepository>();
      final pickers = ReplyPickers(
        mediaFlag: featureEnabledSnapshot(context, kFeatureMedia),
        gifFlag: featureEnabledSnapshot(context, kFeatureGif),
        mediaSub: posts.subFeatureEnabled(kPostsSubFeatureMedia),
        gifSub: posts.subFeatureEnabled(kFeatureGif),
      );
      final offered = !blocked && pickers.photo;
      return _withAttachments(
        context,
        offered: offered,
        gif: pickers.gif,
        build: (attachments) => BlocProvider(
          create: (context) => ComposerCubit.reply(
            postsRepository: posts,
            postTextLimit: () => subscriptionPostLimit(context),
            postPolicyChanges: subscriptionPostChanges(context),
            replyToPostId: postId,
            usage: UsageScope.of(context),
            // Bound to the session it was opened in: after a sign-out or an
            // account switch nothing typed here is sent, and the screen
            // leaves.
            sessionEpoch: context.read<AppDatabase?>()?.sessionEpoch,
            attachments: attachments,
            mediaOn: attachments != null,
            gifFlag: pickers.gif,
            onUnexpectedError: attachments == null
                ? null
                : context.read<UnexpectedErrorReporter>(),
          ),
          child: _ReplyEditor(
            parent: view,
            // A picker start that is not offered (or a blocked reply) is a
            // plain focused field.
            start: blocked ? ReplyStart.text : pickers.effective(start),
            tools: attachments != null,
          ),
        ),
      );
    },
  );

  /// A reply holds an [AttachmentsCubit] (photos, a GIF) only when the
  /// composer offers pickers: `media` on and replying allowed. Otherwise it is
  /// text only, as before.
  Widget _withAttachments(
    BuildContext context, {
    required bool offered,
    required bool gif,
    required Widget Function(AttachmentsCubit? attachments) build,
  }) {
    if (!offered) return build(null);
    return BlocProvider<AttachmentsCubit>(
      create: (context) => AttachmentsCubit(
        picker: context.read<ImagePickerService>(),
        processor: context.read<ImageProcessor>(),
        uploader: MediaUploader(
          repository: context.read<MediaRepository>(),
          onUnexpectedError: context.read<UnexpectedErrorReporter>(),
        ),
        gifSource: gif ? context.read<GifSource>() : null,
        gifPreparer: gif ? context.read<GifPreparer>() : null,
        gifEnabled: gif,
      ),
      child: BlocListener<AttachmentsCubit, AttachmentsState>(
        listenWhen: (prev, curr) =>
            (curr.pickFailed && !prev.pickFailed) ||
            (curr.refusal != null && prev.refusal == null),
        listener: (context, state) {
          final cubit = context.read<AttachmentsCubit>();
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(content: Text(state.refusal ?? kPickFailedMessage)),
            );
          if (state.refusal != null) {
            cubit.refusalShown();
          } else {
            cubit.pickFailureShown();
          }
        },
        child: Builder(
          builder: (context) => build(context.read<AttachmentsCubit>()),
        ),
      ),
    );
  }
}

class _ReplyEditor extends StatefulWidget {
  const _ReplyEditor({
    required this.parent,
    required this.start,
    required this.tools,
  });
  final pb.PostView parent;
  final ReplyStart start;

  /// The composer holds attachments: the Photo / GIF tools show in the footer
  /// and the discard prompt counts a picked photo.
  final bool tools;
  @override
  State<_ReplyEditor> createState() => _ReplyEditorState();
}

class _ReplyEditorState extends State<_ReplyEditor> {
  bool _leaving = false;
  bool _asking = false;

  /// Set by the first [_leaveOnce]: the screen pops once, whatever the cubit
  /// emits until the route is gone.
  bool _left = false;

  /// The field's text. Owned here (not by the field) so it survives the
  /// editor moving between full screen and a dialog on a resize.
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Opened by the photo viewer's Photo / GIF button: the picker starts as
    // soon as the screen is up (a cancelled picker leaves the plain reply; the
    // footer's buttons pick again). Not on the web, where a picker needs a
    // user gesture: there the field is just focused and the buttons pick.
    if (widget.tools &&
        !kIsWeb &&
        (widget.start == ReplyStart.photo || widget.start == ReplyStart.gif)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final attachments = context.read<AttachmentsCubit>();
        unawaited(
          widget.start == ReplyStart.gif
              ? attachments.pickGif()
              : attachments.pick(),
        );
      });
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

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
    if (state.draft.text.isNotEmpty || state.hasAttachments) {
      _asking = true;
      final discard = await showAppMaterialDialog<bool>(
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
    final viewer = viewerAuthorSnapshot(
      context.read<OnboardingBloc>().state.profile,
    );
    final gutter = postCardGutterOf(context);
    final blocked = !repliesOn || replyKnownNotAllowed(widget.parent);
    // ReplyComposer mocks: full screen (phones, a cold start) puts Reply in
    // the header; the tablet and desktop dialogs put it in the footer, by
    // the counter. Only the chrome around the body changes, so the field
    // keeps its place in the tree across a switch.
    final phone =
        ComposerPresentationScope.of(context) ==
        ComposerPresentation.fullScreen;
    final theme = Theme.of(context);
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
      builder: (context, state) {
        final cubit = context.read<ComposerCubit>();
        final reply = AppPillButton(
          label: 'Reply',
          compact: true,
          busy: state.isSubmitting,
          busySemanticsLabel: 'Sending reply',
          onPressed: !blocked && state.canSubmit ? cubit.submit : null,
        );
        return SubmitShortcut(
          // Ctrl/Cmd+Enter replies, exactly when the Reply button is on.
          canSubmit: () =>
              !blocked && cubit.state.canSubmit && !cubit.state.isSubmitting,
          onSubmit: cubit.submit,
          child: PopScope(
            canPop:
                _leaving ||
                (!state.isSubmitting &&
                    state.draft.text.isEmpty &&
                    !state.hasAttachments),
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _close();
            },
            child: Semantics(
              // Full screen nothing else names the route (the dialogs are
              // named by their frame).
              label: phone ? 'Reply' : null,
              namesRoute: phone,
              explicitChildNodes: true,
              child: Scaffold(
                // The dialogs sit inside the safe area already (the legacy one
                // keeps the window's padding): only full screen insets.
                body: SafeArea(
                  left: phone,
                  top: phone,
                  right: phone,
                  bottom: phone,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ReplyHeader(
                        key: const ValueKey('reply-header'),
                        onClose: state.isSubmitting ? null : _close,
                        reply: phone ? reply : null,
                      ),
                      Expanded(
                        key: const ValueKey('reply-body'),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // The rail runs past "Replying to", toward the
                              // viewer's avatar (the mocks).
                              ConversationRow(
                                connectAfter: true,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    PostCard(
                                      indentBody: true,
                                      view: widget.parent,
                                      // Own posts are told apart (no "Ask to
                                      // join" on the viewer's own plan, the
                                      // own-post menu).
                                      viewerUserId: viewer.userId,
                                      graphActionsEnabled: false,
                                    ),
                                    // In line with the post above: the body
                                    // column for the text, the avatar column
                                    // for the viewer, the card's gutters.
                                    Padding(
                                      padding: EdgeInsetsDirectional.only(
                                        start: gutter + kPostBodyStart,
                                        end: gutter,
                                        bottom: AppSpacing.md,
                                      ),
                                      child: _ReplyingTo(
                                        handle:
                                            widget.parent.post.author.handle,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: gutter,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: AppSpacing.minTapTarget,
                                      child: Center(
                                        child: AppAvatar.sized(
                                          url: viewer.avatarUrl,
                                          size: AppAvatarSize.post,
                                          name: viewer.displayName,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: kPostAvatarGap),
                                    Expanded(
                                      child: TextField(
                                        controller: _text,
                                        autofocus: !blocked,
                                        enabled:
                                            !blocked && !state.isSubmitting,
                                        minLines: 4,
                                        maxLines: null,
                                        maxLengthEnforcement:
                                            MaxLengthEnforcement.none,
                                        inputFormatters: [
                                          LengthLimitingTextInputFormatter(
                                            kComposerInputCap,
                                          ),
                                        ],
                                        style: _fieldStyle(theme, phone: phone),
                                        decoration: const InputDecoration(
                                          hintText: 'Post your reply',
                                          // The text starts on the body
                                          // column, as "Replying to" above.
                                          contentPadding: EdgeInsets.symmetric(
                                            vertical: AppSpacing.sm,
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
                              if (widget.tools)
                                const Padding(
                                  padding: EdgeInsets.only(top: AppSpacing.sm),
                                  child: AttachmentGrid(),
                                ),
                              if (blocked)
                                Padding(
                                  padding: const EdgeInsets.all(AppSpacing.md),
                                  child: Text(
                                    repliesOn
                                        ? replyNotAllowedHint(widget.parent)
                                        : 'Replies are not available.',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      _ReplyFooter(
                        key: const ValueKey('reply-footer'),
                        tools: widget.tools && !blocked
                            ? _ReplyTools(submitting: state.isSubmitting)
                            : null,
                        problem: DraftProblemHint(problem: state.draft.problem),
                        counter: CharacterCounter.ring(
                          remaining: state.draft.remaining,
                          ringOf: kMaxPostCodePoints,
                          ringSize: phone
                              ? AppSize.counterRingPhone
                              : AppSize.counterRing,
                        ),
                        reply: phone ? null : reply,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The reply text: 19 sp full screen, 20 sp in the dialogs (the mocks).
TextStyle? _fieldStyle(ThemeData theme, {required bool phone}) =>
    theme.textTheme.bodyLarge?.copyWith(
      fontSize: phone
          ? AppTypeTokens.replyFieldSizePhone
          : AppTypeTokens.replyFieldSizeDialog,
      height: phone
          ? AppTypeTokens.replyFieldLineHeightPhone
          : AppTypeTokens.replyFieldLineHeightDialog,
      fontWeight: AppTypeTokens.weightBody,
    );

/// Close at the start; full screen also the Reply pill at the end (the
/// dialogs carry it in [_ReplyFooter]).
class _ReplyHeader extends StatelessWidget {
  const _ReplyHeader({super.key, required this.onClose, this.reply});

  final VoidCallback? onClose;
  final Widget? reply;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(
      AppSpacing.sm,
      0,
      AppSpacing.md,
      0,
    ),
    // Grows with the pill at large text instead of clipping it.
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSize.headerRow),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
          const Spacer(),
          ?reply,
        ],
      ),
    ),
  );
}

/// "Replying to @handle": muted, the handle in the accent and bold.
class _ReplyingTo extends StatelessWidget {
  const _ReplyingTo({required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        text: 'Replying to ',
        children: [
          TextSpan(
            text: '@$handle',
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontWeight: AppTypeTokens.weightUi,
            ),
          ),
        ],
      ),
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: AppTypeTokens.weightBody,
      ),
    );
  }
}

/// Under a hairline: the draft problem, the character ring and, in the
/// dialogs, the Reply pill.
class _ReplyFooter extends StatelessWidget {
  const _ReplyFooter({
    super.key,
    required this.problem,
    required this.counter,
    this.reply,
    this.tools,
  });

  /// The Photo and GIF buttons, at the start.
  final Widget? tools;
  final Widget problem;
  final Widget counter;
  final Widget? reply;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: Padding(
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
        child: Row(
          children: [
            ?tools,
            Expanded(child: problem),
            counter,
            if (reply case final reply?) ...[
              const SizedBox(width: AppSpacing.smd),
              reply,
            ],
          ],
        ),
      ),
    ),
  );
}

/// The reply footer's Photo and GIF buttons, driven by the composer's rules
/// (the same ones as the post composer): they add, or add again after a
/// cancelled picker or a removed photo, and are off while sending.
class _ReplyTools extends StatelessWidget {
  const _ReplyTools({required this.submitting});

  final bool submitting;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ComposerCubit>();
    final attachBusy = context.select<AttachmentsCubit, bool>(
      (c) => c.state.isBusy,
    );
    // The rules read what is attached now.
    context.select<ComposerCubit, (bool, bool)>(
      (c) => (c.state.hasAttachments, c.state.attachmentsReady),
    );
    final rules = cubit.rules;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AddPhotoButton(block: rules.photo),
        if (rules.showGif)
          ComposerGifButton(
            block: rules.gif,
            enabled: !submitting && !attachBusy,
            onPressed: () => context.read<AttachmentsCubit>().pickGif(),
          ),
      ],
    );
  }
}
