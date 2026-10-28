import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../data/messaging_repository.dart';

/// Opens the conversation with [peer] (W7-17): `/messages/<id>` when the
/// cache holds a conversation with that person (never a second one), else the
/// draft thread, whose first send names the recipient and then switches to
/// the conversation the server returns. Reads the cache only; no request.
///
/// [replace] swaps the current page (the picker) instead of stacking on it.
/// Used by the new-message picker and the profile's Message button.
Future<void> openConversationWith(
  BuildContext context,
  common.AuthorSnapshot peer, {
  bool replace = false,
}) async {
  final repository = context.read<MessagingRepository>();
  final router = GoRouter.of(context);
  String? existing;
  try {
    existing = (await repository.cachedConversationWith(peer.userId))?.id;
  } on Object {
    // A broken disk must not stop the user: a draft is always possible.
  }
  final String location = existing == null
      ? AppRouter.messageDraftPath
      : AppRouter.messagePath(existing);
  final Object? extra = existing == null ? peer : null;
  if (replace) {
    await router.pushReplacement<void>(location, extra: extra);
  } else {
    await router.push<void>(location, extra: extra);
  }
}
