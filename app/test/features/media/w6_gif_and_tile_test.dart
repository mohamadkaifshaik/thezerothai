import 'dart:math' as math;

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/media/presentation/widgets/attachment_grid.dart';
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/media_fixtures.dart';
import '../../support/theme_harness.dart';

/// W6-19: what happens to a GIF upload after the busy-slot retries run out
/// (the existing path re-signs and PUTs again), and the rejected tile of a
/// PHOTO (the server's reason, an empty reason, semantics).
void main() {
  setUpAll(registerMediaFallbacks);

  group('GIF finalize: retries exhausted, then the next attempt', () {
    late MockMediaRepository repo;
    late MediaUploader uploader;
    late List<Duration> waits;
    late List<String> finalizeKeys;
    late List<String> createKeys;
    late List<pb.SignedUpload> puts;

    setUp(() {
      repo = MockMediaRepository();
      waits = [];
      finalizeKeys = [];
      createKeys = [];
      puts = [];
      uploader = MediaUploader(
        repository: repo,
        delay: (d) async => waits.add(d),
        random: math.Random(1),
      );
      when(
        () => repo.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      ).thenAnswer((invocation) async {
        createKeys.add(invocation.namedArguments[#idempotencyKey] as String);
        return [
          uploadTarget(
            'm1',
            expiresAt: DateTime.now().add(const Duration(minutes: 10)),
          ),
        ];
      });
      when(() => repo.putObject(any(), any())).thenAnswer((invocation) async {
        puts.add(invocation.positionalArguments.first as pb.SignedUpload);
      });
    });

    /// MEDIA_NOT_READY for the first [busy] calls, then READY.
    void stubBusy(int busy) {
      var calls = 0;
      when(
        () => repo.finalizeUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          items: any(named: 'items'),
        ),
      ).thenAnswer((invocation) async {
        finalizeKeys.add(invocation.namedArguments[#idempotencyKey] as String);
        if (++calls <= busy) {
          throw const MediaNotReadyException('busy', mediaId: 'm1');
        }
        final items =
            invocation.namedArguments[#items] as List<FinalizeRequestItem>;
        return [for (final i in items) readyResult(i.mediaId)];
      });
    }

    Future<List<UploadOutcome>> uploadGif() => uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: [UploadJob(id: 'g', image: fakeGifProcessed())],
    );

    test('three quiet repeats fail, the user taps Post again: the same '
        'CreateUpload key re-signs, both objects are PUT again, the same '
        'finalize key lands', () async {
      stubBusy(4); // the first attempt: 1 call + 3 repeats, all busy

      await expectLater(uploadGif(), throwsA(isA<MediaNotReadyException>()));
      expect(finalizeKeys, hasLength(4));
      expect(puts, hasLength(2));
      expect(createKeys, hasLength(1));

      final out = await uploadGif();

      expect(out.single.status, UploadOutcomeStatus.ready);
      expect(out.single.mediaId, 'm1');
      expect(createKeys, hasLength(2));
      expect(createKeys.toSet(), hasLength(1), reason: 'replay, no new quota');
      expect(puts, hasLength(4), reason: 'full + thumb, once more');
      expect(finalizeKeys, hasLength(5));
      expect(finalizeKeys.toSet(), hasLength(1));
      // 3 waits for the first attempt; the second one needed none.
      expect(waits, hasLength(3));
    });

    test('a second exhausted attempt behaves the same again', () async {
      stubBusy(100);
      for (var round = 0; round < 3; round++) {
        await expectLater(uploadGif(), throwsA(isA<MediaNotReadyException>()));
      }
      expect(createKeys.toSet(), hasLength(1));
      expect(finalizeKeys, hasLength(12), reason: '4 calls per attempt');
      expect(waits, hasLength(9));
      expect(puts, hasLength(6));
    });

    test('the waits are the documented 2 s, 4 s, 8 s plus a quarter of '
        'jitter at most', () async {
      stubBusy(100);
      await expectLater(uploadGif(), throwsA(isA<MediaNotReadyException>()));
      for (final (i, base) in [2, 4, 8].indexed) {
        expect(waits[i], greaterThanOrEqualTo(Duration(seconds: base)));
        expect(
          waits[i],
          lessThanOrEqualTo(Duration(milliseconds: base * 1250)),
        );
      }
    });
  });

  group('rejected PHOTO tile', () {
    late MockMediaRepository repo;
    late AttachmentsCubit cubit;

    setUp(() {
      repo = MockMediaRepository();
      cubit = AttachmentsCubit(
        picker: FakeImagePicker(),
        processor: FakeImageProcessor(),
        uploader: MediaUploader(repository: repo),
        gifSource: FakeGifSource(),
        gifPreparer: FakeGifPreparer(),
      );
    });

    tearDown(() => cubit.close());

    Future<void> reject(String reason) async {
      stubHappyUpload(repo, result: (id) => rejectedResult(id, reason));
      await cubit.addImages([imageBytes('a')]);
      await expectLater(cubit.uploadAll(), throwsA(isA<ValidationException>()));
    }

    Future<void> host(
      WidgetTester tester, {
      double width = 360,
      Brightness brightness = Brightness.light,
      double scale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: brightness),
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: app!,
          ),
          home: Scaffold(
            body: BlocProvider.value(
              value: cubit,
              child: const AttachmentGrid(),
            ),
          ),
        ),
      );
    }

    testWidgets('shows the server reason on the tile and in semantics, with '
        'photo wording', (tester) async {
      final handle = tester.ensureSemantics();
      await reject('This image was not accepted by our safety checks.');
      await host(tester);

      expect(
        find.text('This image was not accepted by our safety checks.'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Photo 1 of 1, was not accepted. '
          'This image was not accepted by our safety checks. Remove it.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('an empty reason: "Not accepted" and no stray full stop', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await reject('');
      await host(tester);

      expect(find.text('Not accepted'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Photo 1 of 1, was not accepted. Remove it.'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a reason without a trailing stop reads cleanly', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await reject('Try a different photo');
      await host(tester);
      expect(
        find.bySemanticsLabel(
          'Photo 1 of 1, was not accepted. Try a different photo. Remove it.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    forEachThemeAndWidth('a very long reason does not overflow the tile', (
      tester,
      env,
    ) async {
      await reject(
        'Image uploads are temporarily limited. Please try again later, '
        'or use a different photo that is smaller. ${'لا يمكن قبول هذه الصورة ' * 4}',
      );
      await host(
        tester,
        width: env.size.width,
        brightness: env.brightness,
        scale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(AttachmentTile), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);
  });
}
