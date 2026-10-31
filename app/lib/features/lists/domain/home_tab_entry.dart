import 'package:flutter/foundation.dart';

import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;

/// What a pinned Home tab shows. Only kinds this client knows; an unknown
/// kind from a newer server is hidden (additive proto rule).
enum HomeTabKind {
  list,
  community;

  common.HomeTabKind get wire => switch (this) {
    HomeTabKind.list => common.HomeTabKind.HOME_TAB_KIND_LIST,
    HomeTabKind.community => common.HomeTabKind.HOME_TAB_KIND_COMMUNITY,
  };

  static HomeTabKind? fromWire(common.HomeTabKind kind) => switch (kind) {
    common.HomeTabKind.HOME_TAB_KIND_LIST => HomeTabKind.list,
    common.HomeTabKind.HOME_TAB_KIND_COMMUNITY => HomeTabKind.community,
    _ => null,
  };
}

/// One pinned Home tab after the fixed Following tab (ADR-0030 D6): the
/// descriptor `HomeScreen` feeds to its tab scaffold (W5-14).
///
/// [title] is the server's (empty for another user's list); the label to show
/// is `HomeTabsRepository.labelFor`, which prefers the freshest list header
/// the client holds.
@immutable
class HomeTabEntry {
  const HomeTabEntry({required this.kind, required this.id, this.title = ''});

  final HomeTabKind kind;
  final String id;
  final String title;

  /// Identity of the tab: kind and id (SetHomeTabs rejects duplicates of it).
  String get key => '${kind.name}:$id';

  common.HomeTab toWire() => common.HomeTab(kind: kind.wire, id: id);

  @override
  bool operator ==(Object other) =>
      other is HomeTabEntry &&
      other.kind == kind &&
      other.id == id &&
      other.title == title;

  @override
  int get hashCode => Object.hash(kind, id, title);

  @override
  String toString() => 'HomeTabEntry($key, "$title")';
}
