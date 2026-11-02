import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/format/relative_time.dart';
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../support/geometry.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

final _created = DateTime.utc(2026, 11, 1, 15, 41);

pb.PostView _view(String text) => pb.PostView(
  post: pb.Post(
    postId: postId(1),
    text: text,
    createdAt: ts.Timestamp.fromDateTime(_created),
    author: common.AuthorSnapshot(
      userId: 'u1',
      handle: 'alice',
      displayName: 'Alice A',
    ),
  ),
);

/// The open post of a thread laid out like X's post page (captured
/// 2026-11-02, `docs/plans/ui-w15-post-detail.md` PD-1).
void main() {
  Future<void> pumpCard(
    WidgetTester tester,
    MatrixEnv env,
    String text, {
    bool focal = true,
    PostActions? actions,
  }) => pumpThemed(
    tester,
    RepositoryProvider<GraphRepository>.value(
      value: _MockGraphRepository(),
      child: SingleChildScrollView(
        child: PostCard(
          view: _view(text),
          focal: focal,
          graphActionsEnabled: false,
          now: _created.add(const Duration(hours: 22)),
          actions: actions,
        ),
      ),
    ),
    brightness: env.brightness,
    size: env.size,
    textScale: env.textScale,
  );

  const phone = MatrixEnv(
    brightness: Brightness.dark,
    size: Size(400, 800),
    textScale: 1,
  );

  forEachThemeAndWidth('focal layout never overflows', (tester, env) async {
    await pumpCard(
      tester,
      env,
      'a long focal post ' * 20,
      actions: PostActions(onReply: () {}, onLike: () {}, onShare: () {}),
    );
    expectNoOverflow(tester);
  }, textScales: const [1.0, 1.3, 2.0]);

  testWidgets('name over handle, no relative time, full time below', (
    tester,
  ) async {
    await pumpCard(tester, phone, 'hello');

    expect(find.text('22h'), findsNothing);
    expect(
      tester.getTopLeft(find.text('@alice')).dy,
      greaterThan(tester.getTopLeft(find.text('Alice A')).dy),
    );
    final stamp = find.text(formatPostTimestamp(_created));
    expect(stamp, findsOneWidget);
    expect(
      tester.getTopLeft(stamp).dy,
      greaterThan(tester.getTopLeft(find.byType(PostRichText)).dy),
    );
  });

  testWidgets('text runs the full width in the focal type, unclamped', (
    tester,
  ) async {
    await pumpCard(tester, phone, List.filled(12, 'line').join('\n'));

    final text = tester.widget<PostRichText>(find.byType(PostRichText));
    expect(text.style!.fontSize, AppFocalPost.bodySize);
    expect(
      text.style!.height! * text.style!.fontSize!,
      closeTo(AppFocalPost.bodyLineHeight, 0.01),
    );
    expect(text.maxLines, isNull);
    // Starts at the card's left padding, under the avatar, not beside it.
    expect(tester.getTopLeft(find.byType(PostRichText)).dx, AppSpacing.md);
  });

  testWidgets('the action row is spread with larger glyphs', (tester) async {
    await pumpCard(
      tester,
      phone,
      'hello',
      actions: PostActions(onReply: () {}, onLike: () {}, onShare: () {}),
    );

    final bar = tester.widget<PostActionBar>(find.byType(PostActionBar));
    expect(bar.spread, isTrue);
    expect(bar.iconSize, AppFocalPost.actionIcon);
    expect(
      tester.getTopRight(find.byIcon(Icons.ios_share)).dx,
      closeTo(phone.size.width - AppSpacing.md, 1),
    );
  });

  testWidgets('list rows keep the one-line author and the relative time', (
    tester,
  ) async {
    await pumpCard(tester, phone, 'hello', focal: false);

    expect(find.text('22h'), findsOneWidget);
    expect(find.text(formatPostTimestamp(_created)), findsNothing);
    expect(
      tester.getTopLeft(find.text('@alice')).dy,
      closeTo(tester.getTopLeft(find.text('Alice A')).dy, 2),
    );
  });
}
