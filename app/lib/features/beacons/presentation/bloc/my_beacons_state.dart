import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'beacons_state.dart' show BeaconsLoad;

/// The `/plans/mine` screen: the caller's plans of one window and role, a
/// page at a time (R39).
@immutable
class MyBeaconsState {
  const MyBeaconsState({
    this.status = BeaconsLoad.loading,
    this.views = const [],
    this.nextPageToken = '',
    this.loadingMore = false,
    this.error,
    this.window = pb.MyBeaconsWindow.MY_BEACONS_WINDOW_UPCOMING,
    this.role = pb.MyBeaconsRole.MY_BEACONS_ROLE_ALL,
  });

  final BeaconsLoad status;
  final List<pb.BeaconView> views;
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;
  final bool loadingMore;
  final AppException? error;
  final pb.MyBeaconsWindow window;
  final pb.MyBeaconsRole role;

  MyBeaconsState copyWith({
    BeaconsLoad? status,
    List<pb.BeaconView>? views,
    String? nextPageToken,
    bool? loadingMore,
    AppException? error,
    bool clearError = false,
    pb.MyBeaconsWindow? window,
    pb.MyBeaconsRole? role,
  }) => MyBeaconsState(
    status: status ?? this.status,
    views: views ?? this.views,
    nextPageToken: nextPageToken ?? this.nextPageToken,
    loadingMore: loadingMore ?? this.loadingMore,
    error: clearError ? null : (error ?? this.error),
    window: window ?? this.window,
    role: role ?? this.role,
  );
}
