import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/data/suggestions_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:mocktail/mocktail.dart';

import 'fake_transport.dart';

class MockSuggestionsRepository extends Mock implements SuggestionsRepository {}

/// One suggested account, as `ListSuggestedUsers` returns it: `since` unset,
/// the caller's relationship to it (none unless asked).
graph.UserListItem suggestedUser(
  int i, {
  graph.FollowState follow = graph.FollowState.FOLLOW_STATE_NONE,
  bool blocking = false,
  bool muting = false,
  String? userId,
}) {
  final id = userId ?? 'u$i';
  return graph.UserListItem(
    user: common.AuthorSnapshot(
      userId: id,
      handle: 'user$i',
      displayName: 'User $i',
    ),
    relationship: graph.Relationship(
      userId: id,
      followState: follow,
      blocking: blocking,
      muting: muting,
    ),
  );
}

/// The real graph and suggestions repositories over an in-memory database and
/// a scripted transport, so a test counts the RPCs that really go out.
///
/// [onSuggestions] answers `ListSuggestedUsers` (default: [users]); throw a
/// `connect.ConnectException` to fail it. `Follow` answers FOLLOWING unless
/// [onFollow] throws. [clock] moves the repository's "now" (built from the real
/// clock, never a fixed date).
class SuggestionsRig {
  SuggestionsRig({
    List<graph.UserListItem>? users,
    this.onSuggestions,
    this.onFollow,
    AppDatabase? database,
    this.onUnexpectedError,
  }) : users = users ?? [for (var i = 1; i <= 5; i++) suggestedUser(i)],
       database = database ?? AppDatabase.forTesting(NativeDatabase.memory()) {
    transport = FakeTransport(_handle);
    apiClient = ApiClient.withTransport(transport);
    graphRepository = GraphRepository(
      apiClient: apiClient,
      database: this.database,
    );
    repository = newRepository();
  }

  final DateTime _base = DateTime.now();

  /// How far "now" has moved since the rig was built.
  Duration clock = Duration.zero;

  List<graph.UserListItem> users;
  Future<graph.ListSuggestedUsersResponse> Function()? onSuggestions;
  Future<graph.FollowResponse> Function(graph.FollowRequest request)? onFollow;
  void Function(Object error, StackTrace stack)? onUnexpectedError;

  final AppDatabase database;
  late final FakeTransport transport;
  late final ApiClient apiClient;
  late final GraphRepository graphRepository;
  late SuggestionsRepository repository;

  /// How many `ListSuggestedUsers` calls went out.
  int get suggestionCalls => transport.calledProcedures
      .where((p) => p.endsWith('/ListSuggestedUsers'))
      .length;

  /// The `maxResults` of every `ListSuggestedUsers` request, in order.
  final List<int> requestedMax = [];

  /// A new repository over the same database and transport: an app restart.
  SuggestionsRepository newRepository() => SuggestionsRepository(
    apiClient: apiClient,
    graphRepository: graphRepository,
    database: database,
    now: () => _base.add(clock),
    onUnexpectedError: (error, stack) => onUnexpectedError?.call(error, stack),
  );

  Future<Object> _handle(String procedure, Object input) async {
    if (procedure.endsWith('/ListSuggestedUsers')) {
      requestedMax.add((input as graph.ListSuggestedUsersRequest).maxResults);
      final custom = onSuggestions;
      if (custom != null) return custom();
      return graph.ListSuggestedUsersResponse(users: users);
    }
    if (procedure.endsWith('/Follow')) {
      final request = input as graph.FollowRequest;
      final custom = onFollow;
      if (custom != null) return custom(request);
      return graph.FollowResponse(
        relationship: graph.Relationship(
          userId: request.userId,
          followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
      );
    }
    throw UnimplementedError(procedure);
  }
}

/// An in-memory stand-in for widget tests that need no database: serves
/// [rows] (minus [hide]n ones) and counts [calls] of [suggestionsFor].
class FakeSuggestionsRepository implements SuggestionsRepository {
  FakeSuggestionsRepository(this.rows);

  List<graph.UserListItem> rows;
  final Set<String> hidden = {};
  final Set<String> dropped = {};
  int calls = 0;
  int clears = 0;

  @override
  Future<List<graph.UserListItem>> suggestionsFor(String uid) async {
    calls++;
    return current(uid);
  }

  @override
  List<graph.UserListItem> current(String uid) => [
    for (final row in rows)
      if (!hidden.contains(row.user.userId)) row,
  ];

  @override
  void hide(String uid, String userId) => hidden.add(userId);

  @override
  void drop(String uid, String userId) {
    dropped.add(userId);
    hidden.add(userId);
  }

  @override
  void clearSession() => clears++;
}
