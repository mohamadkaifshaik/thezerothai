---
name: media-pipeline
description: Free-tier image upload, validation, moderation and delivery flow across Flutter, the Go media module and GCS. Use for any media feature.
---

# Media pipeline (Stage 0: images only)

```
Flutter: pick → resize + re-encode on device (full ≤ 1600 px WebP/JPEG q75, thumb 400 px) → strips EXIF
Client ──CreateUpload(count, sizes, types, sha256)──▶ API (media module)
   ├─ checks quota (20 uploads/day/user) and DEGRADED_MODE
   ├─ writes media/{id} status=PENDING (expireAt = now+2d, TTL)
   └─ returns 2 V4 signed PUT URLs (full + thumb), 10 min TTL, bound to exact object, Content-Type and
      x-goog-content-length-range: 0,2097152 (full) / 0,262144 (thumb)
Client ──PUT──▶ gs://<proj>-media-upload/u/<uid>/<mediaId>.webp  and  .../<mediaId>_t.webp
Client ──FinalizeUpload(mediaId)──▶ API: object metadata check (size, content-type, magic bytes via 512-byte ranged read)
   → SafeSearch on every image (paid past free 1,000/month; if counter ≥ VISION_MONTHLY_CAP, apply VISION_EXHAUSTED_POLICY — ADR-0005)
   → status READY (copy to public bucket) | REJECTED (delete objects)
CreatePost(media_ids) → posts module verifies ownership + READY, stores url/thumbUrl/w/h/blurhash in the post
Delivery: public-read objects at https://storage.googleapis.com/<bucket>/..., Cache-Control: public, max-age=31536000, immutable
```

Why no server-side resize worker: re-encoding on device is free, already strips EXIF, and saves Cloud Run CPU.
The server still never trusts the client: it enforces size caps via the signed URL, verifies type by magic bytes, and moderates.

## Limits (enforced server-side)
Images ≤ 4 per post; full ≤ 2 MB, thumb ≤ 256 KB after client compression; jpeg/png/webp/heic input accepted on device.
GIF (ADR-0029 D11, F11): accepted as post media only, at most 2 MiB, 1,280 px a side and 300 frames, uploaded unchanged with a still JPEG/WebP thumbnail. FinalizeUpload pre-scans it without decoding pixels (frame count, screen size, summed frame area), then decodes the frames visible at t = 0, T/4, T/2 and 3T/4 of the playback time (a delay under 2 cs counts as 10 cs, as browsers play it) into one 2 x 2 contact sheet, and screens the sheet by bytes plus the thumbnail: always 2 Vision units, REJECTED for every account at the Vision cap. One GIF decode per instance at a time (5 s wait, then retryable MEDIA_NOT_READY), 2 s decode deadline. Residual (accepted): an explicit frame shown only between samples. Not schedulable; `FEATURE_GIF` gates it. **Video: not at Stage 0** (ADR needed; first step would be ≤ 30 s MP4 compressed on device, served progressively).

## Bucket (Terraform)
Two buckets, both in `us-central1` (free storage is US-only and is shared across buckets), Standard class, uniform access, no versioning:
- `<proj>-media-upload` — **private**. Signed PUT URLs point here. Lifecycle: delete after 2 days.
- `<proj>-media` — **public-read** (`allUsers:objectViewer`). On FinalizeUpload the API copies approved objects here
  (same-location copy: no egress, 1 Class A op each) and deletes the upload. Unmoderated content is never public.
- CORS on the upload bucket: allow PUT from the web app origin(s) with the `Content-Type` header.
- Signed URL paths in the flow above therefore read `gs://<proj>-media-upload/...` for uploads and `<proj>-media` for delivery.

## Budget
~300 KB per image pair. 5 GB free ≈ 15k images. Egress 100 GB/month free from NA; lists use thumbnails;
clients cache with `cached_network_image` (disk cache) so repeat views cost nothing.

## Rules
- Orphaned PENDING media: Firestore TTL deletes the doc; the upload bucket's 2-day lifecycle deletes the objects. No job needed.
- Deleting a post/account deletes its objects in the public bucket via the Pub/Sub delete job.
- Blurhash computed on device and sent in FinalizeUpload (validated for length/charset).
- Avatars use the same flow (1 image, 400 px, thumb 96 px).
- Flutter: `image_picker` + the pure-Dart `image` package (decode/resize/encode via `compute`; ADR-0005 Amendment 2026-10-17), upload with progress + retry; background upload on mobile is a Stage 1 nicety. Do not add `flutter_image_compress` (rejected unless measured HEIC failure rates justify it; it would need a security-auditor review of its web script) or a web canvas processor (only if web jank is measured).
