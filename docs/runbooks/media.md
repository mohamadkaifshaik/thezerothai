# Runbook: media (images, avatars, SafeSearch)

Owner: backend. Slice P4, ADR-0005. Flag: `FEATURE_MEDIA` (off | allowlist | percent | on). Plan: `docs/plans/media-uploads.md`.

## Switches (all environment variables, no redeploy of code)
| Variable | Default | Effect |
|---|---|---|
| `FEATURE_MEDIA`, `FEATURE_MEDIA_ALLOWLIST`, `FEATURE_MEDIA_PERCENT` | off | MediaService, CreatePost `media_ids`, UpdateProfile avatar. Off answers FEATURE_DISABLED / MEDIA_NOT_READY |
| `DEGRADED_MODE=nomedia` | off | CreateUpload and FinalizeUpload answer UNAVAILABLE + DEGRADED_MODE; text posting and attaching READY images continue |
| `VISION_MONTHLY_CAP` | 10000 | Most SafeSearch units per calendar month (UTC). 0 = never call Vision |
| `VISION_EXHAUSTED_POLICY` | `unscreened_established` | At the cap: accounts older than 7 days publish unscreened, newer ones are rejected. `reject` rejects everyone |
| `VISION_SCREEN_THUMB` | true | 2 units per image (full + thumbnail). `false` halves Vision spend and leaves the thumbnail unscreened |
| `QUOTA_MEDIA_PER_DAY` / `QUOTA_NEW_ACCOUNT_MEDIA_PER_DAY` | 20 / 5 | Images per user per IST day |
| `MEDIA_UPLOAD_BUCKET`, `MEDIA_BUCKET`, `MEDIA_PUBLIC_BASE_URL` | `<proj>-media-upload`, `<proj>-media`, `https://storage.googleapis.com/<MEDIA_BUCKET>` | Private upload bucket (2-day lifecycle), public-read bucket, URL prefix put in posts |

## Failure modes
### Vision spend is climbing (cost alert, or `vision_cap_exhausted=true` in request logs)
1. Read the month's counter: Firestore `admin/vision-<yyyymm>.units`. Each unit is about $0.0015 past the first 1,000.
2. Abuse wave: set `DEGRADED_MODE=nomedia` (see `cost-spike.md`). Uploads stop within one deploy; existing images keep serving.
3. Just growth: lower `VISION_MONTHLY_CAP` or set `VISION_SCREEN_THUMB=false`. The counter is cached 60 s per instance and
   there are at most 3 instances, so the cap can be overshot by a few units, never by orders of magnitude.
4. Once the cap is spent, `READY_UNSCREENED` images exist. Review reports against them first; there is no automated
   re-screen. List them: `media` where `status == READY_UNSCREENED` (add a `Limit`).

### FinalizeUpload returns UNAVAILABLE ("image checks are temporarily unavailable")
Vision (or its credentials) failed. Nothing was published and the image is still PENDING, so the client may retry.
Check the Vision API is enabled in the project and the runtime service account can read the upload bucket. If it persists
for hours, set `VISION_MONTHLY_CAP=0` only if you accept unscreened publishing for established accounts (D7).

### A deleted post's images are still served
`post_delete` failed or was never published (`post_delete_job_publish_failed` in Error Reporting).
1. Find the post's media: Firestore `media` where `postId == <id>` (Limit 4).
2. Delete the public objects `m/<mediaId>.<ext>` and `m/<mediaId>_t.<ext>`, then the media docs. Or re-publish
   `{"kind":"post_delete","uid":"<uid>","postId":"<postId>","mediaIds":[...]}` to the jobs topic: the job refuses while the
   post exists and is idempotent.
3. Messages that exhaust retries go to the jobs dead-letter subscription; the same message can be re-published.

### Orphaned uploads
PENDING and REJECTED documents are removed by the Firestore TTL (48 h) and the upload bucket's lifecycle rule deletes the
objects after 2 days. No action. If the bucket grows, check the lifecycle rule is applied (`terraform plan`).

### Storage growth
Replaced avatars are not deleted until the account is (plan D10). If `<proj>-media` approaches 4 GB, add `avatarMediaId`
to `users` and delete the previous avatar on change (one extra read and a job message per avatar change).

## Verification after enabling `FEATURE_MEDIA` for the allowlist (dev project, real GCS)
1. CreateUpload returns signed URLs; PUT both files with the returned headers; FinalizeUpload returns READY with a
   `thumb_url`.
2. CreatePost with the media id; GetPost shows `media[0].thumb_url`; open the image URL (public, immutable cache).
3. DeletePost; within a minute `m/<id>.<ext>` returns 404 and `media/<id>` is gone.
4. Check one request log line per RPC: `fs_reads`/`fs_writes` within `docs/plans/media-uploads.md`.
