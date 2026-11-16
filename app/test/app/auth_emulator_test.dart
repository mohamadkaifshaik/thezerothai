import 'package:dzeroth/app/app_config.dart';
import 'package:dzeroth/app/auth_emulator.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements fb_auth.FirebaseAuth {}

AppConfig _config({required bool emulators, String host = '127.0.0.1:9099'}) =>
    AppConfig(
      apiBaseUrl: 'http://127.0.0.1:8081',
      useEmulators: emulators,
      authEmulatorHost: host,
      appCheckDebugToken: '',
      recaptchaSiteKey: '',
      googleWebClientId: '',
      appleServiceId: '',
      appleRedirectUri: '',
      firebaseEnv: FirebaseEnv.dev,
      shareOrigin: kDevShareOrigin,
    );

void main() {
  test('points Auth at the emulator when emulators are on', () async {
    final auth = _MockAuth();
    when(() => auth.useAuthEmulator(any(), any())).thenAnswer((_) async {});
    await configureAuthEmulator(auth, _config(emulators: true));
    verify(() => auth.useAuthEmulator('127.0.0.1', 9099)).called(1);
  });

  test('does nothing when emulators are off', () async {
    final auth = _MockAuth();
    await configureAuthEmulator(auth, _config(emulators: false));
    verifyZeroInteractions(auth);
  });

  test('fails closed when useAuthEmulator throws', () async {
    final auth = _MockAuth();
    when(() => auth.useAuthEmulator(any(), any())).thenThrow(StateError('x'));
    await expectLater(
      configureAuthEmulator(auth, _config(emulators: true)),
      throwsA(isA<AppConfigError>()),
    );
  });

  test('fails closed on a malformed host without calling Auth', () async {
    final auth = _MockAuth();
    await expectLater(
      configureAuthEmulator(auth, _config(emulators: true, host: 'nohost')),
      throwsA(isA<AppConfigError>()),
    );
    verifyNever(() => auth.useAuthEmulator(any(), any()));
  });
}
