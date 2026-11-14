import '../../../core/widgets/shell_side_column.dart';
import 'widgets/thread_side_boxes.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_avatar.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../data/messaging_repository.dart';
import '../domain/messaging_feature_flag.dart';
import 'bloc/message_composer_cubit.dart';
import 'thread_screen.dart'
    show ThreadPeerHeader, ThreadReadOnlyLine, kThreadReadOnlyText;
import 'widgets/message_composer.dart';
import 'widgets/outgoing_bubble.dart';

/// `/messages/new/draft`: a thread with someone the
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
        outbox: context.read<MessagingRepository>().outbox,
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

class _DraftView extends StatefulWidget {
  const _DraftView({required this.peer});

  final common.AuthorSnapshot peer;

  @override
  State<_DraftView> createState() => _DraftViewState();
}

class _DraftViewState extends State<_DraftView> {
  common.AuthorSnapshot get peer => widget.peer;

  /// The desktop Chat mock's peer card (nothing else exists yet: no
  /// conversation to mute, delete or share plans in), inside the shell from
  /// 1200 dp.
  final _sideColumn = ShellSideColumnLease();

  @override
  void dispose() {
    _sideColumn.dispose();
    super.dispose();
  }

  void _back(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.messagesPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    _sideColumn.set(
      context,
      active: shellSideColumnBeside(context),
      builder: (context) => ThreadSideBoxes(
        peer: peer,
        onViewProfile: peer.handle.isEmpty
            ? null
            : () => context.push(AppRouter.profilePath(peer.handle)),
      ),
    );
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
                      ? _FirstMessageHero(peer: peer)
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

/// The empty draft (dzeroth-mobile DraftThread): "Say hello." over the line
/// that sends the caller to the composer. The phone draws the glowing orbit
/// above it; the tablet and desktop draw the person's avatar (their DraftThread
/// designs).
class _FirstMessageHero extends StatelessWidget {
  const _FirstMessageHero({required this.peer});

  final common.AuthorSnapshot peer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final name = peer.displayName.isEmpty ? peer.handle : peer.displayName;
    final accent = AppTextStyles.displayAccent(theme, size: phone ? 28 : 40);
    // Centred while it fits; scrolls on a short window or at a large text
    // scale instead of overflowing.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ExcludeSemantics(
                  child: phone
                      ? const _Orbit()
                      : AppAvatar.sized(
                          url: peer.avatarUrl,
                          size: AppAvatarSize.lg,
                          name: name,
                        ),
                ),
                const SizedBox(height: AppSpacing.md),
                Semantics(
                  header: true,
                  child: Text.rich(
                    textAlign: TextAlign.center,
                    TextSpan(
                      style: accent.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      children: [
                        const TextSpan(text: 'Say '),
                        TextSpan(text: 'hello', style: accent),
                        const TextSpan(text: '.'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Write your first message below.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Two teal rings around a glowing dot.
class _Orbit extends StatelessWidget {
  const _Orbit();

  @override
  Widget build(BuildContext context) {
    Widget ring(double inset, double alpha, double width) => Positioned.fill(
      left: inset,
      top: inset,
      right: inset,
      bottom: inset,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: AppPalette.tealElectric.withValues(alpha: alpha),
            width: width,
          ),
        ),
      ),
    );
    return SizedBox.square(
      dimension: AppMessagesLayout.heroOrbit,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ring(0, AppMessagesLayout.heroRingOuterAlpha, 1),
          ring(
            AppMessagesLayout.heroOrbitInner,
            AppMessagesLayout.heroRingInnerAlpha,
            AppMessagesLayout.heroRingInnerWidth,
          ),
          Container(
            width: AppMessagesLayout.heroDot,
            height: AppMessagesLayout.heroDot,
            decoration: BoxDecoration(
              color: AppPalette.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppPalette.tealElectric.withValues(
                    alpha: AppMessagesLayout.heroDotHaloAlpha,
                  ),
                  spreadRadius: AppMessagesLayout.heroDotHalo,
                ),
                BoxShadow(
                  color: AppPalette.tealElectric.withValues(
                    alpha: AppMessagesLayout.heroDotGlowAlpha,
                  ),
                  blurRadius: AppMessagesLayout.heroDotGlowBlur,
                  spreadRadius: AppMessagesLayout.heroDotGlowSpread,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
