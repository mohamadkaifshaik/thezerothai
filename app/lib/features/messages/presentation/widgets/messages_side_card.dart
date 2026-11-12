import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../../shared/widgets/primitives/app_surface.dart';
import '../../domain/messaging_feature_gate.dart';
import '../messages_list_detail.dart' show kNewMessageLabel;
import 'messaging_access_builder.dart';

/// The desktop side column's card beside the inbox (desktop Conversations):
/// "Select a conversation." and, for a caller who may send, New message. The
/// desktop inbox is one column with no conversation open beside it, so the
/// card says what the column is for; the tablet's list-detail draws its own
/// placeholder in the detail pane.
class MessagesSideCard extends StatelessWidget {
  const MessagesSideCard({super.key});

  @override
  Widget build(BuildContext context) => MessagingAccessBuilder(
    builder: (context, access) {
      if (access == MessagingAccess.hidden) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final accent = AppTextStyles.displayAccent(theme, size: 36);
      return AppSurface(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: const EdgeInsets.symmetric(
          horizontal: AppMessagesLayout.sideCardPaddingH,
          vertical: AppMessagesLayout.sideCardPaddingV,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MESSAGES',
              style: AppTextStyles.eyebrow(theme)
                  .copyWith(color: context.appColors.accentText),
            ),
            const SizedBox(height: AppSpacing.smd),
            Semantics(
              header: true,
              child: Text.rich(
                TextSpan(
                  style: accent.copyWith(color: theme.colorScheme.onSurface),
                  children: [
                    const TextSpan(text: 'Select a '),
                    TextSpan(text: 'conversation', style: accent),
                    const TextSpan(text: '.'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.smd),
            Text(
              'Choose one from your inbox, or start a new one.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (access == MessagingAccess.full) ...[
              const SizedBox(height: AppSpacing.md),
              AppPillButton(
                label: kNewMessageLabel,
                onPressed: () =>
                    unawaited(context.push<void>(AppRouter.messageNewPath)),
              ),
            ],
          ],
        ),
      );
    },
  );
}
