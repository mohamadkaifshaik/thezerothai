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

void main() {
  late _MockAccounts accounts;
  late _MockAuth auth;
  final reported = <Object>[];

  AccountCubit build() => AccountCubit(
    accountRepository: accounts,
    authRepository: auth,
    promptPassword: () async => 'pw',
    onUnexpectedError: (e, _) => reported.add(e),
  );

  setUp(() {
    accounts = _MockAccounts();
    auth = _MockAuth();
    reported.clear();
    when(
      () => auth.reauthenticate(
        promptPassword: any(named: 'promptPassword'),
        appleWebOptions: any(named: 'appleWebOptions'),
        googleWebClientId: any(named: 'googleWebClientId'),
      ),
    ).thenAnswer((_) async => const ReauthResult());
  });

  group('deleteAccount', () {
    test('success sends one call and ends deleted', () async {
      when(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async => null);
      final cubit = build();

      await cubit.deleteAccount();

      expect(cubit.state.status, AccountStatus.deleted);
      verify(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      verifyNever(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      );
    });

    test('REAUTH_REQUIRED re-authenticates once and retries once with the '
        'same key', () async {
      final keys = <String>[];
      var calls = 0;
      when(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((invocation) async {
        keys.add(invocation.namedArguments[#idempotencyKey] as String);
        if (++calls == 1) throw const ReauthRequiredException('old');
        return null;
      });
      final cubit = build();

      await cubit.deleteAccount();

      expect(cubit.state.status, AccountStatus.deleted);
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
      verify(
        () => auth.reauthenticate(
          promptPassword: any(named: 'promptPassword'),
          appleWebOptions: any(named: 'appleWebOptions'),
          googleWebClientId: any(named: 'googleWebClientId'),
        ),
      ).called(1);
    });

    test('a second REAUTH_REQUIRED is surfaced, not looped', () async {
      when(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(const ReauthRequiredException('old'));
      final cubit = build();

      await cubit.deleteAccount();

      expect(cubit.state.status, AccountStatus.failed);
      expect(cubit.state.error, isA<ReauthRequiredException>());
      verify(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(2);
    });

    test('a cancelled re-authentication sends nothing more', () async {
      when(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(const ReauthRequiredException('old'));
      when(
        () => auth.reauthenticate(
          promptPassword: any(named: 'promptPassword'),
          appleWebOptions: any(named: 'appleWebOptions'),
          googleWebClientId: any(named: 'googleWebClientId'),
        ),
      ).thenThrow(const AuthFailure.cancelled());
      final cubit = build();

      await cubit.deleteAccount();

      expect(cubit.state.status, AccountStatus.cancelled);
      verify(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });

    test('a retry after a network error reuses the same key', () async {
      final keys = <String>[];
      var calls = 0;
      when(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((invocation) async {
        keys.add(invocation.namedArguments[#idempotencyKey] as String);
        if (++calls == 1) throw const NetworkException('offline');
        return null;
      });
      final cubit = build();

      await cubit.deleteAccount();
      expect(cubit.state.status, AccountStatus.failed);
      expect(cubit.state.error, isA<NetworkException>());
      await cubit.deleteAccount();

      expect(cubit.state.status, AccountStatus.deleted);
      expect(keys[0], keys[1]);
    });

    test('Apple re-auth revokes the token before the retry', () async {
      var calls = 0;
      when(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async {
        if (++calls == 1) throw const ReauthRequiredException('old');
        return null;
      });
      when(
        () => auth.reauthenticate(
          promptPassword: any(named: 'promptPassword'),
          appleWebOptions: any(named: 'appleWebOptions'),
          googleWebClientId: any(named: 'googleWebClientId'),
        ),
      ).thenAnswer(
        (_) async => const ReauthResult(appleAuthorizationCode: 'code'),
      );
      when(() => auth.revokeAppleToken('code')).thenAnswer((_) async {});
      final cubit = build();

      await cubit.deleteAccount();

      expect(cubit.state.status, AccountStatus.deleted);
      verifyInOrder([
        () => auth.revokeAppleToken('code'),
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ]);
    });

    test('an unexpected error is reported as a non-fatal', () async {
      when(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(const UnknownApiException('boom'));
      final cubit = build();

      await cubit.deleteAccount();

      expect(cubit.state.status, AccountStatus.failed);
      expect(reported, hasLength(1));
    });
  });

  group('requestExport', () {
    test('success exposes the export; quota error is typed', () async {
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => const AccountExport(
          exportId: 'e1',
          status: identity.ExportStatus.EXPORT_STATUS_PENDING,
        ),
      );
      final cubit = build();
      await cubit.requestExport();
      expect(cubit.state.status, AccountStatus.exportRequested);
      expect(cubit.state.export!.exportId, 'e1');

      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(const QuotaExceededException('x', quota: 'exports'));
      await cubit.requestExport();
      expect(cubit.state.error, isA<QuotaExceededException>());
    });
  });
}
