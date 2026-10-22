import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_avatar.dart';
import '../../../../shared/widgets/app_pill_button.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';

/// The entry row under the Home app bar: the viewer's avatar, a "Write a
/// post" prompt and a Post button. It only navigates: every tap target opens
/// the existing composer (`/compose`); nothing is typed here.
///
/// Shown by [HomeScreen] under the same rule as the shell's "New post"
/// button (`canComposeAt`). Rebuilds only when the viewer's avatar changes.
class HomeComposerEntry extends StatelessWidget {
  const HomeComposerEntry({super.key});

  static const promptLabel = 'Write a post';
  static const postLabel = 'Post';

  static void _openComposer(BuildContext context) =>
      context.push(AppRouter.composePath);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatarUrl = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.avatarThumbUrl ?? '',
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              // One button for the avatar and the prompt, announced once.
              child: Semantics(
                button: true,
                enabled: true,
                label: promptLabel,
                onTap: () => _openComposer(context),
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  onTap: () => _openComposer(context),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: AppSpacing.minTapTarget,
                    ),
                    child: Row(
                      children: [
                        AppAvatar(url: avatarUrl),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Text(
                            promptLabel,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            AppPillButton(
              label: postLabel,
              compact: true,
              onPressed: () => _openComposer(context),
            ),
          ],
        ),
      ),
    );
  }
}
