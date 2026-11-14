import 'dart:async';

import 'package:dzeroth/features/search/data/search_repository.dart';

/// A scriptable [SearchRepository] for widget and bloc tests. Set the
/// `*Result` fields, or `error` to make every call throw; `calls` records
/// what was asked, in order (`people:ab`, `posts:go:SEARCH_TAB_TOP`,
/// `trends:`). Set a `*Gate` completer to hold an answer.
class FakeSearchRepository implements SearchRepository {
  /// How many times [clearSession] ran.
  int clears = 0;

  @override
  void clearSession() => clears++;

  SearchPeopleResult peopleResult = const SearchPeopleResult();
  SearchPostsPage postsResult = const SearchPostsPage();
  TrendsResult trendsResult = const TrendsResult();

  /// When set, answers `searchPosts` instead of [postsResult] (per query, tab
  /// and page token), so a test can script several hashtags and pages.
  SearchPostsPage Function(String query, SearchTab tab, String? pageToken)?
  postsHandler;

  /// Thrown by every call when set.
  Object? error;

  /// When set, the matching call waits for it before answering.
  Completer<void>? peopleGate;
  Completer<void>? postsGate;
  Completer<void>? trendsGate;

  final List<String> calls = [];
  final List<String> peopleQueries = [];
  final List<String?> postsPageTokens = [];

  @override
  Future<SearchPeopleResult> searchPeople(String query, {int limit = 5}) async {
    calls.add('people:$query');
    peopleQueries.add(query);
    await peopleGate?.future;
    final e = error;
    if (e != null) throw e;
    return peopleResult;
  }

  @override
  Future<SearchPostsPage> searchPosts(
    String query, {
    required SearchTab tab,
    String? pageToken,
    int pageSize = 20,
  }) async {
    calls.add('posts:$query:${tab.name}');
    postsPageTokens.add(pageToken);
    await postsGate?.future;
    final e = error;
    if (e != null) throw e;
    return postsHandler?.call(query, tab, pageToken) ?? postsResult;
  }

  @override
  Future<TrendsResult> getTrends({int limit = 10, String prefix = ''}) async {
    calls.add('trends:$prefix');
    await trendsGate?.future;
    final e = error;
    if (e != null) throw e;
    return trendsResult;
  }
}
