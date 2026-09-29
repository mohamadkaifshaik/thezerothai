import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;

part 'user_list_state.freezed.dart';

enum UserListStatus { loading, ready, loadingMore, error, rateLimited }

/// One page-at-a-time list of `UserListItem`s — shared by followers,
/// following, blocked and muted accounts (they all page the same way).
@freezed
abstract class UserListState with _$UserListState {
  const factory UserListState({
    @Default(UserListStatus.loading) UserListStatus status,
    @Default(<graph.UserListItem>[]) List<graph.UserListItem> items,
    @Default('') String nextPageToken,
    AppException? error,
  }) = _UserListState;

  const UserListState._();

  bool get hasMore => nextPageToken.isNotEmpty;
}
