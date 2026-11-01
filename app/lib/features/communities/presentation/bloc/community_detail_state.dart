import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;

enum CommunityDetailStatus {
  /// `GetCommunity` in flight, nothing to show yet.
  loading,

  /// [CommunityDetailState.community] is known.
  ready,

  /// NOT_FOUND: missing, suspended or hidden (one text for every cause).
  unavailable,

  /// Another failure with nothing to show (offline, quota, not served yet).
  error,
}

@immutable
class CommunityDetailState {
  const CommunityDetailState({
    this.status = CommunityDetailStatus.loading,
    this.community,
    this.rules = const [],
    this.owner,
    this.moderators = const [],
    this.error,
    this.joinBusy = false,
    this.joinedOptimistically = false,
    this.leftOptimistically = false,
    this.bannedByRefusal = false,
    this.pinned = false,
    this.pinFull = false,
    this.pinWriteUnavailable = false,
    this.pinBusy = false,
  });

  final CommunityDetailStatus status;

  /// The header, with the caller's server-given `viewer_role`.
  final pb.Community? community;
  final List<pb.CommunityRule> rules;
  final graph.UserListItem? owner;
  final List<graph.UserListItem> moderators;
  final AppException? error;

  /// A Join or Leave is in flight.
  final bool joinBusy;

  /// The Join is in flight: the header already reads "Joined" (optimistic).
  final bool joinedOptimistically;

  /// The Leave is in flight: the header already reads "Join" (optimistic).
  final bool leftOptimistically;

  /// A Join was refused as banned although the header said otherwise (the ban
  /// landed after the page loaded).
  final bool bannedByRefusal;

  /// From `HomeTabsRepository`, so an optimistic pin shows at once.
  final bool pinned;
  final bool pinFull;
  final bool pinWriteUnavailable;
  final bool pinBusy;

  CommunityDetailState copyWith({
    CommunityDetailStatus? status,
    pb.Community? community,
    List<pb.CommunityRule>? rules,
    graph.UserListItem? owner,
    List<graph.UserListItem>? moderators,
    AppException? error,
    bool clearError = false,
    bool? joinBusy,
    bool? joinedOptimistically,
    bool? leftOptimistically,
    bool? bannedByRefusal,
    bool? pinned,
    bool? pinFull,
    bool? pinWriteUnavailable,
    bool? pinBusy,
  }) => CommunityDetailState(
    status: status ?? this.status,
    community: community ?? this.community,
    rules: rules ?? this.rules,
    owner: owner ?? this.owner,
    moderators: moderators ?? this.moderators,
    error: clearError ? null : (error ?? this.error),
    joinBusy: joinBusy ?? this.joinBusy,
    joinedOptimistically: joinedOptimistically ?? this.joinedOptimistically,
    leftOptimistically: leftOptimistically ?? this.leftOptimistically,
    bannedByRefusal: bannedByRefusal ?? this.bannedByRefusal,
    pinned: pinned ?? this.pinned,
    pinFull: pinFull ?? this.pinFull,
    pinWriteUnavailable: pinWriteUnavailable ?? this.pinWriteUnavailable,
    pinBusy: pinBusy ?? this.pinBusy,
  );
}
