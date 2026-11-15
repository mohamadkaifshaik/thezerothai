import 'location_models.dart';

final _apostrophes = RegExp('[\'’]');
final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// The search form of [input] (shared rules,
/// `testdata/location/area_rules.json`): lower case, apostrophes dropped, any
/// other punctuation becomes a space, runs of whitespace collapse to one
/// space, trimmed.
String normaliseAreaText(String input) => input
    .toLowerCase()
    .replaceAll(_apostrophes, '')
    .replaceAll(_nonWord, ' ')
    .trim();

/// The areas matching [query], best first. Each word of the query must start
/// a word of the name, an alias or the city. Rank: the name or an alias
/// starts with the query, then a word prefix of the name or aliases, then a
/// city-only match; ties by name. Retired areas never match. An empty query
/// lists every active area ordered by city, then name.
List<AreaEntry> searchAreas(List<AreaEntry> areas, String query) {
  final q = normaliseAreaText(query);
  final active = [
    for (final a in areas)
      if (!a.retired) a,
  ];
  if (q.isEmpty) {
    return active..sort(_byCityThenName);
  }
  final tokens = q.split(' ');
  final ranked = <(int, AreaEntry)>[];
  for (final entry in active) {
    final name = normaliseAreaText(entry.ref.name);
    final aliases = [for (final a in entry.aliases) normaliseAreaText(a)];
    final city = normaliseAreaText(entry.ref.cityName);
    final own = [...name.split(' '), for (final a in aliases) ...a.split(' ')];
    final all = [...own, ...city.split(' ')];
    if (!tokens.every((t) => all.any((w) => w.startsWith(t)))) continue;
    final int rank;
    if (name.startsWith(q) || aliases.any((a) => a.startsWith(q))) {
      rank = 0;
    } else if (tokens.every((t) => own.any((w) => w.startsWith(t)))) {
      rank = 1;
    } else {
      rank = 2;
    }
    ranked.add((rank, entry));
  }
  ranked.sort((a, b) {
    final byRank = a.$1.compareTo(b.$1);
    return byRank != 0 ? byRank : _byName(a.$2, b.$2);
  });
  return [for (final r in ranked) r.$2];
}

int _byName(AreaEntry a, AreaEntry b) =>
    a.ref.name.toLowerCase().compareTo(b.ref.name.toLowerCase());

int _byCityThenName(AreaEntry a, AreaEntry b) {
  final c = a.ref.cityName.toLowerCase().compareTo(
    b.ref.cityName.toLowerCase(),
  );
  if (c != 0) return c;
  // The city row first within its city.
  if (a.ref.type != b.ref.type) {
    return a.ref.type == AreaType.city ? -1 : 1;
  }
  return _byName(a, b);
}

/// One city of the picker: its "All of [city]" choice ([city], null when the
/// catalogue has no active city row) and the matching [areas] in rank order.
class AreaGroup {
  const AreaGroup({
    required this.cityId,
    required this.cityName,
    required this.city,
    required this.areas,
  });

  final String cityId;
  final String cityName;
  final AreaRef? city;
  final List<AreaRef> areas;
}

/// Groups [results] (best first) by city, cities in the order of their best
/// match. A city row in the results becomes the group's "All of" choice, not
/// a row of its own.
List<AreaGroup> groupByCity(List<AreaEntry> results, List<AreaEntry> all) {
  final cityRows = <String, AreaRef>{
    for (final e in all)
      if (!e.retired && e.ref.type == AreaType.city) e.ref.id: e.ref,
  };
  final order = <String>[];
  final names = <String, String>{};
  final byCity = <String, List<AreaRef>>{};
  for (final e in results) {
    final cityId = e.ref.type == AreaType.city ? e.ref.id : e.ref.cityId;
    final list = byCity.putIfAbsent(cityId, () {
      order.add(cityId);
      return <AreaRef>[];
    });
    names.putIfAbsent(
      cityId,
      () => e.ref.type == AreaType.city ? e.ref.name : e.ref.cityName,
    );
    if (e.ref.type != AreaType.city) list.add(e.ref);
  }
  return [
    for (final id in order)
      AreaGroup(
        cityId: id,
        cityName: names[id]!,
        city: cityRows[id],
        areas: byCity[id]!,
      ),
  ];
}
