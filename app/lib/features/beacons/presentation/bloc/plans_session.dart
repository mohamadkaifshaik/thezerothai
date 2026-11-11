import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../communities/data/communities_repository.dart';
import '../../../communities/domain/communities_feature_flag.dart';
import '../../data/beacons_repository.dart';
import '../../domain/beacons_feature_flag.dart';
import 'beacons_cubit.dart';
import 'my_beacons_cubit.dart';

/// The `/plans` list and its "Your plans" section, hoisted above both of
/// their placements (tablet plan section 5.2): the band A list (the route
/// child) and the band B list pane (built by `MainShell`) are different
/// widgets, so crossing 840dp would otherwise load the list again.
///
/// - **Lazy.** Nothing is created until a placement reads [list] or
///   [yourPlans], and reading sends nothing: the route's open loads
///   (`refresh`), the list pane only makes sure a load was started
///   (`ensureLoaded`). Plans with `beacons` off builds no cubit (the paused
///   page), so nothing exists then either.
/// - **Per account.** `AppWidget` registers [reset] with the account reset
///   (sign-out and an account switch) and calls [featuresChanged] on every
///   new flag set: `beacons` off drops both; `communities` changing rebuilds
///   the list, because [BeaconsCubit] captures it at construction (its
///   audience chips), and loads the new one when the old one had loaded.
/// - Every replacement or drop ticks [changes], so a mounted placement
///   rebinds. Placements never close these cubits.
///
/// A plain object (not a `Listenable`) so it can be provided as a value.
class PlansSession {
  PlansSession({
    required BeaconsRepository repository,
    CommunitiesRepository? communities,
  }) : _repository = repository,
       _communities = communities;

  /// The "Your plans" page size (tablet plan section 4.1: limit 2).
  static const yourPlansLimit = 2;

  final BeaconsRepository _repository;
  final CommunitiesRepository? _communities;

  BeaconsCubit? _list;
  bool _listWithCommunities = false;
  MyBeaconsCubit? _yourPlans;
  bool _disposed = false;
  final ValueNotifier<int> _revision = ValueNotifier(0);

  /// Ticks when a cubit was replaced or dropped: a placement listening to
  /// it reads [list] or [yourPlans] again.
  Listenable get changes => _revision;

  void _notify() => _revision.value++;

  /// The `/plans` list (created on first read; nothing is sent).
  BeaconsCubit get list => _list ??= _newList();

  /// The "Your plans" section: the caller's next plans, 2 of them.
  MyBeaconsCubit get yourPlans => _yourPlans ??= MyBeaconsCubit(
    repository: _repository,
    pageSize: yourPlansLimit,
  );

  @visibleForTesting
  BeaconsCubit? get listIfCreated => _list;

  @visibleForTesting
  MyBeaconsCubit? get yourPlansIfCreated => _yourPlans;

  BeaconsCubit _newList() {
    _listWithCommunities = _communities?.enabled ?? false;
    return BeaconsCubit(
      repository: _repository,
      communities: _communities,
      communitiesEnabled: _listWithCommunities,
    );
  }

  /// A fresh `GetMe` flag set: drops everything without `beacons`; rebuilds
  /// the list when `communities` is no longer what it was built with.
  void featuresChanged(Set<String> features) {
    if (_disposed) return;
    if (!features.contains(kFeatureBeacons)) {
      if (_drop()) _notify();
      return;
    }
    final old = _list;
    if (old == null) return;
    final communities =
        _communities != null && features.contains(kFeatureCommunities);
    if (communities == _listWithCommunities) return;
    _list = null;
    final reload = old.started;
    unawaited(old.close());
    if (reload) unawaited(list.load());
    _notify();
  }

  /// Sign-out or an account switch: forget both (the next account reads
  /// fresh, empty cubits).
  void reset() {
    if (_disposed) return;
    if (_drop()) _notify();
  }

  /// A write in the band B detail (cancel, join, leave, an edit): the list
  /// pane beside it never left the screen, so it reloads what was loaded.
  /// Band A and phones reload on return instead.
  void refreshAfterWrite() {
    if (_list case final list? when list.started) unawaited(list.refresh());
    if (_yourPlans case final mine? when mine.started) {
      unawaited(mine.refresh());
    }
  }

  bool _drop() {
    final had = _list != null || _yourPlans != null;
    unawaited(_list?.close());
    unawaited(_yourPlans?.close());
    _list = null;
    _yourPlans = null;
    return had;
  }

  void dispose() {
    _drop();
    _disposed = true;
    _revision.dispose();
  }
}
