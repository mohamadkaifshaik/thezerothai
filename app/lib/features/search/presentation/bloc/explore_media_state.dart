import 'package:freezed_annotation/freezed_annotation.dart';

import '../../domain/explore_media.dart';

part 'explore_media_state.freezed.dart';

enum ExploreMediaStatus {
  /// Not started: no trends yet.
  initial,

  /// The first pages are in flight and there are no tiles yet.
  loading,

  /// [ExploreMediaState.tiles] is what the first pages found (possibly none).
  ready,

  /// Every first page failed. [ExploreMediaState.error] says why.
  failed,

  /// `search`, `media` or `trends` is off for this caller: nothing is asked
  /// again.
  unavailable,
}

@freezed
abstract class ExploreMediaState with _$ExploreMediaState {
  const factory ExploreMediaState({
    @Default(ExploreMediaStatus.initial) ExploreMediaStatus status,
    @Default(<ExploreMediaTile>[]) List<ExploreMediaTile> tiles,

    /// A further page is in flight.
    @Default(false) bool loadingMore,

    /// Some hashtag still has a next page token.
    @Default(false) bool hasMore,

    /// The last page request failed (the tiles stay); [error] says why.
    @Default(false) bool pagingFailed,
    Object? error,
  }) = _ExploreMediaState;
}
