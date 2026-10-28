import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../graph/data/graph_repository.dart';

/// The server flag (`GetMe.enabled_features`) of W4's people search. The
/// picker asks a [PeopleSource] to search only while it is on for the caller;
/// W4 owns the flag, this is the one name the picker compares against.
const kPickerSearchFlag = 'search';

/// Where the new-message picker (W7-17) gets people from. The picker depends
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
  Future<GraphPage> page({required int pageSize, required String pageToken});

  /// True when [search] asks the server. The picker also needs the `search`
  /// flag ([kPickerSearchFlag]) before it calls it.
  bool get searchesRemotely;

  /// Typeahead rows for [query] (the picker sends it normalised, at least
  /// two characters, debounced). Only called when [searchesRemotely].
  Future<List<graph.UserListItem>> search(String query);
}

/// The people the caller follows (`GraphService.ListFollowing`, the existing
/// graph read row). No remote search.
class FollowingPeopleSource implements PeopleSource {
  const FollowingPeopleSource({
    required GraphRepository graphRepository,
    required this.userId,
  }) : _graph = graphRepository;

  final GraphRepository _graph;

  /// The caller's own user id.
  final String userId;

  @override
  Future<GraphPage> page({required int pageSize, required String pageToken}) =>
      _graph.listFollowing(
        userId: userId,
        pageSize: pageSize,
        pageToken: pageToken,
      );

  @override
  bool get searchesRemotely => false;

  @override
  Future<List<graph.UserListItem>> search(String query) async =>
      throw UnsupportedError('Following cannot search remotely');
}
