import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as pb;

part 'creator_insights_state.freezed.dart';

/// The Insights group: one of four looks, always for [windowDays].
@freezed
sealed class CreatorInsightsState with _$CreatorInsightsState {
  const factory CreatorInsightsState.loading({@Default(28) int windowDays}) =
      CreatorInsightsLoading;

  /// Nothing recorded in either window and no top posts.
  const factory CreatorInsightsState.empty({@Default(28) int windowDays}) =
      CreatorInsightsEmpty;

  const factory CreatorInsightsState.ready({
    required int windowDays,
    required pb.GetCreatorInsightsResponse data,
  }) = CreatorInsightsReady;

  const factory CreatorInsightsState.error({
    required int windowDays,
    required AppException error,
  }) = CreatorInsightsError;
}
