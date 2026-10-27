import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/profile/presentation/bloc/post_pin_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockIdentityRepository extends Mock implements IdentityRepository {}

/// W3-17: Pin / Unpin intents, their idempotency keys and the session-long
/// refusal of `profile_extras`.
void main() {
  late _MockIdentityRepository repo;
  late List<identity.Profile> updated;
  late PostPinCubit cubit;
  var refused = false;

  identity.Profile profile(String pin) =>
      identity.Profile(userId: 'me', handle: 'kaif', pinnedPostId: pin);

  setUp(() {
    refused = false;
    repo = _MockIdentityRepository();
    updated = [];
    when(() => repo.profileExtrasRefused).thenAnswer((_) => refused);
    cubit = PostPinCubit(
      identityRepository: repo,
      onProfileUpdated: updated.add,
    );
  });

  tearDown(() => cubit.close());

  Future<identity.Profile> call() => repo.updatePinnedPost(
    idempotencyKey: any(named: 'idempotencyKey'),
    postId: any(named: 'postId'),
  );

  test('pin sends the post id and hands the server profile on', () async {
    when(() => call()).thenAnswer((_) async => profile('42'));

    await cubit.pin('42');

    final captured = verify(
      () => repo.updatePinnedPost(
        idempotencyKey: captureAny(named: 'idempotencyKey'),
        postId: '42',
      ),
    ).captured;
    expect(captured.single, isNotEmpty);
    expect(updated.single.pinnedPostId, '42');
  });

  test('unpin sends an empty post id', () async {
    when(() => call()).thenAnswer((_) async => profile(''));

    await cubit.unpin();

    verify(
      () => repo.updatePinnedPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        postId: '',
      ),
    ).called(1);
    expect(updated.single.pinnedPostId, '');
  });

  test(
    'a retried intent reuses its key; a new intent gets a new one',
    () async {
      final keys = <String>[];
      var fail = true;
      when(() => call()).thenAnswer((invocation) async {
        keys.add(invocation.namedArguments[#idempotencyKey] as String);
        if (fail) throw const NetworkException('offline');
        return profile('42');
      });

      await expectLater(cubit.pin('42'), throwsA(isA<NetworkException>()));
      fail = false;
      await cubit.pin('42');
      expect(keys, hasLength(2));
      expect(keys[0], keys[1], reason: 'the retry is the same intent');

      // Unpin, then pin the same post again: three distinct requests.
      await cubit.unpin();
      await cubit.pin('42');
      expect(keys.toSet(), hasLength(3));
    },
  );

  test('pinning two posts uses two keys', () async {
    final keys = <String>[];
    when(() => call()).thenAnswer((invocation) async {
      keys.add(invocation.namedArguments[#idempotencyKey] as String);
      throw const NetworkException('offline');
    });

    await expectLater(cubit.pin('1'), throwsA(isA<NetworkException>()));
    await expectLater(cubit.pin('2'), throwsA(isA<NetworkException>()));

    expect(keys.toSet(), hasLength(2));
  });

  test('failures are rethrown and nothing is handed on', () async {
    when(() => call()).thenAnswer(
      (_) async =>
          throw const ValidationException('nope', field: 'pinned_post_id'),
    );

    await expectLater(cubit.pin('42'), throwsA(isA<ValidationException>()));
    expect(updated, isEmpty);
    expect(cubit.state.refused, isFalse);
  });

  test('FEATURE_DISABLED profile_extras flips the state to refused', () async {
    when(() => call()).thenAnswer((_) async {
      refused = true;
      throw const FeatureDisabledException('off', feature: 'profile_extras');
    });

    await expectLater(
      cubit.pin('42'),
      throwsA(isA<FeatureDisabledException>()),
    );

    expect(cubit.state.refused, isTrue);
  });

  test('a session that was already refused starts refused', () {
    refused = true;
    final next = PostPinCubit(
      identityRepository: repo,
      onProfileUpdated: (_) {},
    );
    addTearDown(next.close);
    expect(next.state.refused, isTrue);
  });
}
