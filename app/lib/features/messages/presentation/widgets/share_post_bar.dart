import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../../domain/messaging_feature_flag.dart';
import '../bloc/share_post_cubit.dart';
import '../share_post_error_messages.dart';

/// Key of the optional caption field.
const kShareCaptionFieldKey = ValueKey('share-caption-field');

/// Key of the Send / Retry / Done button.
const kShareSendButtonKey = ValueKey('share-send-button');

/// The caption's length (the message limit).
const kShareCaptionMaxLength = 280;

/// What the picker's trailing slot shows for one person in share mode: an
/// empty or checked circle while choosing, then the result of the send (a
/// spinner, "Sent", or the short reason). The result is in words as well as
/// the glyph, never by colour alone.
class SharePostRowTrailing extends StatelessWidget {
  const SharePostRowTrailing({super.key, required this.recipient});

  /// Null: the person is not chosen.
  final ShareRecipient? recipient;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final row = recipient;
    if (row == null) {
      return Icon(
        Icons.radio_button_unchecked,
        size: AppIconSize.lg,
        color: colors.onSurfaceVariant,
      );
    }
    switch (row.status) {
      case ShareRowStatus.idle:
        return Icon(
          Icons.check_circle,
          size: AppIconSize.lg,
          color: context.appColors.accentText,
        );
      case ShareRowStatus.sending:
        return const SizedBox(
          width: AppIconSize.md,
          height: AppIconSize.md,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case ShareRowStatus.sent:
        return _Labelled(
          icon: Icons.check_circle,
          label: 'Sent',
          color: context.appColors.accentText,
        );
      case ShareRowStatus.failed:
        return _Labelled(
          icon: Icons.error_outline,
          label: sharePostRowReason(row.error!),
          color: colors.error,
        );
      case ShareRowStatus.skipped:
        return _Labelled(
          icon: Icons.remove_circle_outline,
          label: 'Not sent',
          color: colors.onSurfaceVariant,
        );
    }
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: AppIconSize.md, color: color),
        const SizedBox(width: AppSpacing.xs),
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// The foot of the share picker: the one line that says what went wrong, the
/// optional caption and the Send button. [dialog] is the tablet / desktop card
/// (16 dp gutter); false is the phone's 20 dp.
///
/// Send becomes "Retry" while some rows failed or were not sent, and "Done"
/// once every row is sent; [onDone] closes the picker.
class SharePostBar extends StatelessWidget {
  const SharePostBar({super.key, required this.dialog, required this.onDone});

  final bool dialog;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cubit = context.read<SharePostCubit>();
    final gutter = dialog
        ? AppPickerLayout.dialogGutter
        : AppPickerLayout.phoneGutter;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            AppSpacing.sm,
            gutter,
            AppSpacing.sm,
          ),
          child: BlocBuilder<SharePostCubit, SharePostState>(
            builder: (context, state) {
              final error = state.lastError;
              final label = state.allSent
                  ? 'Done'
                  : state.started
                  ? 'Retry'
                  : state.recipients.isEmpty
                  ? 'Send'
                  : 'Send (${state.recipients.length})';
              final note = error != null
                  ? sharePostErrorMessage(error)
                  : state.limitHit
                  ? 'You can send to up to $kSharePostMaxRecipients people '
                        'at once.'
                  : null;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (note != null)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: Text(
                          note,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: error != null
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          key: kShareCaptionFieldKey,
                          enabled: !state.started,
                          minLines: 1,
                          maxLines: 3,
                          textInputAction: TextInputAction.done,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(
                              kShareCaptionMaxLength,
                            ),
                          ],
                          onChanged: cubit.setCaption,
                          decoration: InputDecoration(
                            hintText: 'Add a caption (optional)',
                            isDense: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.field,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      AppPillButton(
                        key: kShareSendButtonKey,
                        label: label,
                        busy: state.sending,
                        busySemanticsLabel: 'Sending',
                        onPressed: state.allSent
                            ? onDone
                            : state.canSend
                            ? cubit.send
                            : null,
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
