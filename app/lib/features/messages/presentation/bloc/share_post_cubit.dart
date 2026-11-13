import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../data/messaging_repository.dart';
import '../../domain/messaging_feature_flag.dart';
import '../share_post_error_messages.dart';

/// Where one recipient of a share stands.
enum ShareRowStatus {
  /// Chosen, nothing sent yet.
  idle,

  /// The send to this person is in flight.
  sending,

  /// Sent (also a replay of an earlier send with the same key).
  sent,

  /// The server refused this send; see [ShareRecipient.error].
  failed,

  /// Not tried because an earlier answer ended the whole share.
  skipped,
}

/// One chosen person and the outcome of the send to them.
@immutable
class ShareRecipient {
  const ShareRecipient({
    required this.peer,
    required this.key,
    this.status = ShareRowStatus.idle,
    this.error,
  });

  final common.AuthorSnapshot peer;

  /// This person's idempotency key, made once for the share action and reused
  /// when the row is retried (a retry returns the stored message).
  final String key;
  final ShareRowStatus status;
  final AppException? error;

  ShareRecipient withStatus(ShareRowStatus status, {AppException? error}) =>
      ShareRecipient(peer: peer, key: key, status: status, error: error);
}

@immutable
class SharePostState {
  const SharePostState({
    this.recipients = const [],
    this.caption = '',
    this.limitHit = false,
    this.started = false,
    this.endedBy,
  });

  /// In the order they were chosen, which is the order they are sent.
  final List<ShareRecipient> recipients;
  final String caption;

  /// The user tried a sixth person; shown as a hint until the next change.
  final bool limitHit;

  /// Send was pressed: the rows are locked and show their results.
  final bool started;

  /// The error that ended the whole share (the rest are "Not sent"), or null.
  final AppException? endedBy;

  bool get sending => recipients.any((r) => r.status == ShareRowStatus.sending);

  /// Rows a (re)send would try.
  int get pending => recipients
      .where(
        (r) =>
            r.status == ShareRowStatus.idle ||
            r.status == ShareRowStatus.failed ||
            r.status == ShareRowStatus.skipped,
      )
      .length;

  bool get allSent =>
      recipients.isNotEmpty &&
      recipients.every((r) => r.status == ShareRowStatus.sent);

  bool get canSend => recipients.isNotEmpty && !sending && pending > 0;

  bool isSelected(String userId) =>
      recipients.any((r) => r.peer.userId == userId);

  /// The error to show once under the rows: the one that ended the share, else
  /// the newest failed row's.
  AppException? get lastError {
    if (endedBy != null) return endedBy;
    for (final r in recipients.reversed) {
      if (r.status == ShareRowStatus.failed) return r.error;
    }
    return null;
  }

  SharePostState copyWith({
    List<ShareRecipient>? recipients,
    String? caption,
    bool? started,
    bool limitHit = false,
    Object? endedBy = _keep,
  }) => SharePostState(
    recipients: recipients ?? this.recipients,
    caption: caption ?? this.caption,
    limitHit: limitHit,
    started: started ?? this.started,
    endedBy: identical(endedBy, _keep)
        ? this.endedBy
        : endedBy as AppException?,
  );
}

const Object _keep = Object();

/// Sends one post to up to [kSharePostMaxRecipients] people, one
/// `SendMessage` after another (never in parallel: the per-minute bucket and
/// a result list in order), each with its own idempotency key and its own
/// result row.
///
/// - The server decides everything (blocks, DM policy, requests, caps, the
///   post's visibility); a refusal of one recipient does not stop the rest.
///   An answer that would be the same for everyone (the post is gone or
///   protected, the flag, a rate limit, read-only, no connection) ends the
///   share: the rows after it are marked "Not sent" and can be retried.
/// - The caller's own account cannot be chosen.
/// - [isEnabled] is checked before every send, so a flag that turned off
///   while the picker was open sends nothing.
/// - Nothing here logs or reports the caption.
class SharePostCubit extends Cubit<SharePostState> {
  SharePostCubit({
    required MessagingRepository repository,
    required this.postId,
    required this.url,
    this.ownUserId,
    bool Function()? isEnabled,
    this.onUnexpectedError,
    Uuid? uuid,
  }) : _repository = repository,
       _isEnabled = isEnabled ?? (() => true),
       _uuid = uuid ?? const Uuid(),
       super(const SharePostState());

  final MessagingRepository _repository;
  final bool Function() _isEnabled;
  final Uuid _uuid;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  /// The post to send: the original's id for a REPOST row.
  final String postId;

  /// The canonical link, sent as the text when there is no caption.
  final String url;
  final String? ownUserId;

  /// Chooses or drops [peer]. Ignored for the caller themself and once Send
  /// was pressed; a sixth person only raises [SharePostState.limitHit].
  void toggle(common.AuthorSnapshot peer) {
    if (isClosed || state.started) return;
    if (peer.userId.isEmpty || peer.userId == ownUserId) return;
    final rows = state.recipients;
    if (state.isSelected(peer.userId)) {
      emit(
        state.copyWith(
          recipients: [
            for (final r in rows)
              if (r.peer.userId != peer.userId) r,
          ],
        ),
      );
      return;
    }
    if (rows.length >= kSharePostMaxRecipients) {
      emit(state.copyWith(limitHit: true));
      return;
    }
    emit(
      state.copyWith(
        recipients: [
          ...rows,
          ShareRecipient(peer: peer, key: _uuid.v4()),
        ],
      ),
    );
  }

  void setCaption(String value) {
    if (isClosed || state.started || value == state.caption) return;
    emit(state.copyWith(caption: value));
  }

  /// The text of every send: the caption (one paragraph) or, with none, the
  /// post link, so a client that predates the card still shows a link.
  String get text {
    final caption = state.caption.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
    return caption.isEmpty ? url : caption;
  }

  /// Sends to every row that is not sent yet, in order. Pressed again after a
  /// failure it retries the failed and the skipped rows with their own keys.
  Future<void> send() async {
    if (isClosed || !state.canSend) return;
    emit(state.copyWith(started: true, endedBy: null));
    final body = text;
    final ids = [
      for (final r in state.recipients)
        if (r.status != ShareRowStatus.sent) r.peer.userId,
    ];
    for (var i = 0; i < ids.length; i++) {
      if (isClosed) return;
      final id = ids[i];
      if (!_isEnabled()) {
        _endShare(
          ids.sublist(i),
          const FeatureDisabledException(
            'This feature is not available.',
            feature: kFeatureDmPostShare,
          ),
        );
        return;
      }
      _setRow(id, ShareRowStatus.sending);
      try {
        await _repository.sendMessage(
          idempotencyKey: _row(id).key,
          text: body,
          recipientUserId: id,
          sharedPostId: postId,
        );
        _setRow(id, ShareRowStatus.sent);
      } on AppException catch (error) {
        _setRow(id, ShareRowStatus.failed, error: error);
        if (sharePostErrorEndsShare(error)) {
          _endShare(ids.sublist(i + 1), error);
          return;
        }
      } catch (error, stack) {
        onUnexpectedError?.call(error, stack);
        _setRow(
          id,
          ShareRowStatus.failed,
          error: const UnknownApiException('Something went wrong.'),
        );
      }
    }
  }

  ShareRecipient _row(String userId) =>
      state.recipients.firstWhere((r) => r.peer.userId == userId);

  void _setRow(String userId, ShareRowStatus status, {AppException? error}) {
    if (isClosed) return;
    emit(
      state.copyWith(
        recipients: [
          for (final r in state.recipients)
            if (r.peer.userId == userId)
              r.withStatus(status, error: error)
            else
              r,
        ],
      ),
    );
  }

  /// [error] ended the share: every row of [userIds] that is not sent is
  /// "Not sent" (a failed one keeps its own error).
  void _endShare(List<String> userIds, AppException error) {
    if (isClosed) return;
    emit(
      state.copyWith(
        recipients: [
          for (final r in state.recipients)
            if (userIds.contains(r.peer.userId) &&
                r.status != ShareRowStatus.sent &&
                r.status != ShareRowStatus.failed)
              r.withStatus(ShareRowStatus.skipped)
            else
              r,
        ],
        endedBy: error,
      ),
    );
  }
}
