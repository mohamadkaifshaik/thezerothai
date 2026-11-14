import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_empty_view.dart';
import 'package:dzeroth/shared/widgets/post/post_list_skeleton.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart'
    show kPostAvatarInset, postCardGutter;
import 'package:dzeroth/shared/widgets/primitives/app_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

/// The skeleton reserves the card's footprint (avatar, padding, media
/// slots) and the empty state has an action slot.
Rect _rectOf(Element e) {
  final box = e.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

void main() {
  forEachThemeAndWidth('skeleton rows reserve a 42dp avatar and media slots, '
      'without overflow', (tester, env) async {
    await pumpThemed(
      tester,
      const SingleChildScrollView(child: PostListSkeleton(rows: 5)),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );

    final circles = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle,
    );
    expect(circles, findsNWidgets(5));
    // The card's 42 dp post avatar (R1 restyle; was 40).
    expect(
      tester.getSize(circles.first),
      const Size.square(AppSize.avatarPost),
    );
    // Rows 2 and 5 (index 1, 4) carry a 16:9 media slot.
    expect(find.byType(AspectRatio), findsNWidgets(2));
    final media = tester.getSize(find.byType(AspectRatio).first);
    expect(media.width / media.height, closeTo(16 / 9, 0.01));
  });

  testWidgets('mediaEvery: 0 reserves no media slot', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PostListSkeleton(rows: 4, mediaEvery: 0)),
      ),
    );
    expect(find.byType(AspectRatio), findsNothing);
  });

  testWidgets('a bounded parent clips the skeleton instead of overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(height: 120, child: PostListSkeleton(rows: 5)),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the skeleton is announced once', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PostListSkeleton(semanticsLabel: 'Loading things'),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Loading things'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('AppEmptyView shows its action under the text', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppEmptyView(
            icon: Icons.dynamic_feed_outlined,
            title: 'Nothing here',
            subtitle: 'Yet.',
            action: TextButton(
              onPressed: () => taps++,
              child: const Text('Do it'),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getTopLeft(find.text('Do it')).dy,
      greaterThan(tester.getTopLeft(find.text('Yet.')).dy),
    );
    await tester.tap(find.text('Do it'));
    expect(taps, 1);
  });

  group('feed card geometry (#936)', () {
    Finder blocks() => find.byType(AppSkeletonBlock);

    for (final width in const [360.0, 600.0, 1200.0]) {
      testWidgets('at $width the body starts at the avatar edge, full width', (
        tester,
      ) async {
        await pumpThemed(
          tester,
          const PostListSkeleton(rows: 2, mediaEvery: 2),
          size: Size(width, 1200),
        );
        final all = [for (final e in blocks().evaluate()) _rectOf(e)];
        // First row: avatar, 2 name bars, 3 body bars.
        final avatar = all[0];
        final nameBars = all.sublist(1, 3);
        final bodyBars = all.sublist(3, 6);
        final gutter = postCardGutter(width);
        final contentLeft = gutter + kPostAvatarInset;
        final contentWidth = width - contentLeft - gutter;
        expect(avatar.left, closeTo(contentLeft, 0.5));
        expect(avatar.width, AppSize.avatarPost);
        for (final bar in nameBars) {
          expect(bar.left, greaterThan(avatar.right));
          expect(bar.center.dy, lessThan(avatar.bottom + 8));
        }
        for (final bar in bodyBars) {
          expect(bar.left, closeTo(avatar.left, 0.5));
          expect(bar.top, greaterThan(avatar.bottom - 0.5));
        }
        expect(bodyBars[0].width, closeTo(contentWidth, 0.5));
        expect(bodyBars[1].width, closeTo(contentWidth, 0.5));
        expect(bodyBars[2].width, closeTo(contentWidth * 0.7, 0.5));
        // The media slot of row two: same left edge, full width.
        final media = tester.getRect(find.byType(AspectRatio));
        expect(media.left, closeTo(avatar.left, 0.5));
        expect(media.width, closeTo(contentWidth, 0.5));
      });
    }

    testWidgets('indentBody keeps the old two-column layout', (tester) async {
      await pumpThemed(
        tester,
        const PostListSkeleton(rows: 1, indentBody: true),
        size: const Size(360, 800),
      );
      final all = [for (final e in blocks().evaluate()) _rectOf(e)];
      // The avatar, then every bar in the column to its right.
      final circle = tester.getRect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).shape == BoxShape.circle,
        ),
      );
      for (final r in all.where((r) => r != circle)) {
        expect(r.left, greaterThan(circle.right));
      }
    });
  });
}
