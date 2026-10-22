import 'package:dzeroth/shared/widgets/app_empty_view.dart';
import 'package:dzeroth/shared/widgets/post_list_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/theme_harness.dart';

/// W1-8: the skeleton reserves the card's footprint (avatar, padding, media
/// slots) and the empty state has an action slot.
void main() {
  forEachThemeAndWidth('skeleton rows reserve a 40dp avatar and media slots, '
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
    expect(tester.getSize(circles.first), const Size(40, 40));
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
}
