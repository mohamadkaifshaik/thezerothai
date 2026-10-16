import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/character_counter.dart';
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
import '../domain/viewer_author_snapshot.dart';
import 'bloc/composer_cubit.dart';
import 'bloc/pending_posts_cubit.dart';
import 'post_error_messages.dart';
import 'widgets/draft_problem_hint.dart';

/// Upper bound on what the field accepts. It is far above the 280 limit so
/// the counter can go negative (the user sees how much to cut), while a huge
/// paste never makes every keystroke expensive.
const kComposerInputCap = 1000;

/// `/compose` (T16): write a text post. 280 code points counted after NFC
/// (ADR-0010 D9), at most 10 lines; Post is disabled otherwise. The server
/// stays authoritative.
class ComposerScreen extends StatelessWidget {
  const ComposerScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
            attachments: mediaEnabled ? context.read<AttachmentsCubit>() : null,
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
              child: _ComposerView(mediaEnabled: mediaEnabled),
            )
          : _ComposerView(mediaEnabled: mediaEnabled),
    );
  }
}

class _ComposerView extends StatefulWidget {
  const _ComposerView({required this.mediaEnabled});

  final bool mediaEnabled;

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

  void _onState(BuildContext context, ComposerState state) {
    if (state.status == ComposerStatus.posted) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRouter.homePath);
      }
      return;
    }
    final error = state.error;
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
          prev.status != curr.status || !identical(prev.error, curr.error),
      listener: _onState,
      builder: (context, state) {
        final cubit = context.read<ComposerCubit>();
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
            appBar: AppBar(
              leading: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: state.isSubmitting
                    ? null
                    : () => _requestClose(context, state),
              ),
              title: const Text('New post'),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, AppSpacing.minTapTarget),
                    ),
                    onPressed: state.canSubmit ? cubit.submit : null,
                    child: state.isSubmitting
                        ? const SizedBox(
                            width: AppIconSize.md,
                            height: AppIconSize.md,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Post'),
                  ),
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        enabled: !state.isSubmitting,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(kComposerInputCap),
                        ],
                        style: Theme.of(context).textTheme.bodyLarge
                            ?.copyWith(fontSize: 18),
                        decoration: InputDecoration(
                          hintText: "What's happening?",
                          hintStyle: Theme.of(context).textTheme.bodyLarge
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
                        ),
                        onChanged: cubit.textChanged,
                      ),
                    ),
                  ),
                  if (widget.mediaEnabled)
                    AttachmentGrid(enabled: !state.isSubmitting),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (widget.mediaEnabled)
                          const _AddPhotoButton()
                        else
                          const SizedBox(width: AppSpacing.sm),
                        DraftProblemHint(problem: state.draft.problem),
                        CharacterCounter(remaining: state.draft.remaining),
                        const SizedBox(width: AppSpacing.sm),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
