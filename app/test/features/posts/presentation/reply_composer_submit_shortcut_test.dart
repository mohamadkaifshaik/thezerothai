import 'package:dzeroth/core/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/composer_tablet_rig.dart';
import '../../../support/posts_fixtures.dart';

/// Ctrl+Enter and Cmd+Enter send the reply from the full-screen reply and
/// from the desktop dialog, exactly when Reply is enabled.
void main() {
  Future<ComposerTabletRig> open(WidgetTester tester, double width) async {
    final rig = ComposerTabletRig();
    when(
      () => rig.posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((_) async => postView(9, text: 'A reply'));
    final path = AppRouter.composeReplyPath(rig.parent.post.postId);
    await rig.pump(
      tester,
      location: AppRouter.homePath,
      width: width,
      height: 900,
      flags: kComposerTabletFlags,
    );
    await rig.push(tester, path);
    return rig;
  }

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey modifier) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  void verifySent(ComposerTabletRig rig, int times) {
    verify(
      () => rig.posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).called(times);
  }

  for (final (label, width) in [('phone', 390.0), ('desktop dialog', 1440.0)]) {
    for (final (name, key) in [
      ('Ctrl', LogicalKeyboardKey.controlLeft),
      ('Cmd', LogicalKeyboardKey.metaLeft),
    ]) {
      testWidgets('$label: $name+Enter sends the reply', (tester) async {
        final rig = await open(tester, width);
        await tester.enterText(find.byType(TextField), 'On my way');
        await tester.pump();
        await chord(tester, key);
        verifySent(rig, 1);
      });
    }

    testWidgets('$label: nothing typed, the chord sends nothing', (
      tester,
    ) async {
      final rig = await open(tester, width);
      await tester.tap(find.byType(TextField));
      await chord(tester, LogicalKeyboardKey.controlLeft);
      verifyNever(
        () => rig.posts.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          replyToPostId: any(named: 'replyToPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
        ),
      );
    });

    testWidgets('$label: plain Enter does not send', (tester) async {
      final rig = await open(tester, width);
      await tester.enterText(find.byType(TextField), 'On my way');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      verifyNever(
        () => rig.posts.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          replyToPostId: any(named: 'replyToPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
        ),
      );
    });
  }
}
