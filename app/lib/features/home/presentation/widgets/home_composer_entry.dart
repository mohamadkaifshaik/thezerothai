import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/post/post_card.dart';
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';

/// The entry row under the Home tab bar: the viewer's avatar and a "Write a
/// post" prompt drawn as an outlined pill field (the Feed designs). It only
/// navigates: the row opens the existing composer (`/compose`); nothing is
/// typed here. There is no separate Post button: the rail's Post control
/// (wide) and this row (narrow) are the entries. In line with the post cards
/// below it: their gutter, a 42 dp avatar and the 12 dp gap.
///
/// Shown by [HomeScreen] under the same rule as the shell's "New post"
/// button (`canComposeAt`). Rebuilds only when the viewer's avatar changes.
class HomeComposerEntry extends StatelessWidget {
  const HomeComposerEntry({super.key});

  static const promptLabel = 'Write a post';

  static void _openComposer(BuildContext context) =>
      context.push(AppRouter.composePath);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatarUrl = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.avatarThumbUrl ?? '',
    );
    final gutter = postCardGutterOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: gutter,
          vertical: AppSpacing.smd,
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
                        SizedBox(
                          width: AppSpacing.minTapTarget,
                          child: Center(
                            child: AppAvatar.sized(
                              url: avatarUrl,
                              size: AppAvatarSize.post,
                            ),
                          ),
                        ),
                        const SizedBox(width: kPostAvatarGap),
                        Expanded(
                          // The look of a field (dz.css `.search`): white,
                          // the 3:1 outline, a pill; still only a button.
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainer,
                              borderRadius: BorderRadius.circular(
                                AppRadius.pill,
                              ),
                              border: Border.all(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: AppSpacing.minTapTarget,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.md,
                                  vertical: AppSpacing.sm,
                                ),
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(
                                    promptLabel,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
