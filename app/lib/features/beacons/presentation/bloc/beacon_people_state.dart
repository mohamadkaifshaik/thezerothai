import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;

enum PeopleLoad { loading, ready, error }

/// One tab of `/plans/:id/people`: the rows of one participant filter, a page
/// at a time, and the organiser's action in flight (R38).
@immutable
class BeaconPeopleState {
  const BeaconPeopleState({
    this.status = PeopleLoad.loading,
    this.rows = const [],
    this.nextPageToken = '',
    this.loadingMore = false,
    this.error,
    this.busyUserId,
    this.actionError,
    this.retryBlockUserId,
    this.pendingBlocks = const {},
  });

  final PeopleLoad status;
  final List<pb.Participant> rows;
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;
  final bool loadingMore;

  /// The failure of the last load (first page or a further one).
  final AppException? error;

  /// The user an accept, decline, block or remove is running for.
  final String? busyUserId;

  /// Friendly text of the last failed action, for a snackbar.
  final String? actionError;

  /// Set with [actionError] when a decline went through but the block after
  /// it failed: the user a "Retry block" action would block.
  final String? retryBlockUserId;

  /// Declined users whose block has not gone through yet (user id to
  /// handle). Stays until the block succeeds, so a retry is always reachable.
  final Map<String, String> pendingBlocks;

  BeaconPeopleState copyWith({
    PeopleLoad? status,
    List<pb.Participant>? rows,
    String? nextPageToken,
    bool? loadingMore,
    AppException? error,
    bool clearError = false,
    String? busyUserId,
    bool clearBusy = false,
    String? actionError,
    bool clearActionError = false,
    String? retryBlockUserId,
    bool clearRetryBlock = false,
    Map<String, String>? pendingBlocks,
  }) => BeaconPeopleState(
    status: status ?? this.status,
    rows: rows ?? this.rows,
    nextPageToken: nextPageToken ?? this.nextPageToken,
    loadingMore: loadingMore ?? this.loadingMore,
    error: clearError ? null : (error ?? this.error),
    busyUserId: clearBusy ? null : (busyUserId ?? this.busyUserId),
    actionError: clearActionError ? null : (actionError ?? this.actionError),
    retryBlockUserId: clearRetryBlock
        ? null
        : (retryBlockUserId ?? this.retryBlockUserId),
    pendingBlocks: pendingBlocks ?? this.pendingBlocks,
  );
}
