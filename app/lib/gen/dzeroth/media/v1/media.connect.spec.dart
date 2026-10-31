//
//  Generated code. Do not modify.
//  source: dzeroth/media/v1/media.proto
//

import "package:connectrpc/connect.dart" as connect;
import "media.pb.dart" as dzerothmediav1media;

abstract final class MediaService {
  /// Fully-qualified name of the MediaService service.
  static const name = 'dzeroth.media.v1.MediaService';

  /// Reserve 1-4 media ids and get signed PUT URLs (full + thumb each), 10-minute TTL, bound to the exact object
  /// path, Content-Type, Content-MD5 and x-goog-content-length-range (full <= 2 MiB, thumb <= 256 KiB; BANNER:
  /// full <= 1 MiB, thumb <= 128 KiB, ADR-0024 D1).
  /// BANNER needs FEATURE_MEDIA and FEATURE_PROFILE_EXTRAS on for the caller, else FAILED_PRECONDITION +
  /// FEATURE_DISABLED, metadata["feature"] = "profile_extras", 0 reads. Its one item declares width <= 1500,
  /// height <= 500 and 3 * height * 0.98 <= width <= 3 * height * 1.02, else INVALID_ARGUMENT + VALIDATION,
  /// metadata["field"] = "width" (layout hints only: the server checks magic bytes, not pixels).
  /// Quota: 20 media/day/user (quotas/{uid}), shared by every purpose. Rejected with DEGRADED_MODE when
  /// DEGRADED_MODE != off.
  /// Batch: Create idempotency doc + media docs (PENDING, expireAt = now + 2 d) + quotas.
  /// GCS: 0 ops here (signing uses IAM signBlob, no GCS call). Client PUTs = 2 Class A per image.
  /// Firestore: reads 2/1 (quotas + replay), writes 6/3 (1 image typical).
  /// GIF (ADR-0029 D10; FEATURE_GIF, wire name "gif"): content_type "image/gif" while gif is not enabled for the caller
  /// => FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "gif", 0 reads. POST purpose only (AVATAR and
  /// BANNER => VALIDATION field "content_type"); exactly one item in a request that carries a GIF (else VALIDATION field
  /// "items"); full <= 2 MiB (the same signed range); declared width and height <= 1,280; thumb_content_type must be
  /// "image/jpeg" or "image/webp" (else VALIDATION field "thumb_content_type"). Same Firestore cost as a photo.
  static const createUpload = connect.Spec(
    '/$name/CreateUpload',
    connect.StreamType.unary,
    dzerothmediav1media.CreateUploadRequest.new,
    dzerothmediav1media.CreateUploadResponse.new,
  );

  /// Verify and moderate uploaded objects, then publish. Per item: GCS object attrs + 512-byte ranged read
  /// (magic bytes) -> SafeSearch on every image while the monthly Vision counter is below VISION_MONTHLY_CAP
  /// (default 10,000, ADR-0005 amendment; the full image, plus the thumbnail when VISION_SCREEN_THUMB is on, the
  /// default) -> copy full+thumb to the public bucket -> READY; or REJECTED (objects deleted). Counter exhausted =>
  /// READY_UNSCREENED for accounts older than 7 days and REJECTED for newer ones, or REJECTED for everyone when
  /// VISION_EXHAUSTED_POLICY=reject (ADR-0005). AVATAR and BANNER use the stricter Racy rule (ADR-0024 D1).
  /// Naturally idempotent: items already READY/REJECTED are returned as-is.
  /// GCS per image: 2 Class A (copies) + 4 Class B (attrs and a ranged read of the full image and of the
  /// thumbnail) + 1-2 Vision fetches; deletes are free.
  /// Firestore: reads 2n+1 worst case (n media docs, Vision counter cached 60 s, +1 per item when the upload
  /// is missing, screening fails or a concurrent finalize race is lost), plus 1 interceptor read; writes 2n+1 (per item one
  /// screening claim and one resolve, or claim and release after a failed attempt; plus the Vision counter). One call per
  /// image screens at a time: a concurrent call answers MEDIA_NOT_READY (retry) or the winner's result, with no Vision spend.
  /// GIF (ADR-0029 D11): Cloud Vision screens only the first frame of an animated GIF, so after the checks above the
  /// server reads the whole uploaded GIF (<= 2 MiB, +1 Class B), refuses it before decoding when it has more than 300
  /// frames, a logical screen above 1,280 on either side or more than 50,000,000 frame pixels in total, samples 4
  /// frames over its display time into one contact sheet and screens the sheet (by bytes) and the thumbnail (by URI):
  /// 2 Vision units, as for a photo. The worse verdict wins. Refused or blocked => REJECTED ("This GIF is too large or
  /// too long" for the limits), objects deleted. At the Vision cap a GIF is REJECTED for every account, never
  /// READY_UNSCREENED. One GIF screens at a time per instance: a call that cannot start within 5 s answers
  /// MEDIA_NOT_READY (retry), with no Vision spend. The thumbnail is checked against thumb_content_type and published
  /// with it; the full GIF is published unchanged. Firestore cost as above.
  /// Screening failures (ADR-0029 Amendment 1 A5; behaviour arrives with W6-40): the screening UNAVAILABLE ("image checks
  /// are temporarily unavailable") carries retry_after (5 s); retry the same FinalizeUpload with the same media id, no
  /// re-upload. RESOURCE_EXHAUSTED + RATE_LIMITED with metadata["limit"] = "media_vision_units_daily" is the per-user daily
  /// Vision-units cap (refused before any claim, nothing written, retry_after to IST midnight; do not retry sooner). A
  /// media item is REJECTED with reason "attempts" after 3 attempts that produced a valid assessment, or 8 claims in total;
  /// its objects are deleted. A busy GIF slot consumes no attempt.
  static const finalizeUpload = connect.Spec(
    '/$name/FinalizeUpload',
    connect.StreamType.unary,
    dzerothmediav1media.FinalizeUploadRequest.new,
    dzerothmediav1media.FinalizeUploadResponse.new,
  );
}
