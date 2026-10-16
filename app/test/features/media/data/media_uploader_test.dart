
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

import '../../../support/media_fixtures.dart';

void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late DateTime now;
  late int keyCounter;
  late MediaUploader uploader;

  setUp(() {
    repo = MockMediaRepository();
    now = DateTime.utc(2026, 10, 14, 12);
    keyCounter = 0;
    uploader = MediaUploader(
      repository: repo,
      clock: () => now,
      uuid: _CountingUuid(() => 'key-${++keyCounter}'),
    );
  });

  void stubCreate(
    List<String> ids, {
    Duration ttl = const Duration(minutes: 10),
  }) {
    when(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenAnswer(
      (_) async => [
        for (final id in ids) uploadTarget(id, expiresAt: now.add(ttl)),
      ],
    );
  }

  void stubPutOk() {
    when(() => repo.putObject(any(), any())).thenAnswer((_) async {});
  }

  void stubFinalize(pb.MediaResult Function(String id) result) {
    when(
      () => repo.finalizeUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        items: any(named: 'items'),
      ),
    ).thenAnswer((invocation) async {
      final items =
          invocation.namedArguments[#items] as List<FinalizeRequestItem>;
      return [for (final item in items) result(item.mediaId)];
    });
  }

  List<UploadJob> jobs(List<String> ids) => [
    for (final id in ids) UploadJob(id: id, image: fakeProcessed(id)),
  ];

  test(
    'reserves, PUTs full then thumb, finalizes and reports progress',
    () async {
      stubCreate(['m1']);
      stubPutOk();
      stubFinalize(readyResult);
      final progress = <double>[];

      final out = await uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a']),
        onProgress: (_, p) => progress.add(p),
      );

      expect(out.single.status, UploadOutcomeStatus.ready);
      expect(out.single.mediaId, 'm1');
      expect(progress.last, 1);
      verify(() => repo.putObject(any(), any())).called(2);
      final sent =
          verify(
                () => repo.finalizeUpload(
                  idempotencyKey: any(named: 'idempotencyKey'),
                  items: captureAny(named: 'items'),
                ),
              ).captured.single
              as List<FinalizeRequestItem>;
      expect(sent.single.blurhash, isNotEmpty);
    },
  );

  test('READY_UNSCREENED counts as published', () async {
    stubCreate(['m1']);
    stubPutOk();
    stubFinalize(
      (id) => pb.MediaResult(
        mediaId: id,
        status: pb.MediaStatus.MEDIA_STATUS_READY_UNSCREENED,
      ),
    );

    final out = await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );

    expect(out.single.status, UploadOutcomeStatus.ready);
  });

  test('a rejected image reports the reason and is not retried', () async {
    stubCreate(['m1']);
    stubPutOk();
    stubFinalize((id) => rejectedResult(id, 'Not allowed'));

    final first = await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );
    final second = await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );

    expect(first.single.status, UploadOutcomeStatus.rejected);
    expect(first.single.reason, 'Not allowed');
    expect(second.single.status, UploadOutcomeStatus.rejected);
    verify(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).called(1);
  });

  test('retry after a failed PUT repeats only that image and keeps the '
      'reservation (no second CreateUpload, no quota spent)', () async {
    stubCreate(['m1', 'm2']);
    stubFinalize(readyResult);
    var failM2 = true;
    when(() => repo.putObject(any(), any())).thenAnswer((invocation) async {
      final target = invocation.positionalArguments.first as pb.SignedUpload;
      if (failM2 && target.url.contains('m2')) {
        throw const NetworkException('offline');
      }
    });

    final first = await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a', 'b']),
    );
    expect(first[0].status, UploadOutcomeStatus.ready);
    expect(first[1].status, UploadOutcomeStatus.failed);
    expect(first[1].error, isA<NetworkException>());

    failM2 = false;
    final second = await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a', 'b']),
    );

    expect(
      second.map((o) => o.status),
      everyElement(UploadOutcomeStatus.ready),
    );
    verify(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).called(1);
    // a: 2 PUTs; b: 1 (full fails) + 2 on retry. a is not uploaded again.
    verify(() => repo.putObject(any(), any())).called(5);
  });

  test(
    'a failed FinalizeUpload retries with the same key and no new PUTs',
    () async {
      stubCreate(['m1']);
      stubPutOk();
      var calls = 0;
      final keys = <String>[];
      when(
        () => repo.finalizeUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          items: any(named: 'items'),
        ),
      ).thenAnswer((invocation) async {
        keys.add(invocation.namedArguments[#idempotencyKey] as String);
        if (++calls == 1) throw const NetworkException('offline');
        return [readyResult('m1')];
      });

      await expectLater(
        uploader.upload(
          purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
          jobs: jobs(['a']),
        ),
        throwsA(isA<NetworkException>()),
      );
      final out = await uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a']),
      );

      expect(out.single.status, UploadOutcomeStatus.ready);
      expect(keys.toSet(), hasLength(1));
      verify(() => repo.putObject(any(), any())).called(2);
    },
  );

  test('a CreateUpload that failed is retried under the same key', () async {
    final keys = <String>[];
    var calls = 0;
    when(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenAnswer((invocation) async {
      keys.add(invocation.namedArguments[#idempotencyKey] as String);
      if (++calls == 1) throw const NetworkException('offline');
      return [
        uploadTarget('m1', expiresAt: now.add(const Duration(minutes: 10))),
      ];
    });
    stubPutOk();
    stubFinalize(readyResult);

    await expectLater(
      uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a']),
      ),
      throwsA(isA<NetworkException>()),
    );
    await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );

    expect(keys, ['key-1', 'key-1']);
  });

  void stubCreateRecording(List<String> keys, {String id = 'm1'}) {
    when(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenAnswer((invocation) async {
      keys.add(invocation.namedArguments[#idempotencyKey] as String);
      // Replay: the same media id, fresh URLs.
      return [uploadTarget(id)];
    });
  }

  test(
    'an expired reservation is re-signed by replaying the same key',
    () async {
      final keys = <String>[];
      stubCreateRecording(keys);
      var failFirstPut = true;
      when(() => repo.putObject(any(), any())).thenAnswer((_) async {
        if (failFirstPut) {
          failFirstPut = false;
          throw const NetworkException('offline');
        }
      });
      stubFinalize(readyResult);

      final first = await uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a']),
      );
      expect(first.single.status, UploadOutcomeStatus.failed);

      now = now.add(const Duration(minutes: 11)); // the signed URLs are dead
      final second = await uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a']),
      );

      expect(second.single.status, UploadOutcomeStatus.ready);
      expect(second.single.mediaId, 'm1');
      expect(keys, ['key-1', 'key-1']);
    },
  );

  test('expiry is measured from local receipt, not server expiresAt', () async {
    final keys = <String>[];
    stubCreateRecording(keys);
    stubPutOk();
    var calls = 0;
    when(() => repo.putObject(any(), any())).thenAnswer((_) async {
      if (++calls == 1) throw const NetworkException('offline');
    });
    stubFinalize(readyResult);
    await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );

    // Only 5 minutes passed locally: the reservation is reused even though
    // the (unset here) server timestamp says nothing.
    now = now.add(const Duration(minutes: 5));
    await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );

    expect(keys, ['key-1']);
  });

  test('a finished PUT is not re-signed when the URLs have expired', () async {
    final keys = <String>[];
    stubCreateRecording(keys);
    stubPutOk();
    var finalizeCalls = 0;
    when(
      () => repo.finalizeUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        items: any(named: 'items'),
      ),
    ).thenAnswer((_) async {
      if (++finalizeCalls == 1) throw const NetworkException('offline');
      return [readyResult('m1')];
    });

    await expectLater(
      uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a']),
      ),
      throwsA(isA<NetworkException>()),
    );
    now = now.add(const Duration(minutes: 30));
    final out = await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );

    expect(out.single.status, UploadOutcomeStatus.ready);
    expect(keys, ['key-1']);
    verify(() => repo.putObject(any(), any())).called(2); // full + thumb, once
  });

  test('a storage 403 drops the URLs and re-signs under the same key', () async {
    final keys = <String>[];
    stubCreateRecording(keys);
    var refuse = true;
    when(() => repo.putObject(any(), any())).thenAnswer((_) async {
      if (refuse) {
        refuse = false;
        throw const StorageRefusedException(403);
      }
    });
    stubFinalize(readyResult);

    final first = await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );
    expect(first.single.status, UploadOutcomeStatus.failed);

    final second = await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );

    expect(second.single.status, UploadOutcomeStatus.ready);
    expect(keys, ['key-1', 'key-1']);
  });

  group('a finished sibling does not break the replayed group', () {
    late List<String> keys;
    late List<String> putUrls;

    void stubGroup({required Object? Function() failB}) {
      keys = [];
      putUrls = [];
      when(
        () => repo.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      ).thenAnswer((invocation) async {
        keys.add(invocation.namedArguments[#idempotencyKey] as String);
        final n = (invocation.namedArguments[#images] as List).length;
        return [for (var i = 1; i <= n; i++) uploadTarget('m$i')];
      });
      when(() => repo.putObject(any(), any())).thenAnswer((invocation) async {
        final target = invocation.positionalArguments.first as pb.SignedUpload;
        putUrls.add(target.url);
        if (target.url.contains('m2')) {
          final error = failB();
          if (error != null) throw error;
        }
      });
      stubFinalize(readyResult);
    }

    test('storage refuses b (403): replay keeps the key, only b is PUT '
        'again', () async {
      var refuse = true;
      stubGroup(
        failB: () {
          if (!refuse) return null;
          refuse = false;
          return const StorageRefusedException(403);
        },
      );

      final first = await uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a', 'b']),
      );
      expect(first[0].status, UploadOutcomeStatus.ready);
      expect(first[1].status, UploadOutcomeStatus.failed);
      expect(first[1].error, isA<UploadInterruptedException>());

      putUrls.clear();
      final second = await uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a', 'b']),
      );

      expect(
        second.map((o) => o.status),
        everyElement(UploadOutcomeStatus.ready),
      );
      expect(keys, ['key-1', 'key-1']);
      expect(putUrls, hasLength(2));
      expect(putUrls, everyElement(contains('m2')));
    });

    test('b fails and its URLs expire: replay keeps the key', () async {
      var fail = true;
      stubGroup(
        failB: () {
          if (!fail) return null;
          fail = false;
          return const NetworkException('offline');
        },
      );

      await uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a', 'b']),
      );
      now = now.add(const Duration(minutes: 11));
      putUrls.clear();
      final second = await uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a', 'b']),
      );

      expect(
        second.map((o) => o.status),
        everyElement(UploadOutcomeStatus.ready),
      );
      expect(keys, ['key-1', 'key-1']);
      expect(putUrls, everyElement(contains('m2')));
    });

    test('removing the finished sibling mints a new key', () async {
      var fail = true;
      stubGroup(
        failB: () {
          if (!fail) return null;
          fail = false;
          return const StorageRefusedException(403);
        },
      );
      await uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['a', 'b']),
      );

      uploader.forget('a');
      await uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs(['b']),
      );

      expect(keys, hasLength(2));
      expect(keys[1], isNot(keys[0]));
    });
  });

  test('a PUT 5xx and a refusal are non-Unknown (never double-reported)',
      () async {
    stubCreate(['m1']);
    when(
      () => repo.putObject(any(), any()),
    ).thenThrow(const UnknownApiException('Upload refused (503).'));

    final out = await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );

    expect(out.single.error, isA<UploadInterruptedException>());
  });

  test('forget drops the remembered result of a removed image', () async {
    stubCreate(['m1']);
    stubPutOk();
    stubFinalize(readyResult);
    await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );

    uploader.forget('a');
    stubCreate(['m2']);
    final out = await uploader.upload(
      purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
      jobs: jobs(['a']),
    );

    expect(out.single.mediaId, 'm2');
  });
}

class _CountingUuid implements Uuid {
  _CountingUuid(this._next);
  final String Function() _next;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #v4) return _next();
    return super.noSuchMethod(invocation);
  }
}
