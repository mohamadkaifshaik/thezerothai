import 'dart:math' as math;

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';

/// A GIF's FinalizeUpload (W6-16): the server screens one GIF at a time and
/// answers a retryable MEDIA_NOT_READY while its slot is busy.
void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late List<Duration> waits;
  late MediaUploader uploader;
  late List<String> finalizeKeys;

  setUp(() {
    repo = MockMediaRepository();
    waits = [];
    finalizeKeys = [];
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

  /// Finalize answers MEDIA_NOT_READY [busy] times, then READY.
  void stubBusy(int busy, {pb.MediaResult Function(String)? then}) {
    var calls = 0;
    when(
      () => repo.finalizeUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        items: any(named: 'items'),
      ),
    ).thenAnswer((invocation) async {
      finalizeKeys.add(invocation.namedArguments[#idempotencyKey] as String);
      if (++calls <= busy) {
        throw const MediaNotReadyException(
          'this GIF is being checked, please try again shortly',
          mediaId: 'm1',
        );
      }
      final items =
          invocation.namedArguments[#items] as List<FinalizeRequestItem>;
      return [for (final i in items) (then ?? readyResult)(i.mediaId)];
    });
  }

  Future<List<UploadOutcome>> uploadGif() => uploader.upload(
    purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
    jobs: [UploadJob(id: 'g', image: fakeGifProcessed())],
  );

  test(
    'a busy GIF slot is waited out quietly: same key, nothing re-PUT',
    () async {
      stubBusy(2);

      final out = await uploadGif();

      expect(out.single.status, UploadOutcomeStatus.ready);
      expect(finalizeKeys, hasLength(3));
      expect(finalizeKeys.toSet(), hasLength(1), reason: 'one key, replayed');
      verify(() => repo.putObject(any(), any()))
          .called(2); // full + thumb, once
      verify(
        () => repo.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      ).called(1);
      expect(waits, hasLength(2));
      // Backoff grows (2 s, 4 s plus at most a quarter of jitter).
      expect(waits[0], greaterThanOrEqualTo(const Duration(seconds: 2)));
      expect(waits[0], lessThanOrEqualTo(const Duration(milliseconds: 2500)));
      expect(waits[1], greaterThanOrEqualTo(const Duration(seconds: 4)));
      expect(waits[1], lessThanOrEqualTo(const Duration(seconds: 5)));
    },
  );

  test('after the retries run out the existing path takes over', () async {
    stubBusy(100);

    await expectLater(uploadGif(), throwsA(isA<MediaNotReadyException>()));

    expect(finalizeKeys, hasLength(4), reason: 'first call + three repeats');
    expect(waits, hasLength(3));
  });

  test('a REJECTED GIF is an outcome, not a retry', () async {
    stubBusy(0, then: (id) => rejectedGif(id));

    final out = await uploadGif();

    expect(out.single.status, UploadOutcomeStatus.rejected);
    expect(out.single.reason, 'This GIF is too large or too long.');
    expect(waits, isEmpty);
  });

  test('a photo\'s MEDIA_NOT_READY is never retried by the uploader', () async {
    stubBusy(1);

    await expectLater(
      uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: [UploadJob(id: 'p', image: fakeProcessed('p'))],
      ),
      throwsA(isA<MediaNotReadyException>()),
    );

    expect(finalizeKeys, hasLength(1));
    expect(waits, isEmpty);
  });
}
