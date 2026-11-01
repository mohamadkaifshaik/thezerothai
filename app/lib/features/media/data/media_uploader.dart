import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../../../core/network/app_exception.dart';
import '../../../gen/dzeroth/media/v1/media.pb.dart' as pb;
import '../domain/processed_image.dart';
import 'media_repository.dart';

/// One image to upload. [id] is the caller's stable local id.
class UploadJob {
  const UploadJob({required this.id, required this.image});
  final String id;
  final ProcessedImage image;
}

enum UploadOutcomeStatus {
  /// Published (READY or READY_UNSCREENED); [UploadOutcome.mediaId] is set.
  ready,

  /// Moderation or validation refused it; [UploadOutcome.reason] may say why.
  rejected,

  /// The PUT failed (network / storage); a retry may succeed.
  failed,
}

class UploadOutcome {
  const UploadOutcome({
    required this.id,
    required this.status,
    this.mediaId = '',
    this.reason = '',
    this.error,
  });

  final String id;
  final UploadOutcomeStatus status;
  final String mediaId;
  final String reason;
  final AppException? error;
}

class _Reservation {
  _Reservation({
    required this.target,
    required this.receivedAt,
    required this.intent,
    required this.group,
  });
  final pb.UploadTarget target;

  /// When this device received the URLs (local clock). Expiry is measured
  /// from here, never from the server's `expires_at` against the device
  /// clock, so a skewed device clock cannot kill (or keep) a reservation.
  final DateTime receivedAt;

  /// The CreateUpload intent (and so idempotency key) it was reserved under.
  final String intent;

  /// Local ids reserved together, in request order (a replay must send the
  /// same items).
  final List<String> group;
  bool putDone = false;

  /// The signed URLs are known to be unusable (storage refused the PUT).
  bool urlsDead = false;
}

/// Runs CreateUpload -> PUT full + thumb -> FinalizeUpload for a set of
/// images, and remembers enough that **retrying never repeats work or burns
/// the daily upload quota**:
///
/// - one CreateUpload idempotency key per distinct set of images (a dropped
///   response replays the stored targets);
/// - a reservation that is still valid is reused, finished PUTs are not
///   repeated, and a finalized image is never uploaded again;
/// - when the signed URLs have expired (10-minute TTL, measured on this
///   device from the moment they arrived) or storage refused them (4xx),
///   the URLs are dropped and re-signed by **replaying the same key** while
///   the image set is unchanged: the server returns the same media ids with
///   fresh URLs and charges no quota (backend `media/service.go`). A changed
///   set mints a new key;
/// - a rejected image stays rejected until the caller drops it.
///
/// Create one per screen/intent; it holds no UI state.
class MediaUploader {
  MediaUploader({
    required MediaRepository repository,
    Uuid? uuid,
    DateTime Function()? clock,
    this.expirySlack = const Duration(seconds: 30),
    this.urlTtl = const Duration(minutes: 10),
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    this.gifBusyDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ],
    this.screeningRetries = 3,
    Future<void> Function(Duration)? delay,
    math.Random? random,
  }) : _repository = repository,
       _delay = delay ?? Future<void>.delayed,
       _jitter = random ?? math.Random(),
       _onUnexpectedError = onUnexpectedError,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now;

  final MediaRepository _repository;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// Told about contract anomalies this class detects itself. Failures the
  /// repository already reported (CreateUpload, Finalize, PUT 5xx) are not
  /// reported again.
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// Waits before each repeat of a GIF FinalizeUpload that found the
  /// server's GIF slot busy; its length is the number of repeats.
  final List<Duration> gifBusyDelays;

  /// How many times a FinalizeUpload that answered "image checks are
  /// temporarily unavailable" is repeated automatically (ADR-0029 Amendment 1
  /// A5.6), after the server's `retry_after`. The same call and media id:
  /// nothing is re-signed or re-PUT, and the server counts it as a retry, not
  /// a screening attempt. After the last repeat the exception is rethrown and
  /// the tile offers a manual Retry.
  final int screeningRetries;
  final Future<void> Function(Duration) _delay;
  final math.Random _jitter;

  /// A reservation closer than this to its expiry is renewed first.
  final Duration expirySlack;

  /// Lifetime of the signed URLs (backend `UploadURLTTL`).
  final Duration urlTtl;

  final Map<String, _Reservation> _reservations = {};
  final Map<String, UploadOutcome> _final = {};
  final Map<String, String> _keys = {};

  UploadInterruptedException _anomaly(String message) {
    final error = UploadInterruptedException(message);
    _onUnexpectedError?.call(error, StackTrace.current);
    return error;
  }

  String _key(String intent) => _keys.putIfAbsent(intent, _uuid.v4);

  bool _unusable(_Reservation r, DateTime now) {
    if (r.putDone) return false; // nothing left to PUT
    if (r.urlsDead) return true;
    return now.difference(r.receivedAt) >= urlTtl - expirySlack;
  }

  /// The local id of the job that reserved [mediaId], if still known (to
  /// mark the right tile when FinalizeUpload names a media id).
  String? jobIdForMedia(String mediaId) {
    for (final entry in _reservations.entries) {
      if (entry.value.target.mediaId == mediaId) return entry.key;
    }
    return null;
  }

  /// Forgets everything remembered about [jobId] (the image was removed).
  void forget(String jobId) {
    _reservations.remove(jobId);
    _final.remove(jobId);
  }

  /// FinalizeUpload. A GIF is screened by one slot per server instance, so
  /// while another GIF holds it the call answers a retryable MEDIA_NOT_READY
  /// with the object safely stored: with [waitForGifSlot] the same call (same
  /// key; nothing is re-signed or re-PUT) is repeated quietly after
  /// [gifBusyDelays] (jittered) before the answer is treated as a missing
  /// object. A photo's MEDIA_NOT_READY is never retried here.
  Future<List<pb.MediaResult>> _finalize({
    required String key,
    required List<FinalizeRequestItem> items,
    required bool waitForGifSlot,
  }) async {
    var screeningAttempts = 0;
    for (var attempt = 0; ; attempt++) {
      try {
        return await _repository.finalizeUpload(
          idempotencyKey: key,
          items: items,
        );
      } on ScreeningUnavailableException catch (error) {
        if (screeningAttempts >= screeningRetries) rethrow;
        // The server's retry_after (5 s), or 2, 4, 8 s when it sent none,
        // plus up to a quarter of jitter. Capped, so a bad value cannot park
        // the upload for long.
        var base =
            error.retryAfter ?? Duration(seconds: 2 << screeningAttempts);
        if (base > const Duration(seconds: 30)) {
          base = const Duration(seconds: 30);
        }
        screeningAttempts++;
        await _delay(
          base +
              Duration(
                milliseconds: _jitter.nextInt(base.inMilliseconds ~/ 4 + 1),
              ),
        );
      } on MediaNotReadyException {
        if (!waitForGifSlot || attempt >= gifBusyDelays.length) rethrow;
        final base = gifBusyDelays[attempt];
        await _delay(
          base +
              Duration(
                milliseconds: _jitter.nextInt(base.inMilliseconds ~/ 4 + 1),
              ),
        );
      }
    }
  }

  /// Uploads [jobs] and returns one outcome per job, in order.
  ///
  /// Throws an [AppException] for a failure of the whole call (flag off,
  /// quota, rate limit, degraded mode, network on CreateUpload/Finalize).
  /// Per-image PUT failures are [UploadOutcomeStatus.failed] outcomes.
  /// [onProgress] receives `(jobId, 0..1)` (full and thumb objects, weighted
  /// by size).
  Future<List<UploadOutcome>> upload({
    required pb.MediaPurpose purpose,
    required List<UploadJob> jobs,
    void Function(String jobId, double progress)? onProgress,
  }) async {
    final now = _clock();
    final todo = [
      for (final job in jobs)
        if (!_final.containsKey(job.id)) job,
    ];
    // Every job the caller passed (finished ones included): a replay must
    // send the original group, so a finished sibling must not break it.
    final byId = {for (final job in jobs) job.id: job};

    // 1. Reserve targets for jobs without usable URLs.
    final needIds = <String>{
      for (final job in todo)
        if (_reservations[job.id] == null ||
            _unusable(_reservations[job.id]!, now))
          job.id,
    };
    // Batches to (re)request. A batch of expired reservations replays the
    // original request (same items, same key) so the server re-signs the
    // same media ids without charging quota; the rest form one new batch.
    final batches = <List<UploadJob>>[];
    final batched = <String>{};
    for (final id in needIds) {
      final reservation = _reservations[id];
      if (reservation == null || batched.contains(id)) continue;
      final group = reservation.group;
      final intact = group.every(
        (g) =>
            byId.containsKey(g) &&
            _reservations[g]?.intent == reservation.intent,
      );
      if (!intact) continue;
      batches.add([for (final g in group) byId[g]!]);
      batched.addAll(group);
    }
    final fresh = [
      for (final job in todo)
        if (needIds.contains(job.id) && !batched.contains(job.id)) job,
    ];
    if (fresh.isNotEmpty) batches.add(fresh);

    // Note: a replay after the server's idempotency record expired is a new
    // request and charges the daily quota for the whole group again.
    for (final batch in batches) {
      // The key covers the exact image set (by local id and MD5), so the
      // same retry replays and a changed set mints a new key.
      final intent =
          'c|${purpose.value}|'
          '${[for (final j in batch) '${j.id}:${j.image.fullMd5}:${j.image.thumbMd5}:'
                '${j.image.fullBytes.length}:${j.image.thumbBytes.length}:'
                '${j.image.width}x${j.image.height}'].join(',')}';
      final targets = await _repository.createUpload(
        idempotencyKey: _key(intent),
        purpose: purpose,
        images: [for (final job in batch) job.image],
      );
      final received = _clock();
      final group = [for (final job in batch) job.id];
      for (var i = 0; i < batch.length; i++) {
        final existing = _reservations[batch[i].id];
        if (existing != null &&
            existing.putDone &&
            existing.target.mediaId == targets[i].mediaId) {
          continue; // replayed ids: already PUT, keep as is
        }
        _reservations[batch[i].id] = _Reservation(
          target: targets[i],
          receivedAt: received,
          intent: intent,
          group: group,
        );
      }
    }

    // 2. PUT what has not been PUT yet.
    final failures = <String, AppException>{};
    for (final job in todo) {
      final reservation = _reservations[job.id]!;
      if (reservation.putDone) {
        onProgress?.call(job.id, 1);
        continue;
      }
      try {
        final full = job.image.fullBytes;
        final thumb = job.image.thumbBytes;
        final total = full.length + thumb.length;
        await _repository.putObject(reservation.target.full, full);
        onProgress?.call(job.id, full.length / total);
        await _repository.putObject(reservation.target.thumb, thumb);
        onProgress?.call(job.id, 1);
        reservation.putDone = true;
      } on StorageRefusedException catch (error) {
        // Storage said no (expired or altered URL): drop the URLs so the
        // next attempt re-signs them under the same key.
        reservation.urlsDead = true;
        failures[job.id] = UploadInterruptedException(
          'Upload refused (${error.status}).',
        );
      } on UnknownApiException {
        // A 5xx from storage: already reported by the repository.
        failures[job.id] = const UploadInterruptedException(
          'Storage had a problem.',
        );
      } on AppException catch (error) {
        // One image failing must not stop the others; a flag-off or quota
        // answer cannot happen here (PUTs go straight to storage).
        failures[job.id] = error;
      }
    }

    // 3. Finalize everything that was PUT.
    final toFinalize = [
      for (final job in todo)
        if (_reservations[job.id]!.putDone) job,
    ];
    if (toFinalize.isNotEmpty) {
      final ids = [
        for (final job in toFinalize) _reservations[job.id]!.target.mediaId,
      ];
      // Retrying the same set replays; the key is dropped once it answered.
      final finalizeIntent = 'f|${ids.join(',')}';
      final List<pb.MediaResult> results;
      try {
        results = await _finalize(
          key: _key(finalizeIntent),
          items: [
            for (final job in toFinalize)
              FinalizeRequestItem(
                mediaId: _reservations[job.id]!.target.mediaId,
                blurhash: job.image.blurhash,
              ),
          ],
          // The server's one GIF slot may be busy (MEDIA_NOT_READY, retry):
          // for a lone GIF that is waited out, not treated as a lost object.
          waitForGifSlot:
              toFinalize.length == 1 && toFinalize.single.image.isGif,
        );
      } on MediaNotReadyException catch (error) {
        // The server did not find the object: PUT it again (re-signed).
        final jobId = jobIdForMedia(error.mediaId ?? '');
        final reservation = jobId == null ? null : _reservations[jobId];
        if (reservation != null) {
          reservation.putDone = false;
          reservation.urlsDead = true;
        } else {
          // Unknown media id: any object may be the missing one.
          for (final job in toFinalize) {
            final r = _reservations[job.id]!;
            r.putDone = false;
            r.urlsDead = true;
          }
        }
        rethrow;
      }
      _keys.remove(finalizeIntent);
      final byMedia = {for (final r in results) r.mediaId: r};
      for (final job in toFinalize) {
        final mediaId = _reservations[job.id]!.target.mediaId;
        final result = byMedia[mediaId];
        if (result == null) {
          failures[job.id] = _anomaly('Upload was not confirmed.');
          continue;
        }
        switch (result.status) {
          case pb.MediaStatus.MEDIA_STATUS_READY ||
              pb.MediaStatus.MEDIA_STATUS_READY_UNSCREENED:
            _final[job.id] = UploadOutcome(
              id: job.id,
              status: UploadOutcomeStatus.ready,
              mediaId: mediaId,
            );
          case pb.MediaStatus.MEDIA_STATUS_REJECTED:
            _final[job.id] = UploadOutcome(
              id: job.id,
              status: UploadOutcomeStatus.rejected,
              reason: result.rejectionReason,
            );
          default:
            // Still PENDING (should not happen): finalize again next time.
            failures[job.id] = _anomaly('Upload is not ready yet.');
        }
      }
    }

    return [
      for (final job in jobs)
        _final[job.id] ??
            UploadOutcome(
              id: job.id,
              status: UploadOutcomeStatus.failed,
              error:
                  failures[job.id] ??
                  const UploadInterruptedException('Upload did not finish.'),
            ),
    ];
  }
}
