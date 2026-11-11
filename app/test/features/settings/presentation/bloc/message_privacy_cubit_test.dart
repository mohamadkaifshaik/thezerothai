import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/settings/data/own_privacy_store.dart';
import 'package:dzeroth/features/settings/domain/message_privacy.dart';
import 'package:dzeroth/features/settings/presentation/bloc/message_privacy_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/data.dart';
import 'package:uuid/uuid.dart';

class _MockIdentity extends Mock implements IdentityRepository {}

class _SeqUuid extends Fake implements Uuid {
  int n = 0;

  @override
  String v4({V4Options? config, Map<String, dynamic>? options}) =>
      'key-${n++}-0123456789abcdef';
}

identity.Profile _profile({
  String uid = 'me',
  bool receipts = false,
  identity.DmPolicy policy = identity.DmPolicy.DM_POLICY_UNSPECIFIED,
}) => identity.Profile(
  userId: uid,
  handle: 'me',
  readReceipts: receipts,
  dmPolicy: policy,
);

void main() {
  late _MockIdentity repo;
  late OwnPrivacyStore store;
  late List<identity.Profile> updated;
  late _SeqUuid uuid;

  setUp(() {
    repo = _MockIdentity();
    store = OwnPrivacyStore();
    updated = [];
    uuid = _SeqUuid();
  });

  MessagePrivacyCubit build({String uid = 'me'}) => MessagePrivacyCubit(
    identityRepository: repo,
    store: store,
    uid: uid,
    onProfileUpdated: updated.add,
    uuid: uuid,
  );

  void stubUpdate(Future<identity.Profile> Function(Invocation) answer) {
    when(
      () => repo.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        readReceipts: any(named: 'readReceipts'),
        dmPolicy: any(named: 'dmPolicy'),
      ),
    ).thenAnswer(answer);
  }

  group('confirmed value', () {
    test('UNSPECIFIED reads as Everyone', () {
      store.record(_profile());
      expect(
        build().state.confirmed,
        const OwnPrivacy(
          userId: 'me',
          readReceipts: false,
          whoCanMessage: WhoCanMessage.everyone,
        ),
      );
    });

    test('another account\'s values are never shown', () {
      store.record(_profile(uid: 'someone-else', receipts: true));
      expect(build().state.confirmed, isNull);
    });

    test('follows the store (a later GetMe) and stops after close', () async {
      final cubit = build();
      expect(cubit.state.confirmed, isNull);
      store.record(_profile(receipts: true));
      expect(cubit.state.confirmed?.readReceipts, isTrue);
      await cubit.close();
      store.record(_profile());
    });

    test('nothing known: a change sends nothing', () async {
      final cubit = build();
      await cubit.setReadReceipts(on: true);
      await cubit.setWhoCanMessage(WhoCanMessage.following);
      verifyNever(
        () => repo.updateProfile(
          idempotencyKey: any(named: 'idempotencyKey'),
          readReceipts: any(named: 'readReceipts'),
          dmPolicy: any(named: 'dmPolicy'),
        ),
      );
    });
  });

  group('read receipts', () {
    blocTest<MessagePrivacyCubit, MessagePrivacyState>(
      'on: shows the server value while saving, then the server answer',
      setUp: () {
        store.record(_profile());
        stubUpdate((_) async => _profile(receipts: true));
      },
      build: build,
      act: (cubit) => cubit.setReadReceipts(on: true),
      expect: () => [
        // Saving: the confirmed value is still OFF (never optimistic).
        isA<MessagePrivacyState>()
            .having((s) => s.savingReceipts, 'saving', true)
            .having((s) => s.confirmed?.readReceipts, 'confirmed', false),
        // The server said ON.
        isA<MessagePrivacyState>()
            .having((s) => s.savingReceipts, 'saving', true)
            .having((s) => s.confirmed?.readReceipts, 'confirmed', true),
        isA<MessagePrivacyState>()
            .having((s) => s.savingReceipts, 'saving', isNull)
            .having((s) => s.busy, 'busy', isFalse),
      ],
      verify: (_) {
        verify(
          () => repo.updateProfile(
            idempotencyKey: 'key-0-0123456789abcdef',
            readReceipts: true,
          ),
        ).called(1);
        expect(updated.single.readReceipts, isTrue);
        expect(store.value?.readReceipts, isTrue);
      },
    );

    blocTest<MessagePrivacyCubit, MessagePrivacyState>(
      'a failure keeps the server value, reports, and a retry reuses the key',
      setUp: () {
        store.record(_profile());
        var calls = 0;
        stubUpdate((_) async {
          if (calls++ == 0) throw const NetworkException('offline');
          return _profile(receipts: true);
        });
      },
      build: build,
      act: (cubit) async {
        await cubit.setReadReceipts(on: true);
        await cubit.setReadReceipts(on: true);
      },
      skip: 1,
      expect: () => [
        isA<MessagePrivacyState>()
            .having((s) => s.confirmed?.readReceipts, 'confirmed', false)
            .having((s) => s.error, 'error', isA<NetworkException>())
            .having((s) => s.serial, 'serial', 1)
            .having((s) => s.busy, 'busy', isFalse),
        isA<MessagePrivacyState>().having((s) => s.savingReceipts, 's', true),
        isA<MessagePrivacyState>().having(
          (s) => s.confirmed?.readReceipts,
          'confirmed',
          true,
        ),
        isA<MessagePrivacyState>().having((s) => s.busy, 'busy', isFalse),
      ],
      verify: (_) {
        verify(
          () => repo.updateProfile(
            idempotencyKey: 'key-0-0123456789abcdef',
            readReceipts: true,
          ),
        ).called(2);
      },
    );

    blocTest<MessagePrivacyCubit, MessagePrivacyState>(
      'FEATURE_DISABLED on turning on marks it refused',
      setUp: () {
        store.record(_profile());
        stubUpdate(
          (_) async => throw const FeatureDisabledException(
            'off',
            feature: kFeatureReadReceipts,
          ),
        );
      },
      build: build,
      act: (cubit) => cubit.setReadReceipts(on: true),
      skip: 1,
      expect: () => [
        isA<MessagePrivacyState>()
            .having((s) => s.receiptsRefused, 'refused', isTrue)
            .having((s) => s.followingRefused, 'following', isFalse)
            .having((s) => s.confirmed?.readReceipts, 'confirmed', false),
      ],
    );

    blocTest<MessagePrivacyCubit, MessagePrivacyState>(
      'turning off is never marked refused',
      setUp: () {
        store.record(_profile(receipts: true));
        stubUpdate((_) async => throw const FeatureDisabledException('off'));
      },
      build: build,
      act: (cubit) => cubit.setReadReceipts(on: false),
      skip: 1,
      expect: () => [
        isA<MessagePrivacyState>()
            .having((s) => s.receiptsRefused, 'refused', isFalse)
            .having((s) => s.confirmed?.readReceipts, 'confirmed', true),
      ],
    );

    blocTest<MessagePrivacyCubit, MessagePrivacyState>(
      'a change to the value the server has, or while saving, is ignored',
      setUp: () {
        store.record(_profile());
        stubUpdate((_) async {
          await Future<void>.delayed(Duration.zero);
          return _profile(receipts: true);
        });
      },
      build: build,
      act: (cubit) async {
        await cubit.setReadReceipts(on: false);
        final first = cubit.setReadReceipts(on: true);
        await cubit.setReadReceipts(on: true);
        await cubit.setWhoCanMessage(WhoCanMessage.following);
        await first;
      },
      verify: (_) {
        verify(
          () => repo.updateProfile(
            idempotencyKey: any(named: 'idempotencyKey'),
            readReceipts: any(named: 'readReceipts'),
            dmPolicy: any(named: 'dmPolicy'),
          ),
        ).called(1);
      },
    );
  });

  group('who can message', () {
    blocTest<MessagePrivacyCubit, MessagePrivacyState>(
      'People you follow sends FOLLOWING_ONLY, never UNSPECIFIED',
      setUp: () {
        store.record(_profile());
        stubUpdate(
          (_) async =>
              _profile(policy: identity.DmPolicy.DM_POLICY_FOLLOWING_ONLY),
        );
      },
      build: build,
      act: (cubit) => cubit.setWhoCanMessage(WhoCanMessage.following),
      expect: () => [
        isA<MessagePrivacyState>()
            .having((s) => s.savingWho, 'saving', WhoCanMessage.following)
            .having(
              (s) => s.confirmed?.whoCanMessage,
              'confirmed',
              WhoCanMessage.everyone,
            ),
        isA<MessagePrivacyState>().having(
          (s) => s.confirmed?.whoCanMessage,
          'confirmed',
          WhoCanMessage.following,
        ),
        isA<MessagePrivacyState>().having((s) => s.busy, 'busy', isFalse),
      ],
      verify: (_) {
        verify(
          () => repo.updateProfile(
            idempotencyKey: 'key-0-0123456789abcdef',
            dmPolicy: identity.DmPolicy.DM_POLICY_FOLLOWING_ONLY,
          ),
        ).called(1);
      },
    );

    blocTest<MessagePrivacyCubit, MessagePrivacyState>(
      'Everyone sends EVERYONE_REQUESTS',
      setUp: () {
        store.record(
          _profile(policy: identity.DmPolicy.DM_POLICY_FOLLOWING_ONLY),
        );
        stubUpdate(
          (_) async =>
              _profile(policy: identity.DmPolicy.DM_POLICY_EVERYONE_REQUESTS),
        );
      },
      build: build,
      act: (cubit) => cubit.setWhoCanMessage(WhoCanMessage.everyone),
      verify: (cubit) {
        verify(
          () => repo.updateProfile(
            idempotencyKey: any(named: 'idempotencyKey'),
            dmPolicy: identity.DmPolicy.DM_POLICY_EVERYONE_REQUESTS,
          ),
        ).called(1);
        expect(cubit.state.confirmed?.whoCanMessage, WhoCanMessage.everyone);
      },
    );

    blocTest<MessagePrivacyCubit, MessagePrivacyState>(
      'FEATURE_DISABLED on People you follow marks it refused, value kept',
      setUp: () {
        store.record(_profile());
        stubUpdate(
          (_) async => throw const FeatureDisabledException(
            'off',
            feature: kFeatureDmPolicy,
          ),
        );
      },
      build: build,
      act: (cubit) => cubit.setWhoCanMessage(WhoCanMessage.following),
      skip: 1,
      expect: () => [
        isA<MessagePrivacyState>()
            .having((s) => s.followingRefused, 'refused', isTrue)
            .having((s) => s.receiptsRefused, 'receipts', isFalse)
            .having(
              (s) => s.confirmed?.whoCanMessage,
              'confirmed',
              WhoCanMessage.everyone,
            ),
      ],
    );

    blocTest<MessagePrivacyCubit, MessagePrivacyState>(
      'an unexpected error is reported generically, the value kept',
      setUp: () {
        store.record(_profile());
        stubUpdate((_) async => throw StateError('boom'));
      },
      build: build,
      act: (cubit) => cubit.setWhoCanMessage(WhoCanMessage.following),
      skip: 1,
      expect: () => [
        isA<MessagePrivacyState>()
            .having((s) => s.error, 'error', isA<UnknownApiException>())
            .having((s) => s.busy, 'busy', isFalse),
      ],
    );
  });

  test('an answer for another account is not recorded', () async {
    store.record(_profile());
    stubUpdate((_) async => _profile(uid: 'other', receipts: true));
    final cubit = build();
    await cubit.setReadReceipts(on: true);
    expect(store.value?.userId, 'me');
    expect(store.value?.readReceipts, isFalse);
    expect(updated, isEmpty);
    await cubit.close();
  });
}
