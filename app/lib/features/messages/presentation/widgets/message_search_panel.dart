import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/shell_geometry.dart';
import '../../../../shared/format/relative_time.dart';
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../data/messaging_repository.dart';
import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/e2ee/encryption_access.dart';
import '../../domain/e2ee/encryption_device.dart';
import '../../domain/message_search.dart';
import '../../domain/messaging_feature_flag.dart';
import '../bloc/message_search_cubit.dart';
import '../bloc/message_search_state.dart';
import '../e2ee/encrypted_search_results.dart';
import '../e2ee/encryption_access_builder.dart';
import '../e2ee/encryption_copy.dart';
import '../messaging_error_messages.dart';

const kMessageSearchHint = 'Search messages';
const kMessageSearchLoadOlder = 'Load older messages';

/// [text] with the [ranges] of the search term marked (bold, tinted by the
/// theme's accent), cut to a window around the first match. One `Text`, so a
/// screen reader reads it as plain text.
class HighlightedMatch extends StatelessWidget {
  const HighlightedMatch({
    super.key,
    required this.text,
    required this.ranges,
    this.style,
    this.maxLines = 3,
  });

  final String text;
  final List<SearchRange> ranges;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final snippet = snippetAround(text, ranges);
    final base = style ?? Theme.of(context).textTheme.bodyMedium;
    final mark = base?.copyWith(
      fontWeight: FontWeight.w700,
      backgroundColor: AppPalette.tealElectric.withValues(alpha: 0.22),
    );
    final spans = <TextSpan>[];
    var at = 0;
    for (final r in snippet.ranges) {
      if (r.start > at) {
        spans.add(TextSpan(text: snippet.text.substring(at, r.start)));
      }
      spans.add(
        TextSpan(text: snippet.text.substring(r.start, r.end), style: mark),
      );
      at = r.end;
    }
    if (at < snippet.text.length) {
      spans.add(TextSpan(text: snippet.text.substring(at)));
    }
    return Text.rich(
      TextSpan(children: spans),
      style: base,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// The search UI over one [MessageSearchCubit]: a field, the on-device note and
/// the results grouped by conversation. The same widget at every width; only
/// the reading column and gutters differ.
///
/// - [conversationId] null searches every cached conversation (the Messages
///   list); set, only that conversation (a chat), with "Load older messages".
/// - [onClose] leaves the search; [onOpenHit] opens a result.
/// - [onOpenConversation] (list search only) opens a conversation from its
///   group header.
class MessageSearchPanel extends StatefulWidget {
  const MessageSearchPanel({
    super.key,
    this.conversationId,
    required this.onClose,
    required this.onOpenHit,
    this.onOpenConversation,
    this.debounce = const Duration(milliseconds: 250),
  });

  final String? conversationId;
  final VoidCallback onClose;
  final void Function(MessageSearchHit hit) onOpenHit;
  final void Function(String conversationId)? onOpenConversation;
  final Duration debounce;

  @override
  State<MessageSearchPanel> createState() => _MessageSearchPanelState();
}

class _MessageSearchPanelState extends State<MessageSearchPanel> {
  final TextEditingController _text = TextEditingController();
  late final MessageSearchCubit _cubit;

  @override
  void initState() {
    super.initState();
    final vault = _vaultSource(context);
    _cubit = MessageSearchCubit(
      repository: context.read<MessagingRepository>(),
      conversationId: widget.conversationId,
      debounce: widget.debounce,
      onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      encrypted: vault.port,
      encryptedAllowed: vault.allowed,
    );
  }

  @override
  void dispose() {
    _text.dispose();
    unawaited(_cubit.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final gutter = phone
        ? AppMessagesLayout.phoneGutter
        : AppMessagesLayout.wideGutter;
    return BlocProvider<MessageSearchCubit>.value(
      value: _cubit,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inset = ShellGeometry.readableInset(
            context,
            constraints.maxWidth,
          );
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: Column(
              children: [
                _header(context, gutter),
                Expanded(
                  child: BlocBuilder<MessageSearchCubit, MessageSearchState>(
                    builder: (context, state) => EncryptionAccessBuilder(
                      builder: (context, access) {
                        final saved =
                            access == EncryptionAccess.full ||
                            access == EncryptionAccess.manage;
                        return ValueListenableBuilder<EncryptedHitGroups>(
                          valueListenable: _cubit.encryptedResults,
                          builder: (context, vault, _) {
                            // With access lost the decrypted hits are not
                            // drawn, and the cubit drops them after the frame.
                            if (!saved && !vault.isEmpty) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) _cubit.accessChanged();
                              });
                            }
                            return _body(
                              context,
                              state,
                              saved ? vault : EncryptedHitGroups.empty,
                              gutter,
                              saved: saved,
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, double gutter) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.sm,
        gutter,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close search',
            onPressed: widget.onClose,
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: TextField(
              controller: _text,
              autofocus: true,
              textInputAction: TextInputAction.search,
              // Message text is private: no suggestions or autocorrect.
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (value) {
                setState(() {});
                _cubit.setQuery(value);
              },
              decoration: InputDecoration(
                hintText: widget.conversationId == null
                    ? kMessageSearchHint
                    : 'Search this conversation',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _text.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: Icon(Icons.close, color: colors.onSurfaceVariant),
                        onPressed: () {
                          _text.clear();
                          setState(() {});
                          _cubit.setQuery('');
                        },
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    MessageSearchState state,
    EncryptedHitGroups vault,
    double gutter, {
    required bool saved,
  }) {
    final theme = Theme.of(context);
    final note = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        AppSpacing.xs,
        gutter,
        AppSpacing.sm,
      ),
      child: Text(
        kMessageSearchNote,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    if (!state.hasQuery) {
      return ListView(
        children: [
          note,
          AppEmptyView(
            icon: Icons.search,
            title: 'Search your messages',
            subtitle: saved
                ? kSearchSavedIdleSubtitle
                : 'Finds messages from conversations you have opened on this '
                      'device.',
          ),
        ],
      );
    }
    final rows = _rows(state, vault);
    final empty = state.status == MessageSearchStatus.ready && rows.isEmpty;
    final body = empty ? 1 : rows.length;
    return ListView.builder(
      itemCount: 1 + body + 1,
      itemBuilder: (context, index) {
        if (index == 0) return note;
        if (index == body + 1) return _footer(context, state, gutter);
        if (empty) {
          return AppEmptyView(
            icon: Icons.search_off,
            title: 'No messages found',
            subtitle: saved
                ? kSearchSavedEmptySubtitle
                : 'Only messages cached on this device are searched.',
          );
        }
        return switch (rows[index - 1]) {
          _GroupRow(:final conversation) => _groupHeader(
            context,
            conversation,
            gutter,
          ),
          _HitRow(:final entry) => _hitRow(context, entry, gutter),
        };
      },
    );
  }

  /// The cache's groups and the vault's merged for display: a conversation in
  /// both is one group, hits and groups newest first. The vault's rows come
  /// straight from the hits (no pb.Message is built from decrypted text), and
  /// only for the query on screen.
  List<_Row> _rows(MessageSearchState state, EncryptedHitGroups vault) {
    final single = widget.conversationId != null;
    final merged = <String, _Merged>{};
    for (final g in state.groups) {
      final group = merged.putIfAbsent(
        g.conversation.id,
        () => _Merged(g.conversation),
      );
      for (final h in g.hits) {
        group.entries.add(_Entry.cache(h));
      }
    }
    if (vault.query == state.query) {
      for (final g in vault.groups) {
        final group = merged.putIfAbsent(
          g.conversation.id,
          () => _Merged(g.conversation),
        );
        for (var i = 0; i < g.hits.length; i++) {
          final entry = _Entry.vault(g.conversation, g.hits[i], g.ranges[i]);
          group.entries.removeWhere((e) => e.messageId == entry.messageId);
          group.entries.add(entry);
        }
      }
    }
    final groups = [
      for (final g in merged.values)
        if (g.entries.isNotEmpty) g..entries.sort(_Entry.newestFirst),
    ]..sort((a, b) => _Entry.newestFirst(a.entries.first, b.entries.first));
    return [
      for (final g in groups) ...[
        if (!single) _GroupRow(g.conversation),
        for (final e in g.entries) _HitRow(e),
      ],
    ];
  }

  void _open(_Entry entry) {
    final cached = entry.cached;
    if (cached != null) {
      widget.onOpenHit(cached);
      return;
    }
    // An id-only message: opening a hit needs the ids, never the text.
    widget.onOpenHit(
      MessageSearchHit(
        conversation: entry.conversation,
        message: pb.Message(
          id: entry.messageId,
          conversationId: entry.conversation.id,
        ),
        ranges: const [],
      ),
    );
  }

  Widget _groupHeader(
    BuildContext context,
    pb.Conversation conversation,
    double gutter,
  ) {
    final theme = Theme.of(context);
    final peer = conversation.peer;
    final name = peer.displayName.isEmpty
        ? '@${peer.handle}'
        : peer.displayName;
    final open = widget.onOpenConversation;
    return Semantics(
      header: true,
      child: InkWell(
        onTap: open == null ? null : () => open(conversation.id),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              AppSpacing.smd,
              gutter,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                AppAvatar(url: peer.avatarUrl, radius: 14, name: name),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hitRow(BuildContext context, _Entry entry, double gutter) {
    final theme = Theme.of(context);
    final at = entry.at;
    final when = at == null ? '' : formatRelativeTimeSpoken(at, DateTime.now());
    final who = entry.mine ? 'You' : 'Them';
    return Semantics(
      button: true,
      label: '$who, $when: ${entry.text}',
      excludeSemantics: true,
      onTap: () => _open(entry),
      child: InkWell(
        onTap: () => _open(entry),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: gutter,
              vertical: AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HighlightedMatch(text: entry.text, ranges: entry.ranges),
                if (when.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      '$who · $when',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer(
    BuildContext context,
    MessageSearchState state,
    double gutter,
  ) {
    if (state.status == MessageSearchStatus.searching || state.loadingOlder) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (!state.canLoadOlder) return const SizedBox(height: AppSpacing.lg);
    final error = state.olderError;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: gutter,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(messagingErrorMessage(error)),
            ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
            ),
            onPressed: _cubit.loadOlder,
            child: const Text(kMessageSearchLoadOlder),
          ),
        ],
      ),
    );
  }
}

sealed class _Row {
  const _Row();
}

class _GroupRow extends _Row {
  const _GroupRow(this.conversation);
  final pb.Conversation conversation;
}

class _HitRow extends _Row {
  const _HitRow(this.entry);
  final _Entry entry;
}

/// One conversation's rows for display, the cache's and the vault's together.
class _Merged {
  _Merged(this.conversation);
  final pb.Conversation conversation;
  final List<_Entry> entries = [];
}

/// One result row, from the cache (a `pb.Message`) or straight from a vault
/// hit. No toString: it may hold decrypted text.
class _Entry {
  _Entry.cache(MessageSearchHit hit)
    : conversation = hit.conversation,
      cached = hit,
      messageId = hit.message.id,
      text = hit.message.text,
      ranges = hit.ranges,
      mine = hit.message.fromSelf,
      at = hit.message.hasCreatedAt()
          ? hit.message.createdAt.toDateTime()
          : null;

  _Entry.vault(
    this.conversation,
    EncryptedSearchHit hit,
    List<SearchRange> found,
  ) : cached = null,
      messageId = hit.messageId,
      text = hit.text,
      ranges = found,
      mine = hit.mine,
      at = hit.at;

  final pb.Conversation conversation;
  final MessageSearchHit? cached;
  final String messageId;
  final String text;
  final List<SearchRange> ranges;
  final bool mine;
  final DateTime? at;

  int get _micros => at?.microsecondsSinceEpoch ?? 0;

  static int newestFirst(_Entry a, _Entry b) {
    final byTime = b._micros.compareTo(a._micros);
    return byTime != 0 ? byTime : b.messageId.compareTo(a.messageId);
  }
}

/// The port and the access check the panel's cubit takes from the tree: null
/// without the encryption wiring (today's search). Closed over objects, not
/// the context, so the cubit may outlive the widget.
({EncryptedMessaging? port, bool Function()? allowed}) _vaultSource(
  BuildContext context,
) {
  final port = context.read<EncryptedMessaging?>();
  final device = context.read<EncryptionDevice?>();
  if (port == null || device == null) return (port: null, allowed: null);
  final onboarding = context.read<OnboardingBloc>();
  return (
    port: port,
    allowed: () {
      final access = encryptionAccessOf(
        flagOn: onboarding.state.enabledFeatures.contains(kFeatureE2eeDm),
        vaultKnown: device.vaultKnown,
        status: device.vaultStatus.value,
      );
      return access == EncryptionAccess.full ||
          access == EncryptionAccess.manage;
    },
  );
}
