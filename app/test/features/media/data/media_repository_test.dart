import 'dart:typed_data';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../../support/fake_transport.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/posts_fixtures.dart';

const _create = '/dzeroth.media.v1.MediaService/CreateUpload';
const _finalize = '/dzeroth.media.v1.MediaService/FinalizeUpload';

void main() {
  late FakeTransport transport;
  late Object Function(String procedure, Object input) answer;
  late List<Object> requests;
  late List<http.BaseRequest> puts;
  late int putStatus;
  late bool enabled;
  late RateLimitHold hold;
  late int disabledCalls;
  late List<Object> reported;
  late MediaRepository repo;
  var putThrows = false;

  setUp(() {
    enabled = true;
    putStatus = 200;
    putThrows = false;
    requests = [];
    puts = [];
    disabledCalls = 0;
    reported = [];
    hold = RateLimitHold();
    answer = (_, _) => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer(procedure, input);
      if (r is Exception) throw r;
      return r;
    });
    repo = MediaRepository(
      apiClient: ApiClient.withTransport(transport),
      httpClient: MockClient((request) async {
        puts.add(request);
        if (putThrows) throw http.ClientException('socket closed');
        return http.Response('', putStatus);
      }),
      isMediaEnabled: () => enabled,
      rateLimitHold: hold,
      onFeatureDisabled: () => disabledCalls++,
      onUnexpectedError: (error, _) => reported.add(error),
    );
  });

  group('createUpload', () {
    test('sends sizes, types and md5 and returns the targets', () async {
      answer = (_, _) => pb.CreateUploadResponse(targets: [uploadTarget('m1')]);

      final targets = await repo.createUpload(
        idempotencyKey: 'k',
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        images: [fakeProcessed('a')],
      );

      expect(targets.single.mediaId, 'm1');
      final sent = requests.single as pb.CreateUploadRequest;
      expect(sent.idempotencyKey, 'k');
      expect(sent.purpose, pb.MediaPurpose.MEDIA_PURPOSE_POST);
      final item = sent.items.single;
      expect(item.contentType, 'image/jpeg');
      expect(item.fullSizeBytes.toInt(), 40);
      expect(item.thumbSizeBytes.toInt(), fakeProcessed('a').thumbBytes.length);
      expect(item.fullMd5, 'full-a');
      expect(item.width, 800);
    });

    test('flag off: no RPC is sent', () async {
      enabled = false;

      await expectLater(
        repo.createUpload(
          idempotencyKey: 'k',
          purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
          images: [fakeProcessed()],
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(transport.calledProcedures, isEmpty);
    });

    test('a held daily read budget is thrown without sending', () async {
      hold.record(
        const RateLimitedException(
          'slow down',
          retryAfter: Duration(minutes: 30),
          limitName: 'read_budget_daily',
        ),
      );

      await expectLater(
        repo.createUpload(
          idempotencyKey: 'k',
          purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
          images: [fakeProcessed()],
        ),
        throwsA(isA<RateLimitedException>()),
      );
      expect(transport.calledProcedures, isEmpty);
    });

    test('a daily read budget answer is recorded in the shared hold', () async {
      answer = (_, _) => serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        metadata: {'limit': 'read_budget_daily'},
      );

      await expectLater(
        repo.createUpload(
          idempotencyKey: 'k',
          purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
          images: [fakeProcessed()],
        ),
        throwsA(isA<RateLimitedException>()),
      );

      expect(hold.check(), isNotNull);
    });

    test(
      'a per-minute media limit is NOT recorded (reads keep working)',
      () async {
        answer = (_, _) => serverError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_RATE_LIMITED,
          metadata: {'limit': 'post_create_minute'},
        );

        await expectLater(
          repo.createUpload(
            idempotencyKey: 'k',
            purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
            images: [fakeProcessed()],
          ),
          throwsA(isA<RateLimitedException>()),
        );

        expect(hold.check(), isNull);
      },
    );

    test('server FEATURE_DISABLED asks the app to refresh the flags', () async {
      answer = (_, _) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'media'},
      );

      await expectLater(
        repo.createUpload(
          idempotencyKey: 'k',
          purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
          images: [fakeProcessed()],
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(disabledCalls, 1);
    });

    test('a target count that does not match is an unexpected error', () async {
      answer = (_, _) => pb.CreateUploadResponse();

      await expectLater(
        repo.createUpload(
          idempotencyKey: 'k',
          purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
          images: [fakeProcessed()],
        ),
        throwsA(isA<UnknownApiException>()),
      );
    });
  });

  group('putObject', () {
    test(
      'PUTs the bytes with exactly the signed headers and no auth',
      () async {
        final target = uploadTarget('m1').full;

        await repo.putObject(target, Uint8List.fromList([1, 2, 3]));

        final request = puts.single as http.Request;
        expect(request.method, 'PUT');
        expect(request.url.toString(), target.url);
        expect(request.bodyBytes, [1, 2, 3]);
        expect(request.headers['Content-MD5'], 'md5-m1');
        expect(request.headers['x-goog-content-length-range'], '0,2097152');
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
        );
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-firebase-appcheck')),
        );
      },
    );

    test('a storage refusal is unexpected and reported', () async {
      putStatus = 403;

      await expectLater(
        repo.putObject(uploadTarget('m1').full, Uint8List(1)),
        throwsA(isA<UnknownApiException>()),
      );
      expect(reported, hasLength(1));
    });

    test('a dropped connection is a NetworkException', () async {
      putThrows = true;

      await expectLater(
        repo.putObject(uploadTarget('m1').full, Uint8List(1)),
        throwsA(isA<NetworkException>()),
      );
    });
  });

  group('finalizeUpload', () {
    test('sends media ids and blurhashes, returns the results', () async {
      answer = (_, _) =>
          pb.FinalizeUploadResponse(results: [readyResult('m1')]);

      final results = await repo.finalizeUpload(
        idempotencyKey: 'f1',
        items: const [FinalizeRequestItem(mediaId: 'm1', blurhash: 'LEHV')],
      );

      expect(results.single.status, pb.MediaStatus.MEDIA_STATUS_READY);
      final sent = requests.single as pb.FinalizeUploadRequest;
      expect(sent.idempotencyKey, 'f1');
      expect(sent.items.single.blurhash, 'LEHV');
      expect(transport.calledProcedures, [_finalize]);
      expect(_create, isNotEmpty);
    });
  });
}
