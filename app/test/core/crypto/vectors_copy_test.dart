import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the integration-test copy of the MLS vectors is byte-identical', () {
    final original = File('../testdata/mls/vectors-v1.json').readAsBytesSync();
    final copy = File('integration_test/assets/mls/vectors-v1.json')
        .readAsBytesSync();
    expect(copy.length, original.length);
    expect(copy, orderedEquals(original));
  });
}
