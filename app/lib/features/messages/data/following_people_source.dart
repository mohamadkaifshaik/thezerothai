import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../graph/data/graph_repository.dart';
import '../domain/people_source.dart';

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
  Future<PeoplePage> page({
    required int pageSize,
    required String pageToken,
  }) async {
    final page = await _graph.listFollowing(
      userId: userId,
      pageSize: pageSize,
      pageToken: pageToken,
    );
    return PeoplePage(items: page.items, nextPageToken: page.nextPageToken);
  }

  @override
  bool get searchesRemotely => false;

  @override
  Future<List<graph.UserListItem>> search(String query) async =>
      throw UnsupportedError('Following cannot search remotely');
}
