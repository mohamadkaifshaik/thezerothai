import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/domain/people_source.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;

/// One Following row: `user<i>` / "User <i>" (W7-17 tests).
graph.UserListItem person(int i, {String? handle, String? name}) =>
    graph.UserListItem(
      user: common.AuthorSnapshot(
        userId: 'u$i',
        handle: handle ?? 'user$i',
        displayName: name ?? 'User $i',
      ),
    );

/// A [PeopleSource] over a fixed list that counts what the picker asks for.
class FakePeopleSource implements PeopleSource {
  FakePeopleSource({
    this.people = const [],
    this.searchesRemotely = false,
    this.remoteResults = const [],
  });

  final List<graph.UserListItem> people;
  final List<graph.UserListItem> remoteResults;

  @override
  final bool searchesRemotely;

  /// Every normalised query [search] received.
  final List<String> searchCalls = [];
  int pageCalls = 0;

  @override
  Future<GraphPage> page({
    required int pageSize,
    required String pageToken,
  }) async {
    pageCalls++;
    return GraphPage(items: people, nextPageToken: '');
  }

  @override
  Future<List<graph.UserListItem>> search(String query) async {
    searchCalls.add(query);
    return remoteResults;
  }
}
