import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

/// The overflow menu must not block the feed: a drag on the list scrolls it
/// and closes the menu (it used to be a modal popup whose barrier ate drags).
void main() {
  testWidgets('an open post menu does not freeze the feed: a drag scrolls it '
      'and closes the menu', (tester) async {
    final graphRepository = _MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: graphRepository,
        child: MaterialApp(
          theme: buildAppTheme(brightness: Brightness.light),
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemCount: 20,
              itemBuilder: (_, i) => PostCard(
                view: pb.PostView(
                  post: pb.Post(
                    postId: postId(i + 1),
                    text: 'post $i',
                    author: common.AuthorSnapshot(
                      userId: 'me',
                      handle: 'me',
                      displayName: 'Me',
                    ),
                  ),
                ),
                viewerUserId: 'me',
                graphActionsEnabled: true,
                reportsEnabled: false,
                onDelete: (_) async {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('More options').first);
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);
    expect(controller.offset, 0);

    // A drag anywhere on the feed, not a tap on a barrier.
    await tester.drag(find.text('post 3'), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(100));
    expect(find.text('Delete'), findsNothing);
  });
}
