import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/post/post_moderation_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/posts_fixtures.dart';

/// W5-35: "Remove from Community" in a post's overflow menu. The card reads no
/// provider: the community screen hands it a [PostModerationControl] only when
/// the server says the viewer moderates.
void main() {
  late List<String> hidden;
  late List<String> restored;
  Object? hideFails;

  PostModerationControl control() => PostModerationControl(
    communityId: '77',
    communityName: 'Chess club',
    onHide: (id) async {
      hidden.add(id);
      final e = hideFails;
      if (e != null) throw e;
    },
    onRestore: (id) async => restored.add(id),
  );

  pb.PostView view({String communityId = '77', String author = 'someone'}) =>
      pb.PostView(
        post: pb.Post(
          postId: postId(7),
          kind: pb.PostKind.POST_KIND_POST,
          text: 'hello world',
          author: common.AuthorSnapshot(userId: author, handle: 'kaif'),
          community: communityId.isEmpty
              ? null
              : pb.CommunityRef(id: communityId, name: 'Chess club'),
        ),
      );

  setUp(() {
    hidden = [];
    restored = [];
    hideFails = null;
  });

  Future<void> open(
    WidgetTester tester,
    pb.PostView post, {
    PostModerationControl? mod,
    bool reports = false,
    String viewer = 'viewer',
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PostCard(
              view: post,
              viewerUserId: viewer,
              graphActionsEnabled: false,
              reportsEnabled: reports,
              moderationControl: mod,
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

  testWidgets('a moderator sees the row on a post of this community', (
    tester,
  ) async {
    await open(tester, view(), mod: control());
    await openMenu(tester);
    expect(find.text('Remove from Community'), findsOneWidget);
  });

  testWidgets('with reports off the menu still exists for a moderator', (
    tester,
  ) async {
    await open(tester, view(), mod: control(), reports: false);
    expect(find.byTooltip('More options'), findsOneWidget);
  });

  testWidgets('no control (a member): no row, and no menu without others', (
    tester,
  ) async {
    await open(tester, view());
    expect(find.byTooltip('More options'), findsNothing);
  });

  testWidgets('a post of another community or none gets no row', (
    tester,
  ) async {
    await open(tester, view(communityId: '99'), mod: control());
    expect(find.byTooltip('More options'), findsNothing);
    await open(tester, view(communityId: ''), mod: control());
    expect(find.byTooltip('More options'), findsNothing);
  });

  testWidgets('confirm, hide, then Undo restores', (tester) async {
    await open(tester, view(), mod: control());
    await openMenu(tester);
    await tester.tap(find.text('Remove from Community'));
    await tester.pumpAndSettle();
    expect(find.text('Remove this post from Chess club?'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(hidden, [postId(7)]);
    expect(find.text('Removed from Chess club.'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(restored, [postId(7)]);
    expect(find.text('Restored to Chess club.'), findsOneWidget);
  });

  testWidgets('Cancel hides nothing', (tester) async {
    await open(tester, view(), mod: control());
    await openMenu(tester);
    await tester.tap(find.text('Remove from Community'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(hidden, isEmpty);
  });

  testWidgets('a refusal is a friendly sentence with Retry', (tester) async {
    hideFails = CommunityForbiddenException(
      CommunityForbiddenReason.notModerator,
    );
    await open(tester, view(), mod: control());
    await openMenu(tester);
    await tester.tap(find.text('Remove from Community'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Only moderators can do that.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
