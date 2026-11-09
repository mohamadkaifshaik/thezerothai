import 'package:dzeroth/features/messages/domain/people_source.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;

/// One Following row: `user<i>` / "User <i>" (tests).
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
  Future<PeoplePage> page({
    required int pageSize,
    required String pageToken,
  }) async {
    pageCalls++;
    return PeoplePage(items: people, nextPageToken: '');
  }

  @override
  Future<List<graph.UserListItem>> search(String query) async {
    searchCalls.add(query);
    return remoteResults;
  }
}
