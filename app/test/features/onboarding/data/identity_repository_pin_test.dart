import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _update = '/dzeroth.identity.v1.IdentityService/UpdateProfile';
const _getMe = '/dzeroth.identity.v1.IdentityService/GetMe';

/// W3-17: the pin request is shaped exactly (field presence is the signal),
/// and a refusal of `profile_extras` is remembered until the next GetMe.
void main() {
  late AppDatabase db;
  late FakeTransport transport;
  late IdentityRepository repo;
  late List<Object> requests;
  late Object Function(String procedure) answer;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    requests = [];
    answer = (_) => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer(procedure);
      if (r is Exception) throw r;
      return r;
    });
    repo = IdentityRepository(
      apiClient: ApiClient.withTransport(transport),
      database: db,
    );
  });

  tearDown(() => db.close());

  identity.Profile profile({String pin = ''}) => identity.Profile(
    userId: 'me',
    handle: 'kaif',
    displayName: 'Kaif',
    pinnedPostId: pin,
  );

  test('pinning sends pinned_post_id and nothing else', () async {
    answer = (_) => identity.UpdateProfileResponse(profile: profile(pin: '42'));

    final result = await repo.updatePinnedPost(
      idempotencyKey: 'key-1234567890abcdef',
      postId: '42',
    );

    final sent = requests.single as identity.UpdateProfileRequest;
    expect(sent.idempotencyKey, 'key-1234567890abcdef');
    expect(sent.hasPinnedPostId(), isTrue);
    expect(sent.pinnedPostId, '42');
    expect(sent.hasDisplayName(), isFalse);
    expect(sent.hasBio(), isFalse);
    expect(sent.hasAvatarMediaId(), isFalse);
    expect(sent.hasBannerMediaId(), isFalse);
    expect(sent.hasLocation(), isFalse);
    expect(sent.hasWebsite(), isFalse);
    expect(sent.hasIsPrivate(), isFalse);
    expect(transport.calledProcedures, [_update]);
    expect(result.pinnedPostId, '42');
  });

  test(
    'unpinning sends an empty pinned_post_id that is still present',
    () async {
      answer = (_) => identity.UpdateProfileResponse(profile: profile());

      await repo.updatePinnedPost(
        idempotencyKey: 'key-1234567890abcdef',
        postId: '',
      );

      final sent = requests.single as identity.UpdateProfileRequest;
      expect(
        sent.hasPinnedPostId(),
        isTrue,
        reason: '"" must stay a real field',
      );
      expect(sent.pinnedPostId, '');
      // On the wire, presence is what tells "clear" from "leave alone".
      expect(sent.writeToBuffer(), isNotEmpty);
      final decoded = identity.UpdateProfileRequest.fromBuffer(
        sent.writeToBuffer(),
      );
      expect(decoded.hasPinnedPostId(), isTrue);
      expect(decoded.pinnedPostId, '');
    },
  );

  test('a name or bio save leaves pinned_post_id out', () async {
    answer = (_) => identity.UpdateProfileResponse(profile: profile());

    await repo.updateProfile(
      idempotencyKey: 'key-1234567890abcdef',
      displayName: 'Kaif S',
    );

    final sent = requests.single as identity.UpdateProfileRequest;
    expect(sent.hasPinnedPostId(), isFalse);
  });

  test('FEATURE_DISABLED profile_extras is remembered until GetMe', () async {
    expect(repo.profileExtrasRefused, isFalse);
    answer = (_) => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      metadata: {'feature': 'profile_extras'},
    );

    await expectLater(
      repo.updatePinnedPost(
        idempotencyKey: 'key-1234567890abcdef',
        postId: '1',
      ),
      throwsA(
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          'profile_extras',
        ),
      ),
    );
    expect(repo.profileExtrasRefused, isTrue);

    answer = (_) => identity.GetMeResponse(profile: profile());
    await repo.getMe();
    expect(transport.calledProcedures.last, _getMe);
    expect(repo.profileExtrasRefused, isFalse);
  });

  test(
    'another feature being disabled is not a profile_extras refusal',
    () async {
      answer = (_) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'something_else'},
      );

      await expectLater(
        repo.updatePinnedPost(
          idempotencyKey: 'key-1234567890abcdef',
          postId: '1',
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(repo.profileExtrasRefused, isFalse);
    },
  );

  test('a VALIDATION answer carries the field and is not remembered', () async {
    answer = (_) => rejectedToken('pinned_post_id');

    await expectLater(
      repo.updatePinnedPost(
        idempotencyKey: 'key-1234567890abcdef',
        postId: '1',
      ),
      throwsA(
        isA<ValidationException>().having(
          (e) => e.field,
          'field',
          'pinned_post_id',
        ),
      ),
    );
    expect(repo.profileExtrasRefused, isFalse);
  });
}
