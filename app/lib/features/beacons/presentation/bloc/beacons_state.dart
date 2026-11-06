import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;

/// [loading] nothing to show yet (skeleton), [ready] rows or the empty state,
/// [error] the call failed and there is nothing to show.
enum BeaconsLoad { loading, ready, error }

/// One audience chip of `/plans`: the public audience (`id` empty) or one of
/// the caller's joined communities. Equal by [id].
@immutable
class BeaconsAudience {
  const BeaconsAudience.public() : id = '', name = 'Public';
  const BeaconsAudience.community(this.id, this.name);

  final String id;
  final String name;
  bool get isPublic => id.isEmpty;

  @override
  bool operator ==(Object other) => other is BeaconsAudience && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'BeaconsAudience($id, $name)';
}

/// The `/plans` screen: the selected audience's upcoming plans, one page at a
/// time (R30).
@immutable
class BeaconsState {
  const BeaconsState({
    this.status = BeaconsLoad.loading,
    this.views = const [],
    this.nextPageToken = '',
    this.loadingMore = false,
    this.error,
    this.audiences = const [BeaconsAudience.public()],
    this.selected = const BeaconsAudience.public(),
  });

  final BeaconsLoad status;
  final List<pb.BeaconView> views;
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;

  /// A further page is in flight ("Load more" shows a spinner).
  final bool loadingMore;

  /// The failure of the last load (first page or a further one).
  final AppException? error;

  /// Public first, then the caller's joined communities.
  final List<BeaconsAudience> audiences;
  final BeaconsAudience selected;

  BeaconsState copyWith({
    BeaconsLoad? status,
    List<pb.BeaconView>? views,
    String? nextPageToken,
    bool? loadingMore,
    AppException? error,
    bool clearError = false,
    List<BeaconsAudience>? audiences,
    BeaconsAudience? selected,
  }) => BeaconsState(
    status: status ?? this.status,
    views: views ?? this.views,
    nextPageToken: nextPageToken ?? this.nextPageToken,
    loadingMore: loadingMore ?? this.loadingMore,
    error: clearError ? null : (error ?? this.error),
    audiences: audiences ?? this.audiences,
    selected: selected ?? this.selected,
  );
}
