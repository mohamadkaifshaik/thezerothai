import 'dart:math' as math;

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';

/// W6-40 (ADR-0029 Amendment 1 A5.6): FinalizeUpload answers "image checks are
/// temporarily unavailable" with a retry_after. The client repeats the same
/// call (same media id, nothing re-uploaded) three times after that delay,
/// then offers a manual Retry on the tile, which calls it again.
void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late List<Duration> waits;
  late MediaUploader uploader;
  late int finalizeCalls;
  late List<String> finalizedIds;

  setUp(() {
    repo = MockMediaRepository();
    waits = [];
    finalizeCalls = 0;
    finalizedIds = [];
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
    ).thenAnswer(
      (_) async => [
        uploadTarget(
          'm1',
          expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        ),
      ],
    );
    when(() => repo.putObject(any(), any())).thenAnswer((_) async {});
  });

  /// Finalize is unavailable for the first [unavailable] calls, then READY.
  void stubFinalize(int unavailable, {Duration? retryAfter}) {
    when(
      () => repo.finalizeUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        items: any(named: 'items'),
      ),
    ).thenAnswer((invocation) async {
      final items =
          invocation.namedArguments[#items] as List<FinalizeRequestItem>;
      finalizedIds.addAll([for (final i in items) i.mediaId]);
      if (++finalizeCalls <= unavailable) {
        throw ScreeningUnavailableException(
          'image checks are temporarily unavailable',
          retryAfter: retryAfter,
        );
      }
      return [for (final i in items) readyResult(i.mediaId)];
    });
  }

  Future<List<UploadOutcome>> uploadPhoto() => uploader.upload(
    purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
    jobs: [UploadJob(id: 'p', image: fakeProcessed('p'))],
  );

  void verifyUploadedOnce() {
    verify(() => repo.putObject(any(), any())).called(2); // full + thumb, once
    verify(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).called(1);
  }

  test(
    'repeats the same finalize after the server retry_after, with no re-upload',
    () async {
      stubFinalize(2, retryAfter: const Duration(seconds: 5));

      final out = await uploadPhoto();

      expect(out.single.status, UploadOutcomeStatus.ready);
      expect(finalizeCalls, 3);
      expect(finalizedIds.toSet(), {'m1'}, reason: 'always the same media id');
      expect(waits, hasLength(2));
      for (final w in waits) {
        expect(w, greaterThanOrEqualTo(const Duration(seconds: 5)));
        expect(w, lessThanOrEqualTo(const Duration(milliseconds: 6250)));
      }
      verifyUploadedOnce();
    },
  );

  test('without retry_after the waits are 2, 4 and 8 seconds', () async {
    stubFinalize(3);

    final out = await uploadPhoto();

    expect(out.single.status, UploadOutcomeStatus.ready);
    expect(finalizeCalls, 4);
    expect(waits, hasLength(3));
    for (final (i, base) in [2, 4, 8].indexed) {
      expect(waits[i], greaterThanOrEqualTo(Duration(seconds: base)));
      expect(waits[i], lessThanOrEqualTo(Duration(milliseconds: base * 1250)));
    }
  });

  test('after three repeats the exception surfaces, the upload is kept and '
      'a later call finalizes without re-uploading', () async {
    stubFinalize(4, retryAfter: const Duration(seconds: 5));

    await expectLater(
      uploadPhoto(),
      throwsA(isA<ScreeningUnavailableException>()),
    );
    expect(finalizeCalls, 4, reason: 'first call + three repeats');
    expect(waits, hasLength(3));

    // The manual Retry: one more call for the same media id.
    final out = await uploadPhoto();

    expect(out.single.status, UploadOutcomeStatus.ready);
    expect(out.single.mediaId, 'm1');
    expect(finalizeCalls, 5);
    verifyUploadedOnce();
  });

  test('an absurd retry_after is capped', () async {
    stubFinalize(1, retryAfter: const Duration(hours: 5));

    await uploadPhoto();

    expect(waits.single, lessThanOrEqualTo(const Duration(seconds: 38)));
  });

  group('the tile', () {
    late FakeImagePicker picker;
    late AttachmentsCubit cubit;

    setUp(() {
      picker = FakeImagePicker();
      cubit = AttachmentsCubit(
        picker: picker,
        processor: FakeImageProcessor(),
        uploader: uploader,
      );
    });

    tearDown(() => cubit.close());

    test('turns unchecked after the retries, blocks Post, and Retry checks the '
        'same media id without uploading again', () async {
      stubFinalize(4, retryAfter: const Duration(seconds: 5));
      picker.next = [imageBytes('a')];
      await cubit.pick();

      await expectLater(
        cubit.uploadAll(),
        throwsA(isA<ScreeningUnavailableException>()),
      );

      expect(cubit.state.items.single.status, AttachmentStatus.unchecked);
      expect(cubit.state.isSendable, isFalse, reason: 'Post waits');
      expect(cubit.state.isBusy, isFalse);

      await cubit.retryCheck(cubit.state.items.single.id);

      final tile = cubit.state.items.single;
      expect(tile.status, AttachmentStatus.uploaded);
      expect(tile.mediaId, 'm1');
      expect(cubit.state.isSendable, isTrue);
      expect(finalizedIds.toSet(), {'m1'});
      verifyUploadedOnce();
    });

    test(
      'a Retry that is unavailable again leaves the tile unchecked',
      () async {
        stubFinalize(100, retryAfter: const Duration(seconds: 5));
        picker.next = [imageBytes('a')];
        await cubit.pick();
        await expectLater(
          cubit.uploadAll(),
          throwsA(isA<ScreeningUnavailableException>()),
        );

        await cubit.retryCheck(cubit.state.items.single.id);

        expect(cubit.state.items.single.status, AttachmentStatus.unchecked);
      },
    );

    test('Retry does nothing for a tile that is not unchecked', () async {
      stubFinalize(0);
      picker.next = [imageBytes('a')];
      await cubit.pick();

      await cubit.retryCheck(cubit.state.items.single.id);

      expect(cubit.state.items.single.status, AttachmentStatus.ready);
      expect(finalizeCalls, 0);
    });
  });
}
