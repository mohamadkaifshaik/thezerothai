# Runbook: media (images, avatars, banners, SafeSearch)

Owner: backend. Slice P4, ADR-0005. Flag: `FEATURE_MEDIA` (off | allowlist | percent | on). Plan: `docs/plans/media-uploads.md`.

## Switches (all environment variables, no redeploy of code)
| Variable | Default | Effect |
|---|---|---|
| `FEATURE_MEDIA`, `FEATURE_MEDIA_ALLOWLIST`, `FEATURE_MEDIA_PERCENT` | off | MediaService, CreatePost `media_ids`, UpdateProfile avatar. Off answers FEATURE_DISABLED / MEDIA_NOT_READY. `off` (not allowlist or percent) also holds scheduled posts that carry images PENDING instead of publishing them: `docs/runbooks/posts.md` section 12, "Images held while `FEATURE_MEDIA` is off" |
| `DEGRADED_MODE=nomedia` | off | CreateUpload and FinalizeUpload answer UNAVAILABLE + DEGRADED_MODE; text posting and attaching READY images continue |
| `FEATURE_PROFILE_EXTRAS`, `FEATURE_PROFILE_EXTRAS_ALLOWLIST`, `FEATURE_PROFILE_EXTRAS_PERCENT` | off | Gates `CreateUpload(purpose=BANNER)` (needs `media` on too; W3-5): off for the caller answers FEATURE_DISABLED `feature=profile_extras` with 0 reads and nothing signed. AVATAR and POST uploads and every `FinalizeUpload` ignore it, so a banner upload started before the flag was lowered still completes. Also gates the UpdateProfile banner, location, website and pin fields (ADR-0024 D9, W3-6). Details in `docs/runbooks/posts.md` |
| `PROFILE_MEDIA_RETIRE` | `off` | Which replaced or removed profile images are deleted 24-48 h after the change (ADR-0024 Amendment 1 A4): `off` nothing, `banner` banners only, `all` banners and avatars. Per-project retention config (Terraform `profile_media_retire`), **not** a `FEATURE_` flag. Checked by the publish (UpdateProfile) and by the `profile_media_retired` job handler, so lowering it stops new messages and makes the queued ones ack without action. Order and preconditions: section "Replaced and removed avatars and banners" below |
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
3. Spend check: summing `vision_units` over the FinalizeUpload lines of one media id must give 1 or 2 (a BANNER always 2).
   More means a screening outlived its 30 s claim (Vision slower than its 10 s deadline plus the copies), so a second call
   screened too: look at Vision latency before raising anything.
4. Client side: the app reads `MEDIA_NOT_READY` from a finalize as "the object is missing" (`media_uploader.dart`) and re-signs and
   PUTs the image again before it retries. For a call that lost the claim that is one wasted upload (at most 1 MiB or 2 MiB
   plus the thumbnail, one Class A operation per file); the image itself is already being published by the winner. A distinct
   reason would need a proto change, so it is not done here.

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
full and thumb for a BANNER (2 Vision units, whatever `VISION_SCREEN_THUMB` says, once per image: see the screening claim above) and blocks LIKELY racy, like an avatar. A
rejected banner is `REJECTED` with reason `policy`; at the Vision cap `VISION_EXHAUSTED_POLICY` applies unchanged (one unit left
is not enough for a banner: an established account publishes it `READY_UNSCREENED`). Banners share the 20/day `uploads` quota.
The request log lines carry `purpose` (`POST`, `AVATAR`, `BANNER`; `MIXED` on a finalize that spans purposes) and, on
FinalizeUpload, `vision_units`. To see banner Vision spend, filter FinalizeUpload lines on `purpose=BANNER` and sum `vision_units`.

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
   **Status (2026-10-27):** dev has the rule (targeted apply of `module.media_buckets.google_storage_bucket.media` only; the bucket
   had no lifecycle rule before, and the 2-day rule on `<proj>-media-upload` is a different bucket and was not touched). Prod does
   not: its plan (1 to change, only this rule) is waiting for the founder's OK, so prod stays at `off`.
2. Set `profile_media_retire = "banner"`. **Never set it before step 1**: an object tagged without the rule outlives its TTL'd
   document and escapes the account eraser (an orphaned public image). Next in dev: set it to `banner` as a separate planned
   change (its own plan and apply, tfvars only), then run steps 3 and 4 of "Verification of the retire step".
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
- Not yet run: steps 3 and 4 (they need the switch above `off`), and everything in prod.
