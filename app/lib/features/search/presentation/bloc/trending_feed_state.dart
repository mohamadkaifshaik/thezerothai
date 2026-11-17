import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/search_repository.dart' show PostView;
import 'trending_paged_cubit.dart';

part 'trending_feed_state.freezed.dart';

/// The Posts section of the Trending tab.
@freezed
abstract class TrendingFeedState with _$TrendingFeedState {
  const factory TrendingFeedState({
    @Default(PagedStatus.initial) PagedStatus status,
    @Default(<PostView>[]) List<PostView> rows,

    /// A pull to refresh is on its way (the rows stay).
    @Default(false) bool refreshing,

    /// A further page is in flight.
    @Default(false) bool loadingMore,

    /// The last page failed (the rows stay); [error] says why.
    @Default(false) bool pagingFailed,

    /// A round found nothing on empty pages; only "Load more" asks again.
    @Default(false) bool stalled,

    /// A next page exists.
    @Default(false) bool hasMore,

    /// A failed refresh with the rows kept.
    Object? notice,
    Object? error,

    /// Changes when an expired token restarted the list from page one.
    @Default(0) int resetSerial,
  }) = _TrendingFeedState;
}
