import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../data/messaging_repository.dart';
import '../domain/messaging_feature_flag.dart';
import 'bloc/message_composer_cubit.dart';
import 'thread_screen.dart'
    show ThreadPeerHeader, ThreadReadOnlyLine, kThreadReadOnlyText;
import 'widgets/message_composer.dart';
import 'widgets/outgoing_bubble.dart';

/// `/messages/new/draft` (W7-17, ADR-0027 D5): a thread with someone the
/// caller has no cached conversation with. Nothing exists on the server yet,
/// so nothing is read and nothing polls: it shows the header, an empty
/// thread, the [MessageComposer] and the rows of the first message while it
/// is on its way.
///
/// - The first send goes out with `recipient_user_id`
///   ([MessageComposerCubit] in draft mode, one idempotency key per intent,
///   reused by a retry). The server returns the conversation; the screen then
///   replaces itself with `/messages/<id>` (which renders from the cache the
///   send filled).
/// - A refusal (CANNOT_MESSAGE, a limit, a degraded mode) keeps the screen:
///   the composer shows the friendly text; CANNOT_MESSAGE swaps the composer
///   for [kThreadReadOnlyText].
/// - Reached only by an in-app `push` carrying the [peer] (route `extra`); a
///   reload has no peer and the router sends the caller to the picker.
class DraftThreadScreen extends StatelessWidget {
  const DraftThreadScreen({
    super.key,
    required this.peer,
    this.onConversationCreated,
  });

  final common.AuthorSnapshot peer;

  /// Test seam: replaces the default switch to `/messages/<id>`.
  final void Function(BuildContext context, String conversationId)?
  onConversationCreated;

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeatureMessaging)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Messages')),
        body: const Center(
          child: AppEmptyView(
            icon: Icons.mail_outline,
            title: "Messages aren't available yet",
          ),
        ),
      );
    }
    return BlocProvider<MessageComposerCubit>(
      create: (context) => MessageComposerCubit(
        repository: context.read<MessagingRepository>(),
        recipientUserId: peer.userId,
        onConversationCreated: (id) {
          if (!context.mounted) return;
          final handler = onConversationCreated;
          if (handler != null) {
            handler(context, id);
          } else {
            unawaited(
              GoRouter.of(context)
                  .pushReplacement<void>(AppRouter.messagePath(id)),
            );
          }
        },
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      ),
      child: _DraftView(peer: peer),
    );
  }
}

class _DraftView extends StatelessWidget {
  const _DraftView({required this.peer});

  final common.AuthorSnapshot peer;

  void _back(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.messagesPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = peer.displayName.isEmpty
        ? '@${peer.handle}'
        : peer.displayName;
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(
                title: name,
                onBack: () => _back(context),
                titleContent: ThreadPeerHeader(peer: peer),
              ),
              Expanded(
                child: BlocBuilder<MessageComposerCubit, MessageComposerState>(
                  buildWhen: (a, b) => a.outgoing != b.outgoing,
                  builder: (context, state) => state.outgoing.isEmpty
                      ? Center(
                          child: AppEmptyView(
                            icon: Icons.mail_outline,
                            title: 'New message to $name',
                            subtitle: 'Write your first message below.',
                          ),
                        )
                      : ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.sm,
                          ),
                          itemCount: state.outgoing.length,
                          itemBuilder: (context, index) {
                            final row = state
                                .outgoing[state.outgoing.length - 1 - index];
                            return OutgoingBubble(
                              key: ValueKey('outgoing-${row.localId}'),
                              message: row,
                              onRetry: (id) => unawaited(
                                context.read<MessageComposerCubit>().retry(id),
                              ),
                            );
                          },
                        ),
                ),
              ),
              BlocSelector<MessageComposerCubit, MessageComposerState, bool>(
                selector: (state) => state.cannotMessage,
                builder: (context, cannotMessage) => cannotMessage
                    ? const ThreadReadOnlyLine()
                    : const MessageComposer(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
