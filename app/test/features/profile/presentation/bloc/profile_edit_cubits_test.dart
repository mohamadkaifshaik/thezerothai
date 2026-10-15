import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/domain/handle_rules.dart'
    show HandleCheckStatus;
import 'package:dzeroth/features/profile/presentation/bloc/change_handle_cubit.dart';
import 'package:dzeroth/features/profile/presentation/bloc/edit_profile_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:fake_async/fake_async.dart';
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
    late List<Object> reported;

    setUp(() {
      reported = [];
      cubit = EditProfileCubit(
        identityRepository: repo,
        initial: profile(),
        onUnexpectedError: (error, _) => reported.add(error),
      );
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

    test(
      'an unexpected error is reported and shown as a generic failure',
      () async {
        stubUpdate(() async => throw StateError('boom'));
        cubit.displayNameChanged('New');

        await cubit.save();

        expect(reported.single, isA<StateError>());
        expect(cubit.state.error, isA<UnknownApiException>());
        expect(cubit.state.status, EditProfileStatus.editing);
      },
    );

    test('an UnknownApiException from the server is reported too', () async {
      stubUpdate(() async => throw const UnknownApiException('weird'));
      cubit.displayNameChanged('New');

      await cubit.save();

      expect(reported.single, isA<UnknownApiException>());
    });

    test('expected failures are not reported', () async {
      stubUpdate(() async => throw const NetworkException('offline'));
      cubit.displayNameChanged('New');

      await cubit.save();

      expect(reported, isEmpty);
    });

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
    late DateTime now;
    late List<Object> reported;

    setUp(() {
      now = DateTime(2026, 10, 14, 12);
      reported = [];
      cubit = ChangeHandleCubit(
        identityRepository: repo,
        currentHandle: 'Kaif',
        debounce: Duration.zero,
        clock: () => now,
        onUnexpectedError: (error, _) => reported.add(error),
      );
    });

    tearDown(() => cubit.close());

    void stubCheck(
      Future<identity.CheckHandleAvailabilityResponse> Function(String) a,
    ) {
      when(() => repo.checkHandleAvailability(any()))
          .thenAnswer((i) => a(i.positionalArguments.single as String));
    }

    void stubAvailable() => stubCheck(
      (_) async => identity.CheckHandleAvailabilityResponse(available: true),
    );

    void stubChange(Future<identity.Profile> Function() answer) {
      when(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      ).thenAnswer((_) => answer());
    }

    /// Types [value] and waits for the answer to that exact handle (local
    /// rules answer at once, a probe after the debounce).
    Future<void> typed(String value) {
      final handle = value.trim().toLowerCase().replaceFirst(RegExp('^@'), '');
      final settled = cubit.stream.firstWhere(
        (s) =>
            s.handle == handle && s.checkStatus != HandleCheckStatus.checking,
      );
      cubit.handleChanged(value);
      return settled;
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
      stubAvailable();
      stubChange(() async => profile(handle: 'new_one'));

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

    test(
      'a generic probe failure is unknown and never shows its message',
      () async {
        stubCheck(
          (_) async => throw const UnknownApiException('db is on fire'),
        );
        await typed('new_one');
        expect(cubit.state.checkStatus, HandleCheckStatus.unknown);
        expect(cubit.state.checkMessage, isNot(contains('fire')));
        expect(cubit.state.canSave, isTrue);
      },
    );

    test(
      'after a rate-limited probe, probing stops until retryAfter',
      () async {
        stubCheck(
          (_) async => throw const RateLimitedException(
            'slow down',
            retryAfter: Duration(seconds: 30),
          ),
        );
        await typed('first_one');
        verify(() => repo.checkHandleAvailability('first_one')).called(1);

        await typed('second_one');
        expect(cubit.state.checkStatus, HandleCheckStatus.unknown);
        expect(cubit.state.canSave, isTrue);
        verifyNever(() => repo.checkHandleAvailability('second_one'));

        // Local rules still answer, and the probe resumes after the wait.
        await typed('ab');
        expect(cubit.state.checkStatus, HandleCheckStatus.unavailable);
        now = now.add(const Duration(seconds: 31));
        stubAvailable();
        await typed('third_one');
        expect(cubit.state.checkStatus, HandleCheckStatus.available);
      },
    );

    test(
      'a rate limit without retryAfter stops probing for the screen',
      () async {
        stubCheck((_) async => throw const RateLimitedException('slow down'));
        await typed('first_one');
        now = now.add(const Duration(days: 2));
        await typed('second_one');
        verifyNever(() => repo.checkHandleAvailability('second_one'));
      },
    );

    test('only the newest keystroke is checked and shown', () async {
      final first = Completer<identity.CheckHandleAvailabilityResponse>();
      final firstAsked = Completer<void>();
      stubCheck((h) {
        if (h == 'first_one') {
          firstAsked.complete();
          return first.future;
        }
        return Future.value(
          identity.CheckHandleAvailabilityResponse(available: true),
        );
      });
      cubit.handleChanged('first_one');
      await firstAsked.future;
      await typed('second_one');
      expect(cubit.state.handle, 'second_one');
      expect(cubit.state.checkStatus, HandleCheckStatus.available);

      first.complete(
        identity.CheckHandleAvailabilityResponse(available: false),
      );
      await pumpEventQueue();
      expect(cubit.state.handle, 'second_one');
      expect(cubit.state.checkStatus, HandleCheckStatus.available);
    });

    test('the cooldown error carries the time left and locks Save', () async {
      stubAvailable();
      stubChange(
        () async => throw const LimitReachedException(
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
      expect(cubit.state.cooldownUntil, now.add(const Duration(days: 3)));
      expect(cubit.cooldownLeft, const Duration(days: 3));
      expect(cubit.state.canSave, isFalse);

      // Still locked after another edit (and no availability probe is
      // spent on it); free once the wait passed.
      clearInteractions(repo);
      await typed('other_one');
      expect(cubit.state.checkStatus, HandleCheckStatus.idle);
      expect(cubit.state.canSave, isFalse);
      verifyNever(() => repo.checkHandleAvailability(any()));
      now = now.add(const Duration(days: 3, minutes: 1));
      await typed('third_one');
      expect(cubit.state.cooldownUntil, isNull);
      expect(cubit.state.canSave, isTrue);
    });

    test('Save re-enables when the cooldown ends, without another edit', () {
      fakeAsync((fa) {
        stubAvailable();
        stubChange(
          () async => throw const QuotaExceededException(
            'daily limit',
            quota: 'snapshot_edits',
            retryAfter: Duration(seconds: 30),
          ),
        );
        cubit.handleChanged('new_one');
        fa.flushTimers();
        fa.flushMicrotasks();
        unawaited(cubit.save());
        fa.flushMicrotasks();
        expect(cubit.state.cooldownUntil, isNotNull);
        expect(cubit.state.canSave, isFalse);

        fa.elapse(const Duration(seconds: 31));

        expect(cubit.state.cooldownUntil, isNull);
        expect(cubit.state.canSave, isTrue);
        expect(cubit.state.handle, 'new_one');
        // Shown available and unchanged, lockout under a minute: no
        // second probe.
        verify(() => repo.checkHandleAvailability('new_one')).called(1);
      });
    });

    test('an edit made during the lockout is checked when it ends', () {
      fakeAsync((fa) {
        stubAvailable();
        stubChange(
          () async => throw const QuotaExceededException(
            'daily limit',
            quota: 'snapshot_edits',
            retryAfter: Duration(seconds: 30),
          ),
        );
        cubit.handleChanged('new_one');
        fa.flushTimers();
        fa.flushMicrotasks();
        unawaited(cubit.save());
        fa.flushMicrotasks();
        clearInteractions(repo);

        cubit.handleChanged('other_one');
        fa.flushMicrotasks();
        expect(cubit.state.checkStatus, HandleCheckStatus.idle);
        verifyNever(() => repo.checkHandleAvailability(any()));

        fa.elapse(const Duration(seconds: 31));
        fa.flushMicrotasks();

        expect(cubit.state.cooldownUntil, isNull);
        expect(cubit.state.handle, 'other_one');
        expect(cubit.state.checkStatus, HandleCheckStatus.available);
        expect(cubit.state.canSave, isTrue);
        verify(() => repo.checkHandleAvailability('other_one')).called(1);
      });
    });

    test('while locked, save() sends nothing', () async {
      stubAvailable();
      stubChange(
        () async => throw const LimitReachedException(
          'once every 7 days',
          quota: 'handle_change',
          retryAfter: Duration(days: 3),
        ),
      );
      await typed('new_one');
      await cubit.save();
      clearInteractions(repo);

      await cubit.save();

      verifyNever(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      );
    });

    test('a bare RESOURCE_EXHAUSTED does not lock Save', () async {
      stubAvailable();
      stubChange(() async => throw const QuotaExceededException('throttled'));
      await typed('new_one');
      await cubit.save();
      expect(cubit.state.error, isA<QuotaExceededException>());
      expect(cubit.state.cooldownUntil, isNull);
      expect(cubit.state.canSave, isTrue);
    });

    test('a cooldown answer without retryAfter locks for 7 days', () async {
      stubAvailable();
      stubChange(
        () async => throw const LimitReachedException(
          'once every 7 days',
          quota: 'handle_change',
        ),
      );
      await typed('new_one');
      await cubit.save();
      expect(cubit.cooldownLeft, kHandleCooldown);
    });

    test('a daily quota answer locks Save until retryAfter', () async {
      stubAvailable();
      stubChange(
        () async => throw const QuotaExceededException(
          'daily limit',
          retryAfter: Duration(hours: 5),
        ),
      );
      await typed('new_one');
      await cubit.save();
      expect(cubit.cooldownLeft, const Duration(hours: 5));
      expect(cubit.state.canSave, isFalse);
    });

    test('other failures do not lock Save', () async {
      stubAvailable();
      stubChange(() async => throw const NetworkException('offline'));
      await typed('new_one');
      await cubit.save();
      expect(cubit.state.cooldownUntil, isNull);
      expect(cubit.state.canSave, isTrue);
    });

    test('taken between check and save marks the field', () async {
      stubAvailable();
      stubChange(() async => throw const HandleTakenException('taken'));
      await typed('new_one');

      await cubit.save();

      expect(cubit.state.checkStatus, HandleCheckStatus.unavailable);
      expect(cubit.state.error, isNull);
      expect(cubit.state.canSave, isFalse);
    });

    test(
      'an unexpected error is reported and shown as a generic failure',
      () async {
        stubAvailable();
        stubChange(() async => throw StateError('boom'));
        await typed('new_one');

        await cubit.save();

        expect(reported.single, isA<StateError>());
        expect(cubit.state.error, isA<UnknownApiException>());
        expect(cubit.state.status, ChangeHandleStatus.editing);
      },
    );

    test('an UnknownApiException from the server is reported too', () async {
      stubAvailable();
      stubChange(() async => throw const UnknownApiException('weird'));
      await typed('new_one');

      await cubit.save();

      expect(reported.single, isA<UnknownApiException>());
      expect(cubit.state.error, isA<UnknownApiException>());
    });

    test(
      'an unexpected probe error is reported and leaves Save possible',
      () async {
        stubCheck((_) async => throw StateError('boom'));
        await typed('new_one');

        expect(reported.single, isA<StateError>());
        expect(cubit.state.checkStatus, HandleCheckStatus.unknown);
      },
    );
  });
}
