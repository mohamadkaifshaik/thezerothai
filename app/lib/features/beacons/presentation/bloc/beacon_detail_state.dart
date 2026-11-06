import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;

enum BeaconDetailStatus { loading, ready, error }

/// The `/plans/:id` screen: the server's view of one plan and the organiser's
/// Cancel (R32).
@immutable
class BeaconDetailState {
  const BeaconDetailState({
    this.status = BeaconDetailStatus.loading,
    this.view,
    this.error,
    this.cancelBusy = false,
    this.actionError,
  });

  final BeaconDetailStatus status;

  /// The server's view; its status is never derived from the clock here.
  final pb.BeaconView? view;

  /// The failure of the load (nothing to show).
  final AppException? error;

  /// A Cancel is in flight.
  final bool cancelBusy;

  /// Friendly text of the last failed action, for a snackbar.
  final String? actionError;

  BeaconDetailState copyWith({
    BeaconDetailStatus? status,
    pb.BeaconView? view,
    AppException? error,
    bool clearError = false,
    bool? cancelBusy,
    String? actionError,
    bool clearActionError = false,
  }) => BeaconDetailState(
    status: status ?? this.status,
    view: view ?? this.view,
    error: clearError ? null : (error ?? this.error),
    cancelBusy: cancelBusy ?? this.cancelBusy,
    actionError: clearActionError ? null : (actionError ?? this.actionError),
  );
}
