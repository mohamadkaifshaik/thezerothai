import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/media/v1/media.pb.dart' as pb;
import '../../data/image_picker_service.dart';
import '../../data/media_uploader.dart';
import '../../domain/image_processor.dart';
import '../../domain/media_feature_flag.dart';
import '../../domain/processed_image.dart';

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

  /// The server refused the image; remove it.
  rejected,

  /// The file could not be read as an image; remove it.
  unsupported,
}

@immutable
class Attachment {
  const Attachment({
    required this.id,
    this.status = AttachmentStatus.processing,
    this.image,
    this.progress = 0,
    this.mediaId = '',
    this.altText = '',
    this.rejectionReason = '',
  });

  final String id;
  final AttachmentStatus status;
  final ProcessedImage? image;

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
  const AttachmentsState({this.items = const [], this.pickFailed = false});

  final List<Attachment> items;

  /// The picker or its permission failed; the screen tells the user once
  /// ([AttachmentsCubit.pickFailureShown]).
  final bool pickFailed;

  bool get isEmpty => items.isEmpty;
  int get count => items.length;
  bool get isFull => items.length >= kMaxPostImages;

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
    Uuid? uuid,
  }) : _picker = picker,
       _processor = processor,
       _uploader = uploader,
       _uuid = uuid ?? const Uuid(),
       super(const AttachmentsState());

  final ImagePickerService _picker;
  final ImageProcessor _processor;
  final MediaUploader _uploader;
  final Uuid _uuid;

  /// Opens the picker for the remaining slots and processes each choice.
  Future<void> pick() async {
    final room = kMaxPostImages - state.count;
    if (room <= 0) return;
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
  }

  /// The screen showed the picker failure.
  void pickFailureShown() {
    if (state.pickFailed && !isClosed) {
      emit(AttachmentsState(items: state.items));
    }
  }

  /// Adds already-read image bytes (the picker result; also used by tests).
  Future<void> addImages(List<Uint8List> files) async {
    final room = kMaxPostImages - state.count;
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
      throw ValidationException(
        rejection.isEmpty
            ? "One of your photos can't be used. Remove it and try again."
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
        throw const UnknownApiException('A photo was not uploaded.');
      }
      mediaIds.add(outcome.mediaId);
      alts.add(a.altText);
    }
    return UploadedAttachments(
      mediaIds: mediaIds,
      altTexts: alts.every((t) => t.isEmpty) ? const [] : alts,
    );
  }

  /// Drops everything (after a post succeeded).
  void clear() => emit(const AttachmentsState());
}
