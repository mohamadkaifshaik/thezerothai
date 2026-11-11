import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/post/post_context_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

pb.PostView _view({bool repost = false}) => pb.PostView(
  post: repost
      ? pb.Post(
          postId: postId(2),
          kind: PostKind.POST_KIND_REPOST,
          author: common.AuthorSnapshot(userId: 'u2', handle: 'bob'),
          embedded: pb.EmbeddedPost(
            postId: postId(1),
            text: 'one line',
            author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
          ),
        )
      : pb.Post(
          postId: postId(1),
          text: 'one line',
          author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
        ),
);

/// List rows lose the padding
/// that doubled the whitespace already inside their 48dp tap boxes. Since the
/// R1 restyle the row follows the designs' `.post` (14 dp above the avatar
/// circle, 14 dp below the 36 dp action row): 136 dp for one line, with every
/// tap target still 48dp.
void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    required bool focal,
    bool withActions = true,
    bool repost = false,
  }) => pumpThemed(
    tester,
    RepositoryProvider<GraphRepository>.value(
      value: _MockGraphRepository(),
      child: SingleChildScrollView(
        child: PostCard(
          view: _view(repost: repost),
          focal: focal,
          graphActionsEnabled: false,
          actions: withActions
              ? PostActions(onReply: () {}, onLike: () {})
              : null,
        ),
      ),
    ),
    brightness: Brightness.dark,
    size: const Size(400, 800),
  );

  testWidgets('a one-line list row with actions is 136dp, targets 48dp', (
    tester,
  ) async {
    await pumpRow(tester, focal: false);

    // 11 top + 48 author row + 21 text + 48 action row + 8 bottom (R1: was
    // 8 + 48 + 20 + 48 + 0 = 124).
    expect(tester.getSize(find.byType(PostCard)).height, closeTo(136, 1));
    expect(
      tester.getSize(find.bySemanticsLabel('Like')).height,
      greaterThanOrEqualTo(AppSpacing.minTapTarget),
    );
    // The avatar circle starts 14dp down, as in the designs (R1: was 12).
    expect(
      tester.getTopLeft(find.byType(CircleAvatar)).dy -
          tester.getTopLeft(find.byType(PostCard)).dy,
      closeTo(14, 0.5),
    );
    expectNoOverflow(tester);
  });

  testWidgets('without actions: 11dp on top, 4 + 12dp below the text', (
    tester,
  ) async {
    await pumpRow(tester, focal: false, withActions: false);

    // 11 + 48 author row + 21 text + 4 spacer + 12 bottom (R1: was 8 top and
    // 92 in all).
    expect(tester.getSize(find.byType(PostCard)).height, closeTo(96, 1));
    expectNoOverflow(tester);
  });

  testWidgets('a repost label keeps the full 12dp above it', (tester) async {
    await pumpRow(tester, focal: false, repost: true);

    expect(
      tester.getTopLeft(find.byType(PostContextLabel)).dy -
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
