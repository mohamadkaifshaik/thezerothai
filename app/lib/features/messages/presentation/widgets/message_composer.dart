import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_notice_banner.dart';
import '../../../../shared/widgets/app_surface.dart';
import '../../../../shared/widgets/character_counter.dart';
import '../../../posts/domain/post_text_rules.dart' show PostDraftProblem;
import '../../../posts/presentation/composer_screen.dart'
    show kComposerInputCap;
import '../../../posts/presentation/widgets/draft_problem_hint.dart';
import '../../domain/messaging_feature_gate.dart';
import '../bloc/message_composer_cubit.dart';
import '../messaging_error_messages.dart';
import '../thread_screen.dart' show ThreadReadOnlyLine, kMessagingReadOnlyText;
import 'messaging_access_builder.dart';

/// The counter shows from this many code points left (and for any draft with
/// a problem, so 281 reads -1 in red).
const kMessageCounterThreshold = 20;

/// Whether Enter sends (and Shift+Enter adds a line): on the web and on
/// desktop, where there is a hardware keyboard. On a phone Enter adds a line
/// and the Send button sends.
bool get messageEnterSends =>
    kIsWeb ||
    switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };

/// The composer under a conversation (W7-16, ADR-0027 D3): a multi-line field,
/// [CharacterCounter] near the limit, [DraftProblemHint] and a Send icon
/// button, over a [MessageComposerCubit] (provided by `ThreadScreen`).
///
/// - Hidden when `messaging` is off for the caller (the server stays
///   authoritative; a send is refused there too).
/// - Enter sends and Shift+Enter adds a line on the web and desktop
///   ([messageEnterSends]); an Enter that confirms an IME composition is left
///   alone. On a phone Enter adds a line.
/// - Degraded (read-only) mode: a banner and Send is off. Any other failed
///   send shows its friendly text above the field until the next edit; the
///   failed bubble itself lives in the thread list.
/// - Typing and sending call `ThreadCubit.noteInput` through the cubit's
///   `onActivity`.
class MessageComposer extends StatefulWidget {
  const MessageComposer({super.key});

  /// Key of the text field.
  static const fieldKey = ValueKey('message-field');

  /// Key of the Send button.
  static const sendKey = ValueKey('message-send');

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'message composer');

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final cubit = context.read<MessageComposerCubit>();
    if (!cubit.state.canSend) return;
    final sending = cubit.send();
    _controller.clear();
    unawaited(sending);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!messageEnterSends) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    // Shift+Enter is a new line; so is Enter with any other modifier.
    if (keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    // Enter that confirms an IME composition belongs to the IME.
    final composing = _controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _submit();
    // Swallow the repeat and the key-up too, so no line is added.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    // W7-26: no field without `messaging` for this caller; read-only Messages
    // says so in one line, hidden Messages shows nothing.
    return MessagingAccessBuilder(
      builder: (context, access) => switch (access) {
        MessagingAccess.full => _composer(context),
        MessagingAccess.readOnly => const ThreadReadOnlyLine(
          text: kMessagingReadOnlyText,
        ),
        MessagingAccess.hidden => const SizedBox.shrink(),
      },
    );
  }

  Widget _composer(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cubit = context.read<MessageComposerCubit>();
    return BlocBuilder<MessageComposerCubit, MessageComposerState>(
      builder: (context, state) {
        final draft = state.draft;
        final showCounter =
            draft.remaining <= kMessageCounterThreshold ||
            draft.problem == PostDraftProblem.forbiddenCharacter ||
            draft.problem == PostDraftProblem.tooManyLines;
        final error = state.error;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.degraded)
                AppNoticeBanner(
                  message: messagingErrorMessage(
                    const DegradedModeException(''),
                  ),
                )
              else if (error != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      AppSpacing.sm,
                      AppSpacing.md,
                      0,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: Text(
                        messagingErrorMessage(error),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.error,
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: AppSurface(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                        ),
                        child: Focus(
                          onKeyEvent: _onKey,
                          skipTraversal: true,
                          canRequestFocus: false,
                          child: TextField(
                            key: MessageComposer.fieldKey,
                            controller: _controller,
                            focusNode: _focus,
                            minLines: 1,
                            maxLines: 5,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            textCapitalization: TextCapitalization.sentences,
                            inputFormatters: [
                              LengthLimitingTextInputFormatter(
                                kComposerInputCap,
                              ),
                            ],
                            style: theme.textTheme.bodyLarge,
                            decoration: InputDecoration(
                              hintText: 'Message',
                              hintStyle: theme.textTheme.bodyLarge?.copyWith(
                                color: colors.onSurfaceVariant,
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
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    IconButton.filled(
                      key: MessageComposer.sendKey,
                      tooltip: 'Send message',
                      onPressed: state.canSend ? _submit : null,
                      constraints: const BoxConstraints(
                        minWidth: AppSpacing.minTapTarget,
                        minHeight: AppSpacing.minTapTarget,
                      ),
                      icon: const Icon(Icons.send, size: AppIconSize.md),
                    ),
                  ],
                ),
              ),
              if (showCounter)
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: AppSpacing.md,
                    end: AppSpacing.md,
                    bottom: AppSpacing.sm,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DraftProblemHint(
                        problem: draft.problem,
                        noun: 'Messages',
                      ),
                      CharacterCounter(remaining: draft.remaining),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
