import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/posts_fixtures.dart';
import '../../support/theme_harness.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

pb.PostView _view(String text) => pb.PostView(
  post: pb.Post(
    postId: postId(1),
    text: text,
    author: common.AuthorSnapshot(
      userId: 'u1',
      handle: 'alice',
      displayName: 'Alice A',
    ),
  ),
);

/// W1-2: list cards clamp long text to [kPostTextClampLines] lines with an
/// in-place "Show more"; the detail view and short posts show everything.
void main() {
  final long = List.generate(12, (i) => 'line ${i + 1}').join('\n');

  Future<void> pumpCard(
    WidgetTester tester,
    MatrixEnv env,
    String text, {
    bool detail = false,
  }) => pumpThemed(
    tester,
    RepositoryProvider<GraphRepository>.value(
      value: _MockGraphRepository(),
      child: SingleChildScrollView(
        child: PostCard(
          view: _view(text),
          graphActionsEnabled: false,
          showFullImages: detail,
        ),
      ),
    ),
    brightness: env.brightness,
    size: env.size,
    textScale: env.textScale,
  );

  forEachThemeAndWidth('a long post is clamped and expands in place', (
    tester,
    env,
  ) async {
    await pumpCard(tester, env, long);

    expect(find.text('Show more'), findsOneWidget);
    final clamped = tester.widget<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && w.maxLines == kPostTextClampLines,
      ),
    );
    expect(clamped.maxLines, 6);

    await tester.tap(find.text('Show more'));
    await tester.pump();

    expect(find.text('Show more'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && w.maxLines == kPostTextClampLines,
      ),
      findsNothing,
    );
  });

  forEachThemeAndWidth('a short post has no control', (tester, env) async {
    await pumpCard(tester, env, 'one\ntwo\nthree');
    expect(find.text('Show more'), findsNothing);
  });

  forEachThemeAndWidth('the detail view shows all of a long post', (
    tester,
    env,
  ) async {
    await pumpCard(tester, env, long, detail: true);
    expect(find.text('Show more'), findsNothing);
  });

  testWidgets('Show more is a 48dp-high labelled button', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(
      tester,
      RepositoryProvider<GraphRepository>.value(
        value: _MockGraphRepository(),
        child: SingleChildScrollView(
          child: PostCard(view: _view(long), graphActionsEnabled: false),
        ),
      ),
      brightness: Brightness.light,
      size: const Size(360, 800),
    );

    expect(find.bySemanticsLabel('Show more'), findsOneWidget);
    final box = tester.getSize(
      find.ancestor(of: find.text('Show more'), matching: find.byType(InkWell)),
    );
    expect(box.height, greaterThanOrEqualTo(48));
    handle.dispose();
  });
}
