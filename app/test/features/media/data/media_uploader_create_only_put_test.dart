import 'dart:typed_data';

import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_transport.dart';
import '../../../support/media_fixtures.dart';

/// W6-34 (the W6-25 review's Dart follow-up, ADR-0029): since W6-25 the signed
/// upload PUT is create-only (`x-goog-if-generation-match: 0`). A PUT that
/// landed but whose answer was lost makes the retry answer **412**, which means
/// "already stored": the image is `putDone`, FinalizeUpload runs with the same
/// media id, and the user never sees a refusal.
///
/// [MediaUploader] is exercised with the real [MediaRepository.putObject]
/// (where the 412 is read) over a fake create-only bucket, so deleting the 412
/// rule, or the uploader treating the answer as a refusal, fails here. A
/// mocked `putObject` could not show that: a stubbed 412 is just a success.
///
/// `putDone` is private to the uploader, so it is asserted through what it
/// causes: FinalizeUpload is called, and a later `upload()` neither PUTs nor
/// finalizes again.
void main() {
  setUpAll(registerMediaFallbacks);

  const full = '/upload/m1';
  const thumb = '/upload/m1_t';

  late _CreateOnlyBucket bucket;
  late List<Object> reported;
  late MockMediaRepository repo;
  late MediaUploader uploader;
  late DateTime now;
  late List<String> createKeys;
  late List<String> finalizeKeys;
  late List<double> progress;
  late List<List<String>> finalizeMediaIds;
  late List<pb.MediaResult> Function(List<String> mediaIds) finalizeAnswer;

  setUp(() {
    bucket = _CreateOnlyBucket();
    reported = [];
    progress = [];
    finalizeKeys = [];
    createKeys = [];
    finalizeMediaIds = [];
    finalizeAnswer = (ids) => [for (final id in ids) readyResult(id)];
    now = DateTime.now();

    // The real PUT path (status handling lives in MediaRepository.putObject);
    // the API client is never used because createUpload and finalizeUpload
    // are stubbed on the mock below.
    final real = MediaRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((_, _) async => throw StateError('unexpected API call')),
      ),
      httpClient: MockClient(bucket.handle),
      isMediaEnabled: () => true,
      onUnexpectedError: (error, _) => reported.add(error),
    );
    repo = MockMediaRepository();
    when(() => repo.putObject(any(), any())).thenAnswer(
      (invocation) => real.putObject(
        invocation.positionalArguments[0] as pb.SignedUpload,
        invocation.positionalArguments[1] as Uint8List,
      ),
    );
    when(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenAnswer((invocation) async {
      createKeys.add(invocation.namedArguments[#idempotencyKey] as String);
      return [uploadTarget('m1')];
    });
    when(
      () => repo.finalizeUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        items: any(named: 'items'),
      ),
    ).thenAnswer((invocation) async {
      finalizeKeys.add(invocation.namedArguments[#idempotencyKey] as String);
      final ids = [
        for (final item
            in invocation.namedArguments[#items] as List<FinalizeRequestItem>)
          item.mediaId,
      ];
      finalizeMediaIds.add(ids);
      return finalizeAnswer(ids);
    });

    uploader = MediaUploader(repository: repo, clock: () => now);
  });

  Future<List<UploadOutcome>> upload() => uploader.upload(
    purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
    jobs: [UploadJob(id: 'a', image: fakeProcessed('a'))],
    onProgress: (_, p) => progress.add(p),
  );

  /// Nothing more is sent after the image is finished: no PUT, no
  /// CreateUpload, no FinalizeUpload (the image is final, `putDone` is spent).
  Future<void> expectNoFurtherWork() async {
    final puts = bucket.log.length;
    final creates = createKeys.length;
    final finalizes = finalizeKeys.length;

    await upload();

    expect(bucket.log, hasLength(puts));
    expect(createKeys, hasLength(creates));
    expect(finalizeKeys, hasLength(finalizes));
  }

  group('a PUT whose answer was lost', () {
    test('the retry gets 412 for the full image and finalizes once with the '
        'same media id', () async {
      bucket.loseTheAnswerOnce(full);

      final first = await upload();

      expect(first.single.status, UploadOutcomeStatus.failed);
      expect(first.single.error, isA<NetworkException>());
      expect(
        finalizeKeys,
        isEmpty,
        reason: 'nothing is finalized after a loss',
      );
      expect(bucket.log, ['$full landed, answer lost']);

      final second = await upload();

      expect(second.single.status, UploadOutcomeStatus.ready);
      expect(second.single.mediaId, 'm1');
      expect(second.single.error, isNull);
      expect(bucket.log, [
        '$full landed, answer lost',
        '$full 412',
        '$thumb 200',
      ]);
      expect(createKeys, hasLength(1), reason: 'no re-sign, no second create');
      expect(finalizeKeys, hasLength(1));
      expect(finalizeMediaIds, [
        ['m1'],
      ]);
      expect(reported, isEmpty, reason: '412 is not an anomaly to report');
      expect(progress.last, 1);
      await expectNoFurtherWork();
    });

    test('the retry gets 412 for both objects when the thumbnail answer was '
        'lost: putDone only after both, then one finalize', () async {
      bucket.loseTheAnswerOnce(thumb);

      final first = await upload();

      expect(first.single.status, UploadOutcomeStatus.failed);
      expect(first.single.error, isA<NetworkException>());
      expect(finalizeKeys, isEmpty);
      expect(bucket.log, ['$full 200', '$thumb landed, answer lost']);

      final second = await upload();

      expect(second.single.status, UploadOutcomeStatus.ready);
      expect(second.single.mediaId, 'm1');
      expect(second.single.error, isNull);
      expect(bucket.log.skip(2), ['$full 412', '$thumb 412']);
      expect(createKeys, hasLength(1));
      expect(finalizeKeys, hasLength(1));
      expect(finalizeMediaIds, [
        ['m1'],
      ]);
      expect(reported, isEmpty);
      expect(progress.last, 1);
      await expectNoFurtherWork();
    });
  });

  group('a 412 on the very first PUT (no earlier attempt)', () {
    // The client cannot tell this from a lost answer and does not try: it is
    // "already stored" and the server decides at FinalizeUpload, which
    // re-verifies the stored object's size, type and MD5 against the pinned
    // generation (W6-25). The client never calls the bytes good on a 412.
    setUp(() => bucket.preStore([full, thumb]));

    test('is treated as stored: FinalizeUpload runs and a good verdict '
        'publishes, with no refusal shown', () async {
      final out = await upload();

      expect(bucket.log, ['$full 412', '$thumb 412']);
      expect(out.single.status, UploadOutcomeStatus.ready);
      expect(out.single.mediaId, 'm1');
      expect(out.single.error, isNull);
      expect(createKeys, hasLength(1));
      expect(finalizeMediaIds, [
        ['m1'],
      ]);
      expect(reported, isEmpty);
      await expectNoFurtherWork();
    });

    test('the server verdict stays authoritative: REJECTED after a 412 is a '
        'rejection with its reason, not an upload refusal, and is not '
        'retried', () async {
      finalizeAnswer = (ids) => [for (final id in ids) rejectedResult(id, 'x')];

      final out = await upload();

      expect(out.single.status, UploadOutcomeStatus.rejected);
      expect(out.single.reason, 'x');
      expect(out.single.error, isNull);
      expect(finalizeKeys, hasLength(1));
      expect(reported, isEmpty);
      await expectNoFurtherWork();
    });
  });

  group('a 412 followed by a failing FinalizeUpload', () {
    setUp(() => bucket.preStore([full, thumb]));

    test('follows the normal retry path: same key and media id, no second '
        'CreateUpload, no second PUT', () async {
      var calls = 0;
      finalizeAnswer = (ids) {
        if (++calls == 1) throw const NetworkException('offline');
        return [for (final id in ids) readyResult(id)];
      };

      await expectLater(upload(), throwsA(isA<NetworkException>()));
      expect(bucket.log, ['$full 412', '$thumb 412']);

      final out = await upload();

      expect(out.single.status, UploadOutcomeStatus.ready);
      expect(out.single.mediaId, 'm1');
      expect(finalizeKeys, hasLength(2));
      expect(finalizeKeys.last, finalizeKeys.first, reason: 'same key');
      expect(finalizeMediaIds, [
        ['m1'],
        ['m1'],
      ]);
      expect(createKeys, hasLength(1));
      expect(bucket.log, hasLength(2), reason: 'putDone: nothing is re-PUT');
      expect(reported, isEmpty);
      await expectNoFurtherWork();
    });

    test(
      'MEDIA_NOT_READY re-signs under the same create key, the re-PUT gets '
      '412 again, and FinalizeUpload runs again with the same media id',
      () async {
        var calls = 0;
        finalizeAnswer = (ids) {
          if (++calls == 1) {
            throw const MediaNotReadyException('not found', mediaId: 'm1');
          }
          return [for (final id in ids) readyResult(id)];
        };

        await expectLater(upload(), throwsA(isA<MediaNotReadyException>()));

        final out = await upload();

        expect(out.single.status, UploadOutcomeStatus.ready);
        expect(out.single.mediaId, 'm1');
        expect(createKeys, hasLength(2));
        expect(
          createKeys.last,
          createKeys.first,
          reason: 'replay, no new quota',
        );
        expect(bucket.log, [
          '$full 412',
          '$thumb 412',
          '$full 412',
          '$thumb 412',
        ]);
        expect(finalizeMediaIds, [
          ['m1'],
          ['m1'],
        ]);
        expect(reported, isEmpty);
        await expectNoFurtherWork();
      },
    );
  });
}

/// A bucket that honours `x-goog-if-generation-match: 0` (create-only): the
/// first PUT of a path stores it and answers 200, every later PUT of the same
/// path answers 412. [loseTheAnswerOnce] makes the first PUT of a path land
/// and then drop the connection, the case W6-25 exists for.
class _CreateOnlyBucket {
  final Set<String> _stored = {};
  final Set<String> _lose = {};

  /// One line per PUT, in order: `<path> <status>` or
  /// `<path> landed, answer lost`.
  final List<String> log = [];

  void loseTheAnswerOnce(String path) => _lose.add(path);

  void preStore(Iterable<String> paths) => _stored.addAll(paths);

  Future<http.Response> handle(http.Request request) async {
    expect(request.method, 'PUT');
    expect(request.headers['x-goog-if-generation-match'], '0');
    final path = request.url.path;
    if (_stored.contains(path)) {
      log.add('$path 412');
      return http.Response('', 412);
    }
    _stored.add(path);
    if (_lose.remove(path)) {
      log.add('$path landed, answer lost');
      throw http.ClientException('connection reset');
    }
    log.add('$path 200');
    return http.Response('', 200);
  }
}
