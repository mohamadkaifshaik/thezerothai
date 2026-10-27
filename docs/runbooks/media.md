# Runbook: media (images, avatars, banners, SafeSearch)

Owner: backend. Slice P4, ADR-0005. Flag: `FEATURE_MEDIA` (off | allowlist | percent | on). Plan: `docs/plans/media-uploads.md`.

## Switches (all environment variables, no redeploy of code)
| Variable | Default | Effect |
|---|---|---|
| `FEATURE_MEDIA`, `FEATURE_MEDIA_ALLOWLIST`, `FEATURE_MEDIA_PERCENT` | off | MediaService, CreatePost `media_ids`, UpdateProfile avatar. Off answers FEATURE_DISABLED / MEDIA_NOT_READY. `off` (not allowlist or percent) also holds scheduled posts that carry images PENDING instead of publishing them: `docs/runbooks/posts.md` section 12, "Images held while `FEATURE_MEDIA` is off" |
| `DEGRADED_MODE=nomedia` | off | CreateUpload and FinalizeUpload answer UNAVAILABLE + DEGRADED_MODE; text posting and attaching READY images continue |
| `FEATURE_PROFILE_EXTRAS`, `FEATURE_PROFILE_EXTRAS_ALLOWLIST`, `FEATURE_PROFILE_EXTRAS_PERCENT` | off | Gates `CreateUpload(purpose=BANNER)` (needs `media` on too; W3-5): off for the caller answers FEATURE_DISABLED `feature=profile_extras` with 0 reads and nothing signed. AVATAR and POST uploads and every `FinalizeUpload` ignore it, so a banner upload started before the flag was lowered still completes. Also gates the UpdateProfile banner, location, website and pin fields (ADR-0024 D9, W3-6). Details in `docs/runbooks/posts.md` |
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

### Web uploads show "No connection" but CreateUpload returned 200
CreateUpload succeeds in the logs, no FinalizeUpload follows, and the browser console shows a CORS preflight error for the
`storage.googleapis.com/<bucket>-media-upload/...` PUT (mobile apps are unaffected: no CORS). Cause: a header the signed PUT
sends is not in the upload bucket's CORS `responseHeader` list. Cloud Storage matches exact names only; `x-goog-*` does not
expand. Check with `gcloud storage buckets describe gs://<project>-media-upload --format='json(cors_config)'`; the list must
hold `Content-Type`, `Content-MD5` and `x-goog-content-length-range`, and the request origin must be in `origin`. Fix in
`infra/terraform/modules/media-buckets/main.tf` (plan, then apply). `objstore_cors_test.go` fails CI if the two drift.

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

### Banners (ADR-0024 D1, W3-5)
A BANNER is one image per `CreateUpload` (declared width <= 1500, height <= 500, 3:1 within 2%), with its own byte caps bound
into the signed URLs: full <= 1 MiB, thumb <= 128 KiB (POST and AVATAR keep 2 MiB / 256 KiB). `FinalizeUpload` always screens
full and thumb for a BANNER (2 Vision units, whatever `VISION_SCREEN_THUMB` says) and blocks LIKELY racy, like an avatar. A
rejected banner is `REJECTED` with reason `policy`; at the Vision cap `VISION_EXHAUSTED_POLICY` applies unchanged (one unit left
is not enough for a banner: an established account publishes it `READY_UNSCREENED`). Banners share the 20/day `uploads` quota.
The request log lines carry `purpose` (`POST`, `AVATAR`, `BANNER`; `MIXED` on a finalize that spans purposes) and, on
FinalizeUpload, `vision_units`. To see banner Vision spend, filter FinalizeUpload lines on `purpose=BANNER` and sum `vision_units`.

### Storage growth
Replaced avatars are not deleted until the account is (plan D10), and neither are replaced or removed banners (ADR-0024 D1,
Option 5A; the account purge deletes every media doc and object of the user, banners included). If `<proj>-media` approaches
2.5 GB (50% of the 5 GB free tier, the ADR-0024 D10 trigger) or 4 GB, add `avatarMediaId` / `bannerMediaId` to `users` and
delete the previous image on change (one extra read and a job message per change; ADR-0024 Option 5B for banners).

## Verification after enabling `FEATURE_MEDIA` for the allowlist (dev project, real GCS)
1. CreateUpload returns signed URLs; PUT both files with the returned headers; FinalizeUpload returns READY with a
   `thumb_url`.
2. CreatePost with the media id; GetPost shows `media[0].thumb_url`; open the image URL (public, immutable cache).
3. DeletePost; within a minute `m/<id>.<ext>` returns 404 and `media/<id>` is gone.
4. Check one request log line per RPC: `fs_reads`/`fs_writes` within `docs/plans/media-uploads.md`.
