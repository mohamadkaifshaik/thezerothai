# Runbook: media (images, avatars, banners, SafeSearch)

Owner: backend. Slice P4, ADR-0005. Flag: `FEATURE_MEDIA` (off | allowlist | percent | on). Plan: `docs/plans/media-uploads.md`.

## Switches (all environment variables, no redeploy of code)
| Variable | Default | Effect |
|---|---|---|
| `FEATURE_MEDIA`, `FEATURE_MEDIA_ALLOWLIST`, `FEATURE_MEDIA_PERCENT` | off | MediaService, CreatePost `media_ids`, UpdateProfile avatar. Off answers FEATURE_DISABLED / MEDIA_NOT_READY. `off` (not allowlist or percent) also holds scheduled posts that carry images PENDING instead of publishing them: `docs/runbooks/posts.md` section 12, "Images held while `FEATURE_MEDIA` is off" |
| `DEGRADED_MODE=nomedia` | off | CreateUpload and FinalizeUpload answer UNAVAILABLE + DEGRADED_MODE; text posting and attaching READY images continue |
| `FEATURE_GIF`, `FEATURE_GIF_ALLOWLIST`, `FEATURE_GIF_PERCENT` | off | `CreateUpload` with an `image/gif` item (needs `media` on too; ADR-0029 D10, W6-9) and `CreatePost` with a GIF media doc. Off for the caller answers FEATURE_DISABLED `feature=gif`: at CreateUpload with 0 reads and nothing signed, at CreatePost after the media read (the content type is only known from the claim) with 0 writes. `FinalizeUpload` ignores it, so a GIF uploaded before the flag was lowered still finalizes but can no longer be posted. **Do not leave `off` until 100 % of traffic is on a revision with W6-10 (frame-sampled screening)**; see "GIFs" below |
| `FEATURE_PROFILE_EXTRAS`, `FEATURE_PROFILE_EXTRAS_ALLOWLIST`, `FEATURE_PROFILE_EXTRAS_PERCENT` | off | Gates `CreateUpload(purpose=BANNER)` (needs `media` on too; W3-5): off for the caller answers FEATURE_DISABLED `feature=profile_extras` with 0 reads and nothing signed. AVATAR and POST uploads and every `FinalizeUpload` ignore it, so a banner upload started before the flag was lowered still completes. Also gates the UpdateProfile banner, location, website and pin fields (ADR-0024 D9, W3-6). Details in `docs/runbooks/posts.md` |
| `PROFILE_MEDIA_RETIRE` | `off` | Which replaced or removed profile images are deleted 24-48 h after the change (ADR-0024 Amendment 1 A4): `off` nothing, `banner` banners only, `all` banners and avatars. Per-project retention config (Terraform `profile_media_retire`), **not** a `FEATURE_` flag. Checked by the publish (UpdateProfile) and by the `profile_media_retired` job handler, so lowering it stops new messages and makes the queued ones ack without action. Order and preconditions: section "Replaced and removed avatars and banners" below |
| `VISION_MONTHLY_CAP` | 10000 | Most SafeSearch units per calendar month (UTC). 0 = never call Vision |
| `VISION_EXHAUSTED_POLICY` | `unscreened_established` | At the cap: accounts older than 7 days publish unscreened, newer ones are rejected. `reject` rejects everyone |
| `VISION_SCREEN_THUMB` | true | 2 units per image (full + thumbnail). `false` halves Vision spend and leaves the thumbnail unscreened |
| `MEDIA_MAX_SCREEN_ATTEMPTS` | 3 (1..10) | Screening claims (FinalizeUpload attempts that reach Vision) one media document gets, counted in `media.screenAttempts` inside the claim write (W6-27, security H-3). The next call REJECTS the document with "This image could not be checked. Please upload it again." and no Vision call. Plain environment variable; not in Terraform (like the GIF caps) |
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
hold `Content-Type`, `Content-MD5`, `x-goog-content-length-range` and `x-goog-if-generation-match` (W6-25; apply the Terraform CORS change before or with the API deploy, or web uploads fail the preflight), and the request origin must be in `origin`. Fix in
`infra/terraform/modules/media-buckets/main.tf` (plan, then apply). `objstore_cors_test.go` fails CI if the two drift.

### Upload replaced after verify (W6-25, H-1)
The signed PUT is create-only (`x-goog-if-generation-match: 0`): a second PUT to the same URL gets 412 (the client treats 412 on its own retry as stored). The generation verify read is pinned on the GIF read and on the publish copy; if the object was replaced anyway, the call answers REJECTED (reason `invalid`) and the request log carries `changed_after_verify=true`; nothing is published. Pinned reads use an `ifGenerationMatch` precondition, so 412 means replaced (REJECTED) and 404 means the object vanished (retryable, not a rejection). If the store ever returns attributes without a generation, `verify` fails closed with an internal error (visible in Error Reporting) and nothing is published. A burst of these is an attack signal (look for repeated PUTs), not a bug. Cost: 0 extra GCS calls (the generation comes from the existing attrs read; the copy precondition is a parameter).

### Animated WebP refused (W6-26, security H-2)
`verify` refuses a WebP (photo, avatar, banner, GIF thumbnail; full or thumbnail object) that is animated or not provably a still: REJECTED, reason `invalid`, before any Vision unit is reserved (0 units). It walks the RIFF chunks in the pinned head: first chunk `VP8 `/`VP8L` is a still; `VP8X` with flag bit `0x02`, or any `ANIM`/`ANMF` chunk, is animated; a `VP8X` file whose `VP8 `/`VP8L` chunk is not within the head, or a truncated file, fails closed. A WebP reads 32 KiB (`webpHeadBytes`) instead of 512 bytes in the same single pinned `UploadHead` call: 0 extra GCS operations, at most 31.5 KiB more egress per WebP object. A user report "my WebP is rejected" with a still image usually means an ICC profile over about 32 KiB; the client's own uploads are JPEG and are unaffected.

### FinalizeUpload returns UNAVAILABLE ("image checks are temporarily unavailable")
Vision (or its credentials) failed. Nothing was published and the image is still PENDING, so the client may retry.
Check the Vision API is enabled in the project and the runtime service account can read the upload bucket. If it persists
for hours, set `VISION_MONTHLY_CAP=0` only if you accept unscreened publishing for established accounts (D7).

### FinalizeUpload REJECTED: "could not be used" for a good image, or "could not be checked" (W6-27, security H-3)
Two new terminal outcomes of the Vision accounting fix:
- **Vision INVALID_ARGUMENT on an image** ("Bad image data"): the file passed size, type, MD5 and magic bytes but Vision cannot
  decode it. The document is REJECTED with the generic "could not be used" reason; a retry cannot fix it. The answered call is billed
  and counted. Many of these from one account is a corrupt-thumbnail loop; from many accounts, a client encoder bug (check the
  `content_type` of the lines first).
- **Attempt cap**: after `MEDIA_MAX_SCREEN_ATTEMPTS` (3) screening claims on one document, the next FinalizeUpload REJECTS it with
  "This image could not be checked. Please upload it again." (request line `screen_attempts_exhausted=true`, `vision_units=0`).
  A Vision outage (UNAVAILABLE answers) therefore burns one attempt per retry: during one, expect honest users to hit the cap after
  3 tries and to upload again (a fresh document, a fresh count). Raise `MEDIA_MAX_SCREEN_ATTEMPTS` (max 10) only if outages are
  frequent; each attempt can bill up to 2 units. An attempt that ends in `MEDIA_NOT_READY` because another call holds the claim
  does not count (it never claims).
- **Accounting**: `vision_units` on a failed FinalizeUpload now counts every call Vision answered (a verdict or a per-image error),
  so the summed units of one media id can reach 2 x attempts. Only a call that never got a response (timeout, transport) is
  released and not counted. Spend check (step 3 of the claim section below): 1 or 2 per attempt, no more.

### FinalizeUpload answers "the upload is not complete yet" after the PUTs finished (screening claim, W3-22 M-3)
One call per image screens at a time. Before it reserves Vision units, FinalizeUpload writes `screeningUntil = now + 30 s`
on the PENDING `media/<id>` document, conditional on the document's UpdateTime (1 write per image, so a finalize is
`2n + 1` writes: claim and resolve per image, plus the Vision counter). A second call for the same image, usually a double
tap or a client retry that landed on another instance, loses that write or sees the live claim, spends nothing, and
answers the retryable `MEDIA_NOT_READY` (or the winner's READY result once the winner has finished). Calls on one
instance share a single flight and all get the same result.
1. Request log lines: `finalize_busy=true` with `outcome=rejected:upload_incomplete` and `vision_units=0` is a loser;
   `finalize_joined=true` is a same-instance call that shared the leader's result. A burst of them is a client retry
   loop, not an outage, and costs 1 to 2 reads each.
2. A claim a crashed call left behind expires on its own after 30 s; a failed attempt (Vision or GCS error) releases it, so
   the client's "try again" works at once. If a PENDING document still carries a `screeningUntil` more than a minute in the
   past or the future, delete that field in the Firestore console; nothing else is wrong with the document.
3. Spend check: summing `vision_units` over the FinalizeUpload lines of one media id must give 1 or 2 per attempt (a BANNER always 2; at most `MEDIA_MAX_SCREEN_ATTEMPTS` attempts, W6-27).
   More means a screening outlived its 30 s claim (Vision slower than its 10 s deadline plus the copies), so a second call
   screened too: look at Vision latency before raising anything.
4. Client side: the app reads `MEDIA_NOT_READY` from a finalize as "the object is missing" (`media_uploader.dart`) and re-signs and
   PUTs the image again before it retries. For a call that lost the claim that is one wasted upload (at most 1 MiB or 2 MiB
   plus the thumbnail, one Class A operation per file); the image itself is already being published by the winner. A distinct
   reason would need a proto change, so it is not done here.

### A deleted post's images are still served
`post_delete` failed or was never published (`post_delete_job_publish_failed` in Error Reporting).
1. Find the post's media: Firestore `media` where `postId == <id>` (Limit 4).
2. Delete the public objects named by the doc (`publicPath`, `thumbPath`; see "Public object names: two shapes"), then the media docs. Or re-publish
   `{"kind":"post_delete","uid":"<uid>","postId":"<postId>","mediaIds":[...]}` to the jobs topic: the job refuses while the
   post exists and is idempotent.
3. Messages that exhaust retries go to the jobs dead-letter subscription; the same message can be re-published.

### Public object names: two shapes (W3-39, W3-36 M-2)
The public bucket is public-read by exact URL, so the name is the only secret. Since W3-39 a new upload publishes as
`m/<mediaId>-<suffix>.<ext>` and `m/<mediaId>-<suffix>_t.<ext>`, where `<suffix>` is 128 bits from `crypto/rand` as 32 lowercase hex
characters, chosen at `CreateUpload` and stored as `nameSuffix` on the PENDING `media/{id}` doc (in the write that already creates
it: +0 reads, writes, deletes). Finalize (and its converge path), the eraser and the `post_delete` job derive every name from the
doc, never from the message. A doc **without** `nameSuffix` (created before W3-39) keeps `m/<mediaId>.<ext>` and
`m/<mediaId>_t.<ext>`; old objects are not renamed (founder B1), so old URLs stay valid and stay guessable from the id.
- **Parser.** `media.ParseObjectName` accepts `^m/([0-9]{19})(?:-([0-9a-f]{32}))?(_t)?\.(jpg|webp)$`; `parseRetiredImage` also requires the
  thumbnail's suffix to equal the full image's (a mismatch is an unparseable message, acked as `refused`). Anything else (upper-case hex,
  31 or 33 characters, `_` or `-` inside the suffix) is not an image media owns.
- **Delete paths.** The eraser and `post_delete` delete the recorded paths plus both derived pairs for a doc with `nameSuffix`
  (the old pair too, covering a suffixed doc an older revision finalized and lost the race to record), and the old pair for a doc
  without. Deletes are free. The retire step tags the recorded paths plus the doc's own-shape pair only: still 2 Class A per image.
- **No log line carries a suffix or a full object name** of a new upload (ids and hashes only). If you need the names of one image, read
  `media/<id>` (`publicPath`, `thumbPath`, `nameSuffix`); do not paste them into tickets.
- **Manual clean-up** in "A deleted post's images are still served": delete the doc's `publicPath` and `thumbPath` (and, if
  `nameSuffix` is set, also the old-shape pair `m/<id>.<ext>`, `m/<id>_t.<ext>`), then the doc.
- **Rollback residual.** A revision older than W3-39 does not know `nameSuffix`: it publishes new uploads under the old, guessable
  names (the doc keeps its `nameSuffix`, which that revision ignores) and its retire parser rejects suffixed avatar and banner URLs (`refused`, the
  object stays until the account is deleted). Roll back only past W3-39 for a real defect, and keep `private_accounts` off the wider
  rollout while the older revision serves (ADR-0025 note W3-36 M-2). Docs written by W3-39 remain valid for the newer code on roll-forward.

### Orphaned uploads
PENDING and REJECTED documents are removed by the Firestore TTL (48 h) and the upload bucket's lifecycle rule deletes the
objects after 2 days. No action. If the bucket grows, check the lifecycle rule is applied (`terraform plan`).

### Banners (ADR-0024 D1, W3-5)
A BANNER is one image per `CreateUpload` (declared width <= 1500, height <= 500, 3:1 within 2%), with its own byte caps bound
into the signed URLs: full <= 1 MiB, thumb <= 128 KiB (POST and AVATAR keep 2 MiB / 256 KiB). `FinalizeUpload` always screens
full and thumb for a BANNER (2 Vision units, whatever `VISION_SCREEN_THUMB` says, once per image: see the screening claim above) and blocks LIKELY racy, like an avatar. A
rejected banner is `REJECTED` with reason `policy`; at the Vision cap `VISION_EXHAUSTED_POLICY` applies unchanged (one unit left
is not enough for a banner: an established account publishes it `READY_UNSCREENED`). Banners share the 20/day `uploads` quota.
The request log lines carry `purpose` (`POST`, `AVATAR`, `BANNER`; `MIXED` on a finalize that spans purposes) and, on
FinalizeUpload, `vision_units`. To see banner Vision spend, filter FinalizeUpload lines on `purpose=BANNER` and sum `vision_units`.

### GIFs (ADR-0029 D10, D11; W6-9 upload and publish, W6-10 screening)
- **Shape.** POST purpose only, exactly one item per `CreateUpload` (never mixed with photos), full <= 2 MiB (the same signed
  range), declared width and height <= `GIF_MAX_EDGE` (1,280), and `thumb_content_type` `image/jpeg` or `image/webp` (a still;
  <= 256 KiB). The full object is `u/<uid>/<id>.gif`, the thumbnail `u/<uid>/<id>_t.jpg|webp`; public names are `m/<id>-<suffix>.gif`
  and `m/<id>-<suffix>_t.jpg|webp`. The thumbnail has its own type everywhere: signing, the attrs and magic-byte check, the
  publish `Content-Type`, and every cleanup name (a lost-race or purge delete of `_t.gif` would silently miss the real object).
- **Verify.** The full object's magic must be `GIF87a` or `GIF89a` and its stored type `image/gif`; a GIF declared but PNG bytes is
  `REJECTED` (reason `invalid`), 0 Vision units. The original bytes are published unchanged.
- **Vision, frame-sampled (W6-10, ADR-0029 D11, F11).** FinalizeUpload reads the whole private GIF (1 Class B), pre-scans the
  container without decoding pixels, then decodes one frame at a time and tiles the frames visible at 0, T/4, T/2 and 3T/4 of the
  display time (up to four) into a 2 x 2 JPEG sheet (up to 1,280 x 960). Vision gets the sheet **by bytes** and the thumbnail **by URI**:
  **always 2 units** (the full object is never sent by URI). This is stricter than D11 point 6, which said 1 unit with
  `VISION_SCREEN_THUMB=false`: the thumbnail is a separate client upload that lists show, so it is always screened, like a banner's.
  Frames between the sample points are not screened (the residual risk the founder accepted in F11 point 2); report-driven review
  (ADR-0016) is the backstop.
- **When `FEATURE_GIF` may leave `off`.** Only when **100 % of traffic in that project is on a revision that contains W6-10**. During
  a split an older revision still screens only the first frame, so the flag stays `off` through the whole rollout of the revision (the
  ADR-0029 D12 "100 % rule" applies on top). Dev: after the deploy-dev run of the merge commit serves 100 %. Prod: after the `v*`
  release that contains it is at 100 % and the `production-reviewer` GO covers it.
- **Guards (per instance).** `GIF_MAX_FRAMES` (300), `GIF_MAX_EDGE` (1,280, checked against the real logical screen, not the declared
  size), `GIF_MAX_FRAME_AREA_SUM` (50,000,000 pixels), a frame outside the logical screen, a missing trailer or any unparseable block ->
  `REJECTED` ("This GIF is too large or too long." for the limits, the generic invalid text for malformed data), 0 Vision units, objects
  deleted. A semaphore of 1 per instance covers read + scan + decode + sheet (about 26 MiB live at the limits); a second GIF waits at
  most 5 s, then answers the retryable `MEDIA_NOT_READY` with no Vision spend and its screening claim released. The sampler has a 2 s
  deadline (a GIF that cannot be sampled in time is `REJECTED` as too large); a decoder panic is recovered, reported to Error Reporting
  (`rpc=media/gif_screen`) and the GIF is `REJECTED` (invalid).
- **Symptoms and what to do.**
  - Many "too large or too long" rejections: read the `gif_screen` lines (`refused_reason`: `frames`, `edge`, `area`, `frame_outside`,
    `deadline`). Mostly `deadline` on ordinary GIFs means the instance CPU is too slow for the limits: lower `GIF_MAX_FRAME_AREA_SUM`
    (config, no code change); do not raise the deadline.
  - Users see "the upload is not complete yet" on GIFs while nobody else is uploading: the slot is contended (one GIF at a time per
    instance, 5 s wait). The client retries. Persistent contention at Stage 0 means the allowlist is larger than planned.
  - A report of an explicit GIF that got through: set `FEATURE_GIF=off`, then take the post down with `opsctl` (ADR-0016). This is the
    F11 rollback trigger.
  - Error Reporting entry `media/gif_screen` with a panic type: a malformed GIF crashed the decoder and was rejected. Keep the bytes
    (private upload bucket, 2-day lifecycle) as a fuzz seed.
- **Budget (one GIF finalize).** Firestore unchanged (claim and resolve writes, the cached Vision counter); GCS Class B +1 (the full
  read; attrs and the 512-byte head stay 2 per object), Class A unchanged (2 copies); Vision 2 units; egress <= 2 MiB us-central1 ->
  asia-south1 (inside the free GCS egress); CPU typically < 0.2 s, worst case at the area cap about 0.7 s on a laptop-class core.
- **Logs.** One `gif_screen` line per screened GIF: `frames`, `sampled`, `units` (2, or 0 when refused or Vision failed), `decode_ms`,
  `refused_reason` (enum; never content).
- **At the Vision cap** a GIF is `REJECTED` (reason `capacity`) for every account, whatever `VISION_EXHAUSTED_POLICY` says
  (ADR-0029 F11 point 4); photos keep their policy. Symptom for users: "Image uploads are temporarily limited" on GIFs only.
- **Kill switch.** `FEATURE_GIF=off` stops new GIF uploads and new GIF posts (CreatePost re-checks the flag after loading
  the media doc); existing GIF posts keep rendering. A moderation-bypass report is the rollback trigger (ADR-0029 F11 point 5).
- **Logs.** Request lines carry `content_type` (`image/jpeg`, `image/webp`, `image/gif`, `MIXED` on a mixed finalize); the value
  comes from validated input or the stored document, never raw client text. Filter FinalizeUpload on `content_type=image/gif` and
  sum `vision_units` for GIF spend.
- **Storage.** GIF objects are about 0.63 MB per DAU-month; the 2-day upload lifecycle and the TTL on `media` docs cover
  abandoned GIF uploads like photos. SchedulePost refuses GIF media (VALIDATION `media_ids`), so no scheduled draft holds one.

### Public read semantics (bucket IAM, W3-22 M-2)
`<proj>-media` is public by exact object URL only. `allUsers` holds `roles/storage.legacyObjectReader`, which is
`storage.objects.get` and nothing else, so the bucket **cannot be listed anonymously** (a replaced banner, a removed avatar or
a taken-down post's image is reachable only by someone who already has its URL). Never grant `roles/storage.objectViewer` to
`allUsers`: it adds `storage.objects.list` and makes every object enumerable (and every list call a billed Class A operation).
Status codes, checked in dev on 2026-10-27:
| Request | Anonymous result |
|---|---|
| `GET https://storage.googleapis.com/<proj>-media/m/<id>.<ext>` (exists) | 200 |
| same URL, object missing or deleted | **404** `NoSuchKey` (the grant change did not turn it into a 403) |
| `GET .../storage/v1/b/<proj>-media/o` (JSON API list) | 401 |
| `GET https://storage.googleapis.com/<proj>-media/` (XML API list) | 403, `storage.objects.list` denied |
So a client that shows a placeholder for a missing avatar or banner (ADR-0024 A4) can key on 404. If an anonymous list ever
answers 200 again, the binding drifted: `terraform plan` in that env shows the role replacement.

### Replaced and removed avatars and banners (ADR-0024 Amendment 1 A4)
A removed or replaced avatar or banner is deleted from `<proj>-media` 24-48 h after the change (founder decision 2026-10-27,
Option 5B; it supersedes plan D10 for avatars and ADR-0024 D1's Option 5A). Only images the profile **never** replaced or
removed stay until the account is deleted, and the account purge deletes those with the rest of the user's media.

**How it works.** After an `UpdateProfile` commit that replaced or removed an image, identity hands the old URLs (it already
read them: 0 extra reads) to media, which publishes `{"kind":"profile_media_retired","uid","purpose","oldUrl","oldThumbUrl","changedAt"}`
on the jobs topic (best effort, 2 s deadline). The handler never acts on the message's word alone. It parses the media id from
the object names (`m/<id>.<ext>`, `m/<id>_t.<ext>`), re-reads `users/{uid}` and the media document, then sets `customTime =
changedAt` on the two public objects (2 Class A) and last writes `retiredAt` and `expireAt = changedAt + 72 h` on the media
document (1 write). The bucket's lifecycle rule (`days_since_custom_time = 1`, Delete; `infra/terraform/modules/media-buckets`)
deletes the objects (free) 24-48 h after `changedAt`; the document's TTL removes it 72 h after. Until then the document stays,
so an account deleted during the grace loses the objects at once (the eraser is purpose-agnostic) and the export lists it with
`retiredAt`. `ResolveAvatar` and `ResolveBanner` refuse a retired document, so a retired image can never be set again (the one
MEDIA_NOT_READY answer). Per image: 2 reads, 1 write, 2 Class A, 1 TTL delete, 1 Pub/Sub message and 1 Cloud Run request.
Nothing else in the application sets `customTime` (`TestCustomTimeIsSetOnlyByTheRetireStep` pins it).

**Job outcomes** (the `outcome` field of the `account_job` log line, `account_job=profile_media_retired`):
| Outcome | Meaning | Action |
|---|---|---|
| `retired` | objects tagged, document marked | none; objects go 24-48 h after `changedAt` |
| `duplicate` | already retired, or the document is gone (TTL, account deleted) | none |
| `still_current` | the old image is the profile's current avatar or banner (the user set it back, or the message is forged) | none; nothing was touched. A burst of these is a bug in the publish side: look at `UpdateProfile` |
| `refused` | the document is not this user's, not this purpose, or not published | none; a forged or corrupt message. Repeated ones: security-auditor |
| `unparseable` | the URL is not an object name media writes | none; the image stays until the account is deleted |
| `disabled` | `PROFILE_MEDIA_RETIRE` does not cover the purpose in this revision | none; see "Switch order" |
| `dropped:malformed_message`, `dropped:invalid_message` | poison, acked | none |
A Firestore, Pub/Sub or GCS error nacks and Pub/Sub redelivers (outcome `error`, WARN, ERROR from the last attempt). A crash between
the object patches and the document write converges on redelivery: the same `customTime` is set again (Cloud Storage never lets it
move backwards, and accepts the same value) and the document is written.

**Switch order (per project; never skip a step).**
1. Apply the lifecycle rule in the project (`terraform apply` of `modules/media-buckets`, dev first, prod with the founder's OK).
   Check `gcloud storage buckets describe gs://<proj>-media --format="default(lifecycle_config)"` shows a `Delete` rule with
   `daysSinceCustomTime: 1`.
   **Status (2026-10-27):** dev and prod both have the rule, each by a targeted apply of
   `module.media_buckets.google_storage_bucket.media` only (1 changed, 0 added, 0 destroyed; neither bucket had a lifecycle rule
   before, and the 2-day rule on `<proj>-media-upload` is a different bucket and was not touched). Dev was applied first (the
   founder's pre-authorised dev apply); prod at 17:13 UTC after the founder's OK (plan-then-OK, ADR-0019). `PROFILE_MEDIA_RETIRE`
   is still `off` in both, so no object is tagged yet.
2. Set `profile_media_retire = "banner"`. **Never set it before step 1**: an object tagged without the rule outlives its TTL'd
   document and escapes the account eraser (an orphaned public image). Step 1 is done in both projects.
   **Status (2026-10-27):** dev has `banner` since 17:56 UTC (its own targeted plan and apply, tfvars only; revision
   `api-00307-fcs`, 100% of traffic; details in "Results, dev, banner switch"). Prod is still `off`: raising it needs the
   founder's OK and the prod throwaway-object check first ("Results, prod"). Steps 3 and 4 of "Verification of the retire step"
   are not run yet: the replace-a-banner leg is owed to the testers, with the exact expectations listed in that section.
   `all` waits for the app release with #361 (the avatar placeholder).
3. Set `all` only after the app release whose `AppAvatar` shows a placeholder when the image no longer loads (old posts,
   quote and repost embeds and notification actors copy the avatar URL, and only a name or handle edit refreshes the newest 100
   posts, so older rows show a 404 image after the grace).
Lowering it is the kill switch: no new messages, and messages already queued ack as `disabled` and are dropped (the images they
named fall back to the account eraser; re-publish a message by hand once the switch is raised again if one matters, the handler
is idempotent). Objects already tagged are still deleted by the rule; to stop that, remove the `customTime` of an object by hand
(`gcloud storage objects update gs://<proj>-media/m/<id>.<ext> --clear-custom-time`) before its day is out.

**Failure modes.**
- **`profile_media_retire_enqueue_failed` in Error Reporting.** The publish failed after the profile change committed. The image
  falls back to the account eraser (stays public until the account is deleted). To retire it anyway, publish the same message by
  hand to the jobs topic (it is idempotent): `{"kind":"profile_media_retired","uid":"<uid>","purpose":"AVATAR|BANNER","oldUrl":"<old url>","oldThumbUrl":"<old thumb url>","changedAt":"<RFC 3339 UTC now>"}`.
  The error line names only the purpose, so find the old image in Firestore: the `media` documents with `ownerId` = the uid and that
  `purpose`, other than the one the profile points at now; the URLs are `https://storage.googleapis.com/<proj>-media/` plus the
  document's `publicPath` and `thumbPath`.
- **An old image is still served after 48 h.** Check, in order: the switch for that purpose in the serving revision; the job log
  line for that uid hash (`retired`? `still_current`? `disabled`? nothing = the publish failed, see above); the object has a
  `customTime` (`gcloud storage objects describe gs://<proj>-media/m/<id>.<ext>`); the lifecycle rule exists in the project. A
  rule applied after the tag still deletes the object: it evaluates the condition on every object each day. Cached copies in
  browsers and intermediaries (`max-age=31536000, immutable`) outlive the delete; nothing recalls them.
- **An old image is gone before the user set it back.** The race the design accepts: the user re-sets the just-replaced image
  between the handler's `users` read and its document write. The resolver passes (not yet retired), the handler retires it, the
  profile then shows a missing image. The user sees the placeholder and uploads again.
- **Soft delete.** The media bucket keeps the Cloud Storage default soft-delete retention (7 days), so a deleted image remains
  restorable by project owners for that long, never publicly. The exports bucket disables it (M3, 2026-10-08); the media
  bucket does not. If "gone from our bucket" must also mean "unrecoverable", that is a separate decision (set
  `soft_delete_policy { retention_duration_seconds = 0 }`, at the cost of no undelete after a mistake).
  **Decided 2026-10-27 (founder): the 7-day soft delete stays ON** in the media buckets (dev and prod); no Terraform change.
- **Reported image.** The grace (24-48 h) is shorter than the ADR-0016 D5 48 h triage SLA, and an ACCOUNT report copies the image
  URLs into its evidence. Save a copy of a reported image when the report is first seen if it is needed past the grace
  (`docs/runbooks/moderation.md`, "Reported profile images").
- **`opsctl clear-profile-fields --fields banner|avatar`** runs the same step in process after the clear committed. It needs
  `PROFILE_MEDIA_RETIRE` set in the operator's shell to the project's value (unset is `off`: nothing is scheduled and the objects
  are printed to delete by hand). An invalid value is refused before any write. A retire failure after the clear exits 1, still
  resolves the `--report`, and prints the objects.

### Storage growth
Replaced and removed avatars and banners are deleted 24-48 h after the change once `PROFILE_MEDIA_RETIRE` covers them (section
above); until then, and for images replaced or removed before the switch was on or whose publish failed, they stay until the
account is deleted (the account purge deletes every media doc and object of the user). If `<proj>-media` approaches 2.5 GB (50%
of the 5 GB free tier, the ADR-0024 D10 trigger) or 4 GB, first check that the switch is on and the lifecycle rule exists; the
stragglers are images no message ever covered.

## Verification after enabling `FEATURE_MEDIA` for the allowlist (dev project, real GCS)
1. CreateUpload returns signed URLs; PUT both files with the returned headers; FinalizeUpload returns READY with a
   `thumb_url`.
2. CreatePost with the media id; GetPost shows `media[0].thumb_url`; open the image URL (public, immutable cache).
3. DeletePost; within a minute `m/<id>.<ext>` returns 404 and `media/<id>` is gone.
4. Check one request log line per RPC: `fs_reads`/`fs_writes` within `docs/plans/media-uploads.md`.

## Verification of the retire step (dev project, real GCS; the Storage emulator cannot do this)
The emulator does not implement object patch (`SetCustomTime` treats its 501 as success against the emulator only), so the
`customTime` tag and the lifecycle deletion are checked once per project on a real bucket, after the rule is applied and before
the switch is raised past `off`:
1. **The rule exists:** `gcloud storage buckets describe gs://<proj>-media --format="default(lifecycle_config)"` lists a `Delete`
   rule with `daysSinceCustomTime: 1`.
2. **Tag and re-tag a throwaway object** (a name outside the media id space, so no document names it): upload
   `m/9999999999999999999.webp`, then `gcloud storage objects update gs://<proj>-media/m/9999999999999999999.webp
   --custom-time=<RFC 3339 UTC, two days ago>` twice with the same value (the redelivery case: it must succeed both times) and
   `gcloud storage objects describe ...` shows the custom time. The lifecycle run deletes it within about a day (it cannot be
   forced); check it is gone the next day.
3. **End to end:** set `profile_media_retire = "banner"` for the dev allowlist uid, replace a banner, and find the
   `account_job=profile_media_retired` log line with `outcome=retired`, `fs_reads=2`, `fs_writes=1`. `media/<id>` now has
   `retiredAt` and `expireAt = retiredAt + 72 h`; both objects have `customTime = changedAt`; the objects are gone 24-48 h later and
   the document 72 h later. Setting the retired banner again answers MEDIA_NOT_READY.
4. Redeliver the message (re-publish it): `outcome=duplicate`, `fs_writes=0`.

**Results, dev (`dzeroth-dev-media`, 2026-10-27, run by the production-deployer with the founder's own `gcloud` credentials).**
`PROFILE_MEDIA_RETIRE` was not set to anything and no flag changed.
- Step 1 passed: after the apply, `lifecycle_config` lists exactly one rule, action `Delete`, condition `daysSinceCustomTime: 1`
  (before the apply it printed `null`). CORS, soft delete (7 days), uniform access, public access prevention and labels are unchanged.
- Step 2, CLI: `m/9999999999999999999.webp` (content type `image/webp`, the public `Cache-Control`) accepted
  `gcloud storage objects update --custom-time=<two days ago>` twice with the same value, both exit 0; `describe` shows the
  custom time, the `Cache-Control` and the content type; each patch adds one metageneration and the generation stays the same.
- Step 2, the application code: a throwaway test (not committed) called the real `objstore.Store.SetCustomTime` against the
  dev bucket, with a second throwaway object `m/9999999999999999997.webp`. Two calls with the same value both returned nil;
  the object's `customTime` was that value, its generation, size, content type and `Cache-Control` were unchanged (the SDK's
  `Update` sends a patch that carries only `customTime`); `SetCustomTime` on a missing object returned nil (the 404 path). Cloud
  Storage refuses to move `customTime` backwards: HTTP 400 "Custom time cannot be decreased", which is what the code comment
  and the failure-mode text above assume, and moving it forwards is accepted. A redelivery always carries the same `changedAt`,
  so it is never a decrease.
- Both throwaway objects were deleted by hand afterwards (the soft-delete policy keeps a deleted object restorable by project
  owners for 7 days, never public). So the lifecycle run itself has not yet been seen deleting a tagged object: step 3 shows it
  end to end (objects gone 24-48 h after the replace).
- The runtime service account holds `roles/storage.objectAdmin` on the bucket, which includes `storage.objects.update`, the
  permission a patch needs (the test above used the founder's credentials, not the runtime account).
- Not yet run in dev: steps 3 and 4. They needed the switch above `off`, which is now `banner` ("Results, dev, banner switch"
  below); the replace-a-banner leg is still owed to the testers.

**Results, dev, banner switch (2026-10-27, run by the production-deployer on the founder's pre-authorised dev apply; times UTC).**
`PROFILE_MEDIA_RETIRE` went `off` to `banner` as its own change: nothing else in the plan, and no flag moved. Prod was not touched.
- Preconditions: the lifecycle rule is on `dzeroth-dev-media` and on `dzeroth-prod-media` (step 1); #360 is on `main`; dev served
  `api-00306-482` (the W3-24 revision) at 100%, `last-good` `api-00561-meb`; no `deploy-dev` run was in flight at the plan, the
  apply or the route.
- tfvars: one line appended to the real, gitignored `infra/terraform/envs/dev/terraform.tfvars`: `profile_media_retire = "banner"`
  (the key appears once). The promotion validators passed (`check-flag-registry.sh` `ok: 20 flags registered`,
  `check-until-dates.sh` `ok: 11 until: marker(s) checked against 2026-10-27`, `check-field-overrides.sh`
  `ok: fieldOverrides unchanged: 35 override(s)`).
- Plan (saved with `-out`, targeted `module.cloud_run_api.google_cloud_run_v2_service.api` only, about 17:53): `Plan: 0 to add, 1 to
  change, 0 to destroy.` The plan JSON had 33 resources, 32 `no-op`; the one change is the `api` service. Read from the JSON, not by
  eye: env 129 names before and after, 0 added, 0 removed, exactly one value changed (`PROFILE_MEDIA_RETIRE` `off` to `banner`);
  every other attribute of the service identical (this plan showed no `template.revision` line at all). In the plain-text plan the
  only difference is that one `env` block.
- Apply of that saved plan file (17:55): the `api` service changed, nothing else. The new revision `api-00307-fcs` was created at
  17:54:58 and is `Ready` True. Its image digest equals the serving revision's (`sha256:906eda13...5708428c`, the same one
  `api-00306-482` runs), its env has 129 entries and `PROFILE_MEDIA_RETIRE=banner`. `scripts/promotion/validate-revision.sh` on
  its real JSON: `RESULT: all checks passed`, the four W3 flags still `allowlist` 3/3 with percent 0, `scaling min=0 max=1`.
- Route (17:56:07): `gcloud run services update-traffic api --to-revisions=api-00307-fcs=100`: `100% api-00307-fcs`, `0%
  api-00561-meb (last-good)`, `0% api-00564-vik (candidate)`. `GET /health` on the service URL: HTTP 200 `ok`. A fresh targeted
  plan after the route: `No changes. Your infrastructure matches the configuration.`
- **Rollback of this change:** remove the `profile_media_retire` line from the tfvars (or set it to `"off"`), the same targeted plan
  (expect one `PROFILE_MEDIA_RETIRE` value change), apply, route the new revision. Fast fallback with no Terraform:
  `gcloud run services update-traffic api --project=dzeroth-dev --region=asia-south1 --to-revisions=api-00306-482=100` (same image,
  switch `off`, W3 flags unchanged), then make the Terraform change so state and live agree, and do not run `deploy-dev` in between.
  Nothing queued is lost by lowering the switch: queued messages ack as `disabled`.
- Handler is registered: `apiserver.go` registers the `profile_media_retired` handler whatever the switch says (the handler acks
  as `disabled` when it is `off`), and nothing logs the switch's value, so no log line can prove `banner` by itself. The evidence
  is the revision's env (`banner`), `config.Load` rejecting any value but `off`, `banner` or `all` at startup, and the revision's
  own startup lines: `feature_flags` and `listening` (`env=dev`, 17:56:14) on `api-00307-fcs` after the route, then real traffic
  (`GetMe`, `ListSuggestedUsers`, `GetHomeTimeline`, `Follow`, all `code=ok` from an allowlisted account from 17:58).
  First ten minutes on the revision (route 17:56:07, window to 18:06:07, queried 18:06:37; the revision's own log lines only):
  no line at severity ERROR or above, none at WARNING, 76 request-log lines all HTTP 200 (so no 5xx; the 17:56 `/health` check
  included), 59 RPC lines all `code=ok`, `/health` 200 again at 18:06, traffic still 100% on `api-00307-fcs`. That traffic includes
  the W3 RPCs (`ListSuggestedUsers`, `ListLikedPosts`, `GetUserTimeline`) and, from an allowlisted account, `CreateUpload`,
  `FinalizeUpload` and three `UpdateProfile` calls (all ok). No `account_job=profile_media_retired` line and no
  `profile_media_retire_enqueue_failed` line yet: the logs do not say whether an `UpdateProfile` replaced or removed a banner
  (a first banner, or an avatar change, retires nothing in `banner` mode), so nothing here counts for the owed leg below.
- **Owed to the testers (steps 3 and 4 of "Verification of the retire step").** The deploying machine has no tester credential and
  the founder's `gcloud` credentials cannot replace a cohort user's banner through the app, so the replace-a-banner leg has not
  run. A tester of the `profile_extras` allowlist (the same three uids as `media`; the banner also needs `media`) first sets a
  banner if the account has none (nothing is retired by a first set; it costs 2 Vision units), then replaces it with another
  image, or removes it (Edit profile, Remove). The old banner `<id>` is the one that must be retired. Expect, in this order:
  1. Within about a minute, one log line `account_job=profile_media_retired` with `outcome=retired`, `fs_reads=2`, `fs_writes=1`,
     `fs_deletes=0` and no `error` field: `gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=api AND
     jsonPayload.account_job="profile_media_retired"' --project=dzeroth-dev --freshness=1h`. Find it by `account_job` and the time of
     the change: for this job kind `uid_hash` is empty (the delivery loop sets no uid for the kinds another module registered,
     such as this one), so the "job log line for that uid hash" wording in the failure modes cannot be followed literally.
  2. Both old objects, `m/<id>.<ext>` and `m/<id>_t.<ext>`, carry `customTime` equal to the moment the profile change committed
     (`changedAt`): `gcloud storage objects describe gs://dzeroth-dev-media/m/<id>.<ext>` (and the `_t` one), generation and
     `Cache-Control` unchanged. The profile's current banner objects have no `customTime`.
  3. The old image's `media/<id>` document has `retiredAt` equal to that same `changedAt` and `expireAt` = `retiredAt` + 72 h (the
     code sets both from `changedAt`, not from the time the handler ran). Setting that retired banner again answers
     MEDIA_NOT_READY.
  4. The two objects return 404 on their public URL 24-48 h after `changedAt` (the lifecycle rule; browsers and intermediaries may
     keep a cached copy, `max-age=31536000, immutable`) and the document is gone 72 h after (Firestore TTL deletes lag `expireAt`
     by up to a day or so). A lifecycle run has not yet been seen deleting a tagged object (the throwaways of the first dev
     check were deleted by hand), so this is the first time it is seen end to end.
  5. Step 4 (redelivery): re-publish the same message on the jobs topic (founder credentials): `outcome=duplicate`, `fs_writes=0`,
     no GCS call.
  6. No `profile_media_retire_enqueue_failed` in Error Reporting and no `account_job` line with `outcome=error`.
  If any expectation fails, set the switch back to `off` (rollback above) before looking further: objects already tagged are still
  deleted by the rule, so check `customTime` on them by hand first (the clear-by-hand command is in the kill-switch text above).
  **Checked 2026-10-28, about 04:10 UTC: still owed.** Since the switch went to `banner`, two allowlisted accounts each set a
  banner once (CreateUpload, FinalizeUpload and UpdateProfile all `ok`, 18:02 and 18:07 UTC on 2026-10-27). Dev Firestore holds
  exactly two `BANNER` media documents, one per account, both `READY` with no `retiredAt`, so both were first sets and retired
  nothing. No `account_job=profile_media_retired` line and no enqueue failure exist, which is correct. The leg needs one of those
  two accounts to **replace or remove** its banner; then run checks 1 to 6 above (`w3-part-a-rollout.md` section 8.2).

**Results, prod (`dzeroth-prod-media`, rule applied 2026-10-27 at 17:13 UTC after the founder's OK; the apply was run by the main
session from a saved targeted plan).** Step 1 only; `PROFILE_MEDIA_RETIRE` is `off` and nothing was written to the bucket.
- Plan, saved with `-out` and applied as that file: `Plan: 0 to add, 1 to change, 0 to destroy`, the only difference the added
  `lifecycle_rule` (action `Delete`, condition `days_since_custom_time = 1`).
- `gcloud storage buckets describe gs://dzeroth-prod-media --project=dzeroth-prod --format="default(lifecycle_config)"` after the
  apply (it printed `null` before; `update_time` 2026-10-27T17:13:04+0000):
  ```
  lifecycle_config:
    rule:
    - action:
        type: Delete
      condition:
        daysSinceCustomTime: 1
  ```
- Unchanged: CORS (`GET`, `HEAD`, origin `*`, `Content-Type`, 3600 s), soft delete (`retentionDurationSeconds` 604800), uniform
  bucket-level access `true`, public access prevention `inherited`, labels, and the `allUsers` binding, which is still only
  `roles/storage.legacyObjectReader`. Anonymous checks after the apply: JSON API list 401, XML API list 403, a missing object 404
  (the W3-22 M-2 result holds).
- A follow-up targeted plan (`-target=module.media_buckets.google_storage_bucket.media`) says "No changes".
- Not run in prod: steps 2 to 4. Do step 2 (a throwaway `m/99999...` object, deleted afterwards) with the founder's OK when the prod
  switch is next in line; the prod bucket holds 0 objects today.
