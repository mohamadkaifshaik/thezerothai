import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;

/// One page of the empty-query people list. [nextPageToken] is the opaque
/// cursor for the next page, empty on the last one.
class PeoplePage {
  const PeoplePage({required this.items, required this.nextPageToken});

  final List<graph.UserListItem> items;
  final String nextPageToken;

  bool get hasMore => nextPageToken.isNotEmpty;
}

/// The server flag (`GetMe.enabled_features`) of W4's people search. The
/// picker asks a [PeopleSource] to search only while it is on for the caller;
/// W4 owns the flag, this is the one name the picker compares against.
const kPickerSearchFlag = 'search';

/// Where the new-message picker gets people from. The picker depends
/// on this interface only, so W4's search is an optional second
/// implementation, not a dependency:
///
/// - [page] is the list shown for an empty query (the people the caller
///   follows), paged with opaque cursors.
/// - [searchesRemotely] / [search] are typeahead. A source that cannot search
///   (the Following source, today the only one) answers false and the picker
///   filters the rows it already loaded instead.
abstract interface class PeopleSource {
  /// One page of the empty-query list. [pageToken] is empty for the first.
  Future<PeoplePage> page({required int pageSize, required String pageToken});

  /// True when [search] asks the server. The picker also needs the `search`
  /// flag ([kPickerSearchFlag]) before it calls it.
  bool get searchesRemotely;

  /// Typeahead rows for [query] (the picker sends it normalised, at least
  /// two characters, debounced). Only called when [searchesRemotely].
  Future<List<graph.UserListItem>> search(String query);
}
