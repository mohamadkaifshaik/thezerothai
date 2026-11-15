import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/network/network_type_service.dart';
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
import '../../data/unsent_posts_store.dart';
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
  _Entry(
    this.localId,
    this.job,
    this.generation,
    this.openedSession,
    this.order,
  ) : held = job.claimKey,
      attachments = job.attachments;
  final String localId;
  final PostSendJob job;
  final int generation;
  final int openedSession;

  /// Send order: the queue sends oldest first.
  final int order;

  /// In the queue: waiting for a connection or for the next retry.
  bool waiting = false;

  /// Waiting for its backoff timer (the queue holds behind it).
  bool backingOff = false;
  Timer? backoffTimer;

  /// Network errors in a row since the last manual Retry (indexes the
  /// backoff).
  int netAttempts = 0;

  /// The post has a record in the unsent-posts store (set once the save
  /// worked), or is being saved right now.
  bool saved = false;
  bool saving = false;

  /// Nothing more is written for this post (it was sent, dismissed, edited or
  /// deleted from Settings).
  bool noPersist = false;

  /// Its processed photos are on disk: memory may drop them, and a send or an
  /// Edit loads them again.
  bool onDisk = false;

  /// Brought back after a restart.
  bool restored = false;

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

  /// While the undo window is open: the timer that starts the send, and the
  /// completer of the future `start` returned.
  Timer? holdTimer;
  Completer<void>? hold;

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
    this.maxFailedWithPhotos = kUnsentPostsWithPhotos,
    Duration Function()? undoDelay,
    NetworkTypeService? network,
    UnsentPostsStore? unsent,
    AttachmentsCubit Function()? newAttachments,
  }) : _undoDelay = undoDelay ?? _noDelay,
       _network = network,
       _unsent = unsent,
       _newAttachments = newAttachments,
       _pending = pending,
       _repository = repository,
       _drafts = drafts,
       _session = sessionEpoch ?? SessionEpoch(),
       _usage = usage,
       _onUnexpectedError = onUnexpectedError,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now {
    _sub = _session.ended.listen((_) => reset());
    _netSub = network?.onlineChanges.listen((online) {
      if (!online) return;
      // A connection came back: the queue starts over, in order.
      for (final e in _entries.values) {
        if (e.waiting && !e.backingOff) e.netAttempts = 0;
      }
      _drain();
    });
  }

  /// Without a network service a network error fails the send at once (no
  /// queue, no backoff).
  final NetworkTypeService? _network;

  /// Where unsent posts and their processed photos survive a restart; null:
  /// nothing is kept.
  final UnsentPostsStore? _unsent;

  /// A new photo holder for a restored post.
  final AttachmentsCubit Function()? _newAttachments;

  /// Waits after the 1st, 2nd, 3rd and 4th network error; then Retry is
  /// manual.
  static const List<Duration> backoff = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  final PendingPostsCubit _pending;
  final PostsRepository _repository;
  final DraftsRepository? _drafts;
  final SessionEpoch _session;
  final UsageReporter _usage;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// How long a post waits, after Post, before anything is uploaded or sent
  /// (the Undo send setting; zero: no window). Read when the post starts.
  final Duration Function() _undoDelay;
  static Duration _noDelay() => Duration.zero;

  /// How long the "Posted" confirmation stays.
  final Duration postedFor;

  /// Failed rows beyond this many drop their photo bytes (they keep any
  /// finished upload, so Retry still works when every photo was uploaded).
  final int maxFailedWithPhotos;

  StreamSubscription<int>? _sub;
  StreamSubscription<bool>? _netSub;
  int _seq = 0;
  bool _draining = false;
  Future<void> _storeOps = Future.value();
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
    await _storeOps;
  }

  bool _dead(_Entry e) =>
      e.generation != _generation || _session.value != e.openedSession;

  /// Adds the status row and runs the send. Returns when the send stops.
  Future<void> start(PostSendJob job) {
    final entry = _Entry(_uuid.v4(), job, _generation, _session.value, _seq++);
    final delay = _undoDelay();
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
        status: delay > Duration.zero
            ? PendingPostStatus.holding
            : PendingPostStatus.sending,
        holdSeconds: (delay.inMilliseconds / 1000).ceil(),
      ),
    );
    if (delay <= Duration.zero) return _launch(entry);
    // The undo window: nothing is uploaded or sent until it closes.
    final done = Completer<void>();
    entry.hold = done;
    entry.holdTimer = Timer(delay, () {
      entry.holdTimer = null;
      entry.hold = null;
      if (_dead(entry)) {
        done.complete();
        return;
      }
      _pending.update(
        entry.localId,
        (p) => p.copyWith(status: PendingPostStatus.sending, holdSeconds: 0),
      );
      done.complete(_launch(entry));
    });
    _running.add(done.future);
    return done.future.whenComplete(() => _running.remove(done.future));
  }

  /// Undo during the window: nothing was uploaded or sent, so the key is
  /// released and the composer reopens with everything (the same seed as
  /// Edit). Null when the window is over (or the post is gone).
  Future<PostEditSeed?> undo(String localId) async {
    final e = _entries[localId];
    if (e == null || e.hold == null) return null;
    e.holdTimer?.cancel();
    e.holdTimer = null;
    e.hold!.complete();
    e.hold = null;
    return edit(localId);
  }

  /// Retry of a failed row: same key, finished uploads are not repeated.
  Future<void> retry(String localId) {
    final e = _entries[localId];
    if (e == null || e.running || e.hold != null || _dead(e)) {
      return Future.value();
    }
    final p = _pending.state.where((x) => x.localId == localId).firstOrNull;
    if (p == null || p.status != PendingPostStatus.failed || !p.canRetry) {
      return Future.value();
    }
    e.netAttempts = 0;
    final net = _network;
    if (net == null) {
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
    // Through the queue: after older posts, and only with a connection.
    if (!net.online) {
      _wait(e, connection: true);
    } else if (_queueBusy()) {
      _wait(e, connection: false);
    } else {
      e.waiting = true;
      _drain();
    }
    return Future.value();
  }

  /// Dismiss: the row leaves, its photos are released. The text stays in its
  /// unsent-post row. A stored key CreatePost never (or only provably
  /// unsuccessfully) used is released, so a later send of that row is not seen
  /// as "an earlier version". Returns the draft id, or null (also while the
  /// send is still running: it cannot be dismissed then).
  Future<String?> release(String localId) async {
    final e = _entries[localId];
    if (e == null || e.running || e.hold != null) return null;
    _entries.remove(localId);
    _timers.remove(localId)?.cancel();
    _pending.remove(localId);
    _forget(e);
    await _releaseHeldKey(e);
    _dropPhotos(e);
    return e.job.draftId;
  }

  /// Edit: the row leaves and the composer reopens from what is returned,
  /// with whatever the server refused taken out. With photos still held they
  /// go to the composer with their uploads. Null while the send is running.
  Future<PostEditSeed?> edit(String localId) async {
    final e = _entries[localId];
    if (e == null || e.running || e.hold != null) return null;
    // Photos that live on disk only come back for the composer.
    if (e.onDisk && e.attachments == null && !e.dropPhotos) {
      final loaded = await _loadBytes(e);
      if (_entries[localId] != e || e.running) {
        unawaited(loaded?.close());
        return null;
      }
      e.attachments = loaded;
    }
    _entries.remove(localId);
    _timers.remove(localId)?.cancel();
    _pending.remove(localId);
    _forget(e);
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

  /// Sign-out or account switch: stop everything, forget everything, and
  /// delete every unsent post and photo this device kept (of any account).
  void reset() {
    _stop();
    final store = _unsent;
    if (store != null) _storeOp(store.deleteEverything);
  }

  /// Rows that were waiting or not sent when the app last closed, back as
  /// "Not sent" rows with Retry / Edit. Nothing is sent: the user taps Retry.
  /// Anything stored for another account is deleted first, and rows past the
  /// idempotency window are swept (see [UnsentPostsStore]). Only thumbnails
  /// come back to memory; the photos load when a post is retried or edited.
  Future<void> restore(String uid) async {
    final store = _unsent;
    if (store == null || uid.isEmpty) return;
    final session = _session.value;
    final generation = _generation;
    bool stale() => session != _session.value || generation != _generation;
    final List<UnsentPostRecord> records;
    try {
      await _storeOps;
      // Signed out (or switched) meanwhile: nothing of it comes back, and
      // nothing is purged on behalf of an account that is gone.
      if (stale()) return;
      await store.purgeOthers(uid);
      if (stale()) return;
      records = await store.load(uid);
    } catch (_, stack) {
      _onUnexpectedError?.call(
        StateError('Unsent posts could not be read.'),
        stack,
      );
      return;
    }
    if (stale()) return;
    for (final record in records) {
      if (record.uid != uid || _entries.containsKey(record.postId)) continue;
      _restoreOne(record);
    }
  }

  void _restoreOne(UnsentPostRecord record) {
    final hadPhotos = record.totalPhotos > 0;
    final withPhotos =
        record.photosKept &&
        record.photos.isNotEmpty &&
        _newAttachments != null;
    final lost = hadPhotos && !withPhotos;
    final ids = [for (final p in record.photos) p.mediaId];
    final uploaded = withPhotos && ids.every((id) => id.isNotEmpty);
    final alts = [for (final p in record.photos) p.altText];
    final job = PostSendJob(
      text: record.text,
      author: record.author,
      policy: record.policy,
      replyAudience: record.replyAudience,
      poll: record.poll,
      communityId: record.communityId,
      beaconId: record.beaconId,
      thumbnails: [
        if (withPhotos)
          for (final p in record.photos) p.image.thumbBytes,
      ],
      gif: record.gif,
      uid: record.uid,
      draftId: record.draftId,
      deleteDraftId: record.deleteDraftId,
      claimKey: record.key,
      // A key that was used may exist on the server: it is reused, never
      // replaced, and its 23 hour window keeps running.
      claimReused: record.claimReused || record.keyUsed,
      claimStartedAt: record.keyStartedAt,
    );
    final flags = record.clearFlags;
    final entry =
        _Entry(record.postId, job, _generation, _session.value, _seq++)
          ..key = record.keyUsed ? record.key : null
          ..keyUsed = record.keyUsed
          ..firstUsedAt = record.keyStartedAt
          ..ambiguous = record.ambiguous
          ..photosLost = lost
          ..saved = true
          ..restored = true
          ..onDisk = withPhotos
          ..clearCommunity = flags & kClearCommunity != 0
          ..clearPlan = flags & kClearPlan != 0
          ..clearPoll = flags & kClearPoll != 0
          ..clearAudience = flags & kClearAudience != 0
          ..dropPhotos = flags & kClearPhotos != 0;
    if (uploaded) {
      // Every photo finished uploading before the app closed: Retry sends
      // those uploads, nothing is uploaded again.
      entry
        ..mediaIds = ids
        ..altTexts = alts.every((t) => t.isEmpty) ? const [] : alts;
    }
    _entries[entry.localId] = entry;
    final String copy;
    if (record.keyUsed && record.ambiguous) {
      copy = lost
          ? 'We could not confirm this post was sent. Its photos could not '
                'be kept.'
          : 'We could not confirm this post was sent. Retry to check and '
                'send it.';
    } else if (lost) {
      copy = 'Not sent. Its photos could not be kept.';
    } else {
      copy =
          record.errorText ??
          'Not sent. It was still waiting when the app closed.';
    }
    _pending.add(
      PendingPost(
        localId: entry.localId,
        text: record.text,
        author: record.author,
        createdAt: record.createdAt,
        thumbnails: job.thumbnails,
        photosTotal: record.totalPhotos,
        draftId: record.draftId,
        status: PendingPostStatus.failed,
        error: copy,
        canRetry: record.canRetry && !lost,
        needsVerify: record.needsVerify,
        keepsPhotos: !lost && !entry.dropPhotos,
      ),
    );
  }

  /// Settings' "Delete unsent posts": the rows that wait or failed go (their
  /// photos are released) and every stored post and photo of [uid] is deleted
  /// through the same ordered store queue as every other write. A send in
  /// progress keeps running but is no longer written to the device.
  Future<void> deleteUnsentPosts(String uid) async {
    for (final e in _entries.values.toList()) {
      if (e.job.uid != uid) continue;
      if (e.running || e.hold != null) {
        e.noPersist = true;
        e.saved = false;
        continue;
      }
      final p = _pending.state.where((x) => x.localId == e.localId).firstOrNull;
      if (p == null ||
          (p.status != PendingPostStatus.failed &&
              p.status != PendingPostStatus.waiting)) {
        continue;
      }
      _entries.remove(e.localId);
      _pending.remove(e.localId);
      _forget(e);
      _dropPhotos(e);
    }
    final store = _unsent;
    if (store != null) await _storeOp(() => store.deleteAll(uid));
  }

  void _stop() {
    _generation++;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    final entries = _entries.values.toList();
    _entries.clear();
    _pending.clear();
    for (final e in entries) {
      e.backoffTimer?.cancel();
      e.backoffTimer = null;
      e.holdTimer?.cancel();
      e.holdTimer = null;
      final waiting = e.hold;
      e.hold = null;
      if (waiting != null && !waiting.isCompleted) waiting.complete();
      _dropPhotos(e);
    }
  }

  Future<void> dispose() async {
    // Closing the app is not a sign-out: what is stored stays.
    _stop();
    await _sub?.cancel();
    await _netSub?.cancel();
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
    // A stored key past its window may be forgotten by the server: only Edit.
    // Checked first: nothing is uploaded for a post that cannot be sent.
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
    // Its photos were shed (and never uploaded): sending now would post it
    // without them.
    if (e.photosLost && e.mediaIds == null) {
      return _fail(
        e,
        'Its photos could not be kept. Edit the post to send it again.',
        canRetry: false,
      );
    }
    // Photos that only live on disk come back for this send.
    if (!await _prepareSend(e)) {
      if (_dead(e)) return;
      return _fail(
        e,
        'Its photos could not be loaded. Edit the post to send it again.',
        canRetry: false,
      );
    }
    if (_dead(e)) return;
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
        if ((error is NetworkException ||
                error is UploadInterruptedException) &&
            _waitForNetwork(e)) {
          return;
        }
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

    // The key is decided once and then reused by every retry.
    final key = e.key ??= e.held ?? _uuid.v4();
    _pending.update(
      e.localId,
      (p) => p.copyWith(uploading: false, photosDone: p.photosTotal),
    );
    // Written ahead: a stored post records that CreatePost may be on its way
    // BEFORE the call, so a kill mid-call never loses the key.
    final store = _unsent;
    if (store != null && !e.noPersist && (e.saved || e.saving)) {
      e.firstUsedAt ??= _clock();
      await _storeOp(
        () => store.updateSend(
          job.uid,
          e.localId,
          epoch: e.openedSession,
          key: key,
          keyStartedAt: _earliest(job.claimStartedAt, e.firstUsedAt),
          keyUsed: true,
          ambiguous: true,
          errorText: null,
          canRetry: true,
          needsVerify: false,
          clearFlags: _clearFlagsOf(e),
          mediaIds: _storedMediaIds(e) ?? (mediaIds.isEmpty ? null : mediaIds),
        ),
      );
    }
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
      _unpersist(e);
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
    // No connection, or the server could not be reached: the post waits and
    // goes again under the same key (the backoff; after it, Retry is manual).
    if (error is NetworkException && !_dead(e) && _waitForNetwork(e)) return;
    if (error is IdempotencyKeyReusedException) {
      if (e.restored && e.keyUsed) {
        return _fail(e, 'This post was already sent.', canRetry: false);
      }
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
    _persist(e);
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
                  (p.status == PendingPostStatus.failed ||
                      p.status == PendingPostStatus.waiting),
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

  bool _queueBusy() => _draining || _entries.values.any((x) => x.waiting);

  /// Starts the send, or queues it: offline, or behind an older post that
  /// waits (posts go out in order).
  Future<void> _launch(_Entry e) {
    final net = _network;
    if (net != null && (!net.online || _queueBusy())) {
      _wait(e, connection: !net.online);
      return Future.value();
    }
    return _run(e);
  }

  /// Puts the post in the queue. With a [delay] (backoff) it goes again when
  /// the timer fires; without one, as soon as there is a connection.
  void _wait(_Entry e, {required bool connection, Duration? delay}) {
    e.activeRun = null;
    e.waiting = true;
    e.backoffTimer?.cancel();
    e.backoffTimer = null;
    e.backingOff = delay != null;
    _pending.update(
      e.localId,
      (p) => p.copyWith(
        status: PendingPostStatus.waiting,
        wasQueued: true,
        waitingForConnection: connection,
        uploading: false,
        photosDone: 0,
        clearError: true,
        needsVerify: false,
      ),
    );
    _persist(e);
    _shedOldFailed();
    if (delay == null) {
      _drain();
    } else {
      e.backoffTimer = Timer(delay, () {
        e.backoffTimer = null;
        e.backingOff = false;
        _drain();
      });
    }
  }

  /// A network error: wait for the connection, or for the next backoff step.
  /// False when the backoff is used up (the caller fails the post; Retry is
  /// manual) or there is no network service.
  bool _waitForNetwork(_Entry e) {
    final net = _network;
    if (net == null) return false;
    if (!net.online) {
      _wait(e, connection: true);
      return true;
    }
    if (e.netAttempts < backoff.length) {
      _wait(e, connection: false, delay: backoff[e.netAttempts++]);
      return true;
    }
    e.netAttempts = 0;
    return false;
  }

  _Entry? _head() {
    _Entry? best;
    for (final e in _entries.values) {
      if (!e.waiting || _dead(e)) continue;
      if (best == null || e.order < best.order) best = e;
    }
    return best;
  }

  /// Sends the queued posts one after the other, oldest first, while there
  /// is a connection. Stops at a post that waits for its backoff, so the
  /// order holds.
  void _drain() {
    if (_draining) return;
    final net = _network;
    if (net != null && !net.online) return;
    if (_head() == null) return;
    final f = _drainLoop();
    _running.add(f);
    unawaited(f.whenComplete(() => _running.remove(f)));
  }

  Future<void> _drainLoop() async {
    _draining = true;
    try {
      while (true) {
        final net = _network;
        if (net != null && !net.online) return;
        final head = _head();
        if (head == null || head.backingOff) return;
        head.waiting = false;
        _pending.update(
          head.localId,
          (p) => p.copyWith(
            status: PendingPostStatus.sending,
            clearError: true,
            photosDone: 0,
            uploading: p.photosTotal > 0 && head.mediaIds == null,
          ),
        );
        await _run(head);
      }
    } finally {
      _draining = false;
    }
  }

  /// Serialises the store writes, so a delete never overtakes the save it
  /// follows. The future completes when this write is done (errors are
  /// reported without details and never thrown).
  Future<void> _storeOp(Future<void> Function() op) {
    final next = _storeOps.then((_) => op()).catchError((
      Object _,
      StackTrace stack,
    ) {
      // Without details: a storage error can carry the post's text.
      _onUnexpectedError?.call(
        StateError('Unsent posts storage failed.'),
        stack,
      );
    });
    _storeOps = next;
    return next;
  }

  static DateTime? _earliest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isBefore(b) ? a : b;
  }

  int _clearFlagsOf(_Entry e) =>
      (e.clearCommunity ? kClearCommunity : 0) |
      (e.clearPlan ? kClearPlan : 0) |
      (e.clearPoll ? kClearPoll : 0) |
      (e.clearAudience ? kClearAudience : 0) |
      (e.dropPhotos ? kClearPhotos : 0);

  /// The media ids of the finished uploads, parallel to the stored photos;
  /// null when there is nothing to say (no photos in memory).
  List<String>? _storedMediaIds(_Entry e) {
    final ids = e.mediaIds;
    if (ids != null) return ids;
    final items = e.attachments?.state.items;
    if (items == null) return null;
    return [
      for (final a in items)
        if (a.image != null)
          a.status == AttachmentStatus.uploaded ? a.mediaId : '',
    ];
  }

  /// Keeps the post (text, key, how it ended and the processed photos) on the
  /// device while it waits or has failed. The first call saves it, with the
  /// idempotency key pinned (so a stored post always has one); later calls
  /// refresh what the send knows.
  void _persist(_Entry e) {
    final store = _unsent;
    final job = e.job;
    if (store == null || job.uid.isEmpty || e.noPersist || _dead(e)) return;
    final epoch = e.openedSession;
    final key = e.key ??= e.held ?? _uuid.v4();
    final startedAt = _earliest(job.claimStartedAt, e.firstUsedAt);
    final row = _pending.state.where((p) => p.localId == e.localId).firstOrNull;
    final failed = row?.status == PendingPostStatus.failed;
    final errorText = failed ? row?.error : null;
    final canRetry = row?.canRetry ?? true;
    final needsVerify = row?.needsVerify ?? false;
    final flags = _clearFlagsOf(e);
    final mediaIds = _storedMediaIds(e);
    if (e.saved || e.saving) {
      unawaited(
        _storeOp(() async {
          await store.updateSend(
            job.uid,
            e.localId,
            epoch: epoch,
            key: key,
            keyStartedAt: startedAt,
            keyUsed: e.keyUsed,
            ambiguous: e.ambiguous,
            errorText: errorText,
            canRetry: canRetry,
            needsVerify: needsVerify,
            clearFlags: flags,
            mediaIds: mediaIds,
          );
          if (e.onDisk) _dropFromMemory(e);
        }),
      );
      return;
    }
    e.saving = true;
    final hadPhotos = job.attachments != null;
    final photos = [
      for (final a in e.attachments?.state.items ?? const <Attachment>[])
        if (a.image != null)
          StoredPhoto(
            image: a.image!,
            altText: a.altText,
            mediaId: a.status == AttachmentStatus.uploaded ? a.mediaId : '',
          ),
    ];
    final record = UnsentPostRecord(
      uid: job.uid,
      postId: e.localId,
      text: job.text,
      author: job.author,
      createdAt: row?.createdAt ?? _clock(),
      poll: job.poll,
      replyAudience: job.replyAudience,
      policy: job.policy,
      communityId: job.communityId,
      beaconId: job.beaconId,
      gif: job.gif,
      draftId: job.draftId,
      deleteDraftId: job.deleteDraftId,
      key: key,
      keyStartedAt: startedAt,
      keyUsed: e.keyUsed,
      ambiguous: e.ambiguous,
      claimReused: job.claimReused,
      photosKept: !e.photosLost && (e.attachments != null || !hadPhotos),
      photoCount: row?.photosTotal,
      photos: photos,
      errorText: errorText,
      canRetry: canRetry,
      needsVerify: needsVerify,
      clearFlags: flags,
    );
    unawaited(
      _storeOp(() async {
        try {
          final result = await store.save(record, epoch: epoch);
          // Only a save that worked counts as saved.
          if (!e.noPersist) e.saved = true;
          if (_dead(e)) return;
          if (result == UnsentSave.textOnly && hadPhotos) {
            _pending.update(e.localId, (p) => p.copyWith(photosNotSaved: true));
          } else if (result == UnsentSave.full && photos.isNotEmpty) {
            e.onDisk = true;
            _dropFromMemory(e);
          }
        } finally {
          e.saving = false;
        }
      }),
    );
  }

  /// Once a post's photos are safe on disk, a post that is not being sent
  /// does not keep their bytes in memory: they load again when needed.
  void _dropFromMemory(_Entry e) {
    if (e.running || e.attachments == null || _newAttachments == null) return;
    final status = _pending.state
        .where((p) => p.localId == e.localId)
        .firstOrNull
        ?.status;
    if (status != PendingPostStatus.waiting &&
        status != PendingPostStatus.failed) {
      return;
    }
    _dropPhotos(e);
  }

  /// The photos of a stored post as a new holder (for an Edit, or a send of
  /// a post that was only on disk); null when they cannot be read.
  Future<AttachmentsCubit?> _loadBytes(_Entry e) async {
    final store = _unsent;
    final make = _newAttachments;
    if (store == null || make == null) return null;
    try {
      final photos = await store.loadFull(e.job.uid, e.localId);
      if (photos.isEmpty || photos.any((p) => !p.fullLoaded)) return null;
      return make()
        ..restore([
          for (final p in photos) (image: p.image, altText: p.altText),
        ], gif: e.job.gif)
        ..retain();
    } catch (_, stack) {
      _onUnexpectedError?.call(
        StateError('Unsent photos could not be read.'),
        stack,
      );
      return null;
    }
  }

  /// Makes sure a send has its photos: in memory, or as the media ids of
  /// uploads that finished (no bytes needed), or loaded from disk.
  Future<bool> _prepareSend(_Entry e) async {
    if (!e.onDisk || e.attachments != null || e.mediaIds != null) return true;
    final cubit = await _loadBytes(e);
    if (cubit == null) return false;
    if (_dead(e)) {
      unawaited(cubit.close());
      return true;
    }
    e.attachments = cubit;
    return true;
  }

  /// The post left the queue for good (sent, dismissed, edited): its stored
  /// copy and photo bytes go, and nothing more is written for it.
  void _unpersist(_Entry e) {
    final store = _unsent;
    if (store == null) return;
    final had = e.saved || e.saving;
    e.noPersist = true;
    e.saved = false;
    if (!had) return;
    unawaited(_storeOp(() => store.delete(e.job.uid, e.localId)));
  }

  /// The post leaves the queue (Dismiss, Edit, discard).
  void _forget(_Entry e) {
    e.backoffTimer?.cancel();
    e.backoffTimer = null;
    e.waiting = false;
    e.backingOff = false;
    _unpersist(e);
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
