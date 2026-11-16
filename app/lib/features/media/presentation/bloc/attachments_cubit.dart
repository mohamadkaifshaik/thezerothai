import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/media/v1/media.pb.dart' as pb;
import '../../../posts/domain/composer_attachment_rules.dart';
import '../../data/gif_source.dart';
import '../../data/image_picker_service.dart';
import '../../data/media_uploader.dart';
import '../../domain/image_processor.dart';
import '../../domain/media_feature_flag.dart';
import '../../domain/photo_edit.dart';
import '../../domain/processed_image.dart';
import '../../domain/processing_cancellation.dart';
import '../../domain/unusual_aspect.dart';

/// Shown when a keyboard GIF arrives while GIFs are off.
const kGifOffMessage = 'GIFs are not available right now.';

/// Whether [bytes] start like a GIF.
bool looksLikeGif(Uint8List bytes) =>
    bytes.length >= 6 &&
    String.fromCharCodes(bytes.sublist(0, 6)).startsWith('GIF8');

/// What an attachment is. A post has up to [kMaxPostImages] photos, or one
/// GIF, never both (the rule lives in `ComposerAttachmentRules`).
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
  ///Post waits until it is checked.
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

  /// Set when the processed photo is very narrow or very flat (never a GIF);
  /// the composer warns before posting. From the size already known, so no
  /// second decode.
  UnusualShape? get unusualShape {
    final i = image;
    if (i == null) return null;
    return unusualShapeOf(width: i.width, height: i.height, isGif: isGif);
  }

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
    this.gifEnabled = false,
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

  /// Whether this composer offers GIFs (`FEATURE_GIF` and `media`). With it a
  /// single GIF chosen in the photo picker stays a GIF; without it the file
  /// is processed as a still photo, as before.
  final bool gifEnabled;

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
      // A lone GIF from the gallery keeps its animation: it goes the GIF way
      // (checked, not re-encoded) instead of becoming a still photo.
      if (gifEnabled &&
          state.isEmpty &&
          files.length == 1 &&
          looksLikeGif(files.single)) {
        await _attachGif(files.single);
        return;
      }
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
      await _attachGif(bytes);
    } finally {
      _picking = false;
    }
  }

  /// Checks [bytes] as a GIF and attaches it (the picker's lock is held by the
  /// caller). A refusal keeps nothing.
  Future<void> _attachGif(Uint8List bytes) async {
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
  }

  /// Content a keyboard inserted into the text field (Gboard's GIF tab, a
  /// sticker): [mimeType] and [bytes]. A GIF becomes the post's GIF (checked,
  /// never re-encoded); a PNG, JPEG or WebP becomes a photo. Both follow the
  /// toolbar's [rules], so a refused insert says why, as its button would.
  /// Any other type is ignored.
  Future<void> insertContent({
    required String mimeType,
    required Uint8List bytes,
    required ComposerAttachmentRules rules,
  }) async {
    final type = mimeType.toLowerCase();
    final isGif = type == kGifContentType;
    if (!isGif && !_photoMimeTypes.contains(type)) return;
    if (_picking || isClosed || bytes.isEmpty) return;
    if (!rules.mediaOn) return;
    if (isGif) {
      if (!rules.showGif) return _refuse(kGifOffMessage);
      final block = rules.gif;
      if (block != ComposerBlock.none) return _refuse(block.gifTooltip);
      _picking = true;
      try {
        await _attachGif(bytes);
      } finally {
        _picking = false;
      }
      return;
    }
    final block = rules.photo;
    if (block != ComposerBlock.none) return _refuse(block.photoTooltip);
    if (state.photoCount >= kMaxPostImages) {
      return _refuse('You can add up to $kMaxPostImages photos.');
    }
    _picking = true;
    try {
      await addImages([bytes]);
    } finally {
      _picking = false;
    }
  }

  void _refuse(String message) {
    if (!isClosed) emit(AttachmentsState(items: state.items, refusal: message));
  }

  /// The mime types a keyboard may insert (the field's allowed list).
  static const List<String> insertableMimeTypes = [
    kGifContentType,
    'image/png',
    'image/jpeg',
    'image/webp',
  ];

  static const _photoMimeTypes = {'image/png', 'image/jpeg', 'image/webp'};

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
    // A photo removed while it waited is skipped, never processed.
    for (var i = 0; i < accepted.length; i++) {
      if (isClosed) return;
      _sources[ids[i]] = accepted[i];
      if (!state.items.any((a) => a.id == ids[i])) continue;
      await _process(ids[i], accepted[i]);
    }
  }

  /// The cancellation of each photo being processed: [remove], [clear] and
  /// [close] cancel it, so a removed photo (or a closed composer) stops the
  /// work (on the web the worker is terminated).
  final Map<String, ProcessingCancellation> _processing = {};

  /// The picked bytes of each photo, kept so the editor can crop and rotate
  /// the SOURCE (not the already processed, smaller copy). Not part of the
  /// state: they are large. Dropped with the photo.
  final Map<String, Uint8List> _sources = {};

  /// The first processed (unedited) full-size copy of each photo: what the
  /// editor shows and crops. It is oriented exactly as the processors orient
  /// the source (EXIF baked in), so the crop fractions land on the right
  /// pixels on every platform, and it is at most 2048 px, so the editor never
  /// decodes a 12 MP original.
  final Map<String, Uint8List> _previews = {};

  /// The edit each photo was last processed with.
  final Map<String, PhotoEdit> _edits = {};

  /// The picked bytes of photo [id], or null (a GIF, or removed).
  Uint8List? sourceOf(String id) => _sources[id];

  /// What the editor shows of photo [id]: the unedited, oriented photo (see
  /// [_previews]), or null while it is first being prepared and for a GIF.
  Uint8List? previewOf(String id) => _previews[id];

  /// The edit photo [id] currently has (none by default).
  PhotoEdit editOf(String id) => _edits[id] ?? PhotoEdit.none;

  Future<void> _process(String id, Uint8List bytes, {PhotoEdit? edit}) async {
    final cancellation = ProcessingCancellation();
    _processing[id] = cancellation;
    try {
      final image = await _processor.process(
        bytes,
        ImagePurpose.post,
        cancellation: cancellation,
        edit: edit,
      );
      if (cancellation.isCancelled) return;
      if (edit == null) _previews[id] = image.fullBytes;
      _update(
        id,
        (a) => a.copyWith(status: AttachmentStatus.ready, image: image),
      );
    } on ImageProcessingCancelled {
      // Removed or closed: the tile is already gone.
    } catch (_) {
      if (cancellation.isCancelled) return;
      _update(id, (a) => a.copyWith(status: AttachmentStatus.unsupported));
    } finally {
      if (identical(_processing[id], cancellation)) _processing.remove(id);
    }
  }

  void _cancelProcessing([String? id]) {
    if (id != null) {
      _processing.remove(id)?.cancel();
      return;
    }
    final all = _processing.values.toList();
    _processing.clear();
    for (final c in all) {
      c.cancel();
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
    _cancelProcessing(id);
    _uploader.forget(id);
    _sources.remove(id);
    _previews.remove(id);
    _edits.remove(id);
    emit(
      AttachmentsState(
        items: [
          for (final a in state.items)
            if (a.id != id) a,
        ],
      ),
    );
  }

  /// Moves the photo at [oldIndex] to [newIndex] (the index it ends up at,
  /// after the move). The order is the post's media order.
  void reorder(int oldIndex, int newIndex) {
    final items = [...state.items];
    if (oldIndex < 0 ||
        oldIndex >= items.length ||
        newIndex < 0 ||
        newIndex >= items.length ||
        oldIndex == newIndex) {
      return;
    }
    items.insert(newIndex, items.removeAt(oldIndex));
    if (!isClosed) emit(AttachmentsState(items: items));
  }

  /// Moves photo [id] one place towards the start ([delta] -1) or the end (+1).
  void move(String id, int delta) {
    final at = state.items.indexWhere((a) => a.id == id);
    if (at < 0) return;
    reorder(at, at + delta);
  }

  /// The editor's Done: sets the alt text and, when [edit] differs from the
  /// photo's current edit, reprocesses the SOURCE with it. A photo that was
  /// already uploaded loses that upload (the next Post uploads the new
  /// pixels); a still-running processing of the old edit is cancelled. GIFs
  /// only take the alt text. Does nothing while the photo uploads.
  void applyEdit(String id, PhotoEdit edit, String altText) {
    final at = state.items.indexWhere((a) => a.id == id);
    if (at < 0) return;
    final item = state.items[at];
    if (item.status == AttachmentStatus.uploading) return;
    setAltText(id, altText);
    final source = _sources[id];
    if (item.isGif || source == null || edit == editOf(id)) return;
    _edits[id] = edit;
    _cancelProcessing(id);
    // Whatever was reserved or published for the old pixels is stale.
    _uploader.forget(id);
    _update(
      id,
      (a) => a.copyWith(
        status: AttachmentStatus.processing,
        mediaId: '',
        progress: 0,
        rejectionReason: '',
      ),
    );
    unawaited(_process(id, source, edit: edit));
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
  ///
  /// [stillWanted] (else the one given to [stopWhen]) is asked before each
  /// request of the upload; once it answers false (the session ended) no
  /// further request starts and an [UploadInterruptedException] is thrown.
  Future<UploadedAttachments> uploadAll({bool Function()? stillWanted}) async {
    final items = state.items;
    // Photos that already finished uploading (also restored ones) keep their
    // media id: nothing is uploaded for them again.
    final done = {
      for (final a in items)
        if (a.status == AttachmentStatus.uploaded && a.mediaId.isNotEmpty) a.id,
    };
    final jobs = [
      for (final a in items)
        if (a.image != null && !done.contains(a.id))
          UploadJob(id: a.id, image: a.image!),
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
      outcomes = jobs.isEmpty
          ? const <UploadOutcome>[]
          : await _uploader.upload(
              purpose: pb.MediaPurpose.MEDIA_PURPOSE_POST,
              jobs: jobs,
              stillWanted: stillWanted ?? _stillWanted,
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
      if (done.contains(a.id)) {
        mediaIds.add(a.mediaId);
        alts.add(a.altText);
        continue;
      }
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

  /// Whether uploads may still go on, set by the composer that owns these
  /// photos (its session has not ended). Asked by [uploadAll] and by the
  /// tile's Retry ([retryCheck]), which the grid calls directly.
  bool Function()? _stillWanted;

  /// Stops every later upload request, of [uploadAll] and of the tile's Retry,
  /// once [stillWanted] answers false.
  void stopWhen(bool Function() stillWanted) => _stillWanted = stillWanted;

  /// The tile's Retry: FinalizeUpload again for
  /// the same media id. The uploader remembers the finished PUTs, so nothing
  /// is re-uploaded and no upload quota is spent. [stillWanted] (else the one
  /// given to [stopWhen]) stops its repeats like [uploadAll]'s.
  Future<void> retryCheck(String id, {bool Function()? stillWanted}) async {
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
        stillWanted: stillWanted ?? _stillWanted,
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

  /// Puts already processed photos back (an unsent post restored after the
  /// app restarted): each is ready to upload, nothing is re-processed and no
  /// original file is needed. A GIF keeps its GIF kind.
  ///
  /// A photo with a [mediaId] finished uploading before: it comes back as
  /// uploaded with that id, and [uploadAll] does not upload it again (a new
  /// upload would be a different media id, and a resend under the same
  /// idempotency key must carry the same ones).
  void restore(
    List<({ProcessedImage image, String altText, String mediaId})> photos, {
    bool gif = false,
  }) {
    if (isClosed) return;
    emit(
      AttachmentsState(
        items: [
          for (final p in photos)
            Attachment(
              id: _uuid.v4(),
              kind: gif ? AttachmentKind.gif : AttachmentKind.photo,
              status: p.mediaId.isEmpty
                  ? AttachmentStatus.ready
                  : AttachmentStatus.uploaded,
              image: p.image,
              altText: p.altText,
              mediaId: p.mediaId,
              progress: p.mediaId.isEmpty ? 0 : 1,
            ),
        ],
      ),
    );
  }

  /// The server no longer has the uploads (MEDIA_NOT_READY): every photo that
  /// counted as uploaded goes back to ready, without its media id, and the
  /// uploader forgets its finished work, so the next [uploadAll] uploads the
  /// bytes again instead of sending the dead ids once more.
  void markNotUploaded() {
    if (isClosed) return;
    final stale = [
      for (final a in state.items)
        if (a.status == AttachmentStatus.uploaded) a,
    ];
    if (stale.isEmpty) return;
    for (final a in stale) {
      _uploader.forget(a.id);
    }
    emit(
      AttachmentsState(
        items: [
          for (final a in state.items)
            if (a.status == AttachmentStatus.uploaded)
              Attachment(
                id: a.id,
                kind: a.kind,
                status: AttachmentStatus.ready,
                image: a.image,
                altText: a.altText,
              )
            else
              a,
        ],
      ),
    );
  }

  /// Drops everything (after a post succeeded).
  void clear() {
    _cancelProcessing();
    _sources.clear();
    _previews.clear();
    _edits.clear();
    emit(const AttachmentsState());
  }

  bool _retained = false;
  bool _closeRequested = false;

  /// Keeps this cubit open past its screen: the post sender uploads the
  /// photos after the composer closed. A [close] while retained is deferred
  /// until [release].
  void retain() => _retained = true;

  /// The sender hands the photos back to a composer (Edit): no longer
  /// retained and no close is pending, the new screen owns the cubit.
  void reclaim() {
    _retained = false;
    _closeRequested = false;
  }

  /// The sender is done with the photos; closes the cubit when its screen
  /// already asked to.
  Future<void> release() {
    _retained = false;
    return _closeRequested ? close() : Future.value();
  }

  /// Leaving the composer stops any photo still being prepared.
  @override
  Future<void> close() {
    if (_retained) {
      _closeRequested = true;
      return Future.value();
    }
    _cancelProcessing();
    _sources.clear();
    _previews.clear();
    _edits.clear();
    return super.close();
  }
}
