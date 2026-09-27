# 0005. Images via client-side resize, V4 signed PUT to GCS (us-central1), SafeSearch on every image
Status: Accepted
Date: 2026-09-26 (amended 2026-09-27: founder chose paid screening past the free quota)
Deciders: architect, founder

## Context
Phase 1 needs ≤ 4 images per post and avatars. Stage 0 constraints: $0; media bytes never pass through the API
(rule 7); GCS free tier is **US regions only** (5 GB-months, 5,000 Class A, 50,000 Class B, 100 GB egress from North
America per month); Cloud Vision SafeSearch 1,000 units/month free; no LB/CDN (fixed cost). Users are in India, so
images travel us-central1 → India (~250 ms first byte on first view; cached on device afterwards).
Contract: `dzeroth.media.v1.MediaService` (`CreateUpload`, `FinalizeUpload`); posts reference `media_ids`.

## Options
### A. Client resize/re-encode + signed PUT to a private upload bucket + API finalize (verify, moderate, copy to public bucket) (chosen)
- Pros: zero Cloud Run CPU for image processing; EXIF stripped on device; server still verifies size (signed length
  range + MD5), type (magic bytes) and content (SafeSearch) before anything is public; everything scales to zero.
- Cons: 4 Class A ops per image (2 PUTs + 2 copies) against a 5,000/month free allowance → ~1,250 images/month free;
  image first-view latency from the US; clients must implement compression + blurhash.
- Cost: idle $0; at 300 DAU (≈ 60 images/day ≈ 1,800/month): 7,200 Class A (2,200 over ≈ $0.01), Class B from
  views ≈ 275k/month (≈ $0.09), egress ≈ 20–40 GB (free), storage < 1 GB (free) → **≈ $0.10/month**.
  At 10× (3k DAU): ≈ $1–2/month GCS ops + ~$5–15/month egress once past 100 GB.

### B. Upload through the API, resize server-side (Go image libs)
- Pros: full control over output.
- Cons: bytes through Cloud Run (violates rule 7), CPU-heavy decode/encode inflates vCPU-s and latency, 32 MiB request
  limit, API egress/ingress on the hot path.
- Cost: ~1–2 vCPU-s per image → 1,800 images ≈ 3k vCPU-s/month (free), but request timeouts and memory spikes on a
  512 MiB instance make it fragile.

### C. Single public bucket with unguessable paths, moderate after publish
- Pros: saves 2 Class A copies per image (~50% of Class A).
- Cons: unmoderated content is publicly reachable (the URL is returned to the uploader and may be shared) — safety risk.
- Cost: saves ≈ $0.01/month at 300 DAU. Not worth the risk.

## Cost impact
- Fixed monthly cost added: **$0**.
- Pay-per-use added (founder decision 2026-09-27): SafeSearch beyond the free 1,000 units/month at ~$1.50/1,000
  images (verify current price) → ≈ $1.20/month at 300 DAU, ≈ $7.50 at 1k DAU. Bounded by `VISION_MONTHLY_CAP`.
- Free-tier quota consumed at 300 DAU: Firestore ≈ 1 read + 1.6 writes per DAU/day (media docs, idempotency, quotas,
  Vision counter); GCS Class A ≈ 7.2k/month (144% of free → cents), Class B ≈ 275k/month (550% of free → cents),
  storage ≈ 0.5 GB/month growth, egress ≈ 20–40 GB/month (≤ 40% of free); Vision ≈ 1,800 units/month demand vs
  1,000 free → ~800 paid units at 300 DAU (every image screened).
- Triggers: Vision spend > $10/month or `VISION_MONTHLY_CAP` hit → revisit cap / alternatives (ADR);
  egress > 100 GB/month or image latency complaints → ADR (Firebase Hosting/CDN options, second bucket region);
  video demanded → separate ADR.

## Decision
Option A:
- **Client:** pick → re-encode on device (full ≤ 1600 px, thumb 400 px; avatars 400/96 px), WebP (JPEG fallback),
  q≈75, EXIF stripped; compute MD5 (base64) and BlurHash; `CreateUpload` → PUT both files with the exact returned
  headers → `FinalizeUpload` → `CreatePost(media_ids, media_alt_texts)`.
- **Buckets (us-central1, Standard, uniform access, no versioning):** `<proj>-media-upload` private, lifecycle delete
  after 2 days, CORS PUT from the web origins; `<proj>-media` public-read (`allUsers:roles/storage.objectViewer`),
  objects `m/<mediaId>.<ext>` and `m/<mediaId>_t.<ext>` with `Cache-Control: public, max-age=31536000, immutable`.
- **Signed URLs:** V4, PUT, TTL 10 min, bound to object path, `Content-Type`, `Content-MD5` and
  `x-goog-content-length-range` (full 0–2,097,152; thumb 0–262,144). Signed with the runtime SA via IAM `signBlob`
  (no key files); the SA needs `roles/iam.serviceAccountTokenCreator` on itself.
- **Finalize:** object attrs (size, content type, MD5) + 512-byte ranged read for magic bytes (JPEG/WebP only) →
  SafeSearch on the full image for **every** upload; `admin/vision-{yyyymm}` counts units for cost metering and
  the safety cap (counter cached 60 s; ≤ 3 instances may overshoot by a few units) → LIKELY/VERY_LIKELY adult/violence/racy(avatars) = REJECTED + objects
  deleted; else copy both to the public bucket, delete uploads, status READY, clear `expireAt`.
- **Paid screening (founder decision 2026-09-27):** past the free 1,000 units we keep screening and pay per use.
  Runaway-bill guard: `VISION_MONTHLY_CAP` (default 10,000 units ≈ $13.50/month, covers ~1,600 DAU). Only if the cap is hit does the fallback
  apply: accounts older than 7 days with no upheld reports get `READY_UNSCREENED` (published, queued for
  report-driven review); newer accounts get `REJECTED` ("image uploads temporarily limited") until the 1st.
  Config: `VISION_MONTHLY_CAP`, `VISION_EXHAUSTED_POLICY`. Raising the cap is a config change, reviewed like logic.
- **Limits:** 4 images/post, 20 media/day/user (`quotas/{uid}`), GIF → static first frame, no video.
- **Orphans:** PENDING docs expire via Firestore TTL (2 days); upload objects via bucket lifecycle. No sweeper job.
- **Deletes:** post/account delete jobs delete public objects (deletes are free ops).
- **Degraded:** `DEGRADED_MODE=nomedia|readonly` → `CreateUpload` returns UNAVAILABLE + `ERROR_REASON_DEGRADED_MODE`;
  text posting continues under `nomedia`.

## Consequences
- Positive: $0–cents; no image-processing servers; every image is screened before it is public (except `READY_UNSCREENED` for
  established accounts if `VISION_MONTHLY_CAP` is ever hit).
- Negative: US-hosted images add first-view latency for Indian users; Class A/B ops exceed free allowances early
  (cents); Vision becomes a small per-use line item past ~160 DAU.
- Follow-up: runbook `docs/runbooks/media-moderation.md` (Vision exhausted, abuse wave → `nomedia`).
- Revisit when: any trigger above fires, or GCS bill > $5/month.

## Handoff
- backend-developer: `internal/media` with `Signer`, `ObjectStore`, `Moderator` interfaces (GCS/Vision impls + fakes);
  magic-byte check; policy knob; `media.Reader` interface for posts to verify ownership + READY in `CreatePost`.
- frontend-developer: `image_picker` + `flutter_image_compress`, MD5 + BlurHash on device, upload with progress and
  retry (reuse the same idempotency key and URLs until they expire, then call `CreateUpload` again with a new key);
  lists render `thumb_url` via `cached_network_image`.
- production-deployer: two buckets in us-central1 (lifecycle, CORS, IAM as above, `force_destroy = false`), Vision API
  enabled, runtime SA roles: objectAdmin on both buckets, tokenCreator on itself.
- tester: emulator tests for oversize/wrong-type/MD5-mismatch rejects, Vision cap cut-over at `VISION_MONTHLY_CAP` (fake moderator),
  replayed Finalize, TTL cleanup of PENDING docs.
