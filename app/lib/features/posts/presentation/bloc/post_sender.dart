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
import '../../../beacons/domain/beacons_feature_flag.dart';
import '../../../communities/domain/communities_feature_flag.dart';
import '../../../media/presentation/bloc/attachments_cubit.dart';
import '../../../media/presentation/media_error_messages.dart';
import '../../data/drafts_repository.dart';
import '../../data/posts_repository.dart';
import '../../domain/composer_attachment_rules.dart';
import '../../domain/composer_draft.dart';
import '../../domain/poll_rules.dart';
import '../../domain/posts_feature_flag.dart';
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
    this.replyAudience = ReplyAudience.everyone,
    this.poll,
    this.communityId = '',
    this.beaconId = '',
    this.attachments,
    this.thumbnails = const [],
    this.gif = false,
    this.uid = '',
    this.draftId,
    this.deleteDraftId,
    this.claimKey,
    this.claimReused = false,
    this.claimStartedAt,
  });

  final String text;
  final common.AuthorSnapshot author;
  final ReplyPolicy policy;

  /// The audience as the composer chose it (what Edit puts back).
  final ReplyAudience replyAudience;
  final DraftPoll? poll;
  final String communityId;
  final String beaconId;

  /// The composer's photos; retained here until the send is over.
  final AttachmentsCubit? attachments;
  final List<Uint8List> thumbnails;
  final bool gif;

  /// The account that owns the unsent-post row.
  final String uid;

  /// The unsent-post row that holds the text and the claimed key; null when
  /// there is none (Edit then reopens the composer from memory).
  final String? draftId;

  /// The row to delete once the post exists (the composer's draft id, also
  /// when the send holds no key on it).
  final String? deleteDraftId;
  final String? claimKey;
  final bool claimReused;
  final DateTime? claimStartedAt;
}

/// What Edit hands to the composer: the post as it was, with whatever the
/// server refused already taken out (the community, the poll, the plan, the
/// audience, the photos), so it can be sent again.
@immutable
class PostEditSeed {
  const PostEditSeed({
    required this.text,
    this.poll,
    this.replyAudience = ReplyAudience.everyone,
    this.communityId = '',
    this.beaconId = '',
    this.draftId,
    this.attachments,
    this.key,
    this.keyStartedAt,
  });

  /// The idempotency key of a send that may have reached the server, with
  /// the time it was first used: the composer sends under it again (a reused
  /// claim), so an unchanged post replays and a changed one gets the normal
  /// "post this version too" choice instead of a duplicate.
  final String? key;
  final DateTime? keyStartedAt;

  final String text;
  final DraftPoll? poll;
  final ReplyAudience replyAudience;
  final String communityId;
  final String beaconId;

  /// The unsent-post row to continue (same id), when there is one.
  final String? draftId;

  /// The photos, still holding their uploads; the composer takes them over.
  final AttachmentsCubit? attachments;

  /// The seed as a draft for the composer.
  ComposerDraft toDraft(String uid, DateTime now) => ComposerDraft(
    id: draftId ?? DraftsRepository.newId(),
    uid: uid,
    text: text,
    poll: poll,
    replyAudience: replyAudience,
    communityId: communityId,
    createdAt: now,
    updatedAt: now,
  );
}

class _Entry {
  _Entry(this.localId, this.job, this.generation, this.openedSession)
    : held = job.claimKey,
      attachments = job.attachments;
  final String localId;
  final PostSendJob job;
  final int generation;
  final int openedSession;

  /// The key the draft row holds for this send; null once released.
  String? held;

  /// The key of this send, pinned at its first CreatePost so every retry
  /// (and never the bounded key memory) decides it.
  String? key;

  /// CreatePost was called at least once (never reset).
  bool keyUsed = false;

  /// When the key was first used (every used key ages out of the server's
  /// idempotency window, stored or not).
  DateTime? firstUsedAt;

  /// An answer that does not prove nothing was created came back (never
  /// reset): the key may exist on the server and must be kept.
  bool ambiguous = false;

  /// The token of the run that owns the send now; only that run clears it.
  int? activeRun;
  bool get running => activeRun != null;

  /// The photos; null once handed over, dropped or shed.
  AttachmentsCubit? attachments;

  /// Finished uploads kept after the bytes were shed.
  List<String>? mediaIds;
  List<String> altTexts = const [];
  bool photosLost = false;

  // What the server refused: Edit takes it out.
  bool clearCommunity = false;
  bool clearPlan = false;
  bool clearPoll = false;
  bool clearAudience = false;
  bool dropPhotos = false;
}

/// Sends posts for the whole session after the composer closed: uploads the
/// photos, then CreatePost, while `PendingPostsCubit` shows the status row.
///
/// Retries never double-post: a send keeps ONE idempotency key (the key
/// claimed on its draft row, else one pinned on the send at its first
/// CreatePost), the uploader reuses finished uploads, and only an answer that
/// proves nothing was created lets a stored key go. Nothing starts after the
/// session ended ([reset] / the epoch), and nothing of the previous session
/// lingers.
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
    this.maxFailedWithPhotos = 3,
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

  /// Failed rows beyond this many drop their photo bytes (they keep any
  /// finished upload, so Retry still works when every photo was uploaded).
  final int maxFailedWithPhotos;

  StreamSubscription<int>? _sub;
  int _generation = 0;
  final Map<String, _Entry> _entries = {};
  final Map<String, Timer> _timers = {};

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
        needsVerify: false,
        photosDone: 0,
        uploading: (e.attachments?.state.count ?? 0) > 0,
      ),
    );
    return _run(e);
  }

  /// Dismiss: the row leaves, its photos are released. The text stays in its
  /// unsent-post row. A stored key CreatePost never (or only provably
  /// unsuccessfully) used is released, so a later send of that row is not seen
  /// as "an earlier version". Returns the draft id, or null (also while the
  /// send is still running: it cannot be dismissed then).
  Future<String?> release(String localId) async {
    final e = _entries[localId];
    if (e == null || e.running) return null;
    _entries.remove(localId);
    _timers.remove(localId)?.cancel();
    _pending.remove(localId);
    await _releaseHeldKey(e);
    _dropPhotos(e);
    return e.job.draftId;
  }

  /// Edit: the row leaves and the composer reopens from what is returned,
  /// with whatever the server refused taken out. With photos still held they
  /// go to the composer with their uploads. Null while the send is running.
  Future<PostEditSeed?> edit(String localId) async {
    final e = _entries[localId];
    if (e == null || e.running) return null;
    _entries.remove(localId);
    _timers.remove(localId)?.cancel();
    _pending.remove(localId);
    await _releaseHeldKey(e);
    // Signed out while the key was released: nothing goes to the composer.
    if (_dead(e)) {
      _dropPhotos(e);
      return null;
    }
    final photos = e.attachments;
    e.attachments = null;
    AttachmentsCubit? keep;
    if (photos != null) {
      if (e.dropPhotos) {
        unawaited(photos.release());
      } else {
        // Ownership moves to the composer: not retained, not closing.
        photos.reclaim();
        keep = photos;
      }
    }
    final job = e.job;
    return PostEditSeed(
      text: job.text,
      poll: e.clearPoll ? null : job.poll,
      replyAudience: e.clearAudience
          ? ReplyAudience.everyone
          : job.replyAudience,
      communityId: e.clearCommunity ? '' : job.communityId,
      beaconId: e.clearPlan ? '' : job.beaconId,
      draftId: job.draftId,
      attachments: keep,
      // A key that may exist on the server travels with the post.
      key: e.keyUsed && (e.ambiguous || job.claimReused) ? e.key : null,
      keyStartedAt: job.claimStartedAt ?? e.firstUsedAt,
    );
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
    _pending.clear();
    for (final e in entries) {
      _dropPhotos(e);
    }
  }

  Future<void> dispose() async {
    reset();
    await _sub?.cancel();
  }

  /// Releases the entry's photos, once.
  void _dropPhotos(_Entry e) {
    final a = e.attachments;
    e.attachments = null;
    if (a != null) unawaited(a.release());
  }

  Future<void> _releaseHeldKey(_Entry e) async {
    final key = e.held;
    final draftId = e.job.draftId;
    if (key == null || draftId == null) return;
    if (e.job.claimReused || e.ambiguous) return;
    e.held = null;
    await _clearClaim(e.job.uid, draftId, key);
  }

  Future<void> _run(_Entry e) {
    final token = ++_runSeq;
    e.activeRun = token;
    final f = _send(e, token);
    _running.add(f);
    return f.whenComplete(() => _running.remove(f));
  }

  int _runSeq = 0;

  Future<void> _send(_Entry e, int token) async {
    try {
      await _attempt(e);
    } finally {
      if (e.activeRun == token) e.activeRun = null;
    }
  }

  Future<void> _attempt(_Entry e) async {
    final job = e.job;
    final attachments = e.attachments;
    var mediaIds = e.mediaIds ?? const <String>[];
    var altTexts = e.altTexts;
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

    // A stored key past its window may be forgotten by the server: only Edit.
    final usedKey = e.key ?? e.held;
    if (usedKey != null &&
        (job.claimReused || e.keyUsed) &&
        sendKeyExpired(
          kind: SendKind.post,
          startedAt: job.claimStartedAt ?? e.firstUsedAt,
          publishAt: null,
          now: _clock(),
        )) {
      return _fail(
        e,
        'We cannot tell whether this post was sent. Edit it to send again.',
        canRetry: false,
      );
    }
    // The key is decided once and then reused by every retry.
    final key = e.key ??= e.held ?? _uuid.v4();
    _pending.update(
      e.localId,
      (p) => p.copyWith(uploading: false, photosDone: p.photosTotal),
    );
    // No await between this check and the call: the repository reads the
    // session as createPost starts.
    if (_dead(e)) return;
    e.keyUsed = true;
    e.firstUsedAt ??= _clock();
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
      // The post exists even if the session ended meanwhile; only the row
      // bookkeeping stops then.
      final deleteId = job.deleteDraftId ?? job.draftId;
      if (deleteId != null && _drafts != null) {
        unawaited(
          _drafts
              .delete(job.uid, [deleteId])
              .then(
                (_) {},
                onError: (Object _, StackTrace stack) => _onUnexpectedError
                    ?.call(StateError('Drafts storage failed.'), stack),
              ),
        );
      }
      _dropPhotos(e);
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
      _failCreate(e, error);
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      if (_dead(e)) return;
      _failCreate(e, const UnknownApiException('Something went wrong.'));
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

  void _failCreate(_Entry e, AppException error) {
    final job = e.job;
    // Only these answers prove nothing was created; every other one (quota,
    // network, MEDIA_NOT_READY, a community refusal, ...) may hide a post that
    // landed, so the key stays for good.
    final proves =
        error is ValidationException ||
        error is FeatureDisabledException ||
        error is EmailNotVerifiedException;
    if (!proves) e.ambiguous = true;
    if (error is IdempotencyKeyReusedException) {
      return _fail(
        e,
        'An earlier version of this post was already sent. Edit it to post '
        'this version too.',
        canRetry: false,
      );
    }
    if (error is EmailNotVerifiedException) {
      return _fail(e, createPostErrorMessage(error), needsVerify: true);
    }
    // Permanent refusals: Retry would only repeat them. Edit reopens the
    // composer with the field taken out, as the composer did itself.
    final feature = error is FeatureDisabledException ? error.feature : null;
    var permanent = proves;
    // A shed row's uploads are the only copy of its photos: when the server
    // no longer has them, Retry cannot succeed; Edit (text) remains.
    if (error is MediaNotReadyException && e.mediaIds != null) {
      permanent = true;
    }
    if (feature == kFeaturePostBeaconEmbed ||
        (error is NotFoundException && job.beaconId.isNotEmpty)) {
      e.clearPlan = true;
      permanent = true;
    }
    if (feature == kFeaturePolls && job.poll != null) e.clearPoll = true;
    if (feature == kFeatureReplyAudience) e.clearAudience = true;
    if (feature == kFeatureGif || feature == kPostsSubFeatureMedia) {
      e.dropPhotos = true;
    }
    if (job.communityId.isNotEmpty) {
      final gone =
          (error is CommunityForbiddenException &&
              (error.reason == CommunityForbiddenReason.notMember ||
                  error.reason == CommunityForbiddenReason.banned)) ||
          error is CommunityStateException ||
          (error is NotFoundException && job.beaconId.isEmpty);
      final refused =
          feature == kFeatureCommunities || error is ProtectedAccountException;
      if (gone || refused) {
        e.clearCommunity = true;
        permanent = true;
      }
    }
    _fail(
      e,
      createPostErrorMessage(error),
      canRetry: !permanent,
      keepsPhotos: !e.dropPhotos,
    );
  }

  void _fail(
    _Entry e,
    String message, {
    bool canRetry = true,
    bool needsVerify = false,
    bool keepsPhotos = true,
  }) {
    if (_dead(e)) return;
    // Retry works from here on, not only once the send's future completes.
    e.activeRun = null;
    _pending.update(
      e.localId,
      (p) => p.copyWith(
        status: PendingPostStatus.failed,
        error: message,
        canRetry: canRetry && !e.photosLost,
        needsVerify: needsVerify,
        keepsPhotos: keepsPhotos && !e.photosLost,
        uploading: false,
      ),
    );
    _shedOldFailed();
  }

  /// At most [maxFailedWithPhotos] failed rows keep their photo bytes: older
  /// ones keep only their finished uploads (Retry still works when every photo
  /// had been uploaded; otherwise Edit has the text only).
  void _shedOldFailed() {
    final failed = [
      for (final e in _entries.values)
        if (!e.running &&
            e.attachments != null &&
            _pending.state.any(
              (p) =>
                  p.localId == e.localId &&
                  p.status == PendingPostStatus.failed,
            ))
          e,
    ];
    final over = failed.length - maxFailedWithPhotos;
    for (var i = 0; i < over; i++) {
      final e = failed[i];
      final photos = e.attachments!;
      final items = photos.state.items;
      final uploaded =
          items.isNotEmpty &&
          items.every(
            (a) =>
                a.status == AttachmentStatus.uploaded && a.mediaId.isNotEmpty,
          );
      if (uploaded) {
        e.mediaIds = [for (final a in items) a.mediaId];
        final alts = [for (final a in items) a.altText];
        e.altTexts = alts.every((t) => t.isEmpty) ? const [] : alts;
      } else {
        e.photosLost = true;
      }
      _dropPhotos(e);
      _pending.update(
        e.localId,
        (p) => p.copyWith(
          thumbnails: const [],
          keepsPhotos: false,
          canRetry: uploaded && p.canRetry,
        ),
      );
    }
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
