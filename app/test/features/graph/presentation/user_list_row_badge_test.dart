import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:dzeroth/shared/widgets/protected_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../../support/geometry.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/suggestions_fixtures.dart' show suggestedUser;
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

/// W3-33c: the lock badge on [UserListRow] from `UserListItem.user.is_private`.
void main() {
  final graphRepo = _MockGraph();

  graph.UserListItem item({
    required bool isPrivate,
    String? name,
    graph.FollowState follow = graph.FollowState.FOLLOW_STATE_NONE,
  }) {
    final base = suggestedUser(1, follow: follow);
    base.user.isPrivate = isPrivate;
    if (name != null) base.user.displayName = name;
    return base;
  }

  Future<void> open(
    WidgetTester tester,
    graph.UserListItem it, {
    MatrixEnv? env,
  }) => pumpThemed(
    tester,
    RepositoryProvider<GraphRepository>.value(
      value: graphRepo,
      child: UserListRow(item: it),
    ),
    brightness: env?.brightness ?? Brightness.light,
    size: env?.size ?? const Size(360, 400),
    textScale: env?.textScale ?? 1.0,
  );

  const long =
      'A very long display name that would fill the whole row and then some';

  forEachThemeAndWidth('a protected row shows the badge, fits, keeps 48dp', (
    tester,
    env,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester, item(isPrivate: true, name: long), env: env);

    expectNoOverflow(tester);
    expect(find.byType(ProtectedBadge), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Protected account')), findsWidgets);
    expectMinTarget(tester, find.byType(FilledButton));

    // The badge stays on screen and never touches the button.
    final badge = tester.getRect(find.byType(ProtectedBadge));
    final button = tester.getRect(find.byType(FilledButton));
    expect(badge.overlaps(button), isFalse);
    expect(badge.right, lessThanOrEqualTo(env.size.width));
    semantics.dispose();
  }, textScales: kMatrixTextScalesLarge);

  forEachThemeAndWidth('a public row shows no badge and no privacy text', (
    tester,
    env,
  ) async {
    await open(tester, item(isPrivate: false), env: env);

    expectNoOverflow(tester);
    expect(find.byType(ProtectedBadge), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(
      find.textContaining(RegExp('public|protected', caseSensitive: false)),
      findsNothing,
    );
  }, textScales: kMatrixTextScalesLarge);

  for (final state in [
    graph.FollowState.FOLLOW_STATE_NONE,
    graph.FollowState.FOLLOW_STATE_REQUESTED,
    graph.FollowState.FOLLOW_STATE_FOLLOWING,
  ]) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('badge with ${state.name} at 360dp x$scale clears the '
          'button', (tester) async {
        await open(
          tester,
          item(isPrivate: true, name: long, follow: state),
          env: MatrixEnv(
            brightness: Brightness.dark,
            size: const Size(360, 800),
            textScale: scale,
          ),
        );
        expectNoOverflow(tester);
        expect(find.byType(ProtectedBadge), findsOneWidget);
        final button = find.byWidgetPredicate(
          (w) => w is FilledButton || w is OutlinedButton,
        );
        expectMinTarget(tester, button);
        expect(
          tester
              .getRect(find.byType(ProtectedBadge))
              .overlaps(tester.getRect(button)),
          isFalse,
        );
      });
    }
  }

  // W3-33d: every FollowButton state fits the row across the whole matrix
  // (the outlined Requested / Following used to overflow at 360dp x2.0).
  for (final state in [
    graph.FollowState.FOLLOW_STATE_NONE,
    graph.FollowState.FOLLOW_STATE_REQUESTED,
    graph.FollowState.FOLLOW_STATE_FOLLOWING,
  ]) {
    for (final private in [true, false]) {
      forEachThemeAndWidth(
        '${state.name} private=$private fits, 48dp, badge when private',
        (tester, env) async {
          await open(
            tester,
            item(isPrivate: private, name: long, follow: state),
            env: env,
          );
          expectNoOverflow(tester);
          expect(
            find.byType(ProtectedBadge),
            private ? findsOneWidget : findsNothing,
          );
          final button = find.byWidgetPredicate(
            (w) => w is FilledButton || w is OutlinedButton,
          );
          expectMinTarget(tester, button);
          expect(
            tester.getRect(button).right,
            lessThanOrEqualTo(env.size.width),
          );
          // The label is never scaled down: it renders at the user's text
          // scale and no FittedBox sits in the button.
          expect(
            find.descendant(of: button, matching: find.byType(FittedBox)),
            findsNothing,
          );
          final label = tester.renderObject<RenderParagraph>(
            find.descendant(of: button, matching: find.byType(RichText)),
          );
          expect(label.textScaler.scale(10), closeTo(10 * env.textScale, 0.01));
          expect(label.didExceedMaxLines, isFalse);
        },
        textScales: kMatrixTextScalesLarge,
      );
    }
  }

  group('the control wraps under the name only when it must', () {
    final textFinder = find.text('@user1');

    testWidgets('inline at 360dp x1.0: beside the name, centred', (
      tester,
    ) async {
      await open(tester, item(isPrivate: true, name: long));
      final button = tester.getRect(find.byType(FilledButton));
      final name = tester.getRect(textFinder);
      expect(button.left, greaterThanOrEqualTo(name.right));
      expectNoOverflow(tester);
    });

    for (final state in [
      graph.FollowState.FOLLOW_STATE_REQUESTED,
      graph.FollowState.FOLLOW_STATE_FOLLOWING,
    ]) {
      testWidgets('${state.name} at 360dp x2.0 sits under the name and '
          'handle, aligned to the text column', (tester) async {
        await open(
          tester,
          item(isPrivate: true, name: long, follow: state),
          env: const MatrixEnv(
            brightness: Brightness.light,
            size: Size(360, 800),
            textScale: 2.0,
          ),
        );
        expectNoOverflow(tester);
        final button = find.byType(OutlinedButton);
        expectMinTarget(tester, button);
        final rect = tester.getRect(button);
        final handle = tester.getRect(textFinder);
        expect(rect.top, greaterThanOrEqualTo(handle.bottom - 0.5));
        // Aligned to the text column; one wider than the column (the outlined
        // Following at x2.0) ends at the row's right edge instead.
        if (rect.width <= 344 - handle.left) {
          expect(rect.left, closeTo(handle.left, 0.5));
        } else {
          expect(rect.right, closeTo(344, 0.5));
        }
        expect(rect.right, lessThanOrEqualTo(360));
        expect(find.byType(ProtectedBadge), findsOneWidget);
      });
    }

    testWidgets('a custom trailing follows the same rule', (tester) async {
      tester.view.devicePixelRatio = 1;
      await pumpThemed(
        tester,
        UserListRow(
          item: item(isPrivate: false, name: long),
          trailing: OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(88, 48)),
            onPressed: () {},
            child: const Text('Unblock'),
          ),
        ),
        size: const Size(360, 800),
        textScale: 2.0,
      );
      expectNoOverflow(tester);
      final rect = tester.getRect(find.byType(OutlinedButton));
      expect(rect.left, closeTo(tester.getRect(textFinder).left, 0.5));
      expectMinTarget(tester, find.byType(OutlinedButton));
    });
  });

  group('the post card keeps its own rule', () {
    pb.PostView view(pb.Visibility visibility, {required bool authorPrivate}) =>
        pb.PostView(
          post: pb.Post(
            postId: postId(7),
            text: 'hello',
            visibility: visibility,
            author: common.AuthorSnapshot(
              userId: 'u-author',
              handle: 'alice',
              displayName: 'Alice A',
              isPrivate: authorPrivate,
            ),
            createdAt: Timestamp.fromDateTime(DateTime.now()),
          ),
        );

    Future<void> card(WidgetTester tester, pb.PostView v) => pumpThemed(
      tester,
      RepositoryProvider<GraphRepository>.value(
        value: graphRepo,
        child: SingleChildScrollView(child: PostCard(view: v)),
      ),
    );

    testWidgets('FOLLOWERS with author.is_private false still shows the lock', (
      tester,
    ) async {
      await card(
        tester,
        view(pb.Visibility.VISIBILITY_FOLLOWERS, authorPrivate: false),
      );
      expect(find.byType(ProtectedBadge), findsOneWidget);
    });

    testWidgets('PUBLIC shows no lock whatever author.is_private says', (
      tester,
    ) async {
      await card(
        tester,
        view(pb.Visibility.VISIBILITY_PUBLIC, authorPrivate: true),
      );
      expect(find.byType(ProtectedBadge), findsNothing);
    });
  });
}
