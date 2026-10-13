import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart'
    show HandleCheckStatus;
import 'package:dzeroth/features/profile/presentation/bloc/change_handle_cubit.dart';
import 'package:dzeroth/features/profile/presentation/bloc/edit_profile_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockIdentityRepository extends Mock implements IdentityRepository {}

identity.Profile profile({
  String handle = 'kaif',
  String name = 'Kaif',
  String bio = 'hello',
}) =>
    identity.Profile(userId: 'me', handle: handle, displayName: name, bio: bio);

void main() {
  late MockIdentityRepository repo;

  setUp(() => repo = MockIdentityRepository());

  group('EditProfileCubit', () {
    late EditProfileCubit cubit;

    setUp(() {
      cubit = EditProfileCubit(identityRepository: repo, initial: profile());
    });

    tearDown(() => cubit.close());

    void stubUpdate(Future<identity.Profile> Function() answer) {
      when(
        () => repo.updateProfile(
          idempotencyKey: any(named: 'idempotencyKey'),
          displayName: any(named: 'displayName'),
          bio: any(named: 'bio'),
        ),
      ).thenAnswer((_) => answer());
    }

    test('starts unchanged: nothing to save', () {
      expect(cubit.hasChanges, isFalse);
      expect(cubit.canSave, isFalse);
      expect(cubit.state.displayNameRemaining, 46);
    });

    test(
      'saves only the changed field and reports the server profile',
      () async {
        stubUpdate(() async => profile(name: 'Kaif S'));
        cubit.displayNameChanged('  Kaif S  ');
        expect(cubit.canSave, isTrue);

        await cubit.save();

        expect(cubit.state.status, EditProfileStatus.saved);
        expect(cubit.state.saved!.displayName, 'Kaif S');
        final call = verify(
          () => repo.updateProfile(
            idempotencyKey: any(named: 'idempotencyKey'),
            displayName: captureAny(named: 'displayName'),
            bio: captureAny(named: 'bio'),
          ),
        );
        expect(call.captured, ['Kaif S', null]);
      },
    );

    test(
      'clearing the bio sends an empty bio; an empty name blocks save',
      () async {
        stubUpdate(() async => profile(bio: ''));
        cubit.displayNameChanged('   ');
        cubit.bioChanged('');
        expect(cubit.canSave, isFalse);

        cubit.displayNameChanged('Kaif');
        expect(cubit.canSave, isTrue);
        await cubit.save();

        final call = verify(
          () => repo.updateProfile(
            idempotencyKey: any(named: 'idempotencyKey'),
            displayName: captureAny(named: 'displayName'),
            bio: captureAny(named: 'bio'),
          ),
        );
        expect(call.captured, [null, '']);
      },
    );

    test('limits: 50 name characters, 160 bio characters', () {
      cubit.displayNameChanged('a' * 51);
      expect(cubit.state.displayNameRemaining, -1);
      expect(cubit.canSave, isFalse);

      cubit.displayNameChanged('a' * 50);
      expect(cubit.canSave, isTrue);

      cubit.bioChanged('b' * 161);
      expect(cubit.state.bioRemaining, -1);
      expect(cubit.canSave, isFalse);
    });

    test(
      'a failure keeps the form; the retry reuses the idempotency key',
      () async {
        var calls = 0;
        stubUpdate(() async {
          calls++;
          if (calls == 1) throw const NetworkException('offline');
          return profile(name: 'New');
        });
        cubit.displayNameChanged('New');

        await cubit.save();
        expect(cubit.state.error, isA<NetworkException>());
        expect(cubit.state.status, EditProfileStatus.editing);
        expect(cubit.state.displayName, 'New');

        await cubit.save();
        expect(cubit.state.status, EditProfileStatus.saved);
        final keys = verify(
          () => repo.updateProfile(
            idempotencyKey: captureAny(named: 'idempotencyKey'),
            displayName: any(named: 'displayName'),
            bio: any(named: 'bio'),
          ),
        ).captured;
        expect(keys, hasLength(2));
        expect(keys[0], keys[1]);
      },
    );

    test('a different edit gets its own key', () async {
      stubUpdate(() async => throw const NetworkException('offline'));
      cubit.displayNameChanged('One');
      await cubit.save();
      cubit.displayNameChanged('Two');
      await cubit.save();

      final keys = verify(
        () => repo.updateProfile(
          idempotencyKey: captureAny(named: 'idempotencyKey'),
          displayName: any(named: 'displayName'),
          bio: any(named: 'bio'),
        ),
      ).captured;
      expect(keys[0], isNot(keys[1]));
    });
  });

  group('ChangeHandleCubit', () {
    late ChangeHandleCubit cubit;

    setUp(() {
      cubit = ChangeHandleCubit(
        identityRepository: repo,
        currentHandle: 'Kaif',
        debounce: Duration.zero,
      );
    });

    tearDown(() => cubit.close());

    void stubCheck(
      Future<identity.CheckHandleAvailabilityResponse> Function(String) a,
    ) {
      when(() => repo.checkHandleAvailability(any()))
          .thenAnswer((i) => a(i.positionalArguments.single as String));
    }

    Future<void> typed(String value) async {
      cubit.handleChanged(value);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    test('local rules answer without a request', () async {
      await typed('ab');
      expect(cubit.state.checkStatus, HandleCheckStatus.unavailable);
      expect(cubit.state.checkMessage, contains('3-15'));

      await typed('admin');
      expect(cubit.state.checkMessage, 'That handle is reserved.');

      await typed('@KAIF');
      expect(cubit.state.checkMessage, kSameHandleMessage);

      await typed('');
      expect(cubit.state.checkStatus, HandleCheckStatus.idle);
      verifyNever(() => repo.checkHandleAvailability(any()));
    });

    test('an available handle can be saved; the profile is reported', () async {
      stubCheck(
        (_) async => identity.CheckHandleAvailabilityResponse(available: true),
      );
      when(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      ).thenAnswer((_) async => profile(handle: 'new_one'));

      await typed('New_One');
      expect(cubit.state.checkStatus, HandleCheckStatus.available);
      expect(cubit.state.canSave, isTrue);

      await cubit.save();

      expect(cubit.state.status, ChangeHandleStatus.saved);
      expect(cubit.state.saved!.handle, 'new_one');
      verify(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: 'new_one',
        ),
      ).called(1);
    });

    test('a taken handle is shown on the field', () async {
      stubCheck(
        (_) async => identity.CheckHandleAvailabilityResponse(
          available: false,
          reason: '',
        ),
      );
      await typed('taken_one');
      expect(cubit.state.checkStatus, HandleCheckStatus.unavailable);
      expect(cubit.state.checkMessage, 'That handle is taken.');
      expect(cubit.state.canSave, isFalse);
    });

    test('a rate-limited check still allows saving', () async {
      stubCheck((_) async => throw const RateLimitedException('slow down'));
      await typed('new_one');
      expect(cubit.state.checkStatus, HandleCheckStatus.unknown);
      expect(cubit.state.canSave, isTrue);
    });

    test('only the newest keystroke is checked and shown', () async {
      final first = Completer<identity.CheckHandleAvailabilityResponse>();
      stubCheck((h) {
        if (h == 'first_one') return first.future;
        return Future.value(
          identity.CheckHandleAvailabilityResponse(available: true),
        );
      });
      await typed('first_one');
      await typed('second_one');
      expect(cubit.state.handle, 'second_one');
      expect(cubit.state.checkStatus, HandleCheckStatus.available);

      first.complete(
        identity.CheckHandleAvailabilityResponse(available: false),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cubit.state.handle, 'second_one');
      expect(cubit.state.checkStatus, HandleCheckStatus.available);
    });

    test('the cooldown error carries the time left', () async {
      stubCheck(
        (_) async => identity.CheckHandleAvailabilityResponse(available: true),
      );
      when(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      ).thenAnswer(
        (_) async => throw const LimitReachedException(
          'once every 7 days',
          quota: 'handle_change',
          retryAfter: Duration(days: 3),
        ),
      );
      await typed('new_one');

      await cubit.save();

      expect(cubit.state.status, ChangeHandleStatus.editing);
      final error = cubit.state.error as LimitReachedException;
      expect(error.retryAfter, const Duration(days: 3));
    });

    test('taken between check and save marks the field', () async {
      stubCheck(
        (_) async => identity.CheckHandleAvailabilityResponse(available: true),
      );
      when(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      ).thenAnswer((_) async => throw const HandleTakenException('taken'));
      await typed('new_one');

      await cubit.save();

      expect(cubit.state.checkStatus, HandleCheckStatus.unavailable);
      expect(cubit.state.error, isNull);
      expect(cubit.state.canSave, isFalse);
    });
  });
}
