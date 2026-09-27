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
  /// path, Content-Type, Content-MD5 and x-goog-content-length-range (full <= 2 MiB, thumb <= 256 KiB).
  /// Quota: 20 media/day/user (quotas/{uid}). Rejected with DEGRADED_MODE when DEGRADED_MODE != off.
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
  /// (magic bytes) -> SafeSearch on the full image if the monthly Vision counter < 950 -> copy full+thumb to the
  /// public bucket -> READY; or REJECTED (objects deleted). Counter exhausted => READY_UNSCREENED (policy knob,
  /// ADR-0005). Naturally idempotent: items already READY/REJECTED are returned as-is.
  /// GCS per image: 2 Class A (copies) + 3 Class B (attrs, ranged read, Vision fetch); deletes are free.
  /// Firestore: reads 5/2 (media docs + Vision counter, cached 60 s), writes 5/2.
  static const finalizeUpload = connect.Spec(
    '/$name/FinalizeUpload',
    connect.StreamType.unary,
    dzerothmediav1media.FinalizeUploadRequest.new,
    dzerothmediav1media.FinalizeUploadResponse.new,
  );
}
