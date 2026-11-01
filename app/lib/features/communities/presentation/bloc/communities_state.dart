import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;

/// [loading] nothing to show yet (skeleton), [ready] rows or the empty state,
/// [error] the call failed and there is nothing to show.
enum CommunitiesLoad { loading, ready, error }

/// The `/communities` screen (W5-31). My Communities and the directory load
/// and fail independently: the directory RPC (ListCommunities) may be missing
/// on the deployed server while ListMyCommunities works, and the reverse.
@immutable
class CommunitiesState {
  const CommunitiesState({
    this.mineStatus = CommunitiesLoad.loading,
    this.mine = const [],
    this.canCreate = false,
    this.mineError,
    this.directoryStatus = CommunitiesLoad.loading,
    this.directory = const [],
    this.directoryError,
    this.joining = const {},
    this.banned = const {},
  });

  final CommunitiesLoad mineStatus;
  final List<pb.Community> mine;

  /// The server's `can_create`. False until ListMyCommunities answered (and
  /// after it failed): the Create entry fails closed.
  final bool canCreate;
  final AppException? mineError;

  final CommunitiesLoad directoryStatus;
  final List<pb.Community> directory;
  final AppException? directoryError;

  /// Join in flight: the row already shows "Joined" (optimistic).
  final Set<String> joining;

  /// A Join the server refused as banned: the row says so.
  final Set<String> banned;

  CommunitiesState copyWith({
    CommunitiesLoad? mineStatus,
    List<pb.Community>? mine,
    bool? canCreate,
    AppException? mineError,
    bool clearMineError = false,
    CommunitiesLoad? directoryStatus,
    List<pb.Community>? directory,
    AppException? directoryError,
    bool clearDirectoryError = false,
    Set<String>? joining,
    Set<String>? banned,
  }) => CommunitiesState(
    mineStatus: mineStatus ?? this.mineStatus,
    mine: mine ?? this.mine,
    canCreate: canCreate ?? this.canCreate,
    mineError: clearMineError ? null : (mineError ?? this.mineError),
    directoryStatus: directoryStatus ?? this.directoryStatus,
    directory: directory ?? this.directory,
    directoryError: clearDirectoryError
        ? null
        : (directoryError ?? this.directoryError),
    joining: joining ?? this.joining,
    banned: banned ?? this.banned,
  );
}
