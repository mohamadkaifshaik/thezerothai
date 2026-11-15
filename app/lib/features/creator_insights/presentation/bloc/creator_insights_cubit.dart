import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as pb;
import '../../data/creator_insights_repository.dart';
import '../../domain/creator_insights_feature_flag.dart';
import 'creator_insights_state.dart';

/// Loads `GetCreatorInsights` for the selected window. A switch or a retry
/// starts a fresh load; a generation counter drops a stale answer.
class CreatorInsightsCubit extends Cubit<CreatorInsightsState> {
  CreatorInsightsCubit({required CreatorInsightsRepository repository})
    : _repository = repository,
      super(
        const CreatorInsightsState.loading(windowDays: kInsightsDefaultWindow),
      );

  final CreatorInsightsRepository _repository;
  int _generation = 0;

  int get windowDays => state.windowDays;

  Future<void> load() => _load(state.windowDays);

  /// Shows [days] (7 or 28); a no-op for the window already shown.
  Future<void> selectWindow(int days) async {
    if (days == state.windowDays && state is! CreatorInsightsError) return;
    await _load(days);
  }

  Future<void> _load(int days) async {
    final generation = ++_generation;
    emit(CreatorInsightsState.loading(windowDays: days));
    try {
      final data = await _repository.load(windowDays: days);
      if (isClosed || generation != _generation) return;
      emit(
        _isEmpty(data)
            ? CreatorInsightsState.empty(windowDays: days)
            : CreatorInsightsState.ready(windowDays: days, data: data),
      );
    } on AppException catch (error) {
      if (isClosed || generation != _generation) return;
      emit(CreatorInsightsState.error(windowDays: days, error: error));
    }
  }

  static bool _isEmpty(pb.GetCreatorInsightsResponse r) =>
      r.topPosts.isEmpty && _zero(r.current) && _zero(r.previous);

  static bool _zero(pb.CreatorInsightsTotals t) =>
      t.impressions == 0 &&
      t.engagements == 0 &&
      t.followersGained == 0 &&
      t.followersLost == 0;
}
