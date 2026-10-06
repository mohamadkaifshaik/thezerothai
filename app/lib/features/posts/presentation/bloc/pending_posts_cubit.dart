import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;

/// A post the user just sent that the server has not confirmed yet (T16
/// optimistic insert). Lives in memory only: when `CreatePost` succeeds the
/// repository has already put the real post into the cached feeds and the
/// pending entry is dropped; on failure it is dropped too (rollback).
@immutable
class PendingPost {
  const PendingPost({
    required this.localId,
    required this.text,
    required this.author,
    required this.createdAt,
  });

  /// The intent's idempotency key; unique per pending post.
  final String localId;

  /// The normalised text the server will store.
  final String text;

  /// The viewer's own snapshot, so the card renders like a real post.
  final common.AuthorSnapshot author;
  final DateTime createdAt;
}

/// Session-wide list of [PendingPost]s, newest first. Home and the own
/// profile's Posts tab render `PendingPostsSection` above their feed
/// (T17/T18), so an optimistic post shows at the top without touching drift.
class PendingPostsCubit extends Cubit<List<PendingPost>> {
  PendingPostsCubit() : super(const []);

  void add(PendingPost post) {
    emit([post, ...state.where((p) => p.localId != post.localId)]);
  }

  void remove(String localId) {
    if (state.every((p) => p.localId != localId)) return;
    emit([
      for (final p in state)
        if (p.localId != localId) p,
    ]);
  }

  /// Sign-out: nothing of the previous session may linger (CLAUDE.md rule 10).
  void clear() {
    if (state.isNotEmpty) emit(const []);
  }
}
