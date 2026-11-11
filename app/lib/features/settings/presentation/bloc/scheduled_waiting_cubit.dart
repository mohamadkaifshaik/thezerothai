import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../posts/data/posts_repository.dart';

/// How many scheduled posts are waiting (F33), from the first page of
/// `ListScheduledPosts`: PENDING items only (a FAILED one is not waiting).
/// [more]: the page had a next token, so [count] is a lower bound.
@immutable
class ScheduledWaiting {
  const ScheduledWaiting({required this.count, required this.more});

  final int count;
  final bool more;

  /// The Scheduled posts row's subtitle; null (nothing drawn) for none.
  String? get label {
    if (count == 0) return null;
    if (more) return '$count+ posts waiting';
    return count == 1 ? '1 post waiting' : '$count posts waiting';
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduledWaiting && other.count == count && other.more == more;

  @override
  int get hashCode => Object.hash(count, more);
}

/// Loads [ScheduledWaiting] once (one `ListScheduledPosts`, first page).
/// Null while loading or after a failure: the row then has no subtitle, the
/// count is a hint, never an error to show.
class ScheduledWaitingCubit extends Cubit<ScheduledWaiting?> {
  ScheduledWaitingCubit({required PostsRepository repository})
    : _repository = repository,
      super(null);

  final PostsRepository _repository;

  /// The first page's size: the list screen's own page.
  static const pageSize = 20;

  Future<void> load() async {
    try {
      final page = await _repository.listScheduledPosts(pageSize: pageSize);
      if (isClosed) return;
      final pending = page.scheduledPosts
          .where(
            (item) =>
                item.status ==
                pb.ScheduledPostStatus.SCHEDULED_POST_STATUS_PENDING,
          )
          .length;
      emit(
        ScheduledWaiting(count: pending, more: page.nextPageToken.isNotEmpty),
      );
    } on Object {
      // A hint only: no subtitle, no message (the list page shows errors).
    }
  }
}
