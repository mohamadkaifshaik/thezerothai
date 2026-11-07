import 'dart:async';

import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/password_reset_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Repository extends Mock implements AuthRepository {}

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
}
