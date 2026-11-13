import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;

enum BeaconDetailStatus { loading, ready, error }

/// One of the detail's writes, while it is in flight.
enum BeaconAction { cancel, request, withdraw, leave }

/// The `/plans/:id` screen: the server's view of one plan and the actions the
/// viewer may take on it (R32, R35, R37).
@immutable
class BeaconDetailState {
  const BeaconDetailState({
    this.status = BeaconDetailStatus.loading,
    this.view,
    this.error,
    this.busy,
    this.actionError,
    this.noteRequired = false,
  });

  final BeaconDetailStatus status;

  /// The server's view; its status and viewer flags are never derived here.
  final pb.BeaconView? view;

  /// The failure of the load (nothing to show).
  final AppException? error;

  /// The action in flight, if any (its button shows a spinner).
  final BeaconAction? busy;

  /// A Cancel is in flight.
  bool get cancelBusy => busy == BeaconAction.cancel;

  /// Friendly text of the last failed action, for a snackbar.
  final String? actionError;

  /// The last request was refused with `note_required`: the screen opens the
  /// note sheet (no [actionError] is set for it).
  final bool noteRequired;

  BeaconDetailState copyWith({
    BeaconDetailStatus? status,
    pb.BeaconView? view,
    AppException? error,
    bool clearError = false,
    BeaconAction? busy,
    bool clearBusy = false,
    String? actionError,
    bool clearActionError = false,
    bool? noteRequired,
  }) => BeaconDetailState(
    status: status ?? this.status,
    view: view ?? this.view,
    error: clearError ? null : (error ?? this.error),
    busy: clearBusy ? null : (busy ?? this.busy),
    actionError: clearActionError ? null : (actionError ?? this.actionError),
    noteRequired: noteRequired ?? this.noteRequired,
  );
}
