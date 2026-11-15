import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

common.MediaRef _image({String type = 'image/jpeg'}) => common.MediaRef(
  url: 'https://cdn.example/m/p.jpg',
  thumbUrl: 'https://cdn.example/m/p_t.jpg',
  width: 1600,
  height: 900,
  contentType: type,
);

pb.PostView _view(String text, {List<common.MediaRef> media = const []}) =>
    pb.PostView(
      post: pb.Post(
        postId: postId(1),
        text: text,
        media: media,
        author: common.AuthorSnapshot(
          userId: 'u1',
          handle: 'alice',
          displayName: 'Alice A',
        ),
      ),
    );

/// A post with pictures keeps its text to two lines with "... Show more"
/// inline at the end of the second; without media the 6-line clamp and the
/// "Show more" row below stay.
void main() {
  final long = List.generate(
    12,
    (i) => 'some words that make a line number ${i + 1} of the post',
  ).join(' ');

  Future<void> pumpCard(
    WidgetTester tester,
    pb.PostView view, {
    double width = 390,
    double textScale = 1,
  }) async {
    addTearDown(() => tester.takeException());
    await pumpThemed(
      tester,
      RepositoryProvider<GraphRepository>.value(
        value: _MockGraphRepository(),
        child: SingleChildScrollView(
          child: PostCard(view: view, graphActionsEnabled: false),
        ),
      ),
      size: Size(width, 900),
      textScale: textScale,
    );
  }

  Finder inlineText() => find.byWidgetPredicate(
    (w) =>
        w is RichText &&
        w.text
            .toPlainText(includeSemanticsLabels: false)
            .contains('… Show more'),
  );

  /// The height of a body of exactly two lines at this width and scale.
  Future<double> twoLines(
    WidgetTester tester, {
    double width = 390,
    double textScale = 1,
  }) async {
    await pumpCard(
      tester,
      _view('one\ntwo', media: [_image()]),
      width: width,
      textScale: textScale,
    );
    return tester
        .getSize(
          find.byWidgetPredicate(
            (w) =>
                w is RichText &&
                w.text.toPlainText(includeSemanticsLabels: false) == 'one\ntwo',
          ),
        )
        .height;
  }

  testWidgets('long text with an image: two lines, inline Show more', (
    tester,
  ) async {
    final two = await twoLines(tester);
    await pumpCard(tester, _view(long, media: [_image()]));

    expect(inlineText(), findsOneWidget);
    // No separate row below the text.
    expect(find.text('Show more'), findsNothing);
    expect(tester.getSize(inlineText()).height, closeTo(two, 0.01));
    // The text before the control is a prefix of the post.
    final plain = tester
        .widget<RichText>(inlineText())
        .text
        .toPlainText(includeSemanticsLabels: false);
    final prefix = plain.substring(0, plain.indexOf('…'));
    expect(long.startsWith(prefix), isTrue);
    expect(find.textContaining('number 12', findRichText: true), findsNothing);
  });

  testWidgets('the control is a labelled 48dp button that expands in place', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCard(tester, _view(long, media: [_image()]));

    final button = find.bySemanticsLabel('Show more');
    expect(button, findsOneWidget);
    expect(tester.getSemantics(button).flagsCollection.isButton, isTrue);
    final box = tester.getRect(
      find.byKey(const ValueKey('post-text-show-more')),
    );
    expect(box.height, greaterThanOrEqualTo(48));
    expect(box.width, greaterThanOrEqualTo(48));
    // The whole target is inside the block, so every part of it is hit.
    final block = tester.getRect(inlineText());
    expect(box.bottom, lessThanOrEqualTo(block.bottom + 8));
    final stack = tester.getRect(
      find
          .ancestor(
            of: find.byKey(const ValueKey('post-text-show-more')),
            matching: find.byType(Stack),
          )
          .first,
    );
    expect(stack.top, lessThanOrEqualTo(box.top));
    expect(stack.bottom, greaterThanOrEqualTo(box.bottom));

    await tester.tap(button);
    await tester.pump();

    expect(inlineText(), findsNothing);
    expect(
      find.textContaining('number 12', findRichText: true),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Show more'), findsNothing);
    handle.dispose();
  });

  testWidgets('tapping the words "Show more" expands too', (tester) async {
    await pumpCard(tester, _view(long, media: [_image()]));
    final rect = tester.getRect(inlineText());
    // The control sits at the end of the second (last) line.
    await tester.tapAt(Offset(rect.right - 20, rect.bottom - 8));
    await tester.pump();
    expect(inlineText(), findsNothing);
  });

  testWidgets('the target is at least 48dp and labelled (guidelines)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCard(tester, _view(long, media: [_image()]));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('a tap at the bottom edge of the target expands', (tester) async {
    await pumpCard(tester, _view(long, media: [_image()]));
    final box = tester.getRect(
      find.byKey(const ValueKey('post-text-show-more')),
    );
    // The part of the target below the second line still counts.
    await tester.tapAt(Offset(box.center.dx, box.bottom - 2));
    await tester.pump();
    expect(inlineText(), findsNothing);
  });

  testWidgets('a GIF counts as media', (tester) async {
    await pumpCard(tester, _view(long, media: [_image(type: 'image/gif')]));
    expect(inlineText(), findsOneWidget);
  });

  testWidgets('text that fits in two lines has no control', (tester) async {
    await pumpCard(tester, _view('one\ntwo', media: [_image()]));
    expect(inlineText(), findsNothing);
    expect(find.text('Show more'), findsNothing);
  });

  testWidgets('three lines with an image get the control', (tester) async {
    await pumpCard(tester, _view('one\ntwo\nthree', media: [_image()]));
    expect(inlineText(), findsOneWidget);
  });

  testWidgets('a large text scale still fits two lines', (tester) async {
    final two = await twoLines(tester, width: 320, textScale: 2);
    await pumpCard(
      tester,
      _view(long, media: [_image()]),
      width: 320,
      textScale: 2,
    );
    expect(inlineText(), findsOneWidget);
    expect(tester.getSize(inlineText()).height, closeTo(two, 0.01));
  });

  testWidgets('without media the six-line clamp and the row below stay', (
    tester,
  ) async {
    await pumpCard(tester, _view(long));
    expect(inlineText(), findsNothing);
    expect(find.text('Show more'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && w.maxLines == kPostTextClampLines,
      ),
      findsOneWidget,
    );
  });
}
