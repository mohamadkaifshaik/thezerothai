import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/thread_shell_rig.dart';

// PostThread from the dzeroth-mobile, tablet and desktop mocks: a
// self-thread is one chain of equal cards joined by the rail, the open post
// tinted, and the reply entry and other people's replies after the chain.
// Any other post keeps the post page (the open post large, the entry under
// it).

const _screenshots = bool.fromEnvironment('THREAD_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/thread/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

Finder _card(int n) => find.byWidgetPredicate(
  (w) => w is PostCard && w.view.post.postId == postId(n),
);

PostCard _cardOf(WidgetTester tester, int n) => tester.widget(_card(n));

Finder get _entry => find.text('Post your reply');

Finder get _highlight => find.byKey(const ValueKey('open-post-highlight'));

/// [selfThread] plus a reply from someone else to its last post.
List<pb.PostView> _withOthers() => [
  ...selfThread(),
  pb.PostView(
    post: pb.Post(
      postId: postId(9),
      text: 'Count me in.',
      author: kThreadAuthor.deepCopy()
        ..userId = 'u-sana'
        ..handle = 'sana.n'
        ..displayName = 'Sana',
      conversationId: postId(1),
      replyToPostId: postId(4),
      replyToHandle: kThreadAuthor.handle,
    ),
  ),
];

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('the root of a self-thread: one chain, entry after it', (
        tester,
      ) async {
        final rig = ThreadShellRig(thread: _withOthers());
        await rig.pump(tester, open: postId(1), size: size);
        expect(tester.takeException(), isNull);
        expect(find.text('Thread · 4 posts'), findsOneWidget);
        // Four equal cards: none is the large open-post card.
        for (var n = 1; n <= 4; n++) {
          expect(_card(n), findsOneWidget, reason: 'post $n');
          expect(_cardOf(tester, n).focal, isFalse, reason: 'post $n');
        }
        // The open post is the tinted one, and its Reply still answers it.
        expect(
          find.ancestor(of: _card(1), matching: _highlight),
          findsOneWidget,
        );
        expect(find.ancestor(of: _card(2), matching: _highlight), findsNothing);
        expect(_cardOf(tester, 1).onReply, isNotNull);
        // In order, then the entry, then someone else's reply.
        for (var n = 1; n < 4; n++) {
          expect(
            tester.getRect(_card(n)).top,
            lessThan(tester.getRect(_card(n + 1)).top),
          );
        }
        await tester.scrollUntilVisible(
          find.text('Count me in.'),
          200,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          tester.getRect(_entry).top,
          greaterThan(tester.getRect(_card(4)).bottom),
        );
        expect(
          tester.getRect(find.text('Count me in.')).top,
          greaterThan(tester.getRect(_entry).bottom),
        );
        expect(find.text('No replies yet'), findsNothing);
      });

      testWidgets('a middle post: its context, itself tinted, the rest', (
        tester,
      ) async {
        final rig = ThreadShellRig();
        await rig.pump(tester, open: postId(3), size: size);
        expect(find.text('Thread · 4 posts'), findsOneWidget);
        for (var n = 1; n <= 4; n++) {
          expect(_card(n), findsOneWidget, reason: 'post $n');
          expect(_cardOf(tester, n).focal, isFalse, reason: 'post $n');
        }
        expect(
          find.ancestor(of: _card(3), matching: _highlight),
          findsOneWidget,
        );
        expect(
          tester.getRect(_entry).top,
          greaterThan(tester.getRect(_card(4)).bottom),
        );
        expect(find.text('No replies yet'), findsNothing);
      });

      testWidgets('not a self-thread: the post page is unchanged', (
        tester,
      ) async {
        final others = _withOthers();
        final rig = ThreadShellRig(
          thread: [others.first, others.last]
            ..last.post.replyToPostId = postId(1),
        );
        await rig.pump(tester, open: postId(1), size: size);
        expect(find.textContaining('Thread ·'), findsNothing);
        expect(_cardOf(tester, 1).focal, isTrue);
        expect(_highlight, findsNothing);
        expect(
          tester.getRect(_entry).top,
          greaterThan(tester.getRect(_card(1)).bottom),
        );
        expect(
          tester.getRect(_entry).bottom,
          lessThan(tester.getRect(find.text('Count me in.')).top),
        );
      });

      testWidgets('tablet: no context pane beside the thread', (tester) async {
        final rig = ThreadShellRig();
        await rig.pump(tester, open: postId(1), size: size);
        // Desktop keeps its own side column (ruling R-1); phones have none.
        expect(find.byType(ContextPane), findsNothing);
      });

      testWidgets('text scale 2.0: nothing overflows', (tester) async {
        final rig = ThreadShellRig();
        await rig.pump(tester, open: postId(1), size: size, textScale: 2);
        expect(tester.takeException(), isNull);
      });
    });
  }

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        testWidgets('$name ${brightness.name}', (tester) async {
          final rig = ThreadShellRig();
          await rig.pump(
            tester,
            open: postId(1),
            size: size,
            brightness: brightness,
          );
          expect(rig.router.state.uri.path, AppRouter.postPath(postId(1)));
          await _capture(tester, '$name-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });
}
