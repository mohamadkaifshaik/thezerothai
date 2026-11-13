import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../data/post_history_repository.dart';
import '../domain/bookmark_history_feature_flag.dart';

final _log = Logger('PostHistory');

/// The callback a post screen calls when a post opens, or null when nothing
/// should be recorded: `bookmark_history` is off for the caller, or no account
/// is signed in. Read once, when the screen's cubit is created.
void Function(String postId)? postOpenRecorder(BuildContext context) {
  if (!isFeatureEnabled(context, kFeatureBookmarkHistory)) return null;
  final uid = context.read<AuthBloc>().state.user?.uid;
  if (uid == null || uid.isEmpty) return null;
  final history = context.read<PostHistoryRepository>();
  return (postId) {
    unawaited(
      history.recordOpen(uid: uid, postId: postId).catchError((Object error) {
        // A history write is a convenience: a failure is logged, never shown.
        _log.warning('could not record an opened post', error);
      }),
    );
  };
}
