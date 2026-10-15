import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';

void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late FakeImagePicker picker;
  late FakeImageProcessor processor;
  late AttachmentsCubit cubit;

  setUp(() {
    repo = MockMediaRepository();
    picker = FakeImagePicker();
    processor = FakeImageProcessor();
    cubit = AttachmentsCubit(
      picker: picker,
      processor: processor,
      uploader: MediaUploader(repository: repo),
    );
  });

  tearDown(() => cubit.close());

  List<AttachmentStatus> statuses() => [
    for (final a in cubit.state.items) a.status,
  ];

  test('picking adds processed, ready photos in order', () async {
    picker.next = [imageBytes('a'), imageBytes('b')];

    await cubit.pick();

    expect(statuses(), [AttachmentStatus.ready, AttachmentStatus.ready]);
    expect(cubit.state.isSendable, isTrue);
    expect(cubit.state.items.first.previewBytes, isNotNull);
  });

  test(
    'at most four photos; the picker is asked only for what is left',
    () async {
      picker.next = [for (final t in 'abc'.split('')) imageBytes(t)];
      await cubit.pick();
      picker.next = [for (final t in 'defg'.split('')) imageBytes(t)];

      await cubit.pick();

      expect(picker.lastLimit, 1);
      expect(cubit.state.count, 4);
      expect(cubit.state.isFull, isTrue);
      picker.calls = 0;
      await cubit.pick();
      expect(picker.calls, 0, reason: 'full: the picker is not even opened');
    },
  );

  test(
    'a file that is not an image is marked unsupported and blocks Post',
    () async {
      picker.next = [imageBytes('a'), badBytes];

      await cubit.pick();

      expect(statuses(), [
        AttachmentStatus.ready,
        AttachmentStatus.unsupported,
      ]);
      expect(cubit.state.isSendable, isFalse);
      expect(cubit.state.hasUnusable, isTrue);

      cubit.remove(cubit.state.items.last.id);
      expect(cubit.state.isSendable, isTrue);
    },
  );

  test('cancelled picker changes nothing', () async {
    await cubit.pick();

    expect(cubit.state.isEmpty, isTrue);
  });

  test('alt text is trimmed and capped', () async {
    picker.next = [imageBytes('a')];
    await cubit.pick();
    final id = cubit.state.items.single.id;

    cubit.setAltText(id, '  a cat  ');
    expect(cubit.state.items.single.altText, 'a cat');

    cubit.setAltText(id, 'x' * 1500);
    expect(cubit.state.items.single.altText.length, 1000);
  });

  test(
    'uploadAll publishes everything and returns ids and alt texts',
    () async {
      stubHappyUpload(repo);
      picker.next = [imageBytes('a'), imageBytes('b')];
      await cubit.pick();
      cubit.setAltText(cubit.state.items.first.id, 'first');

      final result = await cubit.uploadAll();

      expect(result.mediaIds, ['m1', 'm2']);
      expect(result.altTexts, ['first', '']);
      expect(statuses(), everyElement(AttachmentStatus.uploaded));
    },
  );

  test('no alt text at all sends no alt list', () async {
    stubHappyUpload(repo);
    picker.next = [imageBytes('a')];
    await cubit.pick();

    final result = await cubit.uploadAll();

    expect(result.altTexts, isEmpty);
  });

  test('progress is reported while uploading', () async {
    final gate = Completer<void>();
    stubHappyUpload(repo, onPut: (_) => gate.future);
    picker.next = [imageBytes('a')];
    await cubit.pick();

    final future = cubit.uploadAll();
    await Future<void>.delayed(Duration.zero);
    expect(statuses(), [AttachmentStatus.uploading]);
    expect(cubit.state.isBusy, isTrue);

    gate.complete();
    await future;
    expect(statuses(), [AttachmentStatus.uploaded]);
  });

  test('a failed PUT marks that photo failed and throws; a retry succeeds '
      'without re-reserving', () async {
    var fail = true;
    stubHappyUpload(
      repo,
      onPut: (target) async {
        if (fail) throw const NetworkException('offline');
      },
    );
    picker.next = [imageBytes('a')];
    await cubit.pick();

    await expectLater(cubit.uploadAll(), throwsA(isA<NetworkException>()));
    expect(statuses(), [AttachmentStatus.failed]);
    expect(cubit.state.isSendable, isTrue, reason: 'failed photos are retried');

    fail = false;
    final result = await cubit.uploadAll();

    expect(result.mediaIds, ['m1']);
    verify(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).called(1);
  });

  test(
    'a rejected photo throws a media validation error with the reason',
    () async {
      stubHappyUpload(repo, result: (id) => rejectedResult(id, 'Not allowed'));
      picker.next = [imageBytes('a')];
      await cubit.pick();

      await expectLater(
        cubit.uploadAll(),
        throwsA(
          isA<ValidationException>()
              .having((e) => e.field, 'field', 'media')
              .having((e) => e.message, 'message', 'Not allowed'),
        ),
      );

      expect(statuses(), [AttachmentStatus.rejected]);
      expect(cubit.state.items.single.rejectionReason, 'Not allowed');
      expect(cubit.state.isSendable, isFalse);
    },
  );

  test('a whole-call failure (quota) puts the photos back to ready', () async {
    when(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenThrow(const QuotaExceededException('limit'));
    picker.next = [imageBytes('a')];
    await cubit.pick();

    await expectLater(
      cubit.uploadAll(),
      throwsA(isA<QuotaExceededException>()),
    );

    expect(statuses(), [AttachmentStatus.ready]);
    verifyNever(() => repo.putObject(any(), any()));
  });
}
