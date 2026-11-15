import 'dart:convert';
import 'dart:io';

import 'package:dzeroth/features/location/domain/area_search.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_location_repository.dart';

void main() {
  group('shared fixture testdata/location/area_rules.json', () {
    final rules = jsonDecode(
      File('../testdata/location/area_rules.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final cases = (rules['search'] as List).cast<Map<String, dynamic>>();

    test('has cases', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test('normalises ${jsonEncode(c['input'])}', () {
        expect(normaliseAreaText(c['input'] as String), c['normalised']);
      });
    }
  });

  group('searchAreas', () {
    test('empty query lists active areas, city row first', () {
      final r = searchAreas(fakeCatalogEntries, '');
      expect(r.map((e) => e.ref.id), [
        'in.ocity',
        'in.ocity.gamma',
        'in.tcity',
        'in.tcity.alpha',
        'in.tcity.beta',
      ]);
    });

    test('retired areas never match', () {
      expect(searchAreas(fakeCatalogEntries, 'old'), isEmpty);
    });

    test('matches a word prefix, ignoring punctuation and case', () {
      expect(
        searchAreas(fakeCatalogEntries, ' LAYOUT. ').map((e) => e.ref.id),
        ['in.tcity.beta'],
      );
    });

    test('matches an alias', () {
      expect(searchAreas(fakeCatalogEntries, 'bee').map((e) => e.ref.id), [
        'in.tcity.beta',
      ]);
    });

    test('name prefix ranks above a city-only match', () {
      final r = searchAreas(fakeCatalogEntries, 'test');
      // The city "Testville" starts with "test"; its areas match via the city.
      expect(r.first.ref.id, 'in.tcity');
      expect(r.skip(1).map((e) => e.ref.id), [
        'in.tcity.alpha',
        'in.tcity.beta',
      ]);
    });

    test('groupByCity: city row becomes the All-of choice', () {
      final groups = groupByCity(
        searchAreas(fakeCatalogEntries, ''),
        fakeCatalogEntries,
      );
      expect(groups.map((g) => g.cityId), ['in.ocity', 'in.tcity']);
      expect(groups.last.city?.type, AreaType.city);
      expect(groups.last.areas.map((a) => a.id), [
        'in.tcity.alpha',
        'in.tcity.beta',
      ]);
    });
  });
}
