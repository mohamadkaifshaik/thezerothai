import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../location/data/location_repository.dart';
import '../../data/beacons_repository.dart';
import '../../domain/tonight_plans.dart';
import 'nearby_plans_cubit.dart';

/// What the desktop "Happening nearby" card shows.
class HappeningNearby {
  const HappeningNearby({
    required this.tonight,
    required this.areaName,
    required this.areaLabel,
  });

  final TonightCount tonight;

  /// The area's own name ("Whitefield") and its label with the city.
  final String areaName;
  final String areaLabel;
}

/// The one ListNearbyBeacons call behind the desktop side column's
/// "Happening nearby" hero, shared by every page that shows it.
///
/// - **Lazy.** [ensure] sends nothing until a card asks; the card asks only
///   with `location`, `beacons` and `search` on, on a desktop window.
/// - **One call per 5 minutes** ([ttl]), however many pages build the card
///   (an in-flight call is shared). A failure is remembered for the same
///   time, so a broken Nearby is not retried on every page.
/// - **No area, no call.** The saved area is read first (memoised by the
///   location repository); without one nothing is asked of Nearby.
/// - **Per account.** [reset] (sign-out, an account switch), a flag going off
///   and a changed saved area drop the answer.
/// - [result] is null while loading, on any failure, with no area and with no
///   plan tonight: the card then draws nothing.
class HappeningNearbySession {
  HappeningNearbySession({
    required BeaconsRepository beacons,
    required LocationRepository location,
    DateTime Function()? clock,
    this.ttl = const Duration(minutes: 5),
  }) : _beacons = beacons,
       _location = location,
       _clock = clock ?? DateTime.now {
    _areaChanges = _location.changes.listen((_) => _drop());
  }

  static const pageSize = NearbyPlansCubit.pageSize;

  final BeaconsRepository _beacons;
  final LocationRepository _location;
  final DateTime Function() _clock;
  final Duration ttl;
  StreamSubscription<Object?>? _areaChanges;

  final ValueNotifier<HappeningNearby?> _result = ValueNotifier(null);
  DateTime? _fetchedAt;
  Future<void>? _inFlight;
  int _generation = 0;
  bool _disposed = false;

  ValueListenable<HappeningNearby?> get result => _result;

  /// Starts a fetch unless one ran within [ttl] or is under way.
  Future<void> ensure() {
    if (_disposed) return Future.value();
    final at = _fetchedAt;
    if (at != null && _clock().difference(at) < ttl) return Future.value();
    return _inFlight ??= _fetch();
  }

  Future<void> _fetch() async {
    final generation = _generation;
    HappeningNearby? answer;
    try {
      final settings = await _location.getSettings();
      final saved = settings.area;
      if (saved != null) {
        final page = await _beacons.listNearby(limit: pageSize);
        final area = page.area ?? saved;
        final tonight = countTonightPlans(
          page.items,
          now: _clock(),
          pageSize: pageSize,
        );
        if (tonight.count > 0) {
          answer = HappeningNearby(
            tonight: tonight,
            areaName: area.name,
            areaLabel: area.label,
          );
        }
      }
    } on Object {
      // Never an error on the page: the card just is not there.
      answer = null;
    }
    if (_disposed || generation != _generation) return;
    _fetchedAt = _clock();
    _inFlight = null;
    _result.value = answer;
  }

  void _drop() {
    _generation++;
    _fetchedAt = null;
    _inFlight = null;
    if (!_disposed) _result.value = null;
  }

  /// Sign-out or an account switch.
  void reset() => _drop();

  /// A fresh `GetMe` flag set: any of [required] off drops the answer.
  void featuresChanged(Set<String> features, Set<String> required) {
    if (!features.containsAll(required)) _drop();
  }

  void dispose() {
    _disposed = true;
    unawaited(_areaChanges?.cancel());
    _result.dispose();
  }
}
