import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/storage/session_epoch.dart';
import '../../../../core/telemetry/analytics_event.dart';
import '../../../../core/telemetry/usage_reporter.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show ReplyPolicy;
import '../../../media/presentation/bloc/attachments_cubit.dart';
import '../../../media/presentation/media_error_messages.dart';
import '../../data/drafts_repository.dart';
import '../../data/posts_repository.dart';
import '../../domain/composer_draft.dart';
import '../../domain/poll_rules.dart';
import '../../domain/post_intent.dart';
import '../../domain/reply_audience.dart';
import '../post_error_messages.dart';
import 'pending_posts_cubit.dart';

/// Everything a background send needs, snapshotted when the user taps Post
/// (the composer is gone by the time it runs).
@immutable
class PostSendJob {
  const PostSendJob({
    required this.text,
    required this.author,
    required this.policy,
    this.poll,
    this.communityId = '',
    this.beaconId = '',
    this.attachments,
    this.thumbnails = const [],
    this.gif = false,
    this.uid = '',
    this.draftId,
    this.claimKey,
    this.claimReused = false,
    this.claimStartedAt,
  });

  final String text;
  final common.AuthorSnapshot author;
  final ReplyPolicy policy;
  final DraftPoll? poll;
  final String communityId;
  final String beaconId;

  /// The composer's photos; retained here until the send is over.
  final AttachmentsCubit? attachments;
  final List<Uint8List> thumbnails;
  final bool gif;

  /// The unsent-post row holding the text and the claimed key, if any.
  final String uid;
  final String? draftId;
  final String? claimKey;
  final bool claimReused;
  final DateTime? claimStartedAt;
}

class _Entry {
  _Entry(this.localId, this.job, this.generation, this.openedSession)
    : claimKey = job.claimKey;
  final String localId;
  final PostSendJob job;
  final int generation;
  final int openedSession;

  /// The key claimed on the draft row; dropped when a refusal proved it unused.
  String? claimKey;

  /// CreatePost may have reached the server (so its key must be kept).
  bool createAttempted = false;
  bool running = false;
}

/// Sends posts for the whole session after the composer closed: uploads the
/// photos, then CreatePost, while `PendingPostsCubit` shows the status row.
///
/// Retries never double-post: a send keeps ONE idempotency key (the key
/// claimed on its draft row, else one remembered per request body), the
/// uploader reuses finished uploads, and a refusal that proves nothing was
/// created is the only thing that releases a stored key. Nothing starts after
/// the session ended ([reset] / the epoch), and nothing of the previous
/// session lingers.
class PostSender {
  PostSender({
    required PendingPostsCubit pending,
    required PostsRepository repository,
    DraftsRepository? drafts,
    SessionEpoch? sessionEpoch,
    UsageReporter usage = const UsageReporter.none(),
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    Uuid? uuid,
    DateTime Function()? clock,
    this.postedFor = const Duration(seconds: 4),
  }) : _pending = pending,
       _repository = repository,
       _drafts = drafts,
       _session = sessionEpoch ?? SessionEpoch(),
       _usage = usage,
       _onUnexpectedError = onUnexpectedError,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now {
    _sub = _session.ended.listen((_) => reset());
  }

  final PendingPostsCubit _pending;
  final PostsRepository _repository;
  final DraftsRepository? _drafts;
  final SessionEpoch _session;
  final UsageReporter _usage;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// How long the "Posted" confirmation stays.
  final Duration postedFor;

  StreamSubscription<int>? _sub;
  int _generation = 0;
  final Map<String, _Entry> _entries = {};
  final Map<String, Timer> _timers = {};

  /// Idempotency key per request body for sends without a stored key.
  final Map<String, String> _keys = {};
  static const _maxKeys = 8;

  /// Sends currently running (tests wait for [idle]).
  final List<Future<void>> _running = [];

  /// Completes when every started send has stopped (done or failed).
  Future<void> get idle async {
    while (_running.isNotEmpty) {
      await Future.wait(List.of(_running));
    }
  }

  bool _dead(_Entry e) =>
      e.generation != _generation || _session.value != e.openedSession;

  /// Adds the status row and runs the send. Returns when the send stops.
  Future<void> start(PostSendJob job) {
    final entry = _Entry(_uuid.v4(), job, _generation, _session.value);
    _entries[entry.localId] = entry;
    job.attachments?.retain();
    _pending.add(
      PendingPost(
        localId: entry.localId,
        text: job.text,
        author: job.author,
        createdAt: _clock(),
        thumbnails: job.thumbnails,
        photosTotal: job.attachments?.state.count ?? 0,
        uploading: (job.attachments?.state.count ?? 0) > 0,
        draftId: job.draftId,
      ),
    );
    return _run(entry);
  }

  /// Retry of a failed row: same key, finished uploads are not repeated.
  Future<void> retry(String localId) {
    final e = _entries[localId];
    if (e == null || e.running || _dead(e)) return Future.value();
    final p = _pending.state.where((x) => x.localId == localId).firstOrNull;
    if (p == null || p.status != PendingPostStatus.failed || !p.canRetry) {
      return Future.value();
    }
    _pending.update(
      localId,
      (x) => x.copyWith(
        status: PendingPostStatus.sending,
        clearError: true,
        photosDone: 0,
        uploading: (e.job.attachments?.state.count ?? 0) > 0,
      ),
    );
    return _run(e);
  }

  /// The row leaves to be edited (Edit) or dropped (Dismiss). The text stays
  /// in its unsent-post row; photos are not kept. A key that CreatePost never
  /// used is released so the edited post is not seen as "an earlier version".
  /// Returns the draft id to reopen, or null.
  Future<String?> release(String localId) async {
    final e = _entries.remove(localId);
    _timers.remove(localId)?.cancel();
    _pending.remove(localId);
    if (e == null) return null;
    final key = e.claimKey;
    final draftId = e.job.draftId;
    if (key != null && draftId != null && !e.createAttempted) {
      await _clearClaim(e.job.uid, draftId, key);
    }
    unawaited(e.job.attachments?.release());
    return draftId;
  }

  /// Sign-out or account switch: stop everything, forget everything.
  void reset() {
    _generation++;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    final entries = _entries.values.toList();
    _entries.clear();
    _keys.clear();
    _pending.clear();
    for (final e in entries) {
      unawaited(e.job.attachments?.release());
    }
  }

  Future<void> dispose() async {
    reset();
    await _sub?.cancel();
  }

  Future<void> _run(_Entry e) {
    e.running = true;
    final f = _send(e).whenComplete(() => e.running = false);
    _running.add(f);
    return f.whenComplete(() => _running.remove(f));
  }

  Future<void> _send(_Entry e) async {
    final job = e.job;
    final attachments = job.attachments;
    var mediaIds = const <String>[];
    var altTexts = const <String>[];
    if (attachments != null && !attachments.state.isEmpty) {
      var lastDone = -1;
      final sub = attachments.stream.listen((s) {
        if (_dead(e)) return;
        final done = s.items
            .where((a) => a.status == AttachmentStatus.uploaded)
            .length;
        if (done == lastDone) return;
        lastDone = done;
        _pending.update(
          e.localId,
          (p) => p.copyWith(photosDone: done, photosTotal: s.items.length),
        );
      });
      try {
        final uploaded = await attachments.uploadAll(
          stillWanted: () => !_dead(e),
        );
        mediaIds = uploaded.mediaIds;
        altTexts = uploaded.altTexts;
      } on AppException catch (error) {
        if (_dead(e)) return;
        return _fail(
          e,
          uploadErrorMessage(error, gif: job.gif),
          canRetry: error is! ValidationException,
        );
      } catch (error, stack) {
        _onUnexpectedError?.call(error, stack);
        if (_dead(e)) return;
        return _fail(e, 'Something went wrong. Try again.');
      } finally {
        await sub.cancel();
      }
    }
    if (_dead(e)) return;

    final intent = postIntentKey(
      text: job.text,
      mediaIds: mediaIds,
      altTexts: altTexts,
      policy: job.policy,
      poll: job.poll,
      communityId: job.communityId,
      beaconId: job.beaconId,
    );
    final stored = e.claimKey;
    if (stored != null &&
        job.claimReused &&
        sendKeyExpired(
          kind: SendKind.post,
          startedAt: job.claimStartedAt,
          publishAt: null,
          now: _clock(),
        )) {
      return _fail(
        e,
        'We cannot tell whether this post was sent. Edit it to send again.',
        canRetry: false,
      );
    }
    final key = stored ?? _keyFor(intent);
    _pending.update(
      e.localId,
      (p) => p.copyWith(uploading: false, photosDone: p.photosTotal),
    );
    // No await between this check and the call: the repository reads the
    // session as createPost starts.
    if (_dead(e)) return;
    e.createAttempted = true;
    try {
      final poll = job.poll;
      final created = await _repository.createPost(
        idempotencyKey: key,
        text: job.text,
        mediaIds: mediaIds,
        mediaAltTexts: altTexts,
        replyPolicy: job.policy,
        poll: poll == null
            ? null
            : DraftPoll(
                choices: analyzePoll(poll).stored,
                durationMinutes: poll.durationMinutes,
              ),
        communityId: job.communityId,
        beaconId: job.beaconId,
      );
      _usage.log(
        PostCreated(
          kind: PostKind.post,
          media: mediaIds.isEmpty
              ? PostMedia.none
              : job.gif
              ? PostMedia.gif
              : PostMedia.photo,
          poll: poll != null,
          scheduled: false,
        ),
      );
      _keys.remove(intent);
      // The post exists even if the session ended meanwhile; only the row
      // bookkeeping stops then.
      final draftId = job.draftId;
      if (draftId != null && _drafts != null) {
        unawaited(
          _drafts
              .delete(job.uid, [draftId])
              .then(
                (_) {},
                onError: (Object _, StackTrace stack) => _onUnexpectedError
                    ?.call(StateError('Drafts storage failed.'), stack),
              ),
        );
      }
      unawaited(job.attachments?.release());
      if (_dead(e)) return;
      _entries.remove(e.localId);
      final notice = _notice(
        policy: job.policy,
        poll: poll,
        communityId: job.communityId,
        created: created,
      );
      _pending.update(
        e.localId,
        (p) => p.copyWith(
          status: PendingPostStatus.posted,
          uploading: false,
          notice: notice,
        ),
      );
      _timers[e.localId] = Timer(postedFor, () {
        _timers.remove(e.localId);
        _pending.remove(e.localId);
      });
    } on AppException catch (error) {
      if (_dead(e)) return;
      await _failCreate(e, error);
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      if (_dead(e)) return;
      await _failCreate(e, const UnknownApiException('Something went wrong.'));
    }
  }

  String? _notice({
    required ReplyPolicy policy,
    required DraftPoll? poll,
    required String communityId,
    required pb.PostView created,
  }) {
    final post = created.post;
    if (poll != null && !post.hasPoll()) return kPollNotAddedMessage;
    if (communityId.isNotEmpty && !post.hasCommunity()) {
      return kCommunityNotAddedText;
    }
    if (communityId.isEmpty && !replyPoliciesMatch(policy, post.replyPolicy)) {
      return kReplyPolicyNotAppliedMessage;
    }
    return null;
  }

  Future<void> _failCreate(_Entry e, AppException error) async {
    if (error is IdempotencyKeyReusedException) {
      return _fail(
        e,
        'An earlier version of this post was already sent. Edit it to post '
        'this version too.',
        canRetry: false,
      );
    }
    // Only a FRESH key whose first use was refused proves nothing was created
    // (a reused key may have landed earlier; quota answers and
    // MEDIA_NOT_READY are ambiguous).
    final proves =
        error is ValidationException ||
        error is FeatureDisabledException ||
        error is EmailNotVerifiedException;
    final key = e.claimKey;
    if (key != null && !e.job.claimReused && proves) {
      e.claimKey = null;
      e.createAttempted = false;
      final draftId = e.job.draftId;
      if (draftId != null) await _clearClaim(e.job.uid, draftId, key);
    }
    if (_dead(e)) return;
    _fail(e, createPostErrorMessage(error), canRetry: !proves);
  }

  void _fail(_Entry e, String message, {bool canRetry = true}) {
    if (_dead(e)) return;
    _pending.update(
      e.localId,
      (p) => p.copyWith(
        status: PendingPostStatus.failed,
        error: message,
        canRetry: canRetry,
        uploading: false,
      ),
    );
  }

  String _keyFor(String intent) {
    final key = _keys.remove(intent) ?? _uuid.v4();
    _keys[intent] = key;
    while (_keys.length > _maxKeys) {
      _keys.remove(_keys.keys.first);
    }
    return key;
  }

  Future<void> _clearClaim(String uid, String draftId, String key) async {
    final repo = _drafts;
    if (repo == null) return;
    try {
      await repo.clearSend(uid, draftId, key);
    } catch (_, stack) {
      _onUnexpectedError?.call(StateError('Drafts storage failed.'), stack);
    }
  }
}
