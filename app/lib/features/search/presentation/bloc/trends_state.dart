import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/search_repository.dart' show Trend;

part 'trends_state.freezed.dart';

enum TrendsStatus {
  /// Nothing asked yet.
  initial,

  /// The first call is in flight and there is nothing to show yet.
  loading,

  /// [TrendsState.trends] is the server's answer (possibly empty: nothing is
  /// trending yet).
  ready,

  /// The last call failed. A list from an earlier answer stays in
  /// [TrendsState.trends]; [TrendsState.error] says why.
  failed,

  /// `FEATURE_TRENDS` is off for this caller or for everyone: every surface
  /// hides itself and nothing is asked again this session.
  unavailable,
}

/// The one trends list of the session (W4-17/18), shared by Explore and the
/// desktop side column.
@freezed
abstract class TrendsState with _$TrendsState {
  const factory TrendsState({
    @Default(TrendsStatus.initial) TrendsStatus status,
    @Default(<Trend>[]) List<Trend> trends,

    /// When the server computed the list; null when there is no list yet.
    DateTime? computedAt,
    Object? error,
  }) = _TrendsState;
}
