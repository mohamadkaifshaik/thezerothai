import 'package:dzeroth/core/session/user_ids.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

const _firebaseUid = 'q7Zk3mV9aXb2LcD8eF1gH4iJ5kL6';
const _publicId = 'u0abcdefghijklmnopqrstuvw2';

OnboardingState _me(String id, {bool flagsPending = false}) => OnboardingState(
  status: OnboardingStatus.ready,
  profile: identity.Profile(userId: id, handle: 'me'),
  flagsPending: flagsPending,
);

void main() {
  group('unavailable account id', () {
    test('the tombstone is exactly u + 26 z, pinned', () {
      expect(kUnavailableUserId, 'uzzzzzzzzzzzzzzzzzzzzzzzzzz');
      expect(kUnavailableUserId.length, 27);
    });

    test('isUnavailableUserId matches only the tombstone', () {
      expect(isUnavailableUserId('uzzzzzzzzzzzzzzzzzzzzzzzzzz'), isTrue);
      expect(isUnavailableUserId(_publicId), isFalse);
      expect(isUnavailableUserId(_firebaseUid), isFalse);
      expect(isUnavailableUserId(''), isFalse);
      expect(isUnavailableUserId(null), isFalse);
      expect(isUnavailableUserId('UZZZZZZZZZZZZZZZZZZZZZZZZZZ'), isFalse);
    });
  });

  group('myUserId', () {
    test('public_ids off: the GetMe id is the Firebase uid, as today', () {
      expect(_me(_firebaseUid).myUserId, _firebaseUid);
    });

    test('public_ids on: the GetMe id is the public id', () {
      expect(_me(_publicId).myUserId, _publicId);
    });

    test('before GetMe loaded: unknown, never a fallback', () {
      expect(const OnboardingState().myUserId, isNull);
      expect(_me(_firebaseUid, flagsPending: true).myUserId, isNull);
      expect(_me(_publicId, flagsPending: true).myUserId, isNull);
    });

    test('an empty or tombstone id is unknown', () {
      expect(_me('').myUserId, isNull);
      expect(_me(kUnavailableUserId).myUserId, isNull);
    });
  });
}
