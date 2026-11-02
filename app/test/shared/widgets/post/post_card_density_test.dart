import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

pb.PostView _view() => pb.PostView(
  post: pb.Post(
    postId: postId(1),
    text: 'one line',
    author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
  ),
);

/// PD-2 (`docs/plans/ui-w15-post-detail.md`): list rows lose the padding
/// that doubled the whitespace already inside their 48dp tap boxes. X's
/// one-line row is about 99dp; ours goes from 148 to 124 with every tap
/// target still 48dp.
void main() {
  Future<void> pumpRow(WidgetTester tester, {required bool focal}) =>
      pumpThemed(
        tester,
        RepositoryProvider<GraphRepository>.value(
          value: _MockGraphRepository(),
          child: SingleChildScrollView(
            child: PostCard(
              view: _view(),
              focal: focal,
              graphActionsEnabled: false,
              actions: PostActions(onReply: () {}, onLike: () {}),
            ),
          ),
        ),
        brightness: Brightness.dark,
        size: const Size(400, 800),
      );

  testWidgets('a one-line list row with actions is 124dp, targets 48dp', (
    tester,
  ) async {
    await pumpRow(tester, focal: false);

    // 8 top + 48 author row + 20 text + 48 action row, no bottom padding.
    expect(tester.getSize(find.byType(PostCard)).height, closeTo(124, 1));
    expect(
      tester.getSize(find.bySemanticsLabel('Like')).height,
      greaterThanOrEqualTo(AppSpacing.minTapTarget),
    );
    // The avatar circle still starts 12dp down, as on X.
    expect(
      tester.getTopLeft(find.byType(CircleAvatar)).dy -
          tester.getTopLeft(find.byType(PostCard)).dy,
      closeTo(AppSpacing.smd, 0.5),
    );
    expectNoOverflow(tester);
  });

  testWidgets('the open post keeps its 12dp padding', (tester) async {
    await pumpRow(tester, focal: true);

    final card = tester.getRect(find.byType(PostCard));
    final bar = tester.getRect(find.byType(PostActionBar));
    expect(card.bottom - bar.bottom, closeTo(AppSpacing.smd, 0.5));
  });
}
