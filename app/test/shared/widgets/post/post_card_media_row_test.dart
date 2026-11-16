import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

/// X-style media on a list card: media keeps the card's full body width (no
/// indent to a text column), and a several-images row scrolls to the screen's
/// edges on a phone while its first tile lines up with the body text.

pb.PostView _view(int images, {String text = 'Two photos.'}) {
  final view = postView(1, text: text);
  for (var i = 0; i < images; i++) {
    view.post.media.add(
      common.MediaRef(
        url: 'https://cdn.example/p$i.jpg',
        thumbUrl: 'https://cdn.example/p${i}_t.jpg',
        width: 900,
        height: 1600,
      ),
    );
  }
  return view;
}

Future<void> _pump(
  WidgetTester tester,
  pb.PostView view, {
  double width = 360,
}) async {
  await pumpThemed(
    tester,
    SingleChildScrollView(
      child: PostCard(view: view, graphActionsEnabled: false),
    ),
    size: Size(width, 1200),
  );
  expect(tester.takeException(), isNull);
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('on iOS the row keeps the left 20 dp free for the back swipe '
      'and bleeds to the right edge only', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await _pump(tester, _view(3));
    final list = tester.getRect(find.byType(ListView));
    expect(list.left, AppSize.iosBackSwipeEdge);
    expect(list.right, 360);
    // The first tile is still on the body text.
    final body = tester.getRect(find.byType(PostRichText));
    final first = tester.getRect(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(first.left, closeTo(body.left, 0.5));
    // A touch in the leftmost 20 dp is not the row's.
    final hit = tester.hitTestOnBinding(Offset(8, list.center.dy));
    expect(
      hit.path.where((e) => e.target is RenderSemanticsGestureHandler).length,
      1,
    );
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('a single image keeps the body width under the avatar', (
    tester,
  ) async {
    await _pump(tester, _view(1));
    final avatar = tester.getRect(find.byType(AppAvatar));
    final body = tester.getRect(find.byType(PostRichText));
    final frame = tester.getRect(
      find.descendant(
        of: find.byType(PostMedia),
        matching: find.byType(ClipRRect),
      ),
    );
    // Not indented to the text column: the image starts where the text does,
    // under the avatar, and reaches the card's right gutter.
    expect(frame.left, closeTo(avatar.left, 0.5));
    expect(frame.left, closeTo(body.left, 0.5));
    expect(frame.right, closeTo(360 - postCardGutter(360), 0.5));
  });

  testWidgets('several images: the row spans the card, the first tile is on '
      'the body text', (tester) async {
    await _pump(tester, _view(3));
    final body = tester.getRect(find.byType(PostRichText));
    final list = tester.getRect(find.byType(ListView));
    expect(list.left, 0);
    expect(list.right, 360);
    final first = tester.getRect(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(first.left, closeTo(body.left, 0.5));
    // The column's geometry is unchanged: the text still starts at the avatar.
    final avatar = tester.getRect(find.byType(AppAvatar));
    expect(body.left, closeTo(avatar.left, 0.5));
  });

  testWidgets('the gutter belongs to the row: a touch there hits the list, '
      'not the card', (tester) async {
    await _pump(tester, _view(3));
    final list = tester.getRect(find.byType(ListView));
    for (final x in [3.0, 357.0]) {
      final result = tester.hitTestOnBinding(Offset(x, list.center.dy));
      // The page's vertical scroller and the row's horizontal one: both are
      // under the touch, so a drag there scrolls the row.
      final scrollers = result.path
          .where((entry) => entry.target is RenderSemanticsGestureHandler)
          .length;
      expect(scrollers, 2, reason: 'a hit at x=$x reaches the row');
    }
  });

  testWidgets('the row is not stretched on tablet widths', (tester) async {
    await _pump(tester, _view(3), width: 700);
    final list = tester.getRect(find.byType(ListView));
    expect(list.left, greaterThan(0));
    expect(list.right, lessThan(700));
    expect(AppSize.postMediaRowGap, 4);
  });
}
