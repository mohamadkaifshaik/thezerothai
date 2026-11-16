import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPolicy;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/shared/widgets/post/pending_posts_section.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/composer_rig.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/posts_fixtures.dart';

class _MockPosts extends Mock implements PostsRepository {}

/// The main composer's Post, in both modes: the foreground send (no sender)
/// and the background send (the session's `PostSender`). Same server calls,
/// same keys; only where the screen waits differs.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  late _MockPosts posts;
  late List<String> keys;
  late List<String> texts;
  late int failures;

  void stubPosts() {
    posts = _MockPosts();
    keys = [];
    texts = [];
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyPolicy: any(named: 'replyPolicy'),
        poll: any(named: 'poll'),
        communityId: any(named: 'communityId'),
        beaconId: any(named: 'beaconId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
      ),
    ).thenAnswer((i) async {
      keys.add(i.namedArguments[#idempotencyKey] as String);
      texts.add(i.namedArguments[#text] as String);
      if (failures > 0) {
        failures--;
        throw const NetworkException('offline');
      }
      return postView(1);
    });
  }

  Future<W6ComposerRig> open(WidgetTester tester, {required bool background}) =>
      pumpW6Composer(
        tester,
        posts: posts,
        features: const {kFeaturePosts},
        backgroundSend: background,
        home: (_) => const Scaffold(
          body: SingleChildScrollView(child: PendingPostsSection()),
        ),
      );

  for (final background in [false, true]) {
    final mode = background ? 'background' : 'foreground';

    testWidgets('$mode: Post creates the post once and the composer goes', (
      tester,
    ) async {
      failures = 0;
      stubPosts();
      await open(tester, background: background);
      await tester.enterText(find.byType(TextField), 'same either way');
      await tester.pump();

      await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 5));

      expect(texts, ['same either way']);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('$mode: after a failure the same key is sent again', (
      tester,
    ) async {
      failures = 1;
      stubPosts();
      await open(tester, background: background);
      await tester.enterText(find.byType(TextField), 'retry me');
      await tester.pump();

      await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      if (background) {
        // The composer is gone; the row offers Retry.
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.text('Retry'));
      } else {
        // The composer stays with the text; Post again.
        expect(find.byType(TextField), findsOneWidget);
        await tester.pump();
        await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 5));

      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
      expect(texts, ['retry me', 'retry me']);
    });
  }

  testWidgets('background: Edit on a failed post reopens the composer with '
      'its text', (tester) async {
    failures = 1;
    stubPosts();
    await open(tester, background: true);
    await tester.enterText(find.byType(TextField), 'fix my typo');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('fix my typo'), findsOneWidget);
  });
}
