import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/shell_geometry.dart';
import '../../../../shared/format/relative_time.dart';
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../data/messaging_repository.dart';
import '../../domain/message_search.dart';
import '../bloc/message_search_cubit.dart';
import '../bloc/message_search_state.dart';
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
    _cubit = MessageSearchCubit(
      repository: context.read<MessagingRepository>(),
      conversationId: widget.conversationId,
      debounce: widget.debounce,
      onUnexpectedError: context.read<UnexpectedErrorReporter>(),
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
                    builder: (context, state) => _body(context, state, gutter),
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

  Widget _body(BuildContext context, MessageSearchState state, double gutter) {
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
          const AppEmptyView(
            icon: Icons.search,
            title: 'Search your messages',
            subtitle:
                'Finds messages from conversations you have opened on this '
                'device.',
          ),
        ],
      );
    }
    final rows = _rows(state);
    final empty = state.status == MessageSearchStatus.ready && rows.isEmpty;
    final body = empty ? 1 : rows.length;
    return ListView.builder(
      itemCount: 1 + body + 1,
      itemBuilder: (context, index) {
        if (index == 0) return note;
        if (index == body + 1) return _footer(context, state, gutter);
        if (empty) {
          return const AppEmptyView(
            icon: Icons.search_off,
            title: 'No messages found',
            subtitle: 'Only messages cached on this device are searched.',
          );
        }
        return switch (rows[index - 1]) {
          _GroupRow() => _groupHeader(
            context,
            (rows[index - 1] as _GroupRow).group,
            gutter,
          ),
          _HitRow(:final hit) => _hitRow(context, hit, gutter),
        };
      },
    );
  }

  List<_Row> _rows(MessageSearchState state) {
    final single = widget.conversationId != null;
    return [
      for (final g in state.groups) ...[
        if (!single) _GroupRow(g),
        for (final h in g.hits) _HitRow(h),
      ],
    ];
  }

  Widget _groupHeader(
    BuildContext context,
    ConversationHits group,
    double gutter,
  ) {
    final theme = Theme.of(context);
    final peer = group.conversation.peer;
    final name = peer.displayName.isEmpty
        ? '@${peer.handle}'
        : peer.displayName;
    final open = widget.onOpenConversation;
    return Semantics(
      header: true,
      child: InkWell(
        onTap: open == null ? null : () => open(group.conversation.id),
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

  Widget _hitRow(BuildContext context, MessageSearchHit hit, double gutter) {
    final theme = Theme.of(context);
    final at = hit.message.hasCreatedAt()
        ? hit.message.createdAt.toDateTime()
        : null;
    final when = at == null ? '' : formatRelativeTimeSpoken(at, DateTime.now());
    final who = hit.message.fromSelf ? 'You' : 'Them';
    return Semantics(
      button: true,
      label: '$who, $when: ${hit.message.text}',
      excludeSemantics: true,
      onTap: () => widget.onOpenHit(hit),
      child: InkWell(
        onTap: () => widget.onOpenHit(hit),
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
                HighlightedMatch(text: hit.message.text, ranges: hit.ranges),
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
  const _GroupRow(this.group);
  final ConversationHits group;
}

class _HitRow extends _Row {
  const _HitRow(this.hit);
  final MessageSearchHit hit;
}
