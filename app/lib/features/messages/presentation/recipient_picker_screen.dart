import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/page_below.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/tablet_modal.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart' show Folder;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../graph/presentation/bloc/user_list_cubit.dart';
import '../../graph/presentation/bloc/user_list_state.dart';
import '../../graph/presentation/widgets/paged_user_list.dart';
import '../../graph/presentation/widgets/user_list_row.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/following_people_source.dart';
import '../data/messaging_repository.dart';
import '../domain/message_suggestions.dart';
import '../domain/messaging_feature_flag.dart';
import '../domain/people_source.dart';
import '../domain/share_post_target.dart';
import 'bloc/message_suggestions_cubit.dart';
import 'bloc/recipient_picker_cubit.dart';
import 'bloc/share_post_cubit.dart';
import 'messaging_error_messages.dart';
import 'open_conversation.dart';
import 'share_post_error_messages.dart' show sharePostRowReason;
import 'widgets/not_encrypted_note.dart';
import 'widgets/share_post_bar.dart';

/// The "To:" field's key.
const kRecipientFieldKey = ValueKey('recipient-field');

/// Key of the "Message @handle" row.
const kRecipientHandleRowKey = ValueKey('recipient-handle-row');

/// Shown when nobody the caller follows matches what is typed.
const kRecipientNoMatchText = 'No one you follow matches';

/// The page of `/messages/new`: a modal on the root navigator. Full
/// screen below 600 dp; a centred card at most 600 dp wide from 600 dp.
class RecipientPickerPage extends Page<void> {
  const RecipientPickerPage({super.key, this.source});

  /// Where people come from; null = the caller's Following list. W4's search
  /// source plugs in here.
  final PeopleSource? source;

  @override
  Route<void> createRoute(BuildContext context) {
    return DialogRoute<void>(
      context: context,
      settings: this,
      barrierDismissible: true,
      barrierLabel: 'Close',
      // [DialogPageFrame] adds the safe area (but on the tablet layout).
      useSafeArea: false,
      builder: (context) => DialogPageFrame(
        builder: (context, host) =>
            RecipientPickerDialog(source: source, host: host),
      ),
    );
  }
}

/// The frame of the picker: [Dialog.fullscreen] under 600 dp, a 600 dp card
/// above (as the Premium dialog). The content is [RecipientPicker].
///
/// On the tablet layout ([host], tablet plan section 4.1 "RecipientPicker")
/// the card is `min(600, C - 48)` wide and `min(H - 48, 640)` tall, centred
/// on the content area beside the rail; the barrier covers the whole
/// window, rail included.
class RecipientPickerDialog extends StatelessWidget {
  const RecipientPickerDialog({
    super.key,
    this.source,
    this.onPicked,
    this.host,
    this.share,
  });

  final PeopleSource? source;

  /// Share mode: choose up to five people and send this post to them
  /// ([RecipientPicker.share]).
  final SharePostTarget? share;

  /// The tablet presentation (`dialogPageHost`); null: today's.
  final TabletModalHost? host;
  final void Function(BuildContext context, common.AuthorSnapshot peer)?
  onPicked;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final picker = RecipientPicker(
      source: source,
      onPicked: onPicked,
      share: share,
      dialog: size.width >= AppBreakpoints.mobile,
    );
    if (size.width < AppBreakpoints.mobile) {
      return Dialog.fullscreen(child: SafeArea(child: picker));
    }
    final theme = Theme.of(context);
    return Dialog(
      insetPadding:
          host?.dialogInsets(context, maxWidth: AppLayout.mainColumnMaxWidth) ??
          const EdgeInsets.all(AppSpacing.lg),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: AppLayout.mainColumnMaxWidth,
          maxHeight: math.max(
            AppSize.contentMax,
            size.height - 2 * AppSpacing.lg,
          ),
        ),
        child: SizedBox(
          height: math.min(size.height - 2 * AppSpacing.lg, 640),
          child: picker,
        ),
      ),
    );
  }
}

/// The new-message picker: a "To:" field over a list of
/// people.
///
/// - Empty field: the people the caller follows (`ListFollowing` through the
///   [PeopleSource], paged, [UserListRow]s without a Follow button). Needs
///   `graph`; without it the list is replaced by a hint to type a handle.
/// - Typing, `search` on and a source that searches: the source's typeahead
///   (debounced, at least two characters). `search` off, or a source that
///   cannot search (today's only one): the loaded Following rows are filtered
///   in place (no request) and, for text that is a valid handle, a
///   "Message @handle" row resolves it with `GetProfile` on tap.
/// - Picking a person calls [onPicked]; the default replaces this page with
///   the existing conversation or a draft ([openConversationWith]).
/// - Needs `messaging`; without it, a short "not available" line.
///
/// With [share] set it is the "Send in a message" picker, the same list and
/// search with these additions: a row toggles a check (up to
/// [kSharePostMaxRecipients] people), "Recent" shows the people of the cached
/// inbox first, and a foot with an optional caption and Send sends the post to
/// each person in turn with a result per row ([SharePostCubit]). It needs
/// `messaging` and `dm_post_share` for the caller.
class RecipientPicker extends StatelessWidget {
  const RecipientPicker({
    super.key,
    this.source,
    this.onPicked,
    this.dialog = false,
    this.share,
  });

  /// The post to send; null is the new-message picker.
  final SharePostTarget? share;

  /// The tablet and desktop card (the flat "To:" pill, the uppercase
  /// section label, divided rows); false: the phone's full screen (the
  /// raised pill, the "Suggested" title, the 20 dp gutter). The same
  /// functions either way.
  final bool dialog;

  /// Where people come from; defaults to the caller's Following list.
  final PeopleSource? source;

  /// Test seam / navigation: called with the chosen person.
  final void Function(BuildContext context, common.AuthorSnapshot peer)?
  onPicked;

  @override
  Widget build(BuildContext context) {
    final title = share == null ? 'New message' : 'Send in a message';
    if (!isFeatureEnabled(context, kFeatureMessaging) ||
        (share != null && !isFeatureEnabled(context, kFeatureDmPostShare))) {
      return Column(
        children: [
          AppBackHeader(
            title: title,
            backTooltip: 'Close',
            onBack: () => _close(context, dialogRoute: share != null),
          ),
          const Expanded(
            child: Center(
              child: AppEmptyView(
                icon: Icons.mail_outline,
                title: "Messages aren't available yet",
              ),
            ),
          ),
        ],
      );
    }
    return _PickerView(
      source: source,
      searchEnabled: isFeatureEnabled(context, kPickerSearchFlag),
      graphEnabled: isFeatureEnabled(context, kFeatureGraph),
      suggestionsEnabled:
          share == null && isFeatureEnabled(context, kFeatureDmSuggestions),
      onPicked: onPicked,
      dialog: dialog,
      share: share,
    );
  }
}

/// Closes the picker. The share picker is a plain dialog route, not a page of
/// the router, so it pops itself: `context.pop` would act on the router's
/// pages under it.
void _close(BuildContext context, {bool dialogRoute = false}) {
  if (dialogRoute) {
    Navigator.of(context).pop();
  } else if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRouter.messagesPath);
  }
}

class _PickerView extends StatefulWidget {
  const _PickerView({
    required this.source,
    required this.searchEnabled,
    required this.graphEnabled,
    required this.suggestionsEnabled,
    required this.onPicked,
    required this.dialog,
    required this.share,
  });

  final PeopleSource? source;
  final SharePostTarget? share;
  final bool dialog;
  final bool searchEnabled;
  final bool graphEnabled;

  /// `dm_suggestions` (new-message mode only): the server's "Suggested"
  /// section before anything is typed.
  final bool suggestionsEnabled;
  final void Function(BuildContext, common.AuthorSnapshot)? onPicked;

  @override
  State<_PickerView> createState() => _PickerViewState();
}

class _PickerViewState extends State<_PickerView> {
  final _controller = TextEditingController();
  late final PeopleSource _source;
  late final UserListCubit _following;
  late final RecipientPickerCubit _picker;
  SharePostCubit? _share;
  MessageSuggestionsCubit? _suggestions;
  String? _ownUserId;

  /// Share mode: the people of the cached inbox, newest first (no request).
  List<graph.UserListItem> _recents = const [];

  @override
  void initState() {
    super.initState();
    final ownUserId = context.read<OnboardingBloc>().state.profile?.userId;
    _ownUserId = ownUserId;
    final target = widget.share;
    if (target != null) {
      final repository = context.read<MessagingRepository>();
      _share = SharePostCubit(
        repository: repository,
        postId: target.postId,
        url: target.url,
        ownUserId: ownUserId,
        isEnabled: () => repository.enabled,
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      );
      unawaited(_loadRecents(repository));
    }
    if (widget.suggestionsEnabled) {
      _suggestions = MessageSuggestionsCubit(
        repository: context.read<MessagingRepository>(),
        ownUserId: ownUserId,
      )..load();
    }
    _source =
        widget.source ??
        FollowingPeopleSource(
          graphRepository: context.read<GraphRepository>(),
          userId: ownUserId ?? '',
        );
    _following = UserListCubit(
      fetchPage: ({required pageSize, required pageToken}) async {
        final page = await _source.page(
          pageSize: pageSize,
          pageToken: pageToken,
        );
        return GraphPage(items: page.items, nextPageToken: page.nextPageToken);
      },
    );
    if (widget.graphEnabled) _following.loadFirstPage();
    _picker = RecipientPickerCubit(
      source: _source,
      identityRepository: context.read<IdentityRepository>(),
      searchEnabled: widget.searchEnabled,
      ownUserId: ownUserId,
      onUnexpectedError: context.read<UnexpectedErrorReporter>(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    unawaited(_following.close());
    unawaited(_picker.close());
    unawaited(_share?.close());
    unawaited(_suggestions?.close());
    super.dispose();
  }

  /// The first few people of the cached inbox: local only, so opening the
  /// picker costs no request. A broken disk just means no "Recent".
  Future<void> _loadRecents(MessagingRepository repository) async {
    try {
      final snapshot = await repository.cachedConversations(
        Folder.FOLDER_INBOX,
      );
      if (!mounted) return;
      final seen = <String>{};
      final rows = <graph.UserListItem>[];
      for (final c in snapshot.conversations) {
        final id = c.peer.userId;
        if (id.isEmpty || id == _ownUserId || !seen.add(id)) continue;
        rows.add(graph.UserListItem(user: c.peer));
        if (rows.length == kSharePostRecentMax) break;
      }
      setState(() => _recents = rows);
    } on Object {
      // No "Recent" section.
    }
  }

  void _pick(common.AuthorSnapshot peer) {
    final share = _share;
    if (share != null) {
      share.toggle(peer);
      return;
    }
    final handler = widget.onPicked;
    if (handler != null) {
      handler(context, peer);
    } else {
      openConversationWith(context, peer, replace: true);
    }
  }

  Future<void> _pickHandle(String handle) async {
    final peer = await _picker.resolveHandle(handle);
    if (peer != null && mounted) _pick(peer);
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<UserListCubit>.value(value: _following),
        BlocProvider<RecipientPickerCubit>.value(value: _picker),
        if (_share != null) BlocProvider<SharePostCubit>.value(value: _share!),
      ],
      child: Column(
        children: [
          AppBackHeader(
            title: _share == null ? 'New message' : 'Send in a message',
            backTooltip: 'Close',
            onBack: () => _close(context, dialogRoute: _share != null),
          ),
          Padding(
            // On the pill's gutter.
            padding: EdgeInsetsDirectional.only(
              start: widget.dialog
                  ? AppPickerLayout.dialogGutter
                  : AppPickerLayout.phoneGutter,
              end: widget.dialog
                  ? AppPickerLayout.dialogGutter
                  : AppPickerLayout.phoneGutter,
              bottom: AppSpacing.xs,
            ),
            child: const Align(
              alignment: AlignmentDirectional.centerStart,
              child: NotEncryptedNote(),
            ),
          ),
          if (_share == null) ..._search() else _shareSearch(),
          Expanded(
            child: _share == null
                ? _list()
                : BlocSelector<SharePostCubit, SharePostState, bool>(
                    selector: (state) => state.started,
                    // Once Send was pressed the list is exactly the chosen
                    // people in send order, each with its result: a person
                    // picked through "Send to @handle", or hidden by what is
                    // typed, has a row too.
                    builder: (context, started) => started
                        ? _ShareResults(dialog: widget.dialog)
                        : _list(),
                  ),
          ),
          if (_share != null)
            SharePostBar(
              dialog: widget.dialog,
              onDone: () => _close(context, dialogRoute: true),
            ),
        ],
      ),
    );
  }

  List<Widget> _search() => [
    _ToField(
      dialog: widget.dialog,
      controller: _controller,
      onChanged: _picker.queryChanged,
      onClear: () {
        _controller.clear();
        _picker.queryChanged('');
      },
    ),
    const _ResolveError(),
  ];

  /// Share mode: the "To:" field and, under it, the chosen people as
  /// removable chips (an off-list pick is visible and can be dropped). Both
  /// leave once Send was pressed (the results list takes over).
  Widget _shareSearch() {
    return BlocSelector<SharePostCubit, SharePostState, bool>(
      selector: (state) => state.started,
      builder: (context, started) => started
          ? const SizedBox.shrink()
          : Column(
              children: [
                ..._search(),
                _ShareChips(dialog: widget.dialog),
              ],
            ),
    );
  }

  Widget _list() {
    return BlocBuilder<RecipientPickerCubit, RecipientPickerState>(
      builder: (context, state) => _body(state),
    );
  }

  /// "Suggested", or in share mode "Recent" (the inbox's people, hidden while
  /// typing: the filter below works on the Following rows) above it.
  Widget _header(RecipientPickerState state, {bool suggested = true}) {
    final suggestions = _suggestions;
    if (suggestions != null && !state.hasQuery && suggested) {
      // The server's people first; the Following list moves under its own
      // title only while there are some (none: today's "Suggested").
      return BlocBuilder<MessageSuggestionsCubit, MessageSuggestionsState>(
        bloc: suggestions,
        builder: (context, s) => s.suggestions.isEmpty
            ? _SuggestedHeader(dialog: widget.dialog)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ..._suggestionSection(s),
                  _SuggestedHeader(dialog: widget.dialog, title: 'Following'),
                ],
              ),
      );
    }
    final recents = _share == null || state.hasQuery
        ? const <graph.UserListItem>[]
        : _recents;
    if (recents.isEmpty) return _SuggestedHeader(dialog: widget.dialog);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SuggestedHeader(dialog: widget.dialog, title: 'Recent'),
        for (final item in recents)
          _PickerRow(
            key: ValueKey('recent-${item.user.userId}'),
            item: item,
            dialog: widget.dialog,
            share: true,
            onTap: () => _pick(item.user),
          ),
        if (suggested) _SuggestedHeader(dialog: widget.dialog),
      ],
    );
  }

  /// The "Suggested" title and one row per server suggestion, with its reason
  /// under the handle. A tap opens the conversation as any picker row does.
  List<Widget> _suggestionSection(MessageSuggestionsState s) => [
    _SuggestedHeader(dialog: widget.dialog),
    for (final suggestion in s.suggestions)
      _PickerRow(
        key: ValueKey('suggestion-${suggestion.user.userId}'),
        item: graph.UserListItem(user: suggestion.user),
        dialog: widget.dialog,
        subtitle: messageSuggestionReason(suggestion),
        onTap: () => _pick(suggestion.user),
      ),
  ];

  /// Whether the Following row [item] shows: it matches the typed text, is
  /// not the caller, and (share mode) is not already listed under "Recent".
  bool _showFollowing(
    graph.UserListItem item,
    RecipientPickerState state,
    String query,
  ) {
    final id = item.user.userId;
    if (_share != null && id == _ownUserId) return false;
    if (_share != null &&
        !state.hasQuery &&
        _recents.any((r) => r.user.userId == id)) {
      return false;
    }
    return !state.hasQuery || _matches(item.user, query);
  }

  Widget _body(RecipientPickerState state) {
    final remote = state.remote;
    if (state.hasQuery && remote != null) return _remoteResults(remote);
    if (state.hasQuery && state.searching) {
      return const SingleChildScrollView(
        physics: NeverScrollableScrollPhysics(),
        child: UserListSkeleton(),
      );
    }
    final query = state.normalized;
    final candidate = state.hasQuery ? state.handleCandidate : null;
    return Column(
      children: [
        if (candidate != null)
          BlocBuilder<UserListCubit, UserListState>(
            builder: (context, following) {
              final listed = following.items.any(
                (i) => i.user.handle.toLowerCase() == candidate,
              );
              return listed
                  ? const SizedBox.shrink()
                  : _HandleRow(
                      verb: _share == null ? 'Message' : 'Send to',
                      dialog: widget.dialog,
                      handle: candidate,
                      busy: state.resolving,
                      onTap: () => _pickHandle(candidate),
                    );
            },
          ),
        Expanded(
          child: widget.graphEnabled
              ? _withSuggestionFallback(
                  state,
                  PagedUserList(
                    cubit: _following,
                    emptyIcon: Icons.mail_outline,
                    emptyMessage: state.hasQuery
                        ? kRecipientNoMatchText
                        : "You're not following anyone yet. Type a handle to "
                              'message someone.',
                    itemFilter: _share == null && !state.hasQuery
                        ? null
                        : (item) => _showFollowing(item, state, query),
                    header: _header(state),
                    rowBuilder: (context, item) => _PickerRow(
                      key: ValueKey(item.user.userId),
                      item: item,
                      dialog: widget.dialog,
                      share: _share != null,
                      onTap: () => _pick(item.user),
                    ),
                  ),
                )
              // Without `graph` there is no Following list; share mode still
              // offers the people of the cached inbox.
              : (_suggestions != null && !state.hasQuery
                    ? BlocBuilder<
                        MessageSuggestionsCubit,
                        MessageSuggestionsState
                      >(
                        bloc: _suggestions,
                        builder: (context, s) => s.suggestions.isEmpty
                            ? const _TypeAHandle()
                            : ListView(children: _suggestionSection(s)),
                      )
                    : _share != null && !state.hasQuery && _recents.isNotEmpty
                    ? ListView(children: [_header(state, suggested: false)])
                    : candidate != null
                    ? const SizedBox.shrink()
                    : const _TypeAHandle()),
        ),
      ],
    );
  }

  /// The Following list carries the suggestions as its header, but the list
  /// draws no header while it loads, fails or is empty: then (and only then)
  /// the suggestions stand alone, so they show for someone who follows nobody.
  Widget _withSuggestionFallback(RecipientPickerState state, Widget paged) {
    final suggestions = _suggestions;
    if (suggestions == null || state.hasQuery) return paged;
    return BlocBuilder<MessageSuggestionsCubit, MessageSuggestionsState>(
      bloc: suggestions,
      builder: (context, s) {
        if (s.suggestions.isEmpty) return paged;
        return BlocBuilder<UserListCubit, UserListState>(
          bloc: _following,
          builder: (context, following) {
            final hasRows =
                (following.status == UserListStatus.ready ||
                    following.status == UserListStatus.loadingMore) &&
                following.items.isNotEmpty;
            return hasRows ? paged : ListView(children: _suggestionSection(s));
          },
        );
      },
    );
  }

  Widget _remoteResults(List<graph.UserListItem> all) {
    final rows = _share == null
        ? all
        : [
            for (final r in all)
              if (r.user.userId != _ownUserId) r,
          ];
    if (rows.isEmpty) {
      return const Center(
        child: AppEmptyView(icon: Icons.search_off, title: 'No people found'),
      );
    }
    return ListView.builder(
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _SuggestedHeader(dialog: widget.dialog);
        final item = rows[index - 1];
        return _PickerRow(
          key: ValueKey(item.user.userId),
          item: item,
          dialog: widget.dialog,
          share: _share != null,
          onTap: () => _pick(item.user),
        );
      },
    );
  }
}

class _TypeAHandle extends StatelessWidget {
  const _TypeAHandle();

  @override
  Widget build(BuildContext context) => const Center(
    child: AppEmptyView(
      icon: Icons.alternate_email,
      title: 'Type a handle',
      subtitle: 'Enter the @handle of the person.',
    ),
  );
}

bool _matches(common.AuthorSnapshot user, String query) =>
    user.handle.toLowerCase().contains(query) ||
    user.displayName.toLowerCase().contains(query);

/// The search pill. Phone: the raised white pill with a search glyph
/// (dzeroth-mobile RecipientPicker). Dialog: the flat outlined pill that
/// leads with "To:" and rings in the accent while focused (dz.css
/// `.search.on`).
class _ToField extends StatelessWidget {
  const _ToField({
    required this.dialog,
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final bool dialog;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  static OutlineInputBorder _pill(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        borderSide: BorderSide(color: color, width: width),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final gutter = dialog
        ? AppPickerLayout.dialogGutter
        : AppPickerLayout.phoneGutter;
    final raisedFill = theme.brightness == Brightness.dark
        ? scheme.surfaceContainerHigh
        : AppPalette.white;
    final field = TextField(
      key: kRecipientFieldKey,
      controller: controller,
      autofocus: true,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.search,
      keyboardType: TextInputType.text,
      style: theme.textTheme.bodyLarge,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: 'Search people or type a handle',
        hintStyle: theme.textTheme.bodyLarge?.copyWith(color: muted),
        isDense: true,
        filled: !dialog,
        fillColor: dialog ? null : raisedFill,
        prefixIcon: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: AppSpacing.md,
            end: AppSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, size: AppIconSize.md, color: muted),
              if (dialog) ...[
                const SizedBox(width: AppSpacing.sm),
                ExcludeSemantics(
                  child: Text(
                    'To:',
                    style: theme.textTheme.bodyLarge?.copyWith(color: muted),
                  ),
                ),
              ],
            ],
          ),
        ),
        prefixIconConstraints: const BoxConstraints(
          minHeight: AppPickerLayout.searchHeight,
        ),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close, size: AppIconSize.md),
                  onPressed: onClear,
                ),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.smd),
        border: _pill(scheme.outlineVariant),
        enabledBorder: _pill(scheme.outlineVariant),
        focusedBorder: dialog
            ? _pill(AppPalette.teal, AppSize.componentBorder)
            : _pill(scheme.outlineVariant),
      ),
    );
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        gutter,
        dialog ? 0 : AppPickerLayout.phoneSearchTop,
        gutter,
        dialog ? AppSpacing.sm : AppPickerLayout.phoneSearchBottom,
      ),
      child: dialog
          ? field
          : DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                boxShadow: AppShadows.searchRaised,
              ),
              child: field,
            ),
    );
  }
}

/// "Suggested" over the people: the phone's display title (w800), the
/// dialog's uppercase muted label (dz.css `.sect`). Announced as a header.
class _SuggestedHeader extends StatelessWidget {
  const _SuggestedHeader({required this.dialog, this.title = 'Suggested'});

  final bool dialog;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: dialog
            ? const EdgeInsetsDirectional.fromSTEB(
                AppPickerLayout.dialogGutter,
                AppPickerLayout.dialogSectionTop,
                AppPickerLayout.dialogGutter,
                AppPickerLayout.dialogSectionBottom,
              )
            : const EdgeInsetsDirectional.fromSTEB(
                AppPickerLayout.phoneGutter,
                AppPickerLayout.phoneSectionTop,
                AppPickerLayout.phoneGutter,
                AppPickerLayout.phoneSectionBottom,
              ),
        child: Text(
          dialog ? title.toUpperCase() : title,
          style: dialog
              ? AppTextStyles.eyebrow(theme)
              : theme.textTheme.titleLarge?.copyWith(
                  fontWeight: AppTypeTokens.weightDisplay,
                ),
        ),
      ),
    );
  }
}

/// The inline answer of a failed "Message @handle" resolve.
class _ResolveError extends StatelessWidget {
  const _ResolveError();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RecipientPickerCubit, RecipientPickerState>(
      buildWhen: (a, b) => a.resolveError != b.resolveError,
      builder: (context, state) {
        final error = state.resolveError;
        if (error == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                _resolveErrorText(error, state.handleCandidate),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One answer for a missing, suspended or blocking account (the server's
/// NOT_FOUND is identical for all three).
String _resolveErrorText(AppException error, String? handle) => switch (error) {
  NotFoundException() =>
    handle == null
        ? "We couldn't find that person."
        : "We couldn't find @$handle.",
  ValidationException() => error.message,
  _ => messagingErrorMessage(error),
};

/// A [UserListRow] without a Follow button that opens the person on tap: one
/// button for a screen reader ("Name, @handle"), at least 48dp tall.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    super.key,
    required this.item,
    required this.dialog,
    required this.onTap,
    this.share = false,
    this.subtitle,
  });

  /// Why the person is offered (a server suggestion), under the @handle.
  final String? subtitle;

  final graph.UserListItem item;
  final bool dialog;
  final VoidCallback onTap;

  /// Share mode: the trailing slot is the check and the result of the send
  /// ([SharePostRowTrailing]) instead of the "Message" pill.
  final bool share;

  @override
  Widget build(BuildContext context) {
    if (!share) return _build(context, null);
    return BlocSelector<SharePostCubit, SharePostState, ShareRecipient?>(
      selector: (state) {
        for (final r in state.recipients) {
          if (r.peer.userId == item.user.userId) return r;
        }
        return null;
      },
      builder: _build,
    );
  }

  Widget _build(BuildContext context, ShareRecipient? chosen) {
    final user = item.user;
    final name = user.displayName.isEmpty
        ? '@${user.handle}'
        : user.displayName;
    final who = user.displayName.isEmpty ? name : '$name, @${user.handle}';
    final Widget trailing = share
        ? SharePostRowTrailing(recipient: chosen)
        : AppPillButton(
            label: 'Message',
            compact: true,
            variant: AppButtonVariant.outline,
            onPressed: onTap,
          );
    return Semantics(
      button: true,
      selected: share ? chosen != null : null,
      label: share
          ? _shareLabel(who, chosen)
          : subtitle == null
          ? 'Message $who'
          : 'Message $who, $subtitle',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        // The mocks' row: a 44 dp avatar, a 12 dp gap and the outlined
        // Message pill (share mode: the check circle); divided in the dialog
        // (dz.css `.row`), open on a phone.
        child: UserListRow(
          item: item,
          avatarRadius: AppSize.avatarRow / 2,
          avatarGap: AppPickerLayout.rowGap,
          horizontalInset: dialog
              ? AppPickerLayout.dialogGutter
              : AppPickerLayout.phoneGutter,
          verticalInset: AppPickerLayout.rowPaddingV,
          handleStyle: TextStyle(
            fontSize: dialog
                ? AppPickerLayout.dialogHandleSize
                : AppPickerLayout.phoneHandleSize,
          ),
          showDivider: dialog,
          subtitle: subtitle,
          trailing: trailing,
        ),
      ),
    );
  }

  /// "Send to Name, @handle", then where this person stands.
  static String _shareLabel(String who, ShareRecipient? chosen) {
    final state = switch (chosen?.status) {
      null => '',
      ShareRowStatus.idle => ', selected',
      ShareRowStatus.sending => ', sending',
      ShareRowStatus.sent => ', sent',
      ShareRowStatus.failed => ', ${sharePostRowReason(chosen!.error!)}',
      ShareRowStatus.skipped => ', not sent',
    };
    return 'Send to $who$state';
  }
}

/// "Message @handle" for text that is a valid handle and not in the loaded
/// Following rows; resolved with `GetProfile` on tap.
class _HandleRow extends StatelessWidget {
  const _HandleRow({
    required this.verb,
    required this.dialog,
    required this.handle,
    required this.busy,
    required this.onTap,
  });

  /// "Message" (the new-message picker) or "Send to" (the share picker).
  final String verb;
  final bool dialog;
  final String handle;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      button: true,
      enabled: !busy,
      label: '$verb @$handle',
      excludeSemantics: true,
      onTap: busy ? null : onTap,
      child: InkWell(
        key: kRecipientHandleRowKey,
        onTap: busy ? null : onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: dialog
                    ? AppPickerLayout.dialogGutter
                    : AppPickerLayout.phoneGutter,
                vertical: AppSpacing.sm,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Row(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.surfaceContainerHigh,
                      ),
                      child: const SizedBox(
                        width: AppSpacing.xl + AppSpacing.sm,
                        height: AppSpacing.xl + AppSpacing.sm,
                        child: Icon(Icons.mail_outline, size: AppIconSize.lg),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        '$verb @$handle',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    if (busy)
                      const SizedBox(
                        width: AppIconSize.md,
                        height: AppIconSize.md,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
          ],
        ),
      ),
    );
  }
}

/// The people chosen so far, as removable chips (share mode, before Send).
/// Empty: nothing is drawn.
class _ShareChips extends StatelessWidget {
  const _ShareChips({required this.dialog});

  final bool dialog;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SharePostCubit, SharePostState>(
      buildWhen: (a, b) =>
          a.recipients.length != b.recipients.length ||
          !_sameIds(a.recipients, b.recipients),
      builder: (context, state) {
        if (state.recipients.isEmpty) return const SizedBox.shrink();
        final gutter = dialog
            ? AppPickerLayout.dialogGutter
            : AppPickerLayout.phoneGutter;
        return Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            gutter,
            0,
            gutter,
            AppSpacing.xs,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                for (final r in state.recipients)
                  InputChip(
                    key: ValueKey('share-chip-${r.peer.userId}'),
                    label: Text(
                      r.peer.displayName.isEmpty
                          ? '@${r.peer.handle}'
                          : r.peer.displayName,
                    ),
                    deleteButtonTooltipMessage: 'Remove @${r.peer.handle}',
                    onDeleted: () =>
                        context.read<SharePostCubit>().toggle(r.peer),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static bool _sameIds(List<ShareRecipient> a, List<ShareRecipient> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].peer.userId != b[i].peer.userId) return false;
    }
    return true;
  }
}

/// After Send: exactly the chosen people, in send order, each with the result
/// of their send (sending, sent, the reason it failed, or not sent). Whoever
/// was chosen has a row, however they were found.
class _ShareResults extends StatelessWidget {
  const _ShareResults({required this.dialog});

  final bool dialog;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SharePostCubit, SharePostState>(
      buildWhen: (a, b) => a.recipients != b.recipients,
      builder: (context, state) => ListView(
        children: [
          for (final r in state.recipients)
            _PickerRow(
              key: ValueKey('share-result-${r.peer.userId}'),
              item: graph.UserListItem(user: r.peer),
              dialog: dialog,
              share: true,
              onTap: () {},
            ),
        ],
      ),
    );
  }
}
