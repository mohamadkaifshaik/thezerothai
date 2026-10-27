import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:dzeroth/shared/widgets/post_pin_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/posts_fixtures.dart';

/// W3-17: the Pin / Unpin rows of a post's overflow menu. The card reads no
/// provider for them: a screen that can pin hands it a [PostPinControl].
void main() {
  const me = 'me';

  pb.PostView view({
    String author = me,
    PostKind kind = PostKind.POST_KIND_POST,
    int n = 7,
  }) => pb.PostView(
    post: pb.Post(
      postId: postId(n),
      kind: kind,
      text: 'hello world',
      author: common.AuthorSnapshot(userId: author, handle: 'kaif'),
    ),
  );

  late List<String> pinned;
  late int unpinned;
  late Object? failWith;

  PostPinControl control({String pin = '', bool canPin = true}) =>
      PostPinControl(
        pinnedPostId: pin,
        canPin: canPin,
        onPin: (id) async {
          pinned.add(id);
          final error = failWith;
          if (error != null) throw error;
        },
        onUnpin: () async {
          unpinned++;
          final error = failWith;
          if (error != null) throw error;
        },
      );

  setUp(() {
    pinned = [];
    unpinned = 0;
    failWith = null;
  });

  Future<void> open(
    WidgetTester tester,
    pb.PostView post, {
    PostPinControl? pin,
    bool withDelete = false,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PostCard(
              view: post,
              viewerUserId: me,
              graphActionsEnabled: false,
              onDelete: withDelete ? (_) async {} : null,
              pinControl: pin,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
  }

  group('which posts get the rows', () {
    for (final kind in [
      PostKind.POST_KIND_POST,
      PostKind.POST_KIND_QUOTE,
      PostKind.POST_KIND_REPLY,
    ]) {
      testWidgets('own ${kind.name} offers Pin to your profile', (
        tester,
      ) async {
        await open(tester, view(kind: kind), pin: control());
        await openMenu(tester);

        expect(find.text('Pin to your profile'), findsOneWidget);
        expect(find.text('Unpin from profile'), findsNothing);
      });
    }

    for (final kind in [
      PostKind.POST_KIND_REPOST,
      PostKind.POST_KIND_UNSPECIFIED,
    ]) {
      testWidgets('own ${kind.name} never does (Delete alone stays)', (
        tester,
      ) async {
        await open(tester, view(kind: kind), pin: control(), withDelete: true);
        await openMenu(tester);

        expect(find.text('Delete'), findsOneWidget);
        expect(find.text('Pin to your profile'), findsNothing);
        expect(find.text('Unpin from profile'), findsNothing);
      });
    }

    testWidgets('a repost with nothing else to offer has no menu', (
      tester,
    ) async {
      await open(tester, view(kind: PostKind.POST_KIND_REPOST), pin: control());

      expect(find.byTooltip('More options'), findsNothing);
    });

    testWidgets("someone else's post has no menu at all", (tester) async {
      await open(tester, view(author: 'someone'), pin: control());

      expect(find.byTooltip('More options'), findsNothing);
    });

    testWidgets('no control, no rows (every other screen)', (tester) async {
      await open(tester, view(), withDelete: true);
      await openMenu(tester);

      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Pin to your profile'), findsNothing);
    });

    testWidgets('pin alone is enough for the menu to exist', (tester) async {
      await open(tester, view(), pin: control());

      expect(find.byTooltip('More options'), findsOneWidget);
    });

    testWidgets('the pinned post offers Unpin from profile instead', (
      tester,
    ) async {
      await open(tester, view(), pin: control(pin: postId(7)));
      await openMenu(tester);

      expect(find.text('Unpin from profile'), findsOneWidget);
      expect(find.text('Pin to your profile'), findsNothing);
    });
  });

  // ADR-0024 Amendment 1 A2 (W3-22 M-1): Unpin is a clear, which the server
  // accepts whatever `profile_extras` says, so it is offered on the pinned post
  // even when Pin is not. Pin (a set) follows `canPin`.
  group('without profile_extras (canPin false)', () {
    testWidgets('the pinned post still offers Unpin from profile, and it '
        'unpins', (tester) async {
      await open(tester, view(), pin: control(pin: postId(7), canPin: false));
      expect(find.byTooltip('More options'), findsOneWidget);
      await openMenu(tester);

      expect(find.text('Unpin from profile'), findsOneWidget);
      expect(find.text('Pin to your profile'), findsNothing);

      await tester.tap(find.text('Unpin from profile'));
      await tester.pumpAndSettle();

      expect(unpinned, 1);
      expect(pinned, isEmpty);
      expect(find.text('Unpinned from your profile.'), findsOneWidget);
    });

    testWidgets('any other post has no pin row, and with nothing else no '
        'menu', (tester) async {
      await open(
        tester,
        view(n: 8),
        pin: control(pin: postId(7), canPin: false),
      );

      expect(find.byTooltip('More options'), findsNothing);
    });

    testWidgets('another post keeps Delete but no Pin row', (tester) async {
      await open(
        tester,
        view(n: 8),
        pin: control(pin: postId(7), canPin: false),
        withDelete: true,
      );
      await openMenu(tester);

      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Pin to your profile'), findsNothing);
      expect(find.text('Unpin from profile'), findsNothing);
    });

    testWidgets('no pin at all: no row on any post', (tester) async {
      await open(tester, view(), pin: control(canPin: false));

      expect(find.byTooltip('More options'), findsNothing);
    });

    testWidgets("a repost is never pinned, so never unpinned from here", (
      tester,
    ) async {
      await open(
        tester,
        view(kind: PostKind.POST_KIND_REPOST),
        pin: control(pin: postId(7), canPin: false),
      );

      expect(find.byTooltip('More options'), findsNothing);
    });

    testWidgets("someone else's post never does", (tester) async {
      await open(
        tester,
        view(author: 'someone'),
        pin: control(pin: postId(7), canPin: false),
      );

      expect(find.byTooltip('More options'), findsNothing);
    });
  });

  group('pinning', () {
    testWidgets('with no pin yet it pins at once and says so', (tester) async {
      await open(tester, view(), pin: control());
      await openMenu(tester);

      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();

      expect(pinned, [postId(7)]);
      expect(find.text('Pinned to your profile.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('replacing another pin asks first; Cancel changes nothing', (
      tester,
    ) async {
      await open(tester, view(), pin: control(pin: postId(1)));
      await openMenu(tester);

      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();
      expect(find.text('Replace your pinned post?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(pinned, isEmpty);
      expect(find.text('Pinned to your profile.'), findsNothing);
    });

    testWidgets('confirming Replace pins the new post', (tester) async {
      await open(tester, view(), pin: control(pin: postId(1)));
      await openMenu(tester);

      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();

      expect(pinned, [postId(7)]);
      expect(find.text('Pinned to your profile.'), findsOneWidget);
    });

    testWidgets('Unpin needs no confirmation', (tester) async {
      await open(tester, view(), pin: control(pin: postId(7)));
      await openMenu(tester);

      await tester.tap(find.text('Unpin from profile'));
      await tester.pumpAndSettle();

      expect(unpinned, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Unpinned from your profile.'), findsOneWidget);
    });
  });

  group('failures', () {
    testWidgets("VALIDATION says this post can't be pinned, no Retry", (
      tester,
    ) async {
      failWith = const ValidationException('x', field: 'pinned_post_id');
      await open(tester, view(), pin: control());
      await openMenu(tester);

      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();

      expect(find.text("This post can't be pinned."), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Pinned to your profile.'), findsNothing);
    });

    testWidgets('FEATURE_DISABLED says so and offers no Retry', (tester) async {
      failWith = const FeatureDisabledException('x', feature: 'profile_extras');
      await open(tester, view(), pin: control());
      await openMenu(tester);

      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();

      expect(find.text("Pinning isn't available right now."), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a network failure offers Retry, which repeats the action', (
      tester,
    ) async {
      failWith = const NetworkException('offline');
      await open(tester, view(), pin: control());
      await openMenu(tester);

      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No connection'), findsOneWidget);
      expect(pinned, [postId(7)]);

      failWith = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(pinned, [postId(7), postId(7)]);
      expect(find.text('Pinned to your profile.'), findsOneWidget);
    });

    testWidgets('an unexpected error is still a friendly message', (
      tester,
    ) async {
      failWith = StateError('boom');
      await open(tester, view(), pin: control());
      await openMenu(tester);

      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();

      expect(
        find.text("Couldn't update your pinned post. Please try again."),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('layout', () {
    for (final width in [360.0, 600.0, 1200.0]) {
      testWidgets('the menu rows fit at ${width.toInt()}dp and text x2', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await open(
          tester,
          view(),
          pin: control(pin: postId(1)),
          withDelete: true,
          size: Size(width, 800),
        );
        await openMenu(tester);

        expect(tester.takeException(), isNull);
        final row = tester.getSize(
          find.ancestor(
            of: find.text('Pin to your profile'),
            matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
          ),
        );
        expect(row.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      });
    }
  });
}
