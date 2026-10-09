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

    test('success does not re-authenticate; quota error is typed', () async {
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async => pending);
      final cubit = build();
      await cubit.requestExport(promptPassword: _pw);
      expect(cubit.state.status, AccountStatus.exportRequested);
      expect(cubit.state.export!.exportId, 'e1');
      verifyNever(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      );

      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(const QuotaExceededException('x', quota: 'exports'));
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
      ).thenThrow(const ReauthRequiredException('old'));
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

    test('a cancelled re-auth on export sends no second call', () async {
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(const ReauthRequiredException('old'));
      stubReauth((_) async => throw const AuthFailure.cancelled());
      final cubit = build();

      await cubit.requestExport(promptPassword: _pw);

      expect(cubit.state.status, AccountStatus.cancelled);
      verify(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });
  });
}
