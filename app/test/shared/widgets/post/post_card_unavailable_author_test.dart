import 'package:dzeroth/core/session/user_ids.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../../support/posts_fixtures.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

final _now = DateTime.utc(2026, 5, 1, 12);

pb.PostView _view({String handle = '', String name = ''}) => pb.PostView(
  post: pb.Post(
    postId: postId(7),
    text: 'still here',
    author: common.AuthorSnapshot(
      userId: kUnavailableUserId,
      handle: handle,
      displayName: name,
    ),
    createdAt: Timestamp.fromDateTime(_now.subtract(const Duration(minutes: 5))),
  ),
);

/// A post whose author is gone (the tombstone id): the author is not
/// openable, reads "Deleted account" without a name of its own, and offers no
/// follow, block or mute.
void main() {
  late _MockGraphRepository graph;

  setUp(() {
    graph = _MockGraphRepository();
    when(() => graph.cached(any())).thenReturn(null);
  });

  Future<List<String>> open(WidgetTester tester, pb.PostView view) async {
    final opened = <String>[];
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: graph,
        child: MaterialApp(
          theme: appLightTheme,
          home: Scaffold(
            body: PostCard(
              view: view,
              viewerUserId: 'u0abcdefghijklmnopqrstuvw2',
              now: _now,
              onOpenProfile: opened.add,
            ),
          ),
        ),
      ),
    );
    return opened;
  }

  testWidgets('without a name it reads "Deleted account", no stray @', (
    tester,
  ) async {
    await open(tester, _view());
    expect(find.text(kUnavailableAccountName), findsOneWidget);
    expect(find.text('@'), findsNothing);
  });

  testWidgets('tapping the avatar or the name opens nothing', (tester) async {
    final opened = await open(tester, _view(handle: 'ghost', name: 'Ghost'));

    await tester.tap(find.text('Ghost'));
    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pump();

    expect(opened, isEmpty);
  });

  testWidgets('the menu offers no Block or Mute for the gone author', (
    tester,
  ) async {
    await open(tester, _view(handle: 'ghost', name: 'Ghost'));

    final more = find.byTooltip('More options');
    if (more.evaluate().isNotEmpty) {
      await tester.tap(more);
      await tester.pumpAndSettle();
    }

    expect(find.textContaining('Block'), findsNothing);
    expect(find.textContaining('Mute'), findsNothing);
    expect(find.textContaining('Follow'), findsNothing);
  });

  testWidgets('a real author is still opened by a tap on the name', (
    tester,
  ) async {
    final view = _view(handle: 'alice', name: 'Alice');
    view.post.author.userId = 'u1abcdefghijklmnopqrstuvw3';
    final opened = await open(tester, view);

    await tester.tap(find.text('Alice'));
    await tester.pump();

    expect(opened, ['u1abcdefghijklmnopqrstuvw3']);
  });
}
