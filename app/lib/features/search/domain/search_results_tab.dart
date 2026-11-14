import 'search_query.dart';

/// The tabs of the results screen `/search`, in display order.
enum SearchResultsTab {
  top('Top'),
  latest('Latest'),
  people('People'),
  media('Media'),

  /// Lists by name prefix (`search_lists` and `lists`).
  lists('Lists'),

  /// Communities by name prefix (`search_lists` and `communities`).
  communities('Communities');

  const SearchResultsTab(this.label);

  final String label;

  /// The `tab=` value of the URL.
  String get queryValue => name;

  /// The tab a `/search?tab=<value>` link names, or the default for [query]
  /// when the value is missing or unknown: People for an `@handle` query,
  /// Top otherwise.
  static SearchResultsTab fromQuery(String? value, {String query = ''}) {
    for (final tab in values) {
      if (tab.name == value) return tab;
    }
    return SearchQuery.parse(query).kind == SearchQueryKind.handle
        ? people
        : top;
  }
}
