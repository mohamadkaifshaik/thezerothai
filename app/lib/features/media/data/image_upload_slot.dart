import 'dart:typed_data';

import '../../../core/network/app_exception.dart';
import '../../../gen/dzeroth/media/v1/media.pb.dart' as pb;
import '../domain/image_processor.dart';
import '../domain/processed_image.dart';
import 'media_uploader.dart';

/// One single-image upload on a screen, for any purpose: the picked photo
/// prepared on the device, the READY media id once it is uploaded, and the
/// retry memory behind both. Edit profile keeps one per picture (avatar,
/// banner); a later purpose adds a slot, never a second upload path.
///
/// - [choose] resizes and re-encodes the picked bytes for [imagePurpose]
///   (nothing is sent) and forgets anything remembered about the old pick.
/// - [ensureUploaded] runs CreateUpload -> PUT -> FinalizeUpload through the
///   shared [MediaUploader] **once**: the media id is remembered, so a retry
///   of a later step (UpdateProfile) never uploads again, and a retry of a
///   failed upload replays under the uploader's own key (no quota burn).
/// - One slot is one `upload()` call with one item, as AVATAR and BANNER
///   require (never batch them).
class ImageUploadSlot {
  ImageUploadSlot({
    required MediaUploader uploader,
    required ImageProcessor processor,
    required this.uploadPurpose,
    required this.imagePurpose,
    required this.jobId,
  }) : _uploader = uploader,
       _processor = processor;

  final MediaUploader _uploader;
  final ImageProcessor _processor;

  /// The `CreateUpload` purpose of this picture.
  final pb.MediaPurpose uploadPurpose;

  /// How the picked bytes are cropped and sized.
  final ImagePurpose imagePurpose;

  /// The uploader's stable local id for this picture; one per slot.
  final String jobId;

  ProcessedImage? _image;
  String? _mediaId;

  /// A picture is chosen (uploaded or not).
  bool get hasImage => _image != null;

  /// A chosen picture still has to be uploaded.
  bool get needsUpload => _image != null && _mediaId == null;

  /// The on-device thumbnail of the choice, for the preview.
  Uint8List? get preview => _image?.thumbBytes;

  /// Prepares [bytes] for upload. Throws [UnsupportedImageException] (or
  /// whatever the processor throws) for a file that cannot be used, leaving
  /// the previous choice untouched.
  Future<ProcessedImage> choose(Uint8List bytes) async {
    final image = await _processor.process(bytes, imagePurpose);
    _image = image;
    _mediaId = null;
    _uploader.forget(jobId);
    return image;
  }

  /// Forgets the choice and everything remembered about its upload.
  void discard() {
    _image = null;
    _mediaId = null;
    _uploader.forget(jobId);
  }

  /// Uploads the choice (once) and returns its READY media id, or null when
  /// nothing is chosen. Throws an [AppException]: a refusal of the image
  /// itself is a [ValidationException] (`field: media`, the server's reason)
  /// and discards the choice so another one is picked; every other failure
  /// keeps it for a retry.
  Future<String?> ensureUploaded() async {
    final image = _image;
    if (image == null) return null;
    final known = _mediaId;
    if (known != null) return known;
    final outcomes = await _uploader.upload(
      purpose: uploadPurpose,
      jobs: [UploadJob(id: jobId, image: image)],
    );
    final outcome = outcomes.single;
    switch (outcome.status) {
      case UploadOutcomeStatus.ready:
        return _mediaId = outcome.mediaId;
      case UploadOutcomeStatus.rejected:
        discard();
        throw ValidationException(
          outcome.reason.isEmpty
              ? "That photo can't be used. Choose a different one."
              : outcome.reason,
          field: 'media',
        );
      case UploadOutcomeStatus.failed:
        throw outcome.error ??
            const UnknownApiException('Upload did not finish.');
    }
  }
}
