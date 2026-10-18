import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../domain/engagement_entry.dart';

/// Which action failed (picks the wording of the snackbar).
enum EngagementAction { like, unlike, repost, undoRepost }

/// One failed action, shown once by the card of [postId] and then cleared.
@immutable
class EngagementFailure {
  const EngagementFailure({
    required this.postId,
    required this.action,
    required this.error,
    required this.serial,
  });

  final String postId;
  final EngagementAction action;
  final AppException error;

  /// Distinguishes two consecutive identical failures.
  final int serial;
}

/// The session's engagement overlay: per target id (the original for a
/// REPOST row), what the caller just did to it. Plain immutable class (no
/// codegen), like `TimelineState`.
@immutable
class EngagementState {
  const EngagementState({this.entries = const {}, this.failure});

  final Map<String, EngagementEntry> entries;
  final EngagementFailure? failure;

  EngagementState copyWith({
    Map<String, EngagementEntry>? entries,
    EngagementFailure? failure,
    bool clearFailure = false,
  }) => EngagementState(
    entries: entries ?? this.entries,
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}
