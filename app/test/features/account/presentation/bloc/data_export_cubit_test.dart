import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/account/presentation/bloc/account_cubit.dart';
import 'package:dzeroth/features/account/presentation/bloc/data_export_cubit.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pbenum.dart'
    show ExportStatus;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAccounts extends Mock implements AccountRepository {}

class _MockAuth extends Mock implements AuthRepository {}

Future<String?> _pw() async => 'pw';

AccountExport _ready(String url, {DateTime? urlExpiresAt}) => AccountExport(
  exportId: 'exp-1',
  status: ExportStatus.EXPORT_STATUS_READY,
  downloadUrl: url,
  downloadUrlExpiresAt: urlExpiresAt,
);

const _pending = AccountExport(
  exportId: 'exp-1',
  status: ExportStatus.EXPORT_STATUS_PENDING,
);

void main() {
  late _MockAccounts accounts;
  late _MockAuth auth;
  late AppDatabase db;
  late DateTime now;
  final reported = <Object>[];

  DataExportCubit build({bool tapAfterRefresh = false}) => DataExportCubit(
    accountCubit: AccountCubit(
      accountRepository: accounts,
      authRepository: auth,
    ),
    accountRepository: accounts,
    database: db,
    uid: 'u1',
    onUnexpectedError: (e, _) => reported.add(e),
    clock: () => now,
    tapAfterRefresh: tapAfterRefresh,
  );

  void stubReauth(Future<ReauthResult> Function(Invocation) answer) {
    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenAnswer(answer);
  }

  // Timers run on the testWidgets fake clock.
  Future<void> elapse(WidgetTester tester, Duration d) async {
    await tester.pump(d);
    await tester.pump();
  }

  Future<DataExportCubit> readyCubit(
    WidgetTester tester, {
    bool tapAfterRefresh = false,
  }) async {
    final cubit = build(tapAfterRefresh: tapAfterRefresh);
    await cubit.request(promptPassword: _pw);
    await elapse(tester, const Duration(seconds: 10));
    expect(cubit.state.phase, DataExportPhase.ready);
    return cubit;
  }

  setUp(() {
    accounts = _MockAccounts();
    auth = _MockAuth();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    now = DateTime(2026, 10, 7, 12);
    reported.clear();
    when(() => auth.reauthNeedsGesture).thenReturn(false);
    // RequestAccountExport needs a recent sign-in, so every request
    // re-authenticates first.
    stubReauth((_) async => const ReauthResult());
    when(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) async => _pending);
  });

  testWidgets('request re-authenticates in the tap, before the RPC, on web and '
      'non-web', (tester) async {
    for (final web in [false, true]) {
      when(() => auth.reauthNeedsGesture).thenReturn(web);
      final events = <String>[];
      stubReauth((_) async {
        events.add('reauth');
        return const ReauthResult();
      });
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async {
        events.add('rpc');
        return _pending;
      });
      final cubit = build();

      final run = cubit.request(promptPassword: _pw);
      // No await since the call: the re-auth already started.
      expect(events, ['reauth'], reason: web ? 'web' : 'non-web');
      expect(cubit.state.phase, DataExportPhase.requesting);
      await run;

      expect(events, ['reauth', 'rpc'], reason: web ? 'web' : 'non-web');
      expect(cubit.state.phase, DataExportPhase.waiting);
      await cubit.close();
    }
  });

  testWidgets('a cancelled re-auth returns to idle with no RPC and no error, '
      'and the retry reuses the key', (tester) async {
    final keys = <String>[];
    var calls = 0;
    when(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((i) async {
      keys.add(i.namedArguments[#idempotencyKey] as String);
      if (++calls == 1) throw const NetworkException('offline');
      return _pending;
    });
    final cubit = build();
    await cubit.request(promptPassword: _pw); // fails: key k
    expect(cubit.state.phase, DataExportPhase.failed);

    stubReauth((_) async => throw const AuthFailure.cancelled());
    await cubit.request(promptPassword: _pw);
    expect(cubit.state, const DataExportState());
    expect(cubit.canResume, isFalse);
    expect(await db.savedExport('u1'), isNull);
    expect(keys, hasLength(1)); // the cancel sent nothing

    stubReauth((_) async => const ReauthResult());
    await cubit.request(promptPassword: _pw);
    expect(cubit.state.phase, DataExportPhase.waiting);
    expect(keys, hasLength(2));
    expect(keys[1], keys[0]);
    await cubit.close();
  });

  test('delayForPoll backs off from 10 s to 60 s', () {
    expect(
      [for (var i = 0; i < 10; i++) DataExportCubit.delayForPoll(i).inSeconds],
      [10, 15, 22, 33, 50, 60, 60, 60, 60, 60],
    );
  });

  test('state toString and export never contain the signed URL', () {
    final state = DataExportState(
      phase: DataExportPhase.ready,
      export: _ready('https://example/secret-sig'),
    );
    expect(state.toString(), isNot(contains('secret-sig')));
    expect('${state.export}', isNot(contains('secret-sig')));
  });

  testWidgets('a download URL older than 14 minutes is re-fetched once', (
    tester,
  ) async {
    var calls = 0;
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
      calls++;
      return _ready('https://example/$calls');
    });
    final cubit = await readyCubit(tester);
    expect(calls, 1);

    expect(
      (await cubit.downloadUrl(promptPassword: _pw)).toString(),
      'https://example/1',
    );
    expect(calls, 1);

    now = now.add(const Duration(minutes: 13));
    expect(
      (await cubit.downloadUrl(promptPassword: _pw)).toString(),
      'https://example/1',
    );
    expect(calls, 1);

    now = now.add(const Duration(minutes: 1));
    expect(
      (await cubit.downloadUrl(promptPassword: _pw)).toString(),
      'https://example/2',
    );
    expect(calls, 2);
    await cubit.close();
  });

  testWidgets('a URL within a minute of its own expiry is refreshed', (
    tester,
  ) async {
    var calls = 0;
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
      calls++;
      return _ready(
        'https://example/$calls',
        urlExpiresAt: now.add(const Duration(minutes: 5)),
      );
    });
    final cubit = await readyCubit(tester);

    now = now.add(const Duration(minutes: 4, seconds: 30));
    expect(
      (await cubit.downloadUrl(promptPassword: _pw)).toString(),
      'https://example/2',
    );
    expect(calls, 2);
    await cubit.close();
  });

  testWidgets('on web a stale refresh asks for a second tap', (tester) async {
    var calls = 0;
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
      calls++;
      return _ready('https://example/$calls');
    });
    final cubit = await readyCubit(tester, tapAfterRefresh: true);

    now = now.add(const Duration(minutes: 20));
    expect(await cubit.downloadUrl(promptPassword: _pw), isNull);
    expect(cubit.state.phase, DataExportPhase.ready);
    expect(cubit.state.linkRefreshed, isTrue);

    expect(
      (await cubit.downloadUrl(promptPassword: _pw)).toString(),
      'https://example/2',
    );
    expect(calls, 2);
    await cubit.close();
  });

  testWidgets('NOT_FOUND during a URL refresh shows expired and forgets the '
      'export', (tester) async {
    var calls = 0;
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
      calls++;
      if (calls > 1) throw const NotFoundException('gone');
      return _ready('https://example/1');
    });
    final cubit = await readyCubit(tester);
    expect(await db.savedExport('u1'), isNotNull);

    now = now.add(const Duration(minutes: 20));
    expect(await cubit.downloadUrl(promptPassword: _pw), isNull);

    expect(cubit.state.phase, DataExportPhase.expired);
    expect(await db.savedExport('u1'), isNull);
    await cubit.close();
  });

  testWidgets('a refresh that returns READY without a URL goes back to '
      'waiting', (tester) async {
    var calls = 0;
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
      calls++;
      return calls == 1
          ? _ready('https://example/1')
          : const AccountExport(
              exportId: 'exp-1',
              status: ExportStatus.EXPORT_STATUS_READY,
            );
    });
    final cubit = await readyCubit(tester);

    now = now.add(const Duration(minutes: 20));
    expect(await cubit.downloadUrl(promptPassword: _pw), isNull);

    expect(cubit.state.phase, DataExportPhase.waiting);
    await cubit.close();
  });

  testWidgets('a failed export job stops polling and forgets the export', (
    tester,
  ) async {
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer(
      (_) async => const AccountExport(
        exportId: 'exp-1',
        status: ExportStatus.EXPORT_STATUS_FAILED,
      ),
    );
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await elapse(tester, const Duration(minutes: 10));

    expect(cubit.state.phase, DataExportPhase.failed);
    expect(cubit.state.jobFailed, isTrue);
    expect(cubit.canResume, isFalse);
    expect(await db.savedExport('u1'), isNull);
    verify(() => accounts.getExport(exportId: 'exp-1')).called(1);
    await cubit.close();
  });

  testWidgets('a quota error while polling stops without retrying', (
    tester,
  ) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenThrow(const QuotaExceededException('quota'));
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await elapse(tester, const Duration(minutes: 10));

    expect(cubit.state.phase, DataExportPhase.failed);
    expect(cubit.state.error, isA<QuotaExceededException>());
    verify(() => accounts.getExport(exportId: 'exp-1')).called(1);
    await cubit.close();
  });

  testWidgets('a degraded-mode error while polling stops', (tester) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenThrow(const DegradedModeException('degraded'));
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await elapse(tester, const Duration(minutes: 10));

    expect(cubit.state.error, isA<DegradedModeException>());
    verify(() => accounts.getExport(exportId: 'exp-1')).called(1);
    await cubit.close();
  });

  testWidgets('a transient rate limit waits for retryAfter, a daily one '
      'stops', (tester) async {
    var calls = 0;
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
      calls++;
      if (calls == 1) {
        throw const RateLimitedException(
          'slow down',
          retryAfter: Duration(seconds: 45),
          limitName: 'export_minute',
        );
      }
      return _pending;
    });
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await elapse(tester, const Duration(seconds: 10));
    expect(calls, 1);
    // Normal next delay would be 15 s; retryAfter is 45 s.
    await elapse(tester, const Duration(seconds: 20));
    expect(calls, 1);
    await elapse(tester, const Duration(seconds: 30));
    expect(calls, 2);
    await cubit.close();

    when(() => accounts.getExport(exportId: 'exp-1')).thenThrow(
      const RateLimitedException('daily', limitName: 'account_ops_daily'),
    );
    final daily = build();
    await daily.request(promptPassword: _pw);
    await elapse(tester, const Duration(seconds: 10));
    expect(daily.state.phase, DataExportPhase.failed);
    await daily.close();
  });

  testWidgets('a failed poll then retry resumes polling without a new '
      'request', (tester) async {
    var calls = 0;
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
      calls++;
      if (calls == 1) throw const DegradedModeException('degraded');
      return _ready('https://example/ok');
    });
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await elapse(tester, const Duration(seconds: 10));
    expect(cubit.state.phase, DataExportPhase.failed);
    expect(cubit.canResume, isTrue);

    cubit.resume();
    await elapse(tester, Duration.zero);

    expect(cubit.state.phase, DataExportPhase.ready);
    verify(() => accounts.getExport(exportId: 'exp-1')).called(2);
    verify(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).called(1);
    await cubit.close();
  });

  testWidgets('request saves the export; init resumes it with a fresh budget', (
    tester,
  ) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenAnswer((_) async => _pending);
    final first = build();
    await first.request(promptPassword: _pw);
    final saved = await db.savedExport('u1');
    expect(saved?.exportId, 'exp-1');
    expect(saved?.expiresAt, now.add(const Duration(days: 7)));
    await first.close();

    final second = build();
    await second.init();
    expect(second.state.phase, DataExportPhase.waiting);
    await elapse(tester, Duration.zero);
    verify(() => accounts.getExport(exportId: 'exp-1')).called(1);
    await second.close();
  });

  test('init drops an expired saved export', () async {
    await db.saveExport(
      exportId: 'old',
      uid: 'u1',
      requestedAt: now.subtract(const Duration(days: 8)),
      expiresAt: now.subtract(const Duration(days: 1)),
      epoch: db.sessionEpoch.value,
    );
    final cubit = build();
    await cubit.init();

    expect(cubit.state.phase, DataExportPhase.idle);
    expect(await db.savedExport('u1'), isNull);
    await cubit.close();
  });

  testWidgets('NOT_FOUND while polling clears the saved export', (
    tester,
  ) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenThrow(const NotFoundException('gone'));
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    expect(await db.savedExport('u1'), isNotNull);
    await elapse(tester, const Duration(seconds: 10));

    expect(cubit.state.phase, DataExportPhase.expired);
    expect(await db.savedExport('u1'), isNull);
    await cubit.close();
  });

  testWidgets('closing while RequestAccountExport is in flight still saves '
      'the accepted export', (tester) async {
    final gate = Completer<AccountExport>();
    when(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) => gate.future);
    final account = AccountCubit(
      accountRepository: accounts,
      authRepository: auth,
    );
    final cubit = DataExportCubit(
      accountCubit: account,
      accountRepository: accounts,
      database: db,
      uid: 'u1',
      clock: () => now,
      tapAfterRefresh: false,
    );
    final pending = cubit.request(promptPassword: _pw);
    await tester.pump();
    await cubit.close();
    await account.close();
    gate.complete(_pending);
    await pending;

    expect((await db.savedExport('u1'))?.exportId, 'exp-1');
    verifyNever(() => accounts.getExport(exportId: any(named: 'exportId')));
  });

  testWidgets('resetting the account cubit mid-RPC still starts polling', (
    tester,
  ) async {
    final gate = Completer<AccountExport>();
    when(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) => gate.future);
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenAnswer((_) async => _pending);
    final account = AccountCubit(
      accountRepository: accounts,
      authRepository: auth,
    );
    final cubit = DataExportCubit(
      accountCubit: account,
      accountRepository: accounts,
      database: db,
      uid: 'u1',
      clock: () => now,
      tapAfterRefresh: false,
    );
    final pending = cubit.request(promptPassword: _pw);
    await tester.pump();
    account.reset();
    gate.complete(_pending);
    await pending;

    expect(cubit.state.phase, DataExportPhase.waiting);
    expect(cubit.canResume, isTrue);
    await elapse(tester, const Duration(seconds: 10));
    verify(() => accounts.getExport(exportId: 'exp-1')).called(1);
    await cubit.close();
    await account.close();
  });

  test('a saved export of another uid is absent and deleted', () async {
    await db.saveExport(
      exportId: 'theirs',
      uid: 'someone-else',
      requestedAt: now,
      expiresAt: now.add(const Duration(days: 7)),
      epoch: db.sessionEpoch.value,
    );
    final cubit = build();
    await cubit.init();

    expect(cubit.state.phase, DataExportPhase.idle);
    expect(await db.savedExport('someone-else'), isNull);
    await cubit.close();
  });

  testWidgets('the server expiresAt updates the saved row', (tester) async {
    final serverExpiry = now.add(const Duration(days: 6));
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer(
      (_) async => AccountExport(
        exportId: 'exp-1',
        status: ExportStatus.EXPORT_STATUS_PENDING,
        expiresAt: serverExpiry,
      ),
    );
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await elapse(tester, const Duration(seconds: 10));

    expect((await db.savedExport('u1'))?.expiresAt, serverExpiry);
    await cubit.close();
  });

  testWidgets('an unknown error while polling is reported once per budget', (
    tester,
  ) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenThrow(const UnknownApiException('boom'));
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    for (var i = 0; i < 12; i++) {
      await elapse(tester, const Duration(seconds: 60));
    }

    expect(cubit.state.phase, DataExportPhase.checkBackLater);
    expect(reported, hasLength(1));
    cubit.resume();
    await elapse(tester, Duration.zero);
    expect(reported, hasLength(2));
    await cubit.close();
  });

  testWidgets('closing the cubit cancels pending polls', (tester) async {
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await cubit.close();
    await elapse(tester, const Duration(minutes: 10));

    verifyNever(() => accounts.getExport(exportId: any(named: 'exportId')));
  });

  group('download needs a recent sign-in', () {
    const readyNoUrl = AccountExport(
      exportId: 'exp-1',
      status: ExportStatus.EXPORT_STATUS_READY,
    );

    // The first poll (stale sign-in) is READY without a link; later fetches
    // (after the re-auth) carry one.
    void stubWithheldThenUrl(List<String> events) {
      var calls = 0;
      when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
        events.add('get');
        return ++calls == 1 ? readyNoUrl : _ready('https://example/$calls');
      });
    }

    testWidgets('polling reaches ready on READY without a URL', (tester) async {
      when(() => accounts.getExport(exportId: 'exp-1'))
          .thenAnswer((_) async => readyNoUrl);
      final cubit = await readyCubit(tester);

      expect(cubit.state.export?.downloadUrl, isNull);
      verify(() => accounts.getExport(exportId: 'exp-1')).called(1);
      await cubit.close();
    });

    testWidgets('non-web: re-authenticates in the tap, then fetches and '
        'returns the URL', (tester) async {
      final events = <String>[];
      stubWithheldThenUrl(events);
      final cubit = await readyCubit(tester);
      events.clear();
      stubReauth((_) async {
        events.add('reauth');
        return const ReauthResult();
      });

      final run = cubit.downloadUrl(promptPassword: _pw);
      // No await since the call: the re-auth already started, no RPC yet.
      expect(events, ['reauth']);
      expect(cubit.state.refreshing, isTrue);
      final url = await run;

      expect(events, ['reauth', 'get']);
      expect(url.toString(), 'https://example/2');
      expect(cubit.state.phase, DataExportPhase.ready);
      expect(cubit.state.refreshing, isFalse);
      expect(cubit.state.linkRefreshed, isFalse);
      // The link is fresh now: the next tap needs no re-auth.
      expect(
        (await cubit.downloadUrl(promptPassword: _pw)).toString(),
        'https://example/2',
      );
      expect(events, ['reauth', 'get']);
      await cubit.close();
    });

    testWidgets('web: re-auth, refresh, then the second tap opens with no '
        'prompt', (tester) async {
      final events = <String>[];
      stubWithheldThenUrl(events);
      final cubit = await readyCubit(tester, tapAfterRefresh: true);
      events.clear();
      stubReauth((_) async {
        events.add('reauth');
        return const ReauthResult();
      });

      expect(await cubit.downloadUrl(promptPassword: _pw), isNull);
      expect(events, ['reauth', 'get']);
      expect(cubit.state.phase, DataExportPhase.ready);
      expect(cubit.state.linkRefreshed, isTrue);

      expect(
        (await cubit.downloadUrl(promptPassword: _pw)).toString(),
        'https://example/2',
      );
      expect(events, ['reauth', 'get']);
      await cubit.close();
    });

    testWidgets('a link that came with the poll opens with no re-auth', (
      tester,
    ) async {
      when(() => accounts.getExport(exportId: 'exp-1'))
          .thenAnswer((_) async => _ready('https://example/1'));
      final cubit = await readyCubit(tester);
      clearInteractions(auth);

      expect(
        (await cubit.downloadUrl(promptPassword: _pw)).toString(),
        'https://example/1',
      );
      verifyNever(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      );
      await cubit.close();
    });

    testWidgets('a cancelled re-auth fetches nothing and stays ready', (
      tester,
    ) async {
      when(() => accounts.getExport(exportId: 'exp-1'))
          .thenAnswer((_) async => readyNoUrl);
      final cubit = await readyCubit(tester);
      stubReauth((_) async => throw const AuthFailure.cancelled());

      expect(await cubit.downloadUrl(promptPassword: _pw), isNull);

      expect(cubit.state.phase, DataExportPhase.ready);
      expect(cubit.state.refreshing, isFalse);
      verify(() => accounts.getExport(exportId: 'exp-1')).called(1);
      clearInteractions(accounts);
      await elapse(tester, const Duration(minutes: 10)); // no loop
      verifyNever(() => accounts.getExport(exportId: any(named: 'exportId')));
      await cubit.close();
    });

    testWidgets('a failed re-auth surfaces the auth failure, no fetch, no '
        'loop, no URL in state text', (tester) async {
      when(() => accounts.getExport(exportId: 'exp-1'))
          .thenAnswer((_) async => readyNoUrl);
      final cubit = await readyCubit(tester);
      stubReauth((_) async => throw const AuthFailure.requiresRecentLogin());

      expect(await cubit.downloadUrl(promptPassword: _pw), isNull);

      expect(cubit.state.phase, DataExportPhase.failed);
      expect(cubit.state.authFailure, isNotNull);
      expect(cubit.canResume, isTrue);
      expect(cubit.state.toString(), isNot(contains('http')));
      clearInteractions(accounts);
      await elapse(tester, const Duration(minutes: 10));
      verifyNever(() => accounts.getExport(exportId: any(named: 'exportId')));
      await cubit.close();
    });

    testWidgets('a getExport failure after the re-auth shows the error', (
      tester,
    ) async {
      var calls = 0;
      when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
        if (++calls == 1) return readyNoUrl;
        throw const DegradedModeException('degraded');
      });
      final cubit = await readyCubit(tester);

      expect(await cubit.downloadUrl(promptPassword: _pw), isNull);

      expect(cubit.state.phase, DataExportPhase.failed);
      expect(cubit.state.error, isA<DegradedModeException>());
      await cubit.close();
    });

    testWidgets('READY without a URL even after the re-auth goes back to '
        'waiting', (tester) async {
      when(() => accounts.getExport(exportId: 'exp-1'))
          .thenAnswer((_) async => readyNoUrl);
      final cubit = await readyCubit(tester);

      expect(await cubit.downloadUrl(promptPassword: _pw), isNull);

      expect(cubit.state.phase, DataExportPhase.waiting);
      await cubit.close();
    });
  });
}
