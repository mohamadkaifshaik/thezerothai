// firebase_messaging 17 deprecates getToken/onTokenRefresh/deleteToken in favour of the FID-based register()/onRegistered/unregister().
// The backend stores the FCM token, so moving to FID registration is a behaviour change with its own ticket, not part of the dependency bump.
// ignore_for_file: deprecated_member_use

import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockFirebaseMessaging extends Mock implements FirebaseMessaging {}

void main() {
  late MockFirebaseMessaging firebase;
  late FirebasePushMessaging messaging;

  setUp(() {
    firebase = MockFirebaseMessaging();
    messaging = FirebasePushMessaging(messaging: firebase);
  });

  FirebaseException apnsNotSet() => FirebaseException(
    plugin: 'firebase_messaging',
    code: 'apns-token-not-set',
  );

  test('apns-token-not-set is "no token yet", not an error', () async {
    when(() => firebase.getToken()).thenThrow(apnsNotSet());

    expect(await messaging.token(), isNull);
  });

  test('another Firebase error still propagates', () async {
    when(() => firebase.getToken()).thenThrow(
      FirebaseException(plugin: 'firebase_messaging', code: 'unknown'),
    );

    await expectLater(messaging.token(), throwsA(isA<FirebaseException>()));
  });

  test('deleteToken delegates and tolerates apns-token-not-set', () async {
    when(() => firebase.deleteToken()).thenAnswer((_) async {});
    await messaging.deleteToken();
    verify(() => firebase.deleteToken()).called(1);

    when(() => firebase.deleteToken()).thenThrow(apnsNotSet());
    await messaging.deleteToken();
  });
}
