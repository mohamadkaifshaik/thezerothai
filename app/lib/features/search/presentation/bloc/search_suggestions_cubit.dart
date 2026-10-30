import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/recent_searches_store.dart';
import '../../data/search_repository.dart';
import '../../domain/search_query.dart';

/// Typeahead waits this long after the last keystroke (client rule: 300 ms).
const kSuggestionsDebounce = Duration(milliseconds: 300);

/// Hashtag suggestions shown under the field.
const kSuggestionTagLimit = 3;

/// People rows shown under the field (the server caps at 20; five fit).
const kSuggestionPeopleLimit = 5;

/// What the suggestions overlay shows.
@immutable
class SearchSuggestionsState {
  const SearchSuggestionsState({
    this.text = '',
    this.recents = const [],
    this.people = const [],
    this.tags = const [],
    this.rateLimited = false,
    this.peopleOff = false,
    this.tagsOff = false,
  });

  /// The raw text of the field.
  final String text;

  /// Recent searches, newest first (shown while [text] is blank).
  final List<String> recents;

  /// People for the current text; empty when none was asked or none matched.
  final List<UserListItem> people;

  /// Hashtag suggestions for the current text.
  final List<Trend> tags;

  /// The last typeahead call was RATE_LIMITED: a quiet inline hint, the
  /// "Search for" row still works.
  final bool rateLimited;

  /// The server said search / trends is off: no more calls this session.
  final bool peopleOff;
  final bool tagsOff;

  bool get blank => text.trim().isEmpty;

  SearchSuggestionsState copyWith({
    String? text,
    List<String>? recents,
    List<UserListItem>? people,
    List<Trend>? tags,
    bool? rateLimited,
    bool? peopleOff,
    bool? tagsOff,
  }) => SearchSuggestionsState(
    text: text ?? this.text,
    recents: recents ?? this.recents,
    people: people ?? this.people,
    tags: tags ?? this.tags,
    rateLimited: rateLimited ?? this.rateLimited,
    peopleOff: peopleOff ?? this.peopleOff,
    tagsOff: tagsOff ?? this.tagsOff,
  );
}

/// Drives the search field's overlay (W4-14): recents from the local store,
/// debounced people and hashtag suggestions. Depends on [SearchRepository]
/// and [RecentSearchesStore] only.
///
/// - No call under [SearchQuery.minLength] characters, none when the parse
///   says people are not searched (a `#tag`, `peopleTooShort`, a phrase).
/// - One timer: only the last keystroke of a burst calls (`a`, `ab` => one
///   SearchPeople). An answer for older text is dropped (the call itself
///   cannot be cancelled on the wire).
/// - Hashtag suggestions need [trendsEnabled]; no GetTrends call otherwise.
/// - A failure never breaks the field: RATE_LIMITED shows a quiet hint,
///   FEATURE_DISABLED stops that source for the session, anything else shows
///   nothing. Nothing here logs the query.
class SearchSuggestionsCubit extends Cubit<SearchSuggestionsState> {
  SearchSuggestionsCubit({
    required SearchRepository repository,
    required RecentSearchesStore store,
    required this.uid,
    required this.trendsEnabled,
    this.debounce = kSuggestionsDebounce,
  }) : _repository = repository,
       _store = store,
       super(const SearchSuggestionsState());

  final SearchRepository _repository;
  final RecentSearchesStore _store;
  final String uid;
  final bool trendsEnabled;
  final Duration debounce;

  Timer? _timer;
  int _generation = 0;

  /// The field gained focus: read the recents (0 RPCs).
  Future<void> loadRecents() async {
    final recents = await _store.read(uid);
    if (!isClosed) emit(state.copyWith(recents: recents));
  }

  /// The text changed.
  void textChanged(String text) {
    _timer?.cancel();
    final generation = ++_generation;
    emit(
      state.copyWith(
        text: text,
        people: const [],
        tags: const [],
        rateLimited: false,
      ),
    );
    final query = SearchQuery.parse(text);
    final people = !state.peopleOff && _longEnough(query.peopleQuery);
    final tags = trendsEnabled && !state.tagsOff && _longEnough(query.tagBody);
    if (!people && !tags) return;
    _timer = Timer(debounce, () {
      if (people) unawaited(_people(query.peopleQuery!, generation));
      if (tags) unawaited(_tags(query.tagBody!, generation));
    });
  }

  bool _longEnough(String? part) =>
      part != null && part.runes.length >= SearchQuery.minLength;

  Future<void> _people(String q, int generation) async {
    try {
      final result = await _repository.searchPeople(
        q,
        limit: kSuggestionPeopleLimit,
      );
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(people: result.users));
    } on Object catch (error) {
      if (isClosed || generation != _generation) return;
      _failed(error, people: true);
    }
  }

  Future<void> _tags(String q, int generation) async {
    try {
      final result = await _repository.getTrends(
        limit: kSuggestionTagLimit,
        prefix: q,
      );
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(tags: result.trends));
    } on Object catch (error) {
      if (isClosed || generation != _generation) return;
      _failed(error, people: false);
    }
  }

  void _failed(Object error, {required bool people}) {
    if (error is SearchRateLimitedException) {
      emit(state.copyWith(rateLimited: true));
    } else if (error is SearchUnavailableException) {
      emit(
        people
            ? state.copyWith(peopleOff: true)
            : state.copyWith(tagsOff: true),
      );
    }
    // Any other failure (network, validation): no suggestions, no noise.
  }

  /// Puts [canonical] first in the recents. A `SearchQuery.canonical` string.
  Future<void> remember(String canonical) async {
    await _store.add(uid, canonical);
    if (!isClosed) emit(state.copyWith(recents: await _store.read(uid)));
  }

  Future<void> removeRecent(String query) async {
    await _store.remove(uid, query);
    if (!isClosed) emit(state.copyWith(recents: await _store.read(uid)));
  }

  Future<void> clearRecents() async {
    await _store.clear(uid);
    if (!isClosed) emit(state.copyWith(recents: const []));
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
