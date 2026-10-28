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

/// W3-33b: the protect request is shaped exactly (is_private alone, `false`
/// still present) and a FEATURE_DISABLED answer to turning it ON is remembered
/// for 10 minutes, while turning it off is never remembered.
void main() {
  late AppDatabase db;
  late IdentityRepository repo;
  late List<Object> requests;
  late Object Function() answer;
  late DateTime now;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    requests = [];
    now = DateTime.now();
    answer = () => throw StateError('unscripted');
    repo = IdentityRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) async {
          requests.add(input);
          final r = answer();
          if (r is Exception) throw r;
          return r;
        }),
      ),
      database: db,
      clock: () => now,
    );
  });

  tearDown(() => db.close());

  Object disabled() => serverError(
    connect.Code.failedPrecondition,
    common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
    metadata: {'feature': 'private_accounts'},
  );

  test('protecting sends is_private alone; unprotecting keeps false', () async {
    answer = () => identity.UpdateProfileResponse(
      profile: identity.Profile(userId: 'me', handle: 'k', isPrivate: true),
    );
    await repo.setProtected(
      idempotencyKey: 'key-1234567890abcdef',
      protect: true,
    );
    final on = requests.single as identity.UpdateProfileRequest;
    expect(on.hasIsPrivate(), isTrue);
    expect(on.isPrivate, isTrue);
    expect(on.hasDisplayName(), isFalse);
    expect(on.hasBio(), isFalse);
    expect(on.hasPinnedPostId(), isFalse);

    requests.clear();
    answer = () => identity.UpdateProfileResponse(
      profile: identity.Profile(userId: 'me', handle: 'k'),
    );
    await repo.setProtected(
      idempotencyKey: 'key-abcdef1234567890',
      protect: false,
    );
    final off = requests.single as identity.UpdateProfileRequest;
    expect(off.hasIsPrivate(), isTrue, reason: 'false is a real field');
    expect(off.isPrivate, isFalse);
    expect(
      identity.UpdateProfileRequest.fromBuffer(off.writeToBuffer())
          .hasIsPrivate(),
      isTrue,
    );
  });

  test('FEATURE_DISABLED on turn-on is remembered for 10 minutes', () async {
    answer = disabled;
    await expectLater(
      repo.setProtected(idempotencyKey: 'key-1234567890abcdef', protect: true),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(repo.privateAccountsRefused, isTrue);
    now = now.add(kPrivateAccountsRefusalBackoff - const Duration(seconds: 1));
    expect(repo.privateAccountsRefused, isTrue);
    now = now.add(const Duration(seconds: 2));
    expect(repo.privateAccountsRefused, isFalse);
  });

  test('a refusal of turning it off is never remembered', () async {
    answer = disabled;
    await expectLater(
      repo.setProtected(idempotencyKey: 'key-1234567890abcdef', protect: false),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(repo.privateAccountsRefused, isFalse);
  });
}
