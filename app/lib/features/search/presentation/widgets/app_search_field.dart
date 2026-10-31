import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_avatar.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../data/recent_searches_store.dart';
import '../../data/search_repository.dart';
import '../../domain/search_feature_flags.dart';
import '../../domain/search_query.dart';
import '../../domain/search_routes.dart';
import '../bloc/search_suggestions_cubit.dart';

/// Spoken label of the field.
const kSearchFieldLabel = 'Search query';

/// Text shown when the field has no recents yet.
const kSearchEmptyHint = 'Try searching for people or #hashtags';

/// The quiet hint shown under a RATE_LIMITED typeahead.
const kSearchRateLimitedHint =
    'Suggestions are paused for a moment. Press Enter to search.';

/// Called with `SearchQuery.canonical` when a search is submitted.
typedef SearchSubmitted = void Function(BuildContext context, String canonical);

enum _Kind { submit, recent, tag, person }

class _Entry {
  const _Entry(this.kind, this.value, {this.person, this.trend});
  final _Kind kind;
  final String value;
  final UserListItem? person;
  final Trend? trend;
}

/// The search pill with its suggestions overlay (W4-14, `FEATURE_SEARCH`).
///
/// - Absent (`SizedBox.shrink`) while `search` is not in
///   `GetMe.enabled_features`; needs a [SearchRepository], a
///   [RecentSearchesStore] and the `OnboardingBloc` above it.
/// - Focus opens the overlay: "Recent" (with "Clear all") for an empty field;
///   while typing, "Search for ...", hashtag suggestions (needs `trends`) and
///   people. See `SearchSuggestionsCubit` for the call rules (300 ms debounce,
///   at least 2 characters).
/// - Enter, or a row, records the search and calls [onSubmitted]; the default
///   pushes `/search?q=` (W4-15 owns the screen). A person row calls
///   [onPersonSelected] (default: pushes the profile).
/// - Keyboard: Arrow Down / Up move through the rows, Enter picks, Escape
///   closes. The overlay is a floating panel under the pill as wide as it.
class AppSearchField extends StatefulWidget {
  const AppSearchField({
    super.key,
    this.onSubmitted,
    this.onPersonSelected,
    this.autofocus = false,
    this.initialText = '',
    this.debounce = kSuggestionsDebounce,
  });

  final SearchSubmitted? onSubmitted;
  final void Function(BuildContext context, UserListItem person)?
  onPersonSelected;
  final bool autofocus;

  /// Text to start with (the results screen shows the current query).
  final String initialText;
  final Duration debounce;

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _fieldKey = GlobalKey();
  late final TextEditingController _text = TextEditingController(
    text: widget.initialText,
  );
  late final FocusNode _focus = FocusNode()..addListener(_onFocus);
  SearchSuggestionsCubit? _cubit;
  int _active = -1;

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _text.dispose();
    _cubit?.close();
    super.dispose();
  }

  SearchSuggestionsCubit _ensureCubit() {
    final onboarding = context.read<OnboardingBloc>().state;
    final existing = _cubit;
    if (existing != null) return existing;
    final cubit = _cubit = SearchSuggestionsCubit(
      repository: context.read<SearchRepository>(),
      store: context.read<RecentSearchesStore>(),
      uid: onboarding.profile?.userId ?? '',
      trendsEnabled: onboarding.enabledFeatures.contains(kFeatureTrends),
      debounce: widget.debounce,
    );
    // Text the screen put in the field (the results page shows its own query)
    // is not typed: it asks nothing until the user edits it.
    if (_text.text != widget.initialText) cubit.textChanged(_text.text);
    return cubit;
  }

  void _onFocus() {
    if (_focus.hasFocus) {
      _ensureCubit().loadRecents();
      if (!_portal.isShowing) _portal.show();
    } else if (_portal.isShowing) {
      _portal.hide();
    }
    setState(() => _active = -1);
  }

  List<_Entry> _entries(SearchSuggestionsState s) {
    if (s.blank) {
      return [for (final r in s.recents) _Entry(_Kind.recent, r)];
    }
    final q = SearchQuery.parse(s.text);
    return [
      if (_submittable(q)) _Entry(_Kind.submit, q.canonical),
      for (final t in s.tags) _Entry(_Kind.tag, '#${t.tag}', trend: t),
      for (final p in s.people)
        _Entry(_Kind.person, '@${p.user.handle}', person: p),
    ];
  }

  /// A search the results screen can answer or explain; empty, invalid, too
  /// long and 1-character people queries stay in the box.
  static bool _submittable(SearchQuery q) =>
      q.isValid || q.issue == SearchQueryIssue.unsupported;

  void _submitText(String raw) {
    final q = SearchQuery.parse(raw);
    if (!_submittable(q)) return;
    _go(q.canonical);
  }

  void _go(String canonical) {
    if (SearchQuery.parse(canonical).isValid) _cubit?.remember(canonical);
    _text.value = TextEditingValue(
      text: canonical,
      selection: TextSelection.collapsed(offset: canonical.length),
    );
    _focus.unfocus();
    final callback = widget.onSubmitted;
    if (callback != null) {
      callback(context, canonical);
    } else {
      context.push(searchResultsLocation(canonical));
    }
  }

  void _activate(_Entry e) {
    if (e.kind != _Kind.person) {
      _go(e.value);
      return;
    }
    _cubit?.remember(e.value);
    _focus.unfocus();
    final callback = widget.onPersonSelected;
    if (callback != null) {
      callback(context, e.person!);
    } else {
      context.push(AppRouter.profilePath(e.person!.user.handle));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _focus.unfocus();
      return KeyEventResult.handled;
    }
    final cubit = _cubit;
    if (cubit == null) return KeyEventResult.ignored;
    final count = _entries(cubit.state).length;
    if (count == 0) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _active = (_active + 1) % count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _active = _active <= 0 ? count - 1 : _active - 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onSubmittedByKeyboard(String raw) {
    final cubit = _cubit;
    if (cubit != null && _active >= 0) {
      final entries = _entries(cubit.state);
      if (_active < entries.length) {
        _activate(entries[_active]);
        return;
      }
    }
    _submitText(raw);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = context.select<OnboardingBloc, bool>(
      (b) => b.state.enabledFeatures.contains(kFeatureSearch),
    );
    if (!enabled) return const SizedBox.shrink();
    final cubit = _ensureCubit();
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return BlocProvider.value(
      value: cubit,
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (_) => _panel(cubit),
          child: Focus(
            onKeyEvent: _onKey,
            child: Semantics(
              label: kSearchFieldLabel,
              child: TextField(
                key: _fieldKey,
                controller: _text,
                focusNode: _focus,
                autofocus: widget.autofocus,
                textInputAction: TextInputAction.search,
                onChanged: (t) {
                  _active = -1;
                  cubit.textChanged(t);
                },
                onSubmitted: _onSubmittedByKeyboard,
                style: Theme.of(context).textTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: 'Search',
                  isDense: true,
                  filled: false,
                  prefixIcon: Icon(
                    Icons.search,
                    size: AppIconSize.md,
                    color: colors.secondaryOnRaised,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: AppSpacing.xxl,
                    minHeight: AppSpacing.xxl,
                  ),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _text,
                    builder: (context, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.cancel, size: 20),
                            constraints: const BoxConstraints(
                              minWidth: AppSpacing.minTapTarget,
                              minHeight: AppSpacing.minTapTarget,
                            ),
                            onPressed: () {
                              _text.clear();
                              _active = -1;
                              cubit.textChanged('');
                              _focus.requestFocus();
                            },
                          ),
                  ),
                  border: _pillBorder(scheme.outlineVariant),
                  enabledBorder: _pillBorder(scheme.outlineVariant),
                  focusedBorder: _pillBorder(scheme.primary),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: AppSpacing.smd,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static OutlineInputBorder _pillBorder(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadius.pill),
    borderSide: BorderSide(color: color),
  );

  Widget _panel(SearchSuggestionsCubit cubit) {
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? AppSize.sideColumn;
    final height = box?.size.height ?? AppSpacing.xxl;
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        offset: Offset(0, height + AppSpacing.xs),
        child: TextFieldTapRegion(
          child: SizedBox(
            width: width,
            child: BlocBuilder<SearchSuggestionsCubit, SearchSuggestionsState>(
              bloc: cubit,
              builder: (context, state) => _Panel(
                state: state,
                entries: _entries(state),
                active: _active,
                onActivate: _activate,
                onClearAll: cubit.clearRecents,
                onRemove: cubit.removeRecent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.state,
    required this.entries,
    required this.active,
    required this.onActivate,
    required this.onClearAll,
    required this.onRemove,
  });

  final SearchSuggestionsState state;
  final List<_Entry> entries;
  final int active;
  final void Function(_Entry) onActivate;
  final VoidCallback onClearAll;
  final void Function(String) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final blank = state.blank;
    final height = MediaQuery.sizeOf(context).height;
    return Semantics(
      container: true,
      label: 'Search suggestions',
      child: Material(
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height * 0.6),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (blank) _recentHeader(context),
                if (blank && entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Text(
                      kSearchEmptyHint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.secondaryOnRaised,
                      ),
                    ),
                  ),
                for (var i = 0; i < entries.length; i++)
                  _row(context, entries[i], i == active),
                if (!blank && state.rateLimited)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Text(
                      kSearchRateLimitedHint,
                      key: const ValueKey('search-rate-limited-hint'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.secondaryOnRaised,
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

  Widget _recentHeader(BuildContext context) {
    if (state.recents.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'Recent',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: onClearAll,
            style: TextButton.styleFrom(
              minimumSize: const Size(
                AppSpacing.minTapTarget,
                AppSpacing.minTapTarget,
              ),
            ),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, _Entry e, bool highlighted) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: colors.secondaryOnRaised,
    );
    final bold = theme.textTheme.bodyLarge?.copyWith(
      fontWeight: FontWeight.w700,
    );
    final (String label, Widget lead, Widget body) = switch (e.kind) {
      _Kind.submit => (
        'Search for ${e.value}',
        const _LeadIcon(Icons.search),
        Text(
          'Search for "${e.value}"',
          style: bold,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      _Kind.recent => (
        'Recent search ${e.value}',
        const _LeadIcon(Icons.history),
        Text(
          e.value,
          style: bold,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      _Kind.tag => (
        'Hashtag ${e.value}, ${_postsText(e.trend!.postCount.toInt())}',
        const _LeadIcon(Icons.tag),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              e.value,
              style: bold,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              _postsText(e.trend!.postCount.toInt()),
              style: muted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      _Kind.person => (
        '${e.person!.user.displayName}, @${e.person!.user.handle}',
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: ExcludeSemantics(
            child: AppAvatar(url: e.person!.user.avatarUrl),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              e.person!.user.displayName,
              style: bold,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '@${e.person!.user.handle}',
              style: muted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    };
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: () => onActivate(e),
      child: Container(
        color: highlighted ? colors.selectedRow : null,
        child: InkWell(
          onTap: () => onActivate(e),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSpacing.xxl),
            child: Row(
              children: [
                lead,
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm,
                    ),
                    child: body,
                  ),
                ),
                if (e.kind == _Kind.recent)
                  IconButton(
                    tooltip: 'Remove ${e.value}',
                    icon: const Icon(Icons.close, size: 20),
                    constraints: const BoxConstraints(
                      minWidth: AppSpacing.minTapTarget,
                      minHeight: AppSpacing.minTapTarget,
                    ),
                    onPressed: () => onRemove(e.value),
                  )
                else
                  const SizedBox(width: AppSpacing.md),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _postsText(int n) =>
      n == 1 ? '1 post' : '${NumberFormat.compact().format(n)} posts';
}

class _LeadIcon extends StatelessWidget {
  const _LeadIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: AppSpacing.xxl + AppSpacing.sm,
    child: ExcludeSemantics(
      child: Icon(
        icon,
        size: AppIconSize.md,
        color: context.appColors.secondaryOnRaised,
      ),
    ),
  );
}
