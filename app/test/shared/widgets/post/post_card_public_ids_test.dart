import 'package:dzeroth/core/session/user_ids.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../../support/posts_fixtures.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

const _firebaseUid = 'q7Zk3mV9aXb2LcD8eF1gH4iJ5kL6';
const _publicId = 'u0abcdefghijklmnopqrstuvw2';
final _now = DateTime.utc(2026, 5, 1, 12);

pb.PostView _view(String authorId) => pb.PostView(
  post: pb.Post(
    postId: postId(7),
    text: 'hello world',
    author: common.AuthorSnapshot(
      userId: authorId,
      handle: 'alice',
      displayName: 'Alice A',
    ),
    createdAt: Timestamp.fromDateTime(
      _now.subtract(const Duration(minutes: 5)),
    ),
  ),
);

OnboardingState _session(String id, {bool flagsPending = false}) =>
    OnboardingState(
      status: OnboardingStatus.ready,
      profile: identity.Profile(userId: id, handle: 'me'),
      flagsPending: flagsPending,
    );

/// "Own post shows Delete" with the viewer id read the way the screens read
/// it (`OnboardingState.myUserId`), in both `public_ids` states.
void main() {
  late _MockGraphRepository graph;

  setUp(() {
    graph = _MockGraphRepository();
    when(() => graph.cached(any())).thenReturn(null);
  });

  Future<void> open(
    WidgetTester tester,
    OnboardingState session,
    String authorId,
  ) async {
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: graph,
        child: MaterialApp(
          theme: appLightTheme,
          home: Scaffold(
            body: PostCard(
              view: _view(authorId),
              viewerUserId: session.myUserId,
              now: _now,
              onDelete: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
  }

  testWidgets('public_ids off: own post (Firebase uid) offers Delete', (
    tester,
  ) async {
    await open(tester, _session(_firebaseUid), _firebaseUid);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Block @alice'), findsNothing);
  });

  testWidgets('public_ids on: own post (public id) offers Delete', (
    tester,
  ) async {
    await open(tester, _session(_publicId), _publicId);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Block @alice'), findsNothing);
  });

  testWidgets('another author is not me in either id kind', (tester) async {
    await open(tester, _session(_publicId), 'u1abcdefghijklmnopqrstuvw3');
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Block @alice'), findsOneWidget);
  });

  testWidgets('before GetMe answered: nothing is mine', (tester) async {
    await open(tester, _session(_publicId, flagsPending: true), _publicId);
    expect(find.text('Delete'), findsNothing);
  });
}
