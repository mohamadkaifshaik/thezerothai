import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as posts_pb;
import '../../data/messaging_repository.dart';
import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/messaging_feature_flag.dart';
import '../e2ee/encryption_error_messages.dart';
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
    this.problem = SendProblem.none,
  });

  final common.AuthorSnapshot peer;

  /// This person's idempotency key, made once for the share action and reused
  /// when the row is retried (a retry returns the stored message).
  final String key;
  final ShareRowStatus status;
  final AppException? error;

  /// The port's reason when it refused this send with no typed [error]
  /// (the text drawn is then `composerRefusalText(problem, null)`).
  final SendProblem problem;

  ShareRecipient withStatus(
    ShareRowStatus status, {
    AppException? error,
    SendProblem problem = SendProblem.none,
  }) => ShareRecipient(
    peer: peer,
    key: key,
    status: status,
    error: error,
    problem: problem,
  );
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

  /// The port's refusal reason of the row [lastError] comes from (none when
  /// the share ended or the error is typed).
  SendProblem get lastProblem {
    if (endedBy != null) return SendProblem.none;
    for (final r in recipients.reversed) {
      if (r.status == ShareRowStatus.failed) return r.problem;
    }
    return SendProblem.none;
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

/// Fetches a post under the caller's own rules (PostsRepository.getPost).
typedef SharedPostLookup = Future<posts_pb.PostView> Function(String postId);

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
    EncryptedMessaging? encrypted,
    SharedPostLookup? getPost,
    this.onUnexpectedError,
    Uuid? uuid,
  }) : _repository = repository,
       _encrypted = encrypted,
       _getPost = getPost,
       _isEnabled = isEnabled ?? (() => true),
       _uuid = uuid ?? const Uuid(),
       super(const SharePostState());

  final MessagingRepository _repository;

  /// The encrypted port, tried first for each person; null: today's path.
  final EncryptedMessaging? _encrypted;

  /// Asks the server for the shared post before an encrypted share (the
  /// server cannot see the post id inside the ciphertext); see [_refusal].
  final SharedPostLookup? _getPost;
  bool _checking = false;
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
    if (caption.isEmpty) return url;
    // A link-only share has no card to carry the link: it stays in the text.
    return postId.isEmpty ? '$caption $url' : caption;
  }

  /// Sends to every row that is not sent yet, in order. Pressed again after a
  /// failure it retries the failed and the skipped rows with their own keys.
  Future<void> send() async {
    if (isClosed || _checking || !state.canSend) return;
    emit(state.copyWith(started: true, endedBy: null));
    final body = text;
    final ids = [
      for (final r in state.recipients)
        if (r.status != ShareRowStatus.sent) r.peer.userId,
    ];
    if (_encrypted != null && postId.isNotEmpty && _isEnabled()) {
      // The server cannot check an encrypted share, so it is asked once for
      // the post, in the existing sending state, before any send.
      final before = state.recipients;
      _checking = true;
      for (final id in ids) {
        _setRow(id, ShareRowStatus.sending);
      }
      AppException? refusal;
      try {
        refusal = await _refusal();
      } finally {
        _checking = false;
      }
      if (isClosed) return;
      if (refusal != null) {
        for (final id in ids) {
          _setRow(id, ShareRowStatus.failed, error: refusal);
        }
        return;
      }
      emit(state.copyWith(recipients: before));
    }
    for (var i = 0; i < ids.length; i++) {
      if (isClosed) return;
      final id = ids[i];
      if (!_isEnabled()) {
        _endShare(
          ids.sublist(i),
          FeatureDisabledException(
            'This feature is not available.',
            feature: postId.isEmpty ? kFeatureMessaging : kFeatureDmPostShare,
          ),
        );
        return;
      }
      _setRow(id, ShareRowStatus.sending);
      try {
        final row = _row(id);
        final port = _encrypted;
        // With a port the person is addressed only from the snapshot the
        // row was chosen from (R1). The port is tried first.
        SendOutcome? outcome;
        if (port != null) {
          try {
            outcome = await port.send(
              to: ThreadRef.recipientOf(row.peer),
              localId: row.key,
              text: body,
              sharedPostId: postId,
            );
          } on Object catch (_, stack) {
            // Never the thrown object: it may carry the caption.
            onUnexpectedError?.call(StateError('send'), stack);
            _setRow(
              id,
              ShareRowStatus.failed,
              error: const UnknownApiException('Something went wrong.'),
            );
            continue;
          }
        }
        switch (outcome?.kind) {
          case SendOutcomeKind.queued:
            _setRow(id, ShareRowStatus.sent);
            continue;
          case SendOutcomeKind.refused:
            final error =
                outcome!.error ??
                UnknownApiException(composerRefusalText(outcome.problem, null));
            _setRow(
              id,
              ShareRowStatus.failed,
              error: error,
              problem: outcome.error == null
                  ? outcome.problem
                  : SendProblem.none,
            );
            if (sharePostErrorEndsShare(error)) {
              _endShare(ids.sublist(i + 1), error);
              return;
            }
            continue;
          case SendOutcomeKind.notEncrypted || null:
            break;
        }
        await _repository.sendMessage(
          idempotencyKey: row.key,
          text: body,
          recipientUserId: id,
          // A link-only share (a plan) names no post.
          sharedPostId: postId.isEmpty ? null : postId,
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

  /// The error that refuses the whole share, or null when the post may go.
  /// Fails closed: a protected author's post (the original's, for a REPOST)
  /// goes only from its author; anything unknown refuses. Nothing about the
  /// post is logged or reported (a fixed StateError at most).
  Future<AppException?> _refusal() async {
    const protected = ProtectedAccountException();
    final lookup = _getPost;
    if (lookup == null) return protected;
    try {
      var judged = (await lookup(postId)).post;
      if (judged.kind == posts_pb.PostKind.POST_KIND_REPOST) {
        // The embed names the original and its author but not its
        // visibility, so the original is fetched once more.
        final originalId = judged.embedded.postId;
        if (originalId.isEmpty) return protected;
        judged = (await lookup(originalId)).post;
        if (judged.kind == posts_pb.PostKind.POST_KIND_REPOST) return protected;
      }
      if (judged.visibility == posts_pb.Visibility.VISIBILITY_FOLLOWERS) {
        final own = ownUserId;
        if (own == null || own.isEmpty || judged.author.userId != own) {
          return protected;
        }
      }
      return null;
    } on AppException catch (error) {
      return switch (error) {
        NotFoundException() ||
        ProtectedAccountException() ||
        ValidationException() ||
        FeatureDisabledException() => error,
        _ => protected,
      };
    } on Object catch (_, stack) {
      onUnexpectedError?.call(StateError('sharedPost'), stack);
      return protected;
    }
  }

  ShareRecipient _row(String userId) =>
      state.recipients.firstWhere((r) => r.peer.userId == userId);

  void _setRow(
    String userId,
    ShareRowStatus status, {
    AppException? error,
    SendProblem problem = SendProblem.none,
  }) {
    if (isClosed) return;
    emit(
      state.copyWith(
        recipients: [
          for (final r in state.recipients)
            if (r.peer.userId == userId)
              r.withStatus(status, error: error, problem: problem)
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
