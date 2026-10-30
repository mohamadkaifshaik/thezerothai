import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/search_repository.dart';
import 'trends_state.dart';

/// How long an answer (or a failure) is reused before a surface may ask again:
/// ADR-0028 "Client" row, one call per five minutes per client.
const kTrendsClientTtl = Duration(minutes: 5);

/// How many trends the one call asks for: the Trending list's 30 (ADR-0028
/// F6). Explore shows the first 10 and expands to 30, the side column the
/// first 5, so the two surfaces never need a second call.
const kTrendsFetchLimit = 30;

/// The app-level trends list (W4-17/18, ADR-0028): provided once by
/// `AppWidget`, read by Explore and the desktop side column, so mounting both
/// is still one `GetTrends` per [kTrendsClientTtl]. Concurrent callers share
/// the call in flight. No timer and no polling: a surface asks when it mounts
/// or the app resumes, and a warm answer is free (0 RPCs). Reset on sign-out.
///
/// A failure counts as an attempt too (a remount inside the window does not
/// call again); the Retry button passes `force`. `FEATURE_DISABLED` ends the
/// session's calls until [reset].
class TrendsCubit extends Cubit<TrendsState> {
  TrendsCubit({required SearchRepository repository, DateTime Function()? now})
    : _repository = repository,
      _now = now ?? DateTime.now,
      super(const TrendsState());

  final SearchRepository _repository;
  final DateTime Function() _now;
  DateTime? _attemptedAt;
  Future<void>? _inflight;
  int _epoch = 0;

  /// Loads the list unless a call is in flight, an answer is younger than
  /// [kTrendsClientTtl], or the feature is off. [force] (Retry) skips the age
  /// check only. Never throws.
  Future<void> ensureLoaded({bool force = false}) {
    final inflight = _inflight;
    if (inflight != null) return inflight;
    if (state.status == TrendsStatus.unavailable) return Future.value();
    final at = _attemptedAt;
    if (!force && at != null && _now().difference(at) < kTrendsClientTtl) {
      return Future.value();
    }
    late final Future<void> call;
    call = _load().whenComplete(() {
      if (identical(_inflight, call)) _inflight = null;
    });
    return _inflight = call;
  }

  Future<void> _load() async {
    final epoch = _epoch;
    _attemptedAt = _now();
    // A list we already hold stays on screen while the new one is on its way.
    if (state.trends.isEmpty) {
      emit(state.copyWith(status: TrendsStatus.loading, error: null));
    }
    try {
      final result = await _repository.getTrends(limit: kTrendsFetchLimit);
      if (isClosed || epoch != _epoch) return;
      emit(
        TrendsState(
          status: TrendsStatus.ready,
          trends: result.trends,
          computedAt: result.computedAt,
        ),
      );
    } on SearchUnavailableException {
      if (isClosed || epoch != _epoch) return;
      emit(const TrendsState(status: TrendsStatus.unavailable));
    } catch (error) {
      if (isClosed || epoch != _epoch) return;
      emit(state.copyWith(status: TrendsStatus.failed, error: error));
    }
  }

  /// Sign-out: forget the list and the attempt, so the next account asks.
  void reset() {
    _epoch++;
    _attemptedAt = null;
    _inflight = null;
    if (!isClosed) emit(const TrendsState());
  }
}
