# Images: signed uploads, SafeSearch with a cap, avatars, post-delete job (Phase 1 slice P4)
Plan owner: backend-developer (resumed from planner's P4 outline in `docs/plans/phase1.md`) · Date: 2026-10-11 ·
Stage: 0 (0 – ~300 DAU, pay-per-use only) · Flag: `FEATURE_MEDIA` (default **off** in every environment)
Inputs: CLAUDE.md (rule 7), ADR-0005 (+ amendment: Vision cap), ADR-0003, ADR-0010, ADR-0011,
`proto/dzeroth/media/v1/media.proto`, `docs/reviews/code-review-modern-ui-110.md` (M2), `docs/reviews/cost-model.md`,
`docs/plans/phase1.md` §P4.

## Goal
Up to 4 images per post and a profile avatar, all moderated before they become public, with the post's objects removed
when the post is deleted. Media bytes never pass through the API: clients PUT to a private bucket with V4 signed URLs;
the API reads attributes and 512 bytes, asks Vision, then copies approved objects into the public-read bucket.

## Status
| Ticket | Title | Owner | Status | PR |
|---|---|---|---|---|
| T1 | objstore: signed PUT, attrs, ranged head, cross-bucket copy | backend | In review | `feat/p4-media-backend` |
| T2 | `internal/media`: CreateUpload / FinalizeUpload / Vision cap / policy | backend | In review | same |
| T3 | CreatePost `media_ids` + alt texts + image-only posts; UpdateProfile avatar | backend | In review | same |
| T4 | `post_delete` job, `media.Eraser`, export section | backend | In review | same |
| T5 | Wiring: `FEATURE_MEDIA`, `DEGRADED_MODE=nomedia`, config, quota `uploads` | backend | In review | same |
| T6 | Review #110 M2: list views thumbnail-only, `useFullImage` for detail | frontend | In review | separate PR (`fix/media-thumb-only-lists`) |
| T7 | Flutter: image_picker + compress + BlurHash + upload with progress/retry, grid, avatar editor | frontend | **Not started** | |
| T8 | Dev smoke on real GCS: IAM signBlob signing, bucket CORS, Vision API, rewrite copy | deployer | **Not started** (needs founder creds) | |
| T9 | Terraform env vars: `FEATURE_MEDIA[_ALLOWLIST\|_PERCENT]`, `VISION_*`, `MEDIA_PUBLIC_BASE_URL`; enable `vision.googleapis.com` | deployer | **Not started** | |
| T10 | Runbook `docs/runbooks/media.md` (added in this PR) | backend | In review | same |

T1-T5 and T10 are one PR on purpose: the post_delete job, the Eraser, the avatar path and CreatePost all consume the
same `media` documents and the same `media.Library`, and splitting them would leave a PR that cannot be tested end to
end. Nothing is user visible until `FEATURE_MEDIA` is turned on.

## Decisions (delegated 2026-10-10)
The founder delegated the open P4 choices. Each is reversible by config unless noted.

| # | Decision | Why | Revisit when |
|---|---|---|---|
| D1 | **Screen the thumbnail as well as the full image** (`VISION_SCREEN_THUMB`, default `true`; 2 Vision units per image). ADR-0005's text counts one unit. | The thumbnail is a separate client-uploaded object and is what every list renders. Screening only the full image would let an explicit thumbnail through. The signed URL binds MD5 per object, not content equality. | Set `false` to follow the ADR literally; at 300 DAU the delta is about +$1.5/month. |
| D2 | An **image-only post is valid**: empty text is accepted exactly when at least one `media_id` is attached (`text.ParseOptional`). | Matches X and what users expect from a photo post; the proto comment now says so. Without images, empty text is still VALIDATION. | Never expected. |
| D3 | `FEATURE_MEDIA` gates **all three** entry points: MediaService, CreatePost `media_ids`, UpdateProfile `avatar_media_id`. With it off, CreatePost answers FEATURE_DISABLED `media` (as in P1) and an avatar id answers MEDIA_NOT_READY. | One switch, one rollout (`flag-rollout`); no half-enabled state. | |
| D4 | `post_delete` is **published only for posts that carry images**, from `DeletePost`, **after** the commit. A publish failure is logged at ERROR and never fails the delete. | A post without images has no dependants yet, so 0 Pub/Sub messages and 0 extra reads for the common case. The post is already gone; the objects are also removed by the account purge, and the media documents never leak PII (only ids). | P5 publishes for every post (likes/reposts), see "post-delete job interface". |
| D5 | The job **never acts on the message's word alone**: it re-reads each media document and requires `ownerId == uid` and `postId == message.postId`, and it re-reads the post (fresh, bypassing the cache) and refuses while the post exists. | IAM control C1 pattern from ADR-0011. A forged or replayed message can delete nothing it does not own, and can never delete the images of a live post. | |
| D6 | **Images are attached inside the CreatePost transaction** (`media/{id}.postId`), so one image can belong to one post and the job can verify membership. | Without it, two posts could reference one image and deleting one would break the other. Cost: +n reads, +n writes. | |
| D7 | **Exhausted Vision cap** (ADR-0005): accounts older than 7 days publish `READY_UNSCREENED`; newer accounts are `REJECTED` (retry after the 1st). `VISION_EXHAUSTED_POLICY=reject` rejects everyone. There is no upheld-report signal until P7. | ADR-0005 amendment, implemented as a config knob. | P7 adds the report signal. |
| D8 | `DEGRADED_MODE=nomedia` blocks **CreateUpload and FinalizeUpload** only. CreatePost may still attach already-READY images and avatars may still be set from READY media. | `nomedia` exists to stop new storage, Class A/B and Vision spend; attaching a READY image costs none of those. | |
| D9 | Quota unit is the **image**, not the call: `quotas/{uid}.uploads` += n, 20/day (`QUOTA_MEDIA_PER_DAY`; 5/day inside the 24 h new-account window, `QUOTA_NEW_ACCOUNT_MEDIA_PER_DAY`), checked as a whole call (`quota.CheckAndReserveN`). | A 4-image call at 18/20 fails entirely instead of half-reserving. | |
| D10 | **Old avatar objects are not deleted when an avatar is replaced** (they are removed with the account). | The profile keeps only URLs, not the previous media id; tracking it needs a field and a job. At ~30 KB per avatar this is noise at Stage 0. | Storage > 50% of 5 GB: add `avatarMediaId` to `users` and clean up in UpdateProfile's job. |
| D11 | **Emulator-only streamed copy.** GCS `rewrite` is the production path; the Storage emulator returns 501 for it, so `objstore.CopyTo` streams the copy **only** when `STORAGE_EMULATOR_HOST` is set. | Lets `make dev` and the integration tests finish a FinalizeUpload. Bytes still never pass through the API in any real environment. | |
| D12 | Local dev uses an allow-all moderator (`ENV=local` only); every other environment builds the Vision client (lazy, no I/O before ListenAndServe). | There is no Vision emulator. | |

### Not decided here (needs the founder)
- Whether D1 stays on in prod (cost: two Vision units per image).
- Enabling `vision.googleapis.com` and the IAM `serviceAccountTokenCreator` self-binding is T9 (Terraform apply, founder).

## Contract changes
- **None to field numbers or messages.** `media.proto` and `posts.proto` changed in comments only (stale `< 950`
  counter text; CreatePost/DeletePost cost lines) and Go connect code was regenerated with the pinned plugin versions
  (`protoc-gen-go` v1.36.12). The Dart generated client carries the same comments and should be regenerated by the
  next `make proto` run (comment-only).
- `media_alt_texts` is empty or parallel to `media_ids` (already the proto's wording), each at most 1,000 characters,
  no control characters.
- Error mapping: any unusable media id is `FAILED_PRECONDITION` + `MEDIA_NOT_READY` (one answer, no ownership oracle).

## Data model
- `media/{mediaId}` (owner: media): `ownerId, purpose (POST|AVATAR), status (PENDING|READY|READY_UNSCREENED|REJECTED),
  contentType, bytes, thumbBytes, w, h, fullMd5, thumbMd5, blurhash, uploadPath, thumbUploadPath, publicPath,
  thumbPath, rejectionReason, postId (set at attach), createdAt, expireAt` (TTL while PENDING and REJECTED: 48 h).
- `posts/{postId}.media[]`: `{mediaId, url, thumbUrl, width, height, blurhash, altText}` copied at create time (no
  join on read). Omitted when empty.
- `admin/vision-{yyyymm}`: `units` (atomic increment). Cached 60 s per instance.
- `quotas/{uid}.uploads`: images today.
- Index: `media` by `ownerId ASC, __name__ ASC` uses the automatic single-field index; no new composite index.
- GCS: `u/<uid>/<mediaId>[_t].<ext>` in `<proj>-media-upload` (private, 2-day lifecycle), `m/<mediaId>[_t].<ext>` in
  `<proj>-media` (public-read, `Cache-Control: public, max-age=31536000, immutable`).

## post-delete job interface (for P5)
Rides the existing shared `jobs` topic and `/internal/pubsub/jobs` push endpoint (ADR-0011 D-A): **no new topic, no new
subscription, no new Terraform.**

```
message (JSON, Pub/Sub data): {"kind":"post_delete","uid":"<authorUid>","postId":"<19 digits>","mediaIds":["<19 digits>", ...]}
publisher : posts.PostDeleteJobs.PostDeleted(ctx, uid, postID, mediaIDs)   // posts/api.go, called after DeletePost's commit
handler   : identity.JobHandler registered with Lifecycle.RegisterJobHandler("post_delete", h)   // media.Jobs today
outcomes  : done | duplicate | refused (post still exists) | dropped:malformed_message | dropped:invalid_message
semantics : at-least-once, idempotent, objects first and document last, nack (error) only for infrastructure failures
```

How P5 (likes, reposts, quotes) extends it, without a new topic:
1. **Publisher.** In `posts/service_delete.go` (`publishPostDelete`) drop the `len(p.Media) == 0` early return so every
   deleted post publishes (the message already carries `uid` and `postId`; `mediaIds` may then be empty).
2. **Handler.** `RegisterJobHandler` takes one handler per kind. Replace the registration in
   `apiserver/apiserver.go` with a small composite that runs the steps in order and nacks if any fails:
   `media.Jobs` (already tolerates a post with no images only if you relax the `len(MediaIDs) == 0` drop in
   `Jobs.Handle` to "nothing to do, ack") and `engagement.Jobs` (delete `likes/{postId}_*` and `reposts/{postId}_*` in
   pages of at most 500 with a `Limit`, resumable because deleted docs drop out of the next page).
3. **Guard.** Keep D5: re-check that the post is gone before deleting dependants; never trust `uid` from the message
   for ownership of other collections.
4. **Budget.** Model the job as `1 + dependants` reads and `dependants` deletes, one delivery per page; document it in
   the P5 plan and add the line to the `lifecycleCollections` guard (`apiserver/lifecycle_collections_guard_test.go`).
5. `media.Eraser` already removes a user's images on account deletion (`step "media"`, after posts and graph, before
   identity); P5's `engagement.Eraser` registers next to it in `registerLifecycleModules`.

## Worst-case Firestore reads/writes per RPC (kept in sync with the integration assertions)
"Cold" includes the account-status interceptor's `users/{uid}` read (1); warm is 0. GCS operations are separate.

| RPC | Reads | Writes / deletes | GCS | Asserted by |
|---|---|---|---|---|
| CreateUpload, n images (1-4) | 2 cold-or-warm (idempotency, quotas) + 1 interceptor = 3 | 2 + n (idempotency, quotas, n media docs); replay 1 read, 0 writes | 0 (signing is IAM `signBlob`) | `TestIntegration_CreateUploadAndFinalizeBudgets` |
| FinalizeUpload, n images | n (media docs) + 1 (Vision counter, once per 60 s per instance) + 1 interceptor; +1 account-age read on the exhausted path (cached) | n (resolve) + 1 (Vision counter) | per image: 2 Class A (copies), 4 Class B (attrs and head of full and thumb), 1-2 Vision fetches; deletes free | same |
| FinalizeUpload replay | n | 0 | 0 | `TestFinalize_ReFinalizeIsIdempotent` (unit) |
| CreatePost with n images | 3 + n (interceptor, idempotency, quotas, n media; +<= 10 handles if mentions) | 4 + n; replay 1 read, 0 writes | 0 | `TestMediaChain_PostWithImagesAndDeleteJob` (reads <= 5, writes 6 for n = 2) |
| DeletePost with images | 1 post (0 cached) + 1 interceptor | 1 + 1 delete; **1 Pub/Sub publish** | 0 | `TestDelete_PublishesPostDeleteJob` (unit), chain test |
| `post_delete` job, n images | 1 (post) + n | n deletes | 4 free deletes per image | `TestIntegration_PostDeleteJobAndPurge` |
| UpdateProfile with avatar | 1 interceptor + 1 media + 1 profile = 3 | 1 | 0 | `TestMediaChain_Avatar` (reads <= 3) |
| Account purge, media step | 1 minimum per page + 1 per doc (page <= 100) | 1 delete per doc (batch <= 100) | 4 free deletes per image | `TestPurgeUser`, `TestIntegration_PostDeleteJobAndPurge` |
| Account export, media section | 1 minimum + 1 per doc (pages of 100) | 0 | 0 | `TestAccountLifecycle_ReferenceAccountBudgets` (704 = 703 + 1) |

Every query has a `Limit` (`ListByOwner` takes an explicit page size, at most 100; the media docs of one post are at
most 4). There are no reads in loops: media docs are fetched with one `GetAll`.

## Cost line (Stage 0, 300 DAU, 0.15 upload calls per DAU, about 1.5 images per call = 68 images/day)
| Resource | Quantity / month | Free allowance | Overage | Notes |
|---|---|---|---|---|
| Firestore | about +0.4 reads, +0.9 writes, +0.15 deletes per DAU per day | 50k / 20k / 20k per day | $0 | negligible; CreatePost with images adds n reads and n writes |
| GCS Class A | 4 per image (2 client PUTs + 2 server copies) = about 8,200 | 5,000 | about $0.04 | runs out near 200 DAU, cents |
| GCS Class B | about 6 per image for processing + about 31 per DAU per day for views = about 33,000 | 50,000 | $0 (about $0.09 beyond 54 DAU in `cost-model.md`) | views are cached on device (`cached_network_image`) |
| GCS storage | about 300 KB per image pair, about 2,000 images/month = 0.6 GB/month | 5 GB | $0 for about 8 months | lifecycle removes unattached uploads after 2 days |
| Cloud Vision SafeSearch | 2 units per image (D1) = about 4,100 units | 1,000 units | about $4.60 ($1.50 per 1,000 units) | **hard-capped by `VISION_MONTHLY_CAP` (default 10,000 units, so at most about $13.50/month)**, then D7 |
| Pub/Sub | one small message per deleted post with images | 10 GiB | $0 | |

No fixed-cost resource is added. All of the above is pay-per-use; the Vision line is the only one that can exceed $1
and it is bounded by code (`VISION_MONTHLY_CAP`), not by hope. With `VISION_SCREEN_THUMB=false` it halves.

## Acceptance criteria and where they are tested
| Criterion (from `phase1.md` P4 "Done when") | Test |
|---|---|
| Oversize, wrong-type and MD5-mismatch uploads are rejected | `TestCreateUpload_Validation`, `TestFinalize_Rejections` |
| Cap cut-over is tested with a fake moderator | `TestFinalize_VisionCap`, `TestFinalize_CapIsSharedAcrossAFinalizeAndNeverExceeded` |
| Unmoderated bytes are never public | `TestFinalize_Rejections` (no public object, private copies deleted), `TestFinalize_ModerationOutageFailsClosed`, `NewBuckets` refuses equal buckets |
| Deleting a post removes its public objects (resumable job, idempotent) | `TestJobsHandle*`, `TestMediaChain_PostWithImagesAndDeleteJob` |
| `DEGRADED_MODE=nomedia` blocks CreateUpload | `TestMediaChain_FlagOffAndNoMedia/nomedia` |
| M2: lists never fall back to the full image | Flutter `PostMedia` tests in `post_action_bar_test.dart`, `post_card_test.dart` |

## Test inventory
- Unit (fakes, table-driven): `internal/media/{service,jobs,purge,server,vision}_test.go`,
  `internal/posts/service_media_test.go`, `internal/posts/text/optional_test.go`, `internal/identity/avatar_test.go`,
  `pkg/platform/objstore/*_test.go` (signed PUT with a real V4 signature).
- Integration (emulators, `//go:build integration`): `internal/media/repo_firestore_integration_test.go` (budgets,
  quota, concurrent finalize, attach-in-transaction, job, purge, Vision counter),
  `internal/apiserver/media_chain_integration_test.go` (CreatePost / avatar / DeletePost -> job -> cleanup, flag off,
  nomedia), `pkg/platform/objstore/objstore_integration_test.go` (attrs, head, copy).
- Not testable on emulators: V4 signing through IAM `signBlob` and `rewrite` on real GCS, Vision itself. Covered by T8.

## Risks and follow-ups
- **MD5 collision** (accepted): the signed URL pins Content-MD5, so a PUT can only store bytes with the declared MD5.
  A crafted MD5-colliding pair could differ between SafeSearch and the copy. Closing it needs generation-pinned
  copies (`Conditions.GenerationMatch`); not done at Stage 0 (needs a chosen-prefix collision *and* a swap in a
  10-minute window).
- A failed `post_delete` publish leaves a deleted post's objects until the account is deleted (D4). The log line
  `post_delete_job_publish_failed` goes to Error Reporting; a reconciliation sweep (`media` where `postId` has no post)
  is a possible P5/P9 follow-up and would cost one query per run.
- Replaced avatars are not cleaned up (D10).
- The TTL policy on `media.expireAt` is already declared in Terraform (`modules/firestore`); confirm it is applied in
  both projects before enabling the flag.
