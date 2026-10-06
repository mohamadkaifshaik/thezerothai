import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../auth/presentation/widgets/verify_email_view.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/posts_repository.dart';
import '../domain/post_text_rules.dart';
import 'bloc/composer_cubit.dart';
import 'bloc/pending_posts_cubit.dart';
import 'post_error_messages.dart';

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
    return BlocProvider(
      create: (context) => ComposerCubit(
        postsRepository: context.read<PostsRepository>(),
        pending: context.read<PendingPostsCubit>(),
        author: common.AuthorSnapshot(
          userId: profile?.userId ?? '',
          handle: profile?.handle ?? '',
          displayName: profile?.displayName ?? '',
          avatarUrl: profile?.avatarThumbUrl ?? '',
          verified: profile?.verified ?? false,
        ),
      ),
      child: const _ComposerView(),
    );
  }
}

class _ComposerView extends StatefulWidget {
  const _ComposerView();

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
        ..showSnackBar(SnackBar(content: Text(createPostErrorMessage(error))));
      context.read<ComposerCubit>().errorShown();
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ComposerCubit, ComposerState>(
      listener: _onState,
      builder: (context, state) {
        if (state.error is EmailNotVerifiedException) {
          return VerifyEmailView(
            banner: createPostErrorMessage(state.error!),
            onBack: context.read<ComposerCubit>().errorShown,
          );
        }
        final cubit = context.read<ComposerCubit>();
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () => context.canPop()
                  ? context.pop()
                  : context.go(AppRouter.homePath),
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
                          width: 20,
                          height: 20,
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
                      decoration: const InputDecoration(
                        hintText: "What's happening?",
                        border: InputBorder.none,
                      ),
                      onChanged: cubit.textChanged,
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _LinesHint(problem: state.draft.problem),
                      CharacterCounter(draft: state.draft),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Explains why Post is disabled when it is not just "nothing typed yet".
class _LinesHint extends StatelessWidget {
  const _LinesHint({required this.problem});

  final PostDraftProblem? problem;

  @override
  Widget build(BuildContext context) {
    final message = switch (problem) {
      PostDraftProblem.tooManyLines => 'Posts can have at most 10 lines.',
      PostDraftProblem.forbiddenCharacter =>
        'Remove the unsupported characters.',
      _ => null,
    };
    if (message == null) return const SizedBox.shrink();
    return Expanded(
      child: Text(
        message,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}

/// Remaining code points: `280` minus the count after NFC; negative past the
/// limit (281 shows `-1`).
class CharacterCounter extends StatelessWidget {
  const CharacterCounter({super.key, required this.draft});

  final PostDraft draft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = draft.remaining;
    final over = remaining < 0;
    final label = over
        ? 'Characters over the limit: ${-remaining}'
        : 'Characters remaining: $remaining';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Text(
        '$remaining',
        style: theme.textTheme.labelLarge?.copyWith(
          color: over ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
