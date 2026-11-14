import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/account/presentation/bloc/account_cubit.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAccounts extends Mock implements AccountRepository {}

class _MockAuth extends Mock implements AuthRepository {}

Future<String?> _pw() async => 'pw';

void main() {
  late _MockAccounts accounts;
  late _MockAuth auth;
  final reported = <Object>[];

  AccountCubit build() => AccountCubit(
    accountRepository: accounts,
    authRepository: auth,
    onUnexpectedError: (e, _) => reported.add(e),
  );

  Future<ReauthResult> Function(Invocation) ok() =>
      (_) async => const ReauthResult();

  void stubReauth(Future<ReauthResult> Function(Invocation) answer) {
    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenAnswer(answer);
  }

  void stubDelete(Future<DateTime?> Function(Invocation) answer) {
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer(answer);
  }

  void verifyDeleteCalls(int n) => verify(
    () => accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
  ).called(n);

  setUp(() {
    accounts = _MockAccounts();
    auth = _MockAuth();
    reported.clear();
    stubReauth(ok());
    when(() => auth.reauthNeedsGesture).thenReturn(false);
  });

  group('deleteAccount', () {
    test('re-authenticates up front, then sends exactly one call', () async {
      stubDelete((_) async => null);
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.deleted);
      verifyInOrder([
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ]);
      verifyNoMoreInteractions(accounts);
    });

    test('re-auth starts synchronously (inside the tap gesture)', () {
      stubDelete((_) async => null);
      final cubit = build();

      // No await: the provider flow must already have been invoked.
      unawaited(cubit.deleteAccount(promptPassword: _pw));

      verify(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      ).called(1);
    });

    test('a cancelled re-authentication sends zero RPCs', () async {
      stubReauth((_) async => throw const AuthFailure.cancelled());
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.cancelled);
      verifyNever(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    test('a wrong password fails without an RPC and keeps the key', () async {
      final keys = <String>[];
      var reauths = 0;
      stubReauth((_) async {
        if (++reauths == 1) throw const AuthFailure.invalidCredentials();
        return const ReauthResult();
      });
      stubDelete((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        throw const NetworkException('offline');
      });
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);
      expect(cubit.state.authFailure, const AuthFailure.invalidCredentials());
      verifyNever(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );

      await cubit.deleteAccount(promptPassword: _pw);
      await cubit.deleteAccount(promptPassword: _pw);
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
    });

    test('a fallback REAUTH_REQUIRED re-authenticates once and retries '
        'once with the same key', () async {
      final keys = <String>[];
      var calls = 0;
      stubDelete((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        if (++calls == 1) throw const ReauthRequiredException('old');
        return null;
      });
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.deleted);
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
      verify(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      ).called(2);
    });

    test('REAUTH_REQUIRED twice is surfaced, not looped', () async {
      stubDelete((_) async => throw const ReauthRequiredException('old'));
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.failed);
      expect(cubit.state.error, isA<ReauthRequiredException>());
      verifyDeleteCalls(2);
    });

    test('a retry after a network error reuses the same key', () async {
      final keys = <String>[];
      var calls = 0;
      stubDelete((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        if (++calls == 1) throw const NetworkException('offline');
        return null;
      });
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);
      expect(cubit.state.error, isA<NetworkException>());
      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.deleted);
      expect(keys[0], keys[1]);
    });

    test('a double tap sends one call', () async {
      final gate = Completer<DateTime?>();
      stubDelete((_) => gate.future);
      final cubit = build();

      final first = cubit.deleteAccount(promptPassword: _pw);
      final second = cubit.deleteAccount(promptPassword: _pw);
      await Future<void>.delayed(Duration.zero);
      gate.complete(null);
      await Future.wait([first, second]);

      verifyDeleteCalls(1);
      verify(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      ).called(1);
    });

    test('Apple re-auth revokes the token before DeleteAccount', () async {
      stubReauth(
        (_) async => const ReauthResult(appleAuthorizationCode: 'code'),
      );
      when(() => auth.revokeAppleToken('code')).thenAnswer((_) async {});
      stubDelete((_) async => null);
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      verifyInOrder([
        () => auth.revokeAppleToken('code'),
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ]);
    });

    test('a revoke failure is reported and the deletion proceeds', () async {
      stubReauth(
        (_) async => const ReauthResult(appleAuthorizationCode: 'code'),
      );
      when(() => auth.revokeAppleToken('code'))
          .thenThrow(const AuthFailure.network());
      stubDelete((_) async => null);
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.deleted);
      expect(reported, hasLength(1));
    });

    test('an unexpected AppException is reported as a non-fatal', () async {
      stubDelete((_) async => throw const UnknownApiException('boom'));
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.failed);
      expect(reported, hasLength(1));
    });

    test('a non-AppException error never leaves the cubit working', () async {
      stubReauth((_) async => throw Exception('platform boom'));
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.failed);
      expect(cubit.state.error, isA<UnknownApiException>());
      expect(reported, hasLength(1));
      verifyNever(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    test('no emit after close', () async {
      final gate = Completer<ReauthResult>();
      stubReauth((_) => gate.future);
      stubDelete((_) async => null);
      final cubit = build();

      final run = cubit.deleteAccount(promptPassword: _pw);
      await cubit.close();
      gate.complete(const ReauthResult());

      await run; // would throw StateError on emit after close
      verifyNever(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    test(
      'skipReauth goes straight to the delete (recent Google sign-in)',
      () async {
        stubDelete((_) async => null);
        final cubit = build();

        await cubit.deleteAccount(promptPassword: _pw, skipReauth: true);

        expect(cubit.state.status, AccountStatus.deleted);
        verifyNever(
          () =>
              auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
        );
        verifyDeleteCalls(1);
      },
    );

    test('skipReauth then REAUTH_REQUIRED: one re-auth, one retry, same key, '
        'no loop', () async {
      final keys = <String>[];
      var calls = 0;
      stubDelete((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        if (++calls <= 2) throw const ReauthRequiredException('old');
        return null;
      });
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw, skipReauth: true);

      expect(cubit.state.status, AccountStatus.failed);
      expect(cubit.state.error, isA<ReauthRequiredException>());
      verify(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      ).called(1);
      verifyDeleteCalls(2);
      expect(keys[0], keys[1]);
    });

    test(
      'after a REAUTH_REQUIRED the next tap never skips the re-auth',
      () async {
        when(() => auth.reauthNeedsGesture).thenReturn(true);
        var calls = 0;
        stubDelete((_) async {
          if (++calls == 1) throw const ReauthRequiredException('old');
          return null;
        });
        final cubit = build();

        await cubit.deleteAccount(promptPassword: _pw, skipReauth: true);
        expect(cubit.state.error, isA<ReauthRequiredException>());
        verifyNever(
          () =>
              auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
        );

        await cubit.deleteAccount(promptPassword: _pw, skipReauth: true);
        expect(cubit.state.status, AccountStatus.deleted);
        verify(
          () =>
              auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
        ).called(1);
      },
    );

    test('a wrong password fails with invalidCredentials and sends nothing; '
        'the key survives for the retry', () async {
      var attempt = 0;
      stubReauth((_) async {
        if (++attempt == 1) throw const AuthFailure.invalidCredentials();
        return const ReauthResult();
      });
      stubDelete((_) async => null);
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);
      expect(cubit.state.authFailure, isA<AuthInvalidCredentials>());
      verifyNever(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );

      cubit.dismissMessage();
      expect(cubit.state.status, AccountStatus.idle);
      await cubit.deleteAccount(promptPassword: _pw);
      expect(cubit.state.status, AccountStatus.deleted);
    });

    test('on web the fallback re-auth is skipped (outside the gesture); the '
        'next tap retries with the same key', () async {
      when(() => auth.reauthNeedsGesture).thenReturn(true);
      final keys = <String>[];
      var calls = 0;
      stubDelete((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        if (++calls == 1) throw const ReauthRequiredException('old');
        return null;
      });
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);
      expect(cubit.state.error, isA<ReauthRequiredException>());
      // Only the up-front re-auth ran, no fallback one.
      verify(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      ).called(1);

      await cubit.deleteAccount(promptPassword: _pw);
      expect(cubit.state.status, AccountStatus.deleted);
      expect(keys[0], keys[1]);
    });

    test('reset during the DeleteAccount RPC does not drop the accepted '
        'deletion', () async {
      final gate = Completer<DateTime?>();
      stubDelete((_) => gate.future);
      final cubit = build();

      final run = cubit.deleteAccount(promptPassword: _pw);
      await Future<void>.delayed(Duration.zero);
      cubit.reset();
      expect(cubit.state.status, AccountStatus.working);
      gate.complete(null);
      await run;

      expect(cubit.state.status, AccountStatus.deleted);
    });

    test('reset frees a flow stuck behind a provider UI', () async {
      final gate = Completer<ReauthResult>();
      stubReauth((_) => gate.future);
      stubDelete((_) async => null);
      final cubit = build();

      final stuck = cubit.deleteAccount(promptPassword: _pw);
      cubit.reset();
      expect(cubit.state.status, AccountStatus.idle);

      gate.complete(const ReauthResult());
      await stuck;
      expect(cubit.state.status, AccountStatus.idle);
      verifyNever(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });
  });

  group('deleteAccount client-side fallback (P8 L-5)', () {
    void stubDeleteUser() {
      when(() => auth.deleteCurrentUser()).thenAnswer((_) async {});
    }

    test('PROFILE_REQUIRED from the server deletes the Auth user from the '
        'client after re-auth, with no retry', () async {
      stubDelete(
        (_) async => throw const ProfileRequiredException(
          'create a profile first',
          fromServerReason: true,
        ),
      );
      stubDeleteUser();
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.deleted);
      verifyInOrder([
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
        () => auth.deleteCurrentUser(),
      ]);
      verifyNoMoreInteractions(accounts);
    });

    test('an Apple caller is revoked once before the client delete', () async {
      stubReauth((_) async => const ReauthResult(appleAuthorizationCode: 'c'));
      when(() => auth.revokeAppleToken('c')).thenAnswer((_) async {});
      stubDelete(
        (_) async =>
            throw const ProfileRequiredException('x', fromServerReason: true),
      );
      stubDeleteUser();
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.deleted);
      verifyInOrder([
        () => auth.revokeAppleToken('c'),
        () => auth.deleteCurrentUser(),
      ]);
    });

    test(
      'requires-recent-login becomes the re-auth prompt, not a success',
      () async {
        stubDelete(
          (_) async =>
              throw const ProfileRequiredException('x', fromServerReason: true),
        );
        when(() => auth.deleteCurrentUser()).thenAnswer(
          (_) async => throw const AuthFailure.requiresRecentLogin(),
        );
        final cubit = build();

        await cubit.deleteAccount(promptPassword: _pw);

        expect(cubit.state.status, AccountStatus.failed);
        expect(cubit.state.error, isA<ReauthRequiredException>());
      },
    );

    test('a code-only FAILED_PRECONDITION does not fall back', () async {
      stubDelete((_) async => throw const ProfileRequiredException('x'));
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.failed);
      verifyNever(() => auth.deleteCurrentUser());
    });

    for (final error in <AppException>[
      const NetworkException('offline'),
      const DegradedModeException('degraded'),
      const EmailNotVerifiedException('verify'),
      const AccountRestrictedException('restricted'),
      const UnknownApiException('boom'),
    ]) {
      test('${error.runtimeType} does not fall back', () async {
        stubDelete((_) async => throw error);
        final cubit = build();

        await cubit.deleteAccount(promptPassword: _pw);

        expect(cubit.state.status, AccountStatus.failed);
        expect(cubit.state.error, error);
        verifyNever(() => auth.deleteCurrentUser());
      });
    }

    test('a cancelled re-auth never reaches the client delete', () async {
      stubReauth((_) async => throw const AuthFailure.cancelled());
      final cubit = build();

      await cubit.deleteAccount(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.cancelled);
      verifyNever(() => auth.deleteCurrentUser());
    });
  });

  group('requestExport', () {
    const pending = AccountExport(
      exportId: 'e1',
      status: identity.ExportStatus.EXPORT_STATUS_PENDING,
    );

    void stubExport(Future<AccountExport> Function(Invocation) answer) {
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(answer);
    }

    void verifyExportCalls(int n) => verify(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).called(n);

    test('re-authenticates up front, then sends exactly one call; quota error '
        'is typed', () async {
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async => pending);
      final cubit = build();
      await cubit.requestExport(promptPassword: _pw);
      expect(cubit.state.status, AccountStatus.exportRequested);
      expect(cubit.state.export!.exportId, 'e1');
      verify(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      ).called(1);
      verifyExportCalls(1);

      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(const QuotaExceededException('x'));
      await cubit.requestExport(promptPassword: _pw);
      expect(cubit.state.error, isA<QuotaExceededException>());
    });

    test('returns the accepted export even when closed mid-RPC', () async {
      final gate = Completer<AccountExport>();
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) => gate.future);
      final cubit = build();
      final result = cubit.requestExport(promptPassword: _pw);
      await Future<void>.delayed(Duration.zero);
      await cubit.close();
      gate.complete(pending);

      expect((await result)?.exportId, 'e1');
    });

    test('returns the accepted export even when reset mid-RPC', () async {
      final gate = Completer<AccountExport>();
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) => gate.future);
      final cubit = build();
      final result = cubit.requestExport(promptPassword: _pw);
      await Future<void>.delayed(Duration.zero);
      cubit.reset();
      gate.complete(pending);

      expect((await result)?.exportId, 'e1');
      expect(cubit.state.status, AccountStatus.idle);
    });

    test('returns null on failure and on a cancelled re-auth', () async {
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(const QuotaExceededException('x'));
      final cubit = build();
      expect(await cubit.requestExport(promptPassword: _pw), isNull);

      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async => pending);
      stubReauth((_) async => throw const AuthFailure.cancelled());
      expect(await cubit.requestExport(promptPassword: _pw), isNull);
      expect(cubit.state.status, AccountStatus.cancelled);
    });

    test(
      'a retry after failure reuses the key; success mints a fresh one',
      () async {
        final keys = <String>[];
        var fail = true;
        when(
          () => accounts.requestExport(
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenAnswer((invocation) async {
          keys.add(invocation.namedArguments[#idempotencyKey] as String);
          if (fail) throw const NetworkException('offline');
          return pending;
        });
        final cubit = build();
        await cubit.requestExport(promptPassword: _pw);
        fail = false;
        await cubit.requestExport(promptPassword: _pw);
        await cubit.requestExport(promptPassword: _pw);

        expect(keys[0], keys[1]);
        expect(keys[2], isNot(keys[1]));
      },
    );

    test('Apple re-auth on export never revokes the token', () async {
      var calls = 0;
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async {
        if (++calls == 1) throw const ReauthRequiredException('old');
        return pending;
      });
      stubReauth(
        (_) async => const ReauthResult(appleAuthorizationCode: 'code'),
      );
      final cubit = build();

      await cubit.requestExport(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.exportRequested);
      verifyNever(() => auth.revokeAppleToken(any()));
    });

    test('a cancelled up-front re-auth sends no RPC', () async {
      stubExport((_) async => pending);
      stubReauth((_) async => throw const AuthFailure.cancelled());
      final cubit = build();

      expect(await cubit.requestExport(promptPassword: _pw), isNull);

      expect(cubit.state.status, AccountStatus.cancelled);
      verifyNever(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    test('a cancelled fallback re-auth (server still REAUTH_REQUIRED) sends '
        'no retry RPC and keeps the key', () async {
      final keys = <String>[];
      stubExport((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        throw const ReauthRequiredException('old'); // server keeps asking
      });
      var reauths = 0;
      stubReauth((_) async {
        if (++reauths == 1) return const ReauthResult(); // up front succeeds
        throw const AuthFailure.cancelled(); // the fallback is cancelled
      });
      final cubit = build();

      expect(await cubit.requestExport(promptPassword: _pw), isNull);

      expect(cubit.state.status, AccountStatus.cancelled);
      verifyExportCalls(1); // the retry after the cancelled fallback never runs
      expect(reauths, 2);

      // The next tap reuses the same key: nothing was consumed.
      stubExport((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        return pending;
      });
      stubReauth(ok());
      await cubit.requestExport(promptPassword: _pw);
      expect(cubit.state.status, AccountStatus.exportRequested);
      expect(keys[1], keys[0]);
    });

    test('a cancel keeps the key: the retry reuses the one already sent '
        'once', () async {
      final keys = <String>[];
      var calls = 0;
      stubExport((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        if (++calls == 1) throw const NetworkException('offline');
        return pending;
      });
      final cubit = build();
      await cubit.requestExport(promptPassword: _pw); // key k, RPC fails

      stubReauth((_) async => throw const AuthFailure.cancelled());
      await cubit.requestExport(promptPassword: _pw); // cancelled, no RPC
      expect(cubit.state.status, AccountStatus.cancelled);

      stubReauth(ok());
      await cubit.requestExport(promptPassword: _pw);
      expect(cubit.state.status, AccountStatus.exportRequested);
      expect(keys, hasLength(2));
      expect(keys[1], keys[0]);
    });

    for (final web in [false, true]) {
      test('${web ? 'web' : 'non-web'}: the re-auth starts synchronously from '
          'the tap and finishes before the RPC', () async {
        when(() => auth.reauthNeedsGesture).thenReturn(web);
        final events = <String>[];
        stubReauth((_) async {
          events.add('reauth');
          return const ReauthResult();
        });
        stubExport((_) async {
          events.add('rpc');
          return pending;
        });
        final cubit = build();

        final run = cubit.requestExport(promptPassword: _pw);
        // No await between the call and this check: the re-auth was
        // already invoked, so a web popup would still be in the gesture.
        expect(events, ['reauth']);
        await run;

        expect(events, ['reauth', 'rpc']);
      });
    }

    test('non-web: REAUTH_REQUIRED after the re-auth re-authenticates once '
        'more and retries once with the same key', () async {
      final keys = <String>[];
      var calls = 0;
      stubExport((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        if (++calls == 1) throw const ReauthRequiredException('old');
        return pending;
      });
      final cubit = build();

      await cubit.requestExport(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.exportRequested);
      expect(keys[1], keys[0]);
      verify(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      ).called(2);
      verifyExportCalls(2);
    });

    test('non-web: a second REAUTH_REQUIRED is not retried again', () async {
      stubExport((_) async => throw const ReauthRequiredException('old'));
      final cubit = build();

      await cubit.requestExport(promptPassword: _pw);

      expect(cubit.state.error, isA<ReauthRequiredException>());
      verifyExportCalls(2);
    });

    test('web: REAUTH_REQUIRED after the re-auth is surfaced without a popup '
        'outside the gesture; the next tap reuses the key', () async {
      when(() => auth.reauthNeedsGesture).thenReturn(true);
      final keys = <String>[];
      var calls = 0;
      stubExport((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        if (++calls == 1) throw const ReauthRequiredException('old');
        return pending;
      });
      final cubit = build();

      await cubit.requestExport(promptPassword: _pw);
      expect(cubit.state.error, isA<ReauthRequiredException>());
      verify(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      ).called(1);

      await cubit.requestExport(promptPassword: _pw);
      expect(cubit.state.status, AccountStatus.exportRequested);
      expect(keys[1], keys[0]);
    });

    test('reset while the re-auth is open sends no RPC', () async {
      final gate = Completer<ReauthResult>();
      stubReauth((_) => gate.future);
      stubExport((_) async => pending);
      final cubit = build();

      final run = cubit.requestExport(promptPassword: _pw);
      cubit.reset();
      gate.complete(const ReauthResult());

      expect(await run, isNull);
      verifyNever(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });
  });

  group('reauthenticate', () {
    test(
      're-authenticates in the tap, sends no RPC, never revokes Apple',
      () async {
        stubReauth(
          (_) async => const ReauthResult(appleAuthorizationCode: 'apple-code'),
        );
        final cubit = build();

        final run = cubit.reauthenticate(promptPassword: _pw);
        // No await since the call: the provider flow already started.
        verify(
          () =>
              auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
        ).called(1);
        expect(cubit.state.status, AccountStatus.working);

        expect(await run, isTrue);
        expect(cubit.state.status, AccountStatus.idle);
        verifyNever(() => auth.revokeAppleToken(any()));
        verifyZeroInteractions(accounts);
      },
    );

    test('a cancel returns false and lands as cancelled', () async {
      stubReauth((_) async => throw const AuthFailure.cancelled());
      final cubit = build();

      expect(await cubit.reauthenticate(promptPassword: _pw), isFalse);
      expect(cubit.state.status, AccountStatus.cancelled);
      verifyZeroInteractions(accounts);
    });

    test('an auth failure returns false and lands as failed', () async {
      stubReauth((_) async => throw const AuthFailure.invalidCredentials());
      final cubit = build();

      expect(await cubit.reauthenticate(promptPassword: _pw), isFalse);
      expect(cubit.state.status, AccountStatus.failed);
      expect(cubit.state.authFailure, isA<AuthInvalidCredentials>());
    });

    test('a double tap while working is ignored', () async {
      final gate = Completer<ReauthResult>();
      stubReauth((_) => gate.future);
      final cubit = build();

      final first = cubit.reauthenticate(promptPassword: _pw);
      expect(await cubit.reauthenticate(promptPassword: _pw), isFalse);
      gate.complete(const ReauthResult());
      expect(await first, isTrue);
      verify(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      ).called(1);
    });
  });
}
