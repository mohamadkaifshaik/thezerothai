import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/domain/notification_prefs.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/notification_prefs_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/data.dart';
import 'package:uuid/uuid.dart';

class _MockRepo extends Mock implements NotificationsRepository {}

class _SeqUuid extends Fake implements Uuid {
  int n = 0;

  @override
  String v4({V4Options? config, Map<String, dynamic>? options}) =>
      'key-${n++}-0123456789abcdef';
}

const _server = NotificationPushPrefs(
  plans: true,
  mentionsReplies: false,
  likesReposts: true,
  followers: true,
  messages: false,
);

void main() {
  late _MockRepo repo;
  late int disabledCalls;

  setUpAll(() => registerFallbackValue(_server));

  setUp(() {
    repo = _MockRepo();
    disabledCalls = 0;
  });

  NotificationPrefsCubit build() => NotificationPrefsCubit(
    repository: repo,
    onFeatureDisabled: () => disabledCalls++,
    uuid: _SeqUuid(),
  );

  group('load', () {
    blocTest<NotificationPrefsCubit, NotificationPrefsState>(
      'shows the server values',
      setUp: () =>
          when(() => repo.getPushPrefs()).thenAnswer((_) async => _server),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        const NotificationPrefsState(),
        const NotificationPrefsState(
          status: NotificationPrefsStatus.ready,
          prefs: _server,
        ),
      ],
    );

    blocTest<NotificationPrefsCubit, NotificationPrefsState>(
      'a failure is the error state, then Retry loads again',
      setUp: () {
        var calls = 0;
        when(() => repo.getPushPrefs()).thenAnswer((_) async {
          if (calls++ == 0) throw const NetworkException('offline');
          return _server;
        });
      },
      build: build,
      act: (cubit) async {
        await cubit.load();
        await cubit.load();
      },
      expect: () => [
        const NotificationPrefsState(),
        isA<NotificationPrefsState>()
            .having((s) => s.status, 'status', NotificationPrefsStatus.failed)
            .having((s) => s.loadError, 'error', isA<NetworkException>())
            .having((s) => s.prefs, 'prefs', isNull),
        isA<NotificationPrefsState>().having(
          (s) => s.status,
          'status',
          NotificationPrefsStatus.loading,
        ),
        const NotificationPrefsState(
          status: NotificationPrefsStatus.ready,
          prefs: _server,
        ),
      ],
    );

    blocTest<NotificationPrefsCubit, NotificationPrefsState>(
      'FEATURE_DISABLED is "not available" and asks for the flags',
      setUp: () =>
          when(() => repo.getPushPrefs())
              .thenThrow(const FeatureDisabledException('off')),
      build: build,
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [
        const NotificationPrefsState(
          status: NotificationPrefsStatus.unavailable,
        ),
      ],
      verify: (_) => expect(disabledCalls, 1),
    );
  });

  group('setGroup', () {
    test(
      'before the load answered nothing is sent (no save from defaults)',
      () async {
        final cubit = build();
        await cubit.setGroup(NotificationPrefsGroup.followers, on: false);
        verifyNever(
          () => repo.updatePushPrefs(
            idempotencyKey: any(named: 'idempotencyKey'),
            prefs: any(named: 'prefs'),
          ),
        );
        await cubit.close();
      },
    );

    blocTest<NotificationPrefsCubit, NotificationPrefsState>(
      'sends every group from the server values with one changed',
      setUp: () =>
          when(
            () => repo.updatePushPrefs(
              idempotencyKey: any(named: 'idempotencyKey'),
              prefs: any(named: 'prefs'),
            ),
          ).thenAnswer(
            (i) async => i.namedArguments[#prefs] as NotificationPushPrefs,
          ),
      build: build,
      seed: () => const NotificationPrefsState(
        status: NotificationPrefsStatus.ready,
        prefs: _server,
      ),
      act: (cubit) =>
          cubit.setGroup(NotificationPrefsGroup.followers, on: false),
      expect: () => [
        // Saving: the switch still shows the server's ON.
        const NotificationPrefsState(
          status: NotificationPrefsStatus.ready,
          prefs: _server,
          saving: NotificationPrefsGroup.followers,
        ),
        NotificationPrefsState(
          status: NotificationPrefsStatus.ready,
          prefs: _server.withGroup(NotificationPrefsGroup.followers, false),
        ),
      ],
      verify: (_) {
        verify(
          () => repo.updatePushPrefs(
            idempotencyKey: 'key-0-0123456789abcdef',
            prefs: const NotificationPushPrefs(
              plans: true,
              mentionsReplies: false,
              likesReposts: true,
              followers: false,
              messages: false,
            ),
          ),
        ).called(1);
      },
    );

    blocTest<NotificationPrefsCubit, NotificationPrefsState>(
      'a failure keeps the server values; the retry reuses the key',
      setUp: () {
        var calls = 0;
        when(
          () => repo.updatePushPrefs(
            idempotencyKey: any(named: 'idempotencyKey'),
            prefs: any(named: 'prefs'),
          ),
        ).thenAnswer((i) async {
          if (calls++ == 0) throw const NetworkException('offline');
          return i.namedArguments[#prefs] as NotificationPushPrefs;
        });
      },
      build: build,
      seed: () => const NotificationPrefsState(
        status: NotificationPrefsStatus.ready,
        prefs: _server,
      ),
      act: (cubit) async {
        await cubit.setGroup(NotificationPrefsGroup.plans, on: false);
        await cubit.setGroup(NotificationPrefsGroup.plans, on: false);
      },
      skip: 1,
      expect: () => [
        isA<NotificationPrefsState>()
            .having((s) => s.prefs, 'prefs', _server)
            .having((s) => s.saving, 'saving', isNull)
            .having((s) => s.error, 'error', isA<NetworkException>())
            .having((s) => s.serial, 'serial', 1),
        isA<NotificationPrefsState>().having(
          (s) => s.saving,
          'saving',
          NotificationPrefsGroup.plans,
        ),
        isA<NotificationPrefsState>().having(
          (s) => s.prefs?.plans,
          'plans',
          isFalse,
        ),
      ],
      verify: (_) {
        verify(
          () => repo.updatePushPrefs(
            idempotencyKey: 'key-0-0123456789abcdef',
            prefs: any(named: 'prefs'),
          ),
        ).called(2);
      },
    );

    blocTest<NotificationPrefsCubit, NotificationPrefsState>(
      'one change at a time, and no change to the value it already has',
      setUp: () =>
          when(
            () => repo.updatePushPrefs(
              idempotencyKey: any(named: 'idempotencyKey'),
              prefs: any(named: 'prefs'),
            ),
          ).thenAnswer((i) async {
            await Future<void>.delayed(Duration.zero);
            return i.namedArguments[#prefs] as NotificationPushPrefs;
          }),
      build: build,
      seed: () => const NotificationPrefsState(
        status: NotificationPrefsStatus.ready,
        prefs: _server,
      ),
      act: (cubit) async {
        await cubit.setGroup(NotificationPrefsGroup.plans, on: true);
        final first = cubit.setGroup(NotificationPrefsGroup.plans, on: false);
        await cubit.setGroup(NotificationPrefsGroup.messages, on: true);
        await first;
      },
      verify: (_) {
        verify(
          () => repo.updatePushPrefs(
            idempotencyKey: any(named: 'idempotencyKey'),
            prefs: any(named: 'prefs'),
          ),
        ).called(1);
      },
    );

    blocTest<NotificationPrefsCubit, NotificationPrefsState>(
      'FEATURE_DISABLED on save is "not available" and asks for the flags',
      setUp: () => when(
        () => repo.updatePushPrefs(
          idempotencyKey: any(named: 'idempotencyKey'),
          prefs: any(named: 'prefs'),
        ),
      ).thenThrow(const FeatureDisabledException('off')),
      build: build,
      seed: () => const NotificationPrefsState(
        status: NotificationPrefsStatus.ready,
        prefs: _server,
      ),
      act: (cubit) => cubit.setGroup(NotificationPrefsGroup.plans, on: false),
      skip: 1,
      expect: () => [
        isA<NotificationPrefsState>()
            .having(
              (s) => s.status,
              'status',
              NotificationPrefsStatus.unavailable,
            )
            .having((s) => s.serial, 'serial', 1),
      ],
      verify: (_) => expect(disabledCalls, 1),
    );
  });
}
