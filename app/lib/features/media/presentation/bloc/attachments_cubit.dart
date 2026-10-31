import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/media/v1/media.pb.dart' as pb;
import '../../data/gif_source.dart';
import '../../data/image_picker_service.dart';
import '../../data/media_uploader.dart';
import '../../domain/image_processor.dart';
import '../../domain/media_feature_flag.dart';
import '../../domain/processed_image.dart';

/// What an attachment is. A post has up to [kMaxPostImages] photos, or one
/// GIF, never both (ADR-0029 F5; the rule lives in `ComposerAttachmentRules`).
enum AttachmentKind { photo, gif }

enum AttachmentStatus {
  /// Being resized/compressed on the device.
  processing,

  /// Ready to upload (nothing sent yet, or a retry is pending).
  ready,

  /// PUT / finalize in flight.
  uploading,

  /// Published; [Attachment.mediaId] is set.
  uploaded,

  /// The upload failed; tap Post again to retry.
  failed,

  /// Uploaded, but the server could not check it (image checks were
  /// unavailable after the automatic retries). The upload is kept: the tile's
  /// Retry repeats FinalizeUpload for the same media id, with no re-upload
  /// (ADR-0029 Amendment 1 A5.6). Post waits until it is checked.
  unchecked,

  /// The server refused the image; remove it.
  rejected,

  /// The file could not be read as an image; remove it.
  unsupported,
}

@immutable
class Attachment {
  const Attachment({
    required this.id,
    this.kind = AttachmentKind.photo,
    this.status = AttachmentStatus.processing,
    this.image,
    this.progress = 0,
    this.mediaId = '',
    this.altText = '',
    this.rejectionReason = '',
  });

  final String id;
  final AttachmentKind kind;
  final AttachmentStatus status;
  final ProcessedImage? image;

  bool get isGif => kind == AttachmentKind.gif;

  /// 0..1 while [AttachmentStatus.uploading].
  final double progress;
  final String mediaId;
  final String altText;
  final String rejectionReason;

  /// Small JPEG for the tile preview (the same bytes that get uploaded as
  /// the thumbnail, so there is no extra decode work).
  Uint8List? get previewBytes => image?.thumbBytes;

  Attachment copyWith({
    AttachmentStatus? status,
    ProcessedImage? image,
    double? progress,
    String? mediaId,
    String? altText,
    String? rejectionReason,
  }) => Attachment(
    id: id,
    kind: kind,
    status: status ?? this.status,
    image: image ?? this.image,
    progress: progress ?? this.progress,
    mediaId: mediaId ?? this.mediaId,
    altText: altText ?? this.altText,
    rejectionReason: rejectionReason ?? this.rejectionReason,
  );
}

@immutable
class AttachmentsState {
  const AttachmentsState({
    this.items = const [],
    this.pickFailed = false,
    this.refusal,
  });

  final List<Attachment> items;

  /// Why the last GIF was refused before any upload ("GIFs can be up to
  /// 2 MB."); the screen tells the user once ([AttachmentsCubit.refusalShown]).
  final String? refusal;

  /// The picker or its permission failed; the screen tells the user once
  /// ([AttachmentsCubit.pickFailureShown]).
  final bool pickFailed;

  bool get isEmpty => items.isEmpty;
  int get count => items.length;
  bool get hasGif => items.any((a) => a.isGif);
  int get photoCount => items.where((a) => !a.isGif).length;
  bool get isFull => photoCount >= kMaxPostImages;

  /// True while any image is being processed or uploaded (Post waits).
  bool get isBusy => items.any(
    (a) =>
        a.status == AttachmentStatus.processing ||
        a.status == AttachmentStatus.uploading,
  );

  /// Every image is usable (none is still processing, rejected or
  /// unsupported). Failed uploads are retryable, so they count as usable.
  bool get isSendable =>
      items.isNotEmpty &&
      items.every(
        (a) =>
            a.status == AttachmentStatus.ready ||
            a.status == AttachmentStatus.uploaded ||
            a.status == AttachmentStatus.failed,
      );

  bool get hasUnusable => items.any(
    (a) =>
        a.status == AttachmentStatus.rejected ||
        a.status == AttachmentStatus.unsupported,
  );
}

/// What [AttachmentsCubit.uploadAll] hands the composer.
class UploadedAttachments {
  const UploadedAttachments({required this.mediaIds, required this.altTexts});
  final List<String> mediaIds;

  /// Parallel to [mediaIds], or empty when no image has alt text.
  final List<String> altTexts;
}

/// Picked images of one post: pick, process on device, remove, describe
/// (alt text) and upload. The composer calls [uploadAll] when the user taps
/// Post, so nothing is sent (and no daily quota spent) for photos the user
/// discards.
class AttachmentsCubit extends Cubit<AttachmentsState> {
  AttachmentsCubit({
    required ImagePickerService picker,
    required ImageProcessor processor,
    required MediaUploader uploader,
    GifSource? gifSource,
    GifPreparer? gifPreparer,
    Uuid? uuid,
  }) : _picker = picker,
       _processor = processor,
       _uploader = uploader,
       _gifSource = gifSource ?? DeviceGifSource(),
       _gifPreparer = gifPreparer ?? const IsolateGifPreparer(),
       _uuid = uuid ?? const Uuid(),
       super(const AttachmentsState());

  final ImagePickerService _picker;
  final ImageProcessor _processor;
  final MediaUploader _uploader;
  final GifSource _gifSource;
  final GifPreparer _gifPreparer;
  final Uuid _uuid;

  /// Opens the picker for the remaining slots and processes each choice.
  Future<void> pick() async {
    if (_picking || state.hasGif) return;
    final room = kMaxPostImages - state.photoCount;
    if (room <= 0) return;
    _picking = true;
    try {
      final List<Uint8List> files;
      try {
        files = await _picker.pickImages(limit: room);
      } catch (_) {
        // Permission denied / picker failure: nothing was added.
        if (!isClosed) {
          emit(AttachmentsState(items: state.items, pickFailed: true));
        }
        return;
      }
      if (isClosed || files.isEmpty) return;
      await addImages(files);
    } finally {
      _picking = false;
    }
  }

  /// Held across the picker and the processing so two overlapping picks
  /// cannot both claim the same free slots.
  bool _picking = false;

  /// Opens the picker for one GIF, checks it on the device (size, edge,
  /// frames: refused with a message, never re-encoded) and attaches it. Does
  /// nothing while anything is attached (the toolbar already says why).
  Future<void> pickGif() async {
    if (_picking || !state.isEmpty) return;
    _picking = true;
    try {
      final Uint8List? bytes;
      try {
        bytes = await _gifSource.pick();
      } catch (_) {
        if (!isClosed) emit(const AttachmentsState(pickFailed: true));
        return;
      }
      if (isClosed || bytes == null) return;
      final id = _uuid.v4();
      emit(
        AttachmentsState(
          items: [Attachment(id: id, kind: AttachmentKind.gif)],
        ),
      );
      try {
        final gif = await _gifPreparer.prepare(bytes);
        _update(
          id,
          (a) => a.copyWith(status: AttachmentStatus.ready, image: gif),
        );
      } on GifRefusedException catch (refused) {
        // Nothing is kept: the user picks another file.
        if (!isClosed) emit(AttachmentsState(refusal: refused.message));
      } catch (_) {
        if (!isClosed) {
          emit(AttachmentsState(refusal: GifRefusedException.notGif.message));
        }
      }
    } finally {
      _picking = false;
    }
  }

  /// The screen showed the GIF refusal.
  void refusalShown() {
    if (state.refusal != null && !isClosed) {
      emit(AttachmentsState(items: state.items));
    }
  }

  /// The screen showed the picker failure.
  void pickFailureShown() {
    if (state.pickFailed && !isClosed) {
      emit(AttachmentsState(items: state.items));
    }
  }

  /// Adds already-read image bytes (the picker result; also used by tests).
  Future<void> addImages(List<Uint8List> files) async {
    final room = kMaxPostImages - state.photoCount;
    final accepted = files.take(room).toList();
    final ids = [for (final _ in accepted) _uuid.v4()];
    emit(
      AttachmentsState(
        items: [
          ...state.items,
          for (final id in ids) Attachment(id: id),
        ],
      ),
    );
    // One at a time: decoding a full-size photo is memory-hungry, and four
    // at once can exhaust a low-end phone. Each tile turns ready in turn.
    for (var i = 0; i < accepted.length; i++) {
      if (isClosed) return;
      await _process(ids[i], accepted[i]);
    }
  }

  Future<void> _process(String id, Uint8List bytes) async {
    try {
      final image = await _processor.process(bytes, ImagePurpose.post);
      _update(
        id,
        (a) => a.copyWith(status: AttachmentStatus.ready, image: image),
      );
    } catch (_) {
      _update(id, (a) => a.copyWith(status: AttachmentStatus.unsupported));
    }
  }

  void _update(String id, Attachment Function(Attachment) change) {
    if (isClosed) return;
    emit(
      AttachmentsState(
        items: [for (final a in state.items) a.id == id ? change(a) : a],
      ),
    );
  }

  void remove(String id) {
    _uploader.forget(id);
    emit(
      AttachmentsState(
        items: [
          for (final a in state.items)
            if (a.id != id) a,
        ],
      ),
    );
  }

  void setAltText(String id, String text) {
    final trimmed = text.trim();
    final clipped = trimmed.runes.length > kMaxAltTextLength
        ? String.fromCharCodes(trimmed.runes.take(kMaxAltTextLength))
        : trimmed;
    _update(id, (a) => a.copyWith(altText: clipped));
  }

  /// Uploads every image that is not published yet and returns the media ids
  /// in picture order. Safe to call again after a failure: finished work is
  /// not repeated.
  ///
  /// Throws an [AppException]: the first failure of the whole call (quota,
  /// degraded mode, network, ...), a per-image network failure, or a
  /// [ValidationException] (`field: media`) when moderation refused an image.
  Future<UploadedAttachments> uploadAll() async {
    final items = state.items;
    final jobs = [
      for (final a in items)
        if (a.image != null) UploadJob(id: a.id, image: a.image!),
    ];
    for (final a in items) {
      if (a.status == AttachmentStatus.ready ||
          a.status == AttachmentStatus.failed) {
        _update(
          a.id,
          (x) => x.copyWith(status: AttachmentStatus.uploading, progress: 0),
        );
      }
    }
    final List<UploadOutcome> outcomes;
    try {
      outcomes = await _uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: jobs,
        onProgress: (id, progress) => _update(
          id,
          (a) => a.status == AttachmentStatus.uploading
              ? a.copyWith(progress: progress)
              : a,
        ),
      );
    } on AppException catch (error) {
      if (error is ScreeningUnavailableException) {
        // Every tile in flight was uploaded and none could be checked. Keep
        // the uploads and offer the manual Retry on each.
        for (final a in state.items) {
          if (a.status == AttachmentStatus.uploading) {
            _update(
              a.id,
              (x) => x.copyWith(status: AttachmentStatus.unchecked),
            );
          }
        }
        rethrow;
      }
      // The server named the image it could not find: that tile failed, the
      // others simply go back to waiting.
      final named = error is MediaNotReadyException && error.mediaId != null
          ? _uploader.jobIdForMedia(error.mediaId!)
          : null;
      for (final a in state.items) {
        if (a.status == AttachmentStatus.uploading) {
          _update(
            a.id,
            (x) => x.copyWith(
              status: a.id == named
                  ? AttachmentStatus.failed
                  : AttachmentStatus.ready,
            ),
          );
        }
      }
      rethrow;
    }

    AppException? firstError;
    String? rejection;
    for (final outcome in outcomes) {
      switch (outcome.status) {
        case UploadOutcomeStatus.ready:
          _update(
            outcome.id,
            (a) => a.copyWith(
              status: AttachmentStatus.uploaded,
              mediaId: outcome.mediaId,
              progress: 1,
            ),
          );
        case UploadOutcomeStatus.rejected:
          rejection ??= outcome.reason;
          _update(
            outcome.id,
            (a) => a.copyWith(
              status: AttachmentStatus.rejected,
              rejectionReason: outcome.reason,
            ),
          );
        case UploadOutcomeStatus.failed:
          firstError ??= outcome.error;
          _update(
            outcome.id,
            (a) => a.copyWith(status: AttachmentStatus.failed),
          );
      }
    }
    if (rejection != null) {
      final gif = state.hasGif;
      throw ValidationException(
        rejection.isEmpty
            ? (gif
                  ? "This GIF can't be used. Remove it and try again."
                  : "One of your photos can't be used. Remove it and try again.")
            : rejection,
        field: 'media',
      );
    }
    if (firstError != null) throw firstError;

    // Built from this call's outcomes (and the items as they were when it
    // started), never from live state: the user may have removed a photo or
    // closed the screen while the upload ran.
    final byId = {for (final o in outcomes) o.id: o};
    final mediaIds = <String>[];
    final alts = <String>[];
    for (final a in items) {
      final outcome = byId[a.id];
      if (outcome == null || outcome.status != UploadOutcomeStatus.ready) {
        // A contract/logic anomaly, not a user-facing failure: the composer's
        // catch-all reports it to Crashlytics.
        throw StateError('A photo was not uploaded.');
      }
      mediaIds.add(outcome.mediaId);
      alts.add(a.altText);
    }
    return UploadedAttachments(
      mediaIds: mediaIds,
      altTexts: alts.every((t) => t.isEmpty) ? const [] : alts,
    );
  }

  /// The tile's Retry (ADR-0029 Amendment 1 A5.6): FinalizeUpload again for
  /// the same media id. The uploader remembers the finished PUTs, so nothing
  /// is re-uploaded and no upload quota is spent.
  Future<void> retryCheck(String id) async {
    final tile = state.items.where((a) => a.id == id).firstOrNull;
    final image = tile?.image;
    if (tile == null ||
        image == null ||
        tile.status != AttachmentStatus.unchecked) {
      return;
    }
    _update(id, (a) => a.copyWith(status: AttachmentStatus.uploading));
    try {
      final outcomes = await _uploader.upload(
        purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: [UploadJob(id: id, image: image)],
      );
      final outcome = outcomes.single;
      _update(
        id,
        (a) => switch (outcome.status) {
          UploadOutcomeStatus.ready => a.copyWith(
            status: AttachmentStatus.uploaded,
            mediaId: outcome.mediaId,
            progress: 1,
          ),
          UploadOutcomeStatus.rejected => a.copyWith(
            status: AttachmentStatus.rejected,
            rejectionReason: outcome.reason,
          ),
          UploadOutcomeStatus.failed => a.copyWith(
            status: AttachmentStatus.failed,
          ),
        },
      );
    } on ScreeningUnavailableException {
      _update(id, (a) => a.copyWith(status: AttachmentStatus.unchecked));
    } on AppException {
      _update(id, (a) => a.copyWith(status: AttachmentStatus.failed));
    }
  }

  /// Drops everything (after a post succeeded).
  void clear() => emit(const AttachmentsState());
}
