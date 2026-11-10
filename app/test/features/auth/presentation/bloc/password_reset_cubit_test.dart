import 'dart:async';

import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/password_reset_cubit.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:mocktail/mocktail.dart';

class _Repository extends Mock implements AuthRepository {}

class _MockFirebaseAuth extends Mock implements fb.FirebaseAuth {}

class _MockGoogleSignIn extends Mock implements GoogleSignIn {}

void main() {
  test('prevents duplicate requests while sending and after success', () async {
    final repository = _Repository();
    final pending = Completer<void>();
    when(() => repository.sendPasswordResetEmail(any()))
        .thenAnswer((_) => pending.future);
    final cubit = PasswordResetCubit(repository);
    addTearDown(cubit.close);
    final first = cubit.send('person@example.com');
    expect(cubit.state.busy, isTrue);
    await cubit.send('person@example.com');
    pending.complete();
    await first;
    await cubit.send('person@example.com');
    expect(cubit.state.sent, isTrue);
    verify(() => repository.sendPasswordResetEmail(any())).called(1);
  });

  test(
    'failure allows retry and closing the dialog during a request is safe',
    () async {
      final repository = _Repository();
      when(() => repository.sendPasswordResetEmail(any()))
          .thenThrow(const AuthFailure.network());
      final cubit = PasswordResetCubit(repository);
      await cubit.send('person@example.com');
      expect(cubit.state.error, contains('connection'));
      expect(cubit.state.busy, isFalse);
      final pending = Completer<void>();
      when(() => repository.sendPasswordResetEmail(any()))
          .thenAnswer((_) => pending.future);
      final retry = cubit.send('person@example.com');
      await cubit.close();
      pending.complete();
      await retry;
      verify(() => repository.sendPasswordResetEmail(any())).called(2);
    },
  );
  group('with the real repository', () {
    late _MockFirebaseAuth firebaseAuth;
    late DateTime now;
    late AuthRepository repository;

    setUp(() {
      firebaseAuth = _MockFirebaseAuth();
      now = DateTime.now();
      repository = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: _MockGoogleSignIn(),
        clock: () => now,
      );
    });

    test('the cooldown survives closing and reopening the dialog', () async {
      when(
        () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
      ).thenAnswer((_) async {});

      // First dialog: sent, then closed.
      final first = PasswordResetCubit(repository);
      await first.send('person@example.com');
      expect(first.state.sent, isTrue);
      await first.close();

      // Reopened 10 s later (a new cubit): the same "sent" answer, no email.
      now = now.add(const Duration(seconds: 10));
      final second = PasswordResetCubit(repository);
      addTearDown(second.close);
      await second.send('person@example.com');
      expect(second.state.sent, isTrue);
      expect(second.state.error, isNull);
      verify(
        () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
      ).called(1);
    });

    test('a disabled account or an unexpected code shows "sent", never the '
        'raw Firebase message', () async {
      for (final code in ['user-disabled', 'invalid-email', 'weird-new-code']) {
        when(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).thenThrow(fb.FirebaseAuthException(code: code, message: 'RAW $code'));
        final cubit = PasswordResetCubit(
          AuthRepository(
            firebaseAuth: firebaseAuth,
            googleSignIn: _MockGoogleSignIn(),
          ),
        );
        await cubit.send('person@example.com');
        expect(cubit.state.sent, isTrue, reason: code);
        expect(cubit.state.error, isNull, reason: code);
        await cubit.close();
      }
    });
  });
}
