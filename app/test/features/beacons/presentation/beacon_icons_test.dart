import 'package:dzeroth/features/beacons/presentation/beacon_icons.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every activity has an icon', () {
    for (final a in pb.BeaconActivity.values) {
      expect(activityIcon(a), isA<IconData>(), reason: a.name);
    }
  });
}
