import '../../../core/widgets/shell_side_column.dart';
import 'widgets/thread_side_boxes.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
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
import '../../../core/vault/vault_status.dart';
import '../../../shared/widgets/post/post_card.dart' show launchPostLink;
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/messaging_repository.dart';
import '../domain/e2ee/encrypted_messaging.dart';
import '../domain/e2ee/encryption_access.dart';
import '../domain/e2ee/encryption_device.dart';
import '../domain/messaging_feature_flag.dart';
import 'bloc/message_composer_cubit.dart';
import 'e2ee/encrypted_thread_items.dart';
import 'e2ee/encryption_access_builder.dart';
import 'e2ee/encryption_copy.dart'
    show kRequiredDraftNoteText, unsentDiscardText;
import 'e2ee/encryption_status.dart';
import 'e2ee/screen_encrypted_port.dart';
import 'e2ee/widgets/thread_status_banner.dart';
import 'thread_items.dart' show EncryptedMessageItem;
import 'widgets/message_bubble.dart';
import 'widgets/not_encrypted_note.dart';
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
    // Two ports (see [ScreenEncryptedPort]): the composer always gets the
    // provided one (a first message never skips the port's fail-closed
    // answers); the person's thread watch and the not-encrypted note follow
    // the visible one, which only ever upgrades.
    return ScreenEncryptedPort(
      builder: (context, ports) => BlocProvider<MessageComposerCubit>(
        create: (context) => MessageComposerCubit(
          vaultNotOpen: _vaultNotOpenOf(context),
          // Plan 6 Task 1.B: read live at each send; fails closed.
          encryptionRequired: e2eeRequiredOf(context.read<OnboardingBloc>()),
          repository: context.read<MessagingRepository>(),
          recipientUserId: peer.userId,
          // R1: the person is addressed from this snapshot only.
          recipient: peer,
          encrypted: ports.send,
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
        child: _DraftView(peer: peer, port: ports.read),
      ),
    );
  }
}

/// Asks the status (when one is provided) whether the vault is not open.
bool Function() _vaultNotOpenOf(BuildContext context) {
  final status = context.read<EncryptionStatusCubit?>();
  return () => status?.state.vaultNotOpen ?? false;
}

class _DraftView extends StatefulWidget {
  const _DraftView({required this.peer, required this.port});

  final common.AuthorSnapshot peer;

  /// The screen's one port (null: today's draft).
  final EncryptedMessaging? port;

  @override
  State<_DraftView> createState() => _DraftViewState();
}

class _DraftViewState extends State<_DraftView> {
  common.AuthorSnapshot get peer => widget.peer;

  /// The desktop Chat mock's peer card (nothing else exists yet: no
  /// conversation to mute, delete or share plans in), inside the shell from
  /// 1200 dp.
  final _sideColumn = ShellSideColumnLease();

  /// With a port: the person's thread (nothing known yet is an empty `ready`
  /// thread; the first queued message shows as a row, and its conversation
  /// id switches the screen to `/messages/<id>`).
  StreamSubscription<EncryptedThread>? _watch;
  List<EncryptedMessageItem> _rows = const [];

  /// Decrypted rows do not outlive the vault: when its status is not `ready`
  /// they are dropped and not drawn (they come back with the next update).
  EncryptionDevice? _device;

  bool get _vaultReady =>
      _device == null || _device!.vaultStatus.value == VaultStatus.ready;

  void _onVaultStatus() {
    if (!mounted) return;
    // A vault change is what lets a stream that ended be tried again.
    _waitForVaultChange = false;
    _resubscribed = false;
    if (_vaultReady) {
      _startWatch();
    } else if (_rows.isNotEmpty) {
      setState(() => _rows = const []);
    }
  }

  late final UnexpectedErrorReporter _report;

  /// Set once a stream ended and was already tried again (or the vault is not
  /// ready): no new subscription until the vault status changes.
  bool _waitForVaultChange = false;

  /// One automatic new subscription per vault change.
  bool _resubscribed = false;

  @override
  void initState() {
    super.initState();
    _report = context.read<UnexpectedErrorReporter>();
    _device = context.read<EncryptionDevice?>();
    _device?.vaultStatus.addListener(_onVaultStatus);
    _startWatch();
  }

  void _startWatch() {
    final port = widget.port;
    if (port == null || _watch != null || _waitForVaultChange) return;
    final sub = port
        .watchThread(ThreadRef.recipientOf(peer))
        .listen(
          _onThread,
          // Never the thrown object: a fixed step.
          onError: (Object _, StackTrace stack) =>
              _report(StateError('draftWatch'), stack),
        );
    sub.onDone(() => _onWatchEnded(sub));
    _watch = sub;
  }

  /// The port's stream ENDS when the vault it reads changes. The draft is
  /// still on screen, so it listens to a new stream: once. A new stream that
  /// ends at once, or a vault that is not ready, waits for the next vault
  /// status change instead of looping.
  void _onWatchEnded(StreamSubscription<EncryptedThread> ended) {
    if (!mounted || !identical(_watch, ended)) return;
    _watch = null;
    // The vault it read changed: its decrypted rows are not drawn while the
    // new stream has not answered.
    if (_rows.isNotEmpty) setState(() => _rows = const []);
    if (_resubscribed || !_vaultReady) {
      _waitForVaultChange = true;
      return;
    }
    _resubscribed = true;
    _startWatch();
  }

  @override
  void didUpdateWidget(_DraftView old) {
    super.didUpdateWidget(old);
    // Upgrade-only: a port that appears later is watched; one never goes.
    if (old.port == null) _startWatch();
  }

  void _onThread(EncryptedThread thread) {
    if (!mounted) return;
    setState(() {
      // No system line exists in a thread that has no conversation yet.
      _rows = _vaultReady
          ? buildEncryptedThreadItems(
              thread.entries,
              showLines: false,
            ).whereType<EncryptedMessageItem>().toList(growable: false)
          : const [];
    });
    final id = thread.conversationId;
    if (id != null) context.read<MessageComposerCubit>().conversationKnown(id);
  }

  @override
  void dispose() {
    _device?.vaultStatus.removeListener(_onVaultStatus);
    unawaited(_watch?.cancel());
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
                  builder: (context, state) => _rows.isNotEmpty
                      ? _encryptedList(context, name)
                      : state.outgoing.isEmpty
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
                // The status banner sits above the composer of a draft too
                // while a vault on this device blocks messaging.
                builder: (context, cannotMessage) => cannotMessage
                    ? const ThreadReadOnlyLine()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Gone once the port's thread shows a row: that
                          // message is encrypted, whatever it is waiting for.
                          if (_rows.isEmpty)
                            _DraftNotEncryptedNote(
                              hasPort: widget.port != null,
                            ),
                          const ConnectedThreadStatusBanner(
                            child: MessageComposer(),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The rows of the person's thread under the first message's place: the
  /// caller's own queued, waiting or not-sent messages (no peer message and
  /// no system line exists before a conversation does).
  Widget _encryptedList(BuildContext context, String peerName) {
    final now = DateTime.now();
    final use24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: _rows.length,
      itemBuilder: (context, index) {
        final item = _rows[index];
        return MessageBubble.encrypted(
          key: ValueKey('bubble-${item.message.id}'),
          entry: item.message,
          peerName: peerName,
          now: now,
          firstOfGroup: item.firstOfGroup,
          lastOfGroup: item.lastOfGroup,
          use24Hour: use24Hour,
          linksEnabled: item.message.mine,
          onOpenLink: (uri) => unawaited(launchPostLink(uri)),
          onRetry: _retryRow,
          onDiscard: (id) => unawaited(_discardRow(id)),
        );
      },
    );
  }

  /// One discard per row at a time: a double tap asks once.
  final Set<String> _discarding = {};

  /// "Discard" under an own row that is not delivered (the first message of
  /// a new conversation included: the port's init discard decides). The line
  /// of the answer, when it has one; `held` is "may still be delivered".
  Future<void> _discardRow(String localId) async {
    final composer = context.read<MessageComposerCubit>();
    if (!composer.hasPort || !_discarding.add(localId)) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final answer = await composer.discardUnsent(localId);
      final line = answer == null ? null : unsentDiscardText(answer);
      if (line != null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(line)));
      }
    } finally {
      _discarding.remove(localId);
    }
  }

  /// One call per row at a time: a double tap retries once.
  final Set<String> _retrying = {};

  void _retryRow(String localId) {
    if (!_retrying.add(localId)) return;
    unawaited(
      context
          .read<MessageComposerCubit>()
          .retry(localId)
          .whenComplete(() => _retrying.remove(localId)),
    );
  }
}

/// "Messages are not end-to-end encrypted." above the composer of a draft,
/// before the first send, for a user with access `full` and a usable vault
/// (security read H1): what the first message is until the pipeline says
/// otherwise. The thread screen's own rule, with no conversation to ask.
/// Under `e2ee_required` (Plan 6 Task 1.B) the first message is never
/// plaintext, so the same place says `kRequiredDraftNoteText` instead (a
/// draft has no earlier messages), decided by the same fail-closed rule the
/// composer's sends use ([e2eeRequiredNow]), live.
class _DraftNotEncryptedNote extends StatelessWidget {
  const _DraftNotEncryptedNote({required this.hasPort});

  /// The screen has a port (its one answer, taken at open).
  final bool hasPort;

  @override
  Widget build(BuildContext context) {
    final requiredOn = context.select(
      (OnboardingBloc bloc) => e2eeRequiredNow(bloc),
    );
    return EncryptionAccessBuilder(
      builder: (context, access) {
        final device = context.read<EncryptionDevice?>();
        final show =
            access == EncryptionAccess.full &&
            hasPort &&
            device?.vaultStatus.value == VaultStatus.ready;
        if (!show) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Center(
            child: NotEncryptedNote(
              textAlign: TextAlign.center,
              encryptionRequired: requiredOn,
              requiredText: kRequiredDraftNoteText,
            ),
          ),
        );
      },
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
