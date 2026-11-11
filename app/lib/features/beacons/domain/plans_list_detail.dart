import 'package:flutter/foundation.dart';

/// Where the Plans list pane is shown in band B (tablet plan section 3, LD
/// families): `/plans` (nothing selected) and `/plans/:id` (that plan
/// selected). Null for every other location: `/plans/new`, `/plans/mine`,
/// `/plans/:id/edit` and `/plans/:id/people` have their own layout.
@immutable
class PlansMasterMatch {
  const PlansMasterMatch({this.selectedId});

  /// The open plan, or null on `/plans` itself.
  final String? selectedId;
}

/// The [PlansMasterMatch] of a matched shell [location] (a path; a query or a
/// trailing slash is ignored). A pure function of the route, never of data.
PlansMasterMatch? plansMasterMatch(String location) {
  final segments = [
    for (final s in Uri.parse(location).pathSegments)
      if (s.isNotEmpty) s,
  ];
  return switch (segments) {
    ['plans'] => const PlansMasterMatch(),
    // `/plans/new` and `/plans/mine` are matched before `/plans/:id`.
    ['plans', 'new' || 'mine'] => null,
    // `pathSegments` are already decoded.
    ['plans', final id] => PlansMasterMatch(selectedId: id),
    _ => null,
  };
}
