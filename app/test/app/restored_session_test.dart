import 'dart:async';

import 'package:dzeroth/app/restored_session.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthRepository {}

const _user = AppUser(
  uid: 'uid-1',
  email: 'a@example.com',
  emailVerified: true,
  isPasswordProvider: true,
);

void main() {
  late _MockAuth auth;
  setUp(() => auth = _MockAuth());

  test('the first real auth event is definitive, a user or nobody', () async {
    for (final user in [_user, null]) {
      when(() => auth.authStateChanges()).thenAnswer((_) => Stream.value(user));
      final restored = await readRestoredSession(auth);
      expect(restored.uid, user?.uid);
      expect(restored.definitive, isTrue);
    }
  });

  test('no event in time (a slow web restore): the current user, NOT '
      'definitive', () {
    fakeAsync((async) {
      when(() => auth.authStateChanges())
          .thenAnswer((_) => StreamController<AppUser?>().stream);
      when(() => auth.currentUser).thenReturn(null);
      ({String? uid, bool definitive})? restored;
      readRestoredSession(auth).then((r) => restored = r);
      async.elapse(kRestoredSessionTimeout);
      expect(restored, isNotNull);
      expect(restored!.uid, isNull);
      expect(restored!.definitive, isFalse);
    });
  });

  test('a failing auth stream: the current user, NOT definitive', () async {
    when(() => auth.authStateChanges())
        .thenAnswer((_) => Stream.error(StateError('sdk down')));
    when(() => auth.currentUser).thenReturn(_user);
    final restored = await readRestoredSession(auth);
    expect(restored.uid, 'uid-1');
    expect(restored.definitive, isFalse);
  });
}
