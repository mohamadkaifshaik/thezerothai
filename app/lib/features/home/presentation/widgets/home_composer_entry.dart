import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/post/post_card.dart';
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';

/// The entry row under the Home tab bar: the viewer's avatar and a "What's
/// your plan?" prompt drawn as an outlined pill field (the Feed designs). It
/// only navigates: the row opens the existing composer (`/compose`); nothing
/// is typed here. The tablet and desktop layouts add a Post button at the
/// end that opens the same composer. In line with the post cards below it:
/// their gutter, a 42 dp avatar and the 12 dp gap.
///
/// The pill is ink on the page's Material (an [Ink]), so the row's ripple
/// and keyboard focus highlight paint over it; keyboard focus also draws the
/// field's 2 dp teal focus border (`.search.on`).
///
/// Shown by [HomeScreen] under the same rule as the shell's "New post"
/// button (`canComposeAt`). Rebuilds only when the viewer's avatar or name
/// changes.
class HomeComposerEntry extends StatefulWidget {
  const HomeComposerEntry({super.key});

  static const promptLabel = "What's your plan?";

  @override
  State<HomeComposerEntry> createState() => _HomeComposerEntryState();
}

class _HomeComposerEntryState extends State<HomeComposerEntry> {
  bool _focused = false;

  static void _openComposer(BuildContext context) =>
      context.push(AppRouter.composePath);

  @override
  Widget build(BuildContext context) {
    const promptLabel = HomeComposerEntry.promptLabel;
    final theme = Theme.of(context);
    final avatarUrl = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.avatarThumbUrl ?? '',
    );
    final name = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.displayName ?? '',
    );
    final gutter = postCardGutterOf(context);
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
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
                  onFocusChange: (focused) =>
                      setState(() => _focused = focused),
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
                              name: name,
                            ),
                          ),
                        ),
                        const SizedBox(width: kPostAvatarGap),
                        Expanded(
                          // The look of a field (dz.css `.search`): white,
                          // the 3:1 outline, a pill; still only a button.
                          // Ink, not a box: the InkWell's highlight paints
                          // over it.
                          child: Ink(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainer,
                              borderRadius: BorderRadius.circular(
                                AppRadius.pill,
                              ),
                              border: _focused
                                  ? Border.all(
                                      color: theme.colorScheme.primary,
                                      width: 2,
                                    )
                                  : Border.all(
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
            if (wide) ...[
              const SizedBox(width: AppSpacing.smd),
              AppPillButton(
                label: 'Post',
                compact: true,
                onPressed: () => _openComposer(context),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
