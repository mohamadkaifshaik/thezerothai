import 'package:flutter/foundation.dart';

import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;

enum ListDetailStatus {
  /// No header yet (the list timeline's answer or one `GetList` brings it).
  loading,

  /// [ListDetailState.header] is known.
  ready,

  /// NOT_FOUND from either RPC: private, deleted, hidden, blocked.
  unavailable,
}

@immutable
class ListDetailState {
  const ListDetailState({
    this.status = ListDetailStatus.loading,
    this.header,
    this.headerFailed = false,
    this.pinned = false,
    this.pinFull = false,
    this.pinWriteUnavailable = false,
    this.pinBusy = false,
  });

  final ListDetailStatus status;
  final pb.ListInfo? header;

  /// The one fallback `GetList` failed (not NOT_FOUND): offer Retry.
  final bool headerFailed;

  /// From `HomeTabsRepository`, not from `ListInfo.pinned_by_viewer`, so an
  /// optimistic pin shows at once.
  final bool pinned;
  final bool pinFull;
  final bool pinWriteUnavailable;
  final bool pinBusy;

  ListDetailState copyWith({
    ListDetailStatus? status,
    pb.ListInfo? header,
    bool? headerFailed,
    bool? pinned,
    bool? pinFull,
    bool? pinWriteUnavailable,
    bool? pinBusy,
  }) => ListDetailState(
    status: status ?? this.status,
    header: header ?? this.header,
    headerFailed: headerFailed ?? this.headerFailed,
    pinned: pinned ?? this.pinned,
    pinFull: pinFull ?? this.pinFull,
    pinWriteUnavailable: pinWriteUnavailable ?? this.pinWriteUnavailable,
    pinBusy: pinBusy ?? this.pinBusy,
  );
}
