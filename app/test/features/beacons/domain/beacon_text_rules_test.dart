import 'package:dzeroth/features/beacons/domain/beacon_text_rules.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:flutter_test/flutter_test.dart';

/// Client-side copies of the server's field rules (docs/beacons-plan.md
/// section 3): trim + NFC, code-point limits, one line for title and venue,
/// and the start window. The server stays authoritative.
void main() {
  group('title', () {
    test('empty after trim is refused', () {
      expect(beaconTitleIssue(''), BeaconTextIssue.empty);
      expect(beaconTitleIssue('   '), BeaconTextIssue.empty);
    });
    test('61 code points is too long, 60 is fine', () {
      expect(
        beaconTitleIssue('x' * (kBeaconTitleMaxLength + 1)),
        BeaconTextIssue.tooLong,
      );
      expect(beaconTitleIssue('x' * kBeaconTitleMaxLength), isNull);
    });
    test('a line break is not one line; padding is trimmed', () {
      expect(beaconTitleIssue('a\nb'), BeaconTextIssue.notPlainOneLine);
      expect(beaconTitleIssue(' Coffee '), isNull);
    });
  });

  group('details', () {
    test('empty is allowed, 301 code points is too long', () {
      expect(beaconDetailsIssue(''), isNull);
      expect(
        beaconDetailsIssue('x' * (kBeaconDetailsMaxLength + 1)),
        BeaconTextIssue.tooLong,
      );
      expect(beaconDetailsIssue('line one\nline two'), isNull);
    });
    test('an invisible character is not plain text', () {
      expect(beaconDetailsIssue('a​b'), BeaconTextIssue.notPlainText);
    });
  });

  group('venue', () {
    test('empty is refused, 81 code points is too long', () {
      expect(beaconVenueIssue(''), BeaconTextIssue.empty);
      expect(
        beaconVenueIssue('x' * (kBeaconVenueMaxLength + 1)),
        BeaconTextIssue.tooLong,
      );
      expect(beaconVenueIssue('Food court entrance, 2nd floor'), isNull);
    });
  });

  group('start time', () {
    // A clock made in the test; nothing here is compared with the real one.
    final now = DateTime(2026, 11, 6, 12, 0);
    test('at least 5 minutes from now', () {
      expect(
        beaconStartIssue(now.add(const Duration(minutes: 4)), now),
        BeaconTimeIssue.tooSoon,
      );
      expect(beaconStartIssue(now.add(kBeaconMinLead), now), isNull);
    });
    test('at most 30 days from now', () {
      expect(beaconStartIssue(now.add(kBeaconMaxLead), now), isNull);
      expect(
        beaconStartIssue(
          now.add(kBeaconMaxLead).add(const Duration(minutes: 1)),
          now,
        ),
        BeaconTimeIssue.tooFar,
      );
    });
  });
}
