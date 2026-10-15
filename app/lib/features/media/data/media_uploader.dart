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
  _Reservation(this.target, this.expiresAt);
  final pb.UploadTarget target;
  final DateTime expiresAt;
  bool putDone = false;
}

/// Runs CreateUpload -> PUT full + thumb -> FinalizeUpload for a set of
/// images, and remembers enough that **retrying never repeats work or burns
/// the daily upload quota**:
///
/// - one CreateUpload idempotency key per distinct set of images (a dropped
///   response replays the stored targets);
/// - a reservation that is still valid is reused, finished PUTs are not
///   repeated, and a finalized image is never uploaded again;
/// - a reservation that has expired (10-minute signed URLs) is dropped and
///   re-reserved under a fresh key (replaying the old key would only return
///   the dead URLs);
/// - a rejected image stays rejected until the caller drops it.
///
/// Create one per screen/intent; it holds no UI state.
class MediaUploader {
  MediaUploader({
    required MediaRepository repository,
    Uuid? uuid,
    DateTime Function()? clock,
    this.expirySlack = const Duration(seconds: 30),
  }) : _repository = repository,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now;

  final MediaRepository _repository;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// A reservation closer than this to its expiry is renewed first.
  final Duration expirySlack;

  final Map<String, _Reservation> _reservations = {};
  final Map<String, UploadOutcome> _final = {};
  final Map<String, String> _keys = {};

  String _key(String intent) => _keys.putIfAbsent(intent, _uuid.v4);

  /// Forgets everything remembered about [jobId] (the image was removed).
  void forget(String jobId) {
    _reservations.remove(jobId);
    _final.remove(jobId);
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

    // 1. Reserve targets for jobs without a valid reservation.
    final needReservation = [
      for (final job in todo)
        if (_reservations[job.id] == null ||
            _reservations[job.id]!.expiresAt.difference(now) <= expirySlack)
          job,
    ];
    if (needReservation.isNotEmpty) {
      for (final job in needReservation) {
        _reservations.remove(job.id);
      }
      // The key covers the exact image set (by local id and MD5), so the
      // same retry replays and a changed set mints a new key.
      final intent =
          'c|${purpose.value}|'
          '${[for (final j in needReservation) '${j.id}:${j.image.fullMd5}'].join(',')}';
      final targets = await _repository.createUpload(
        idempotencyKey: _key(intent),
        purpose: purpose,
        images: [for (final job in needReservation) job.image],
      );
      for (var i = 0; i < needReservation.length; i++) {
        final full = targets[i].full;
        final expiresAt = full.hasExpiresAt()
            ? full.expiresAt.toDateTime()
            : now.add(const Duration(minutes: 10));
        _reservations[needReservation[i].id] = _Reservation(
          targets[i],
          expiresAt,
        );
        // The intent is spent: an expiry re-reservation needs a new key.
        _keys.remove(intent);
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
      final results = await _repository.finalizeUpload(
        idempotencyKey: _key('f|${ids.join(',')}'),
        items: [
          for (final job in toFinalize)
            FinalizeRequestItem(
              mediaId: _reservations[job.id]!.target.mediaId,
              blurhash: job.image.blurhash,
            ),
        ],
      );
      final byMedia = {for (final r in results) r.mediaId: r};
      for (final job in toFinalize) {
        final mediaId = _reservations[job.id]!.target.mediaId;
        final result = byMedia[mediaId];
        if (result == null) {
          failures[job.id] = const UnknownApiException(
            'Upload was not confirmed.',
          );
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
            failures[job.id] = const UnknownApiException(
              'Upload is not ready yet.',
            );
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
                  const UnknownApiException('Upload did not finish.'),
            ),
    ];
  }
}
