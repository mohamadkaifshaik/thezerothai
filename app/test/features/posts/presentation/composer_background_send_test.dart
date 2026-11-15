import 'dart:async';

import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/post_sender.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPolicy;
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/shared/widgets/post/pending_posts_section.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/composer_rig.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/posts_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

/// Fix #1: Post validates, then the composer closes at once and the post goes
/// out from the session's sender while Home shows its status row.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  testWidgets('Post closes the composer at once; Home shows the post '
      'sending, then Posted', (tester) async {
    final posts = _MockPostsRepository();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    final gate = Completer<void>();
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
      ),
    ).thenAnswer((_) async {
      await gate.future;
      return postView(1);
    });

    await pumpW6Composer(
      tester,
      posts: posts,
      features: const {kFeaturePosts},
      backgroundSend: true,
      home: (_) => const Scaffold(
        body: SingleChildScrollView(child: PendingPostsSection()),
      ),
    );
    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.pump();

    await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
    // The request is still in flight, yet the composer is gone.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Posting...'), findsOneWidget);
    expect(find.text('hello world'), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('Posted'), findsOneWidget);
    // Let the "Posted" row's timer end inside the test.
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Posted'), findsNothing);
  });

  testWidgets('a failed send leaves the row with its error', (tester) async {
    final posts = _MockPostsRepository();
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
      ),
    ).thenAnswer((_) async => throw StateError('boom'));

    final rig = await pumpW6Composer(
      tester,
      posts: posts,
      features: const {kFeaturePosts},
      backgroundSend: true,
      home: (_) => const Scaffold(
        body: SingleChildScrollView(child: PendingPostsSection()),
      ),
    );
    await tester.enterText(find.byType(TextField), 'will fail');
    await tester.pump();

    await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(rig.pending.state.single.status, PendingPostStatus.failed);
    expect(find.text('Retry'), findsOneWidget);
  });

  group('Edit seed photos', () {
    Future<AttachmentsCubit> heldPhotos() async {
      final picker = FakeImagePicker()..next = [imageBytes('a')];
      final cubit = AttachmentsCubit(
        picker: picker,
        processor: FakeImageProcessor(),
        uploader: MediaUploader(repository: MockMediaRepository()),
      );
      await cubit.pick();
      await Future<void>.delayed(Duration.zero);
      return cubit;
    }

    testWidgets('photos off: the seed cubit is released, text only', (
      tester,
    ) async {
      final posts = _MockPostsRepository();
      when(() => posts.subFeatureEnabled(any())).thenReturn(true);
      final held = (await tester.runAsync(heldPhotos))!;
      final rig = await pumpW6Composer(
        tester,
        posts: posts,
        features: const {kFeaturePosts},
        backgroundSend: true,
      );

      unawaited(
        rig.router.push<void>(
          '/compose',
          extra: PostEditSeed(text: 'seeded words', attachments: held),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('seeded words'), findsOneWidget);
      expect(held.isClosed, isTrue);
    });

    testWidgets('a seed cubit that is already closed is not used: the '
        'composer opens on the text', (tester) async {
      final posts = _MockPostsRepository();
      when(() => posts.subFeatureEnabled(any())).thenReturn(true);
      final held = (await tester.runAsync(heldPhotos))!;
      await tester.runAsync(held.close);
      final rig = await pumpW6Composer(
        tester,
        posts: posts,
        features: const {kFeaturePosts, kFeatureMedia},
        backgroundSend: true,
      );

      unawaited(
        rig.router.push<void>(
          '/compose',
          extra: PostEditSeed(text: 'seeded words', attachments: held),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('seeded words'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a live seed cubit comes along with its photos', (
      tester,
    ) async {
      final posts = _MockPostsRepository();
      when(() => posts.subFeatureEnabled(any())).thenReturn(true);
      final held = (await tester.runAsync(heldPhotos))!;
      final rig = await pumpW6Composer(
        tester,
        posts: posts,
        features: const {kFeaturePosts, kFeatureMedia},
        backgroundSend: true,
      );

      unawaited(
        rig.router.push<void>(
          '/compose',
          extra: PostEditSeed(text: 'seeded words', attachments: held),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('seeded words'), findsOneWidget);
      expect(held.isClosed, isFalse);
      expect(held.state.count, 1);
    });
  });

  testWidgets('Undo send: Post closes the composer, the row counts down, '
      'Undo brings the composer back with the text and nothing is sent', (
    tester,
  ) async {
    final posts = _MockPostsRepository();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    await pumpW6Composer(
      tester,
      posts: posts,
      features: const {kFeaturePosts},
      backgroundSend: true,
      undoWindow: const Duration(seconds: 5),
      home: (_) => const Scaffold(
        body: SingleChildScrollView(child: PendingPostsSection()),
      ),
    );
    await tester.enterText(find.byType(TextField), 'maybe not');
    await tester.pump();

    await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Sending in 5s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Sending in 3s'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('maybe not'), findsOneWidget);
    verifyNever(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyPolicy: any(named: 'replyPolicy'),
        poll: any(named: 'poll'),
        communityId: any(named: 'communityId'),
        beaconId: any(named: 'beaconId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    );
  });
}
