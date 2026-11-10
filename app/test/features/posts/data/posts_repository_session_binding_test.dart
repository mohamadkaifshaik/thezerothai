import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/session_tokens.dart';

/// A CreatePost a screen started for account A, carrying A's text, can never
/// reach the network under account B (the real ApiClient interceptor chain).
void main() {
  late AppDatabase db;
  late String? session;
  late ScriptedAuthTokens auth;
  late RecordingHttp http;
  late PostsRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    session = null;
    auth = ScriptedAuthTokens();
    http = RecordingHttp(
      respond: (_) =>
          protoOk(pb.CreatePostResponse(post: postView(9, authorId: 'uid-a'))),
    );
    repo = PostsRepository(
      apiClient: ApiClient(
        baseUrl: 'https://api.example.test',
        authTokens: auth,
        appCheckTokens: ScriptedAppCheck(),
        sessionUid: () => session,
        httpClient: http.client,
      ),
      store: TimelineStore(db),
      gate: PostsFeatureGate(isPostsEnabled: () => true),
    );
  });

  tearDown(() => db.close());

  Future<Object?> create() => repo
      .createPost(idempotencyKey: 'k1', text: 'written by A')
      .then<Object?>((v) => v, onError: (Object e) => e);

  test('started under A, account switched to B before the token: the '
      'transport never sees it', () async {
    session = 'uid-a';
    final result = create();
    session = 'uid-b';
    auth.complete(idTokenFor('uid-b'));

    expect(await result, isA<UnauthenticatedException>());
    expect(http.sent, isEmpty);
  });

  test('started and finished under A: sent with A\'s token', () async {
    session = 'uid-a';
    final result = create();
    auth.complete(idTokenFor('uid-a'));

    expect(await result, isA<pb.PostView>());
    expect(http.sent, hasLength(1));
    expect(http.bearerOf(0), 'Bearer ${idTokenFor('uid-a')}');
  });
}
