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
  /// is missing, screening fails or a concurrent finalize race is lost), plus 1 interceptor read; writes n+1.
  static const finalizeUpload = connect.Spec(
    '/$name/FinalizeUpload',
    connect.StreamType.unary,
    dzerothmediav1media.FinalizeUploadRequest.new,
    dzerothmediav1media.FinalizeUploadResponse.new,
  );
}
