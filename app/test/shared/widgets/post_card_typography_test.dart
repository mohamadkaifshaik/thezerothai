import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/geometry.dart';
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

/// W0-2 acceptance: the post body is X's 15dp on a 20dp line pitch, in both
/// themes, and nothing overflows at text scale 1.3.
void main() {
  Future<void> pumpCard(WidgetTester tester, MatrixEnv env, String text) =>
      pumpThemed(
        tester,
        RepositoryProvider<GraphRepository>.value(
          value: _MockGraphRepository(),
          child: SingleChildScrollView(
            child: PostCard(view: _view(text), graphActionsEnabled: false),
          ),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );

  forEachThemeAndWidth(
    'post body line pitch is 20dp at scale 1.0 and nothing overflows',
    (tester, env) async {
      await pumpCard(tester, env, 'one\ntwo\nthree');

      final height = tester.getSize(find.byType(PostRichText)).height;
      final pitch = height / 3;
      // 15dp x 1.33 = 19.95dp per line, times the text scale.
      expect(pitch, closeTo(19.95 * env.textScale, 1.0));
      expectNoOverflow(tester);
    },
    textScales: const [1.0, 1.3],
  );

  testWidgets('the body style is the theme bodyLarge (15 / 1.33)', (
    tester,
  ) async {
    await pumpCard(
      tester,
      const MatrixEnv(
        brightness: Brightness.light,
        size: Size(400, 800),
        textScale: 1,
      ),
      'hello',
    );
    final style = tester.widget<PostRichText>(find.byType(PostRichText)).style!;
    expect(style.fontSize, 15);
    expect(style.height, closeTo(1.33, 0.001));
    expect(AppIconSize.action, 16);
  });
}
