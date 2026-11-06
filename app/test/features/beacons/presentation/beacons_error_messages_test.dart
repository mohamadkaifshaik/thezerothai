import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixed, friendly text per typed failure; never the server's message, and
/// never "profile required" for a plan whose state changed.
void main() {
  test('state conflicts read by reason', () {
    expect(
      beaconsErrorMessage(StateConflictException('full')),
      'This plan is full.',
    );
    expect(
      beaconsErrorMessage(StateConflictException('ended')),
      'This plan has already ended.',
    );
    expect(
      beaconsErrorMessage(StateConflictException('cancelled')),
      'This plan has already been cancelled.',
    );
    expect(
      beaconsErrorMessage(StateConflictException('already_requested')),
      "You've already asked to join this plan.",
    );
    expect(
      beaconsErrorMessage(StateConflictException('something_new')),
      "This plan's state has changed. Refresh and try again.",
    );
  });

  test('limits, forbidden and the fixed texts', () {
    expect(
      beaconsErrorMessage(
        LimitReachedException('server says no', quota: kBeaconsOpenLimit),
      ),
      'You can have up to $kMaxOpenBeacons open plans. Cancel one to create '
      'another.',
    );
    expect(
      beaconsErrorMessage(
        CommunityForbiddenException(CommunityForbiddenReason.notMember),
      ),
      CommunityForbiddenReason.notMember.userMessage,
    );
    expect(
      beaconsErrorMessage(
        CommunityForbiddenException(CommunityForbiddenReason.unknown),
      ),
      "You can't do that with this plan.",
    );
    expect(
      beaconsErrorMessage(NotFoundException('beacon not found')),
      'This plan is unavailable.',
    );
    expect(
      beaconsErrorMessage(const FeatureDisabledException('off')),
      "Plans aren't available yet.",
    );
    expect(
      beaconsErrorMessage(ValidationException('bad')),
      'Check the details of your plan, then try again.',
    );
    expect(
      beaconsErrorMessage(HandleTakenException('unrelated')),
      'Something went wrong. Please try again.',
    );
  });

  test('no message echoes the server text', () {
    for (final e in <AppException>[
      StateConflictException('full'),
      NotFoundException('server says no'),
      ValidationException('server says no'),
      HandleTakenException('server says no'),
    ]) {
      expect(beaconsErrorMessage(e), isNot(contains('server says no')));
    }
  });
}
