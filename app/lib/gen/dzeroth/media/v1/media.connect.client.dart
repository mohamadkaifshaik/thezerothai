//
//  Generated code. Do not modify.
//  source: dzeroth/media/v1/media.proto
//

import "package:connectrpc/connect.dart" as connect;
import "media.pb.dart" as dzerothmediav1media;
import "media.connect.spec.dart" as specs;

extension type MediaServiceClient (connect.Transport _transport) {
  /// Reserve 1-4 media ids and get signed PUT URLs (full + thumb each), 10-minute TTL, bound to the exact object
  /// path, Content-Type, Content-MD5 and x-goog-content-length-range (full <= 2 MiB, thumb <= 256 KiB).
  /// A purpose other than POST or AVATAR (UNSPECIFIED, or the removed value 3) => INVALID_ARGUMENT + VALIDATION,
  /// metadata["field"] = "purpose".
  /// No daily upload quota: only the per-minute bucket limits how often a user can call it. Rejected with
  /// DEGRADED_MODE when DEGRADED_MODE != off.
  /// Batch: Create idempotency doc + media docs (PENDING, expireAt = now + 2 d).
  /// GCS: 0 ops here (signing uses IAM signBlob, no GCS call). Client PUTs = 2 Class A per image.
  /// GIF (FEATURE_GIF, wire name "gif"): content_type "image/gif" while gif is not enabled for the caller
  /// => FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "gif", before any lookup. POST purpose only (AVATAR =>
  /// VALIDATION field "content_type"); exactly one item in a request that carries a GIF (else VALIDATION field
  /// "items"); full <= 2 MiB (the same signed range); declared width and height <= 1,280; thumb_content_type must be
  /// "image/jpeg" or "image/webp" (else VALIDATION field "thumb_content_type").
  Future<dzerothmediav1media.CreateUploadResponse> createUpload(
    dzerothmediav1media.CreateUploadRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MediaService.createUpload,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Verify and moderate uploaded objects, then publish. Per item: GCS object attrs + 512-byte ranged read
  /// (magic bytes) -> SafeSearch on every image, always (the full image, plus the thumbnail when VISION_SCREEN_THUMB
  /// is on, the default) -> copy full+thumb to the public bucket -> READY; or REJECTED (objects deleted). Nothing is
  /// published unscreened: when screening cannot be done (Vision quota or outage, timeout) the call answers the
  /// retryable UNAVAILABLE and the image stays PENDING, and it is REJECTED once its attempts are used up. AVATAR uses
  /// the stricter Racy rule.
  /// Naturally idempotent: items already READY, READY_UNSCREENED or REJECTED are returned as-is.
  /// GCS per image: 2 Class A (copies) + 4 Class B (attrs and a ranged read of the full image and of the
  /// thumbnail) + 1-2 Vision fetches; deletes are free.
  /// The month's Vision usage counter is only a cost meter; it never limits screening. Per item the call writes one screening claim and one resolve, or a claim and a
  /// release after a failed attempt. One call per image screens at a time: a concurrent call answers MEDIA_NOT_READY (retry) or the winner's result, with no Vision spend.
  /// GIF: Cloud Vision screens only the first frame of an animated GIF, so after the checks above the
  /// server reads the whole uploaded GIF (<= 2 MiB, +1 Class B), refuses it before decoding when it has more than 300
  /// frames, a logical screen above 1,280 on either side or more than 50,000,000 frame pixels in total, samples 4
  /// frames over its display time into one contact sheet and screens the sheet (by bytes) and the thumbnail (by URI):
  /// 2 Vision units, as for a photo. The worse verdict wins. Refused or blocked => REJECTED ("This GIF is too large or
  /// too long" for the limits), objects deleted. One GIF screens at a time per instance: a call that cannot start within 5 s answers
  /// MEDIA_NOT_READY (retry), with no Vision spend. The thumbnail is checked against thumb_content_type and published
  /// with it; the full GIF is published unchanged.
  /// Screening failures (behaviour arrives later): the screening UNAVAILABLE ("image checks
  /// are temporarily unavailable") carries retry_after (5 s); retry the same FinalizeUpload with the same media id, no
  /// re-upload. RESOURCE_EXHAUSTED + RATE_LIMITED with metadata["limit"] = "media_vision_units_daily" is the per-user daily
  /// Vision-units cap (refused before any claim, nothing written, retry_after to IST midnight; do not retry sooner). A
  /// media item is REJECTED with reason "attempts" after 3 attempts that produced a valid assessment, or 8 claims in total;
  /// its objects are deleted. A busy GIF slot consumes no attempt.
  Future<dzerothmediav1media.FinalizeUploadResponse> finalizeUpload(
    dzerothmediav1media.FinalizeUploadRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MediaService.finalizeUpload,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
