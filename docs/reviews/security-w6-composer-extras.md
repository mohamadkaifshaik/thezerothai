# Security review: W6 composer extras, polls, drafts and GIFs (W6-20)

**Reviewer:** security-auditor · **Date:** 2026-10-31 · **Reviewed:** `origin/main` at `57d86828`, read only. It includes W6-5 #497, W6-6 #504, W6-7/8 #515, W6-9 #496, W6-10 #505, W6-18 #519 and W6-15 + W6-16 #525 (branch head `ff3582d9`, merged as `7e3f5855`). Two open PRs were read as diffs: #521 (D-1 delay clamp) and #530 (`post_hash` on the VotePoll line).

**Design:** ADR-0029 (Accepted 2026-10-30), with its as-built notes N1 to N4 and the founder decisions of 2026-11-01. Plan `docs/plans/ui-w6-composer-extras.md`, W6-20.

**Code read:**
- `backend/internal/engagement/{service_polls,server_polls,repo_polls,purge_polls,purge,service}.go`
- `backend/internal/posts/{poll,convert,api,audience,service_engagement,service_delete}.go`, `posts/text/text.go` (`NormalizeLabel`)
- `backend/internal/media/{finalize,gifscan,gifscreen,gcs,vision,service}.go`
- `backend/pkg/platform/objstore/objstore.go` (`SignedPutURL`, `CopyTo`, `Attrs`), `pkg/platform/mw/mw.go` (request line), `pkg/platform/logger/{logger,convhash}.go`, `pkg/platform/apierr/apierr.go`
- `backend/internal/apiserver/{ratelimit_config,apiserver,lifecycle_poll_votes,engagement_wiring}.go`, `pkg/platform/config/config.go`
- Client: `app/lib/features/posts/{data/drafts_repository,domain/composer_draft,presentation/{composer_screen,drafts_screen,bloc/composer_cubit,bloc/drafts_cubit,widgets/draft_row}}.dart`, `app/lib/core/storage/app_database.dart`, `app/lib/core/router/app_router.dart`, `app/lib/features/account/presentation/delete_account_screen.dart`, `app/lib/features/media/{data/gif_source,data/media_repository,data/media_uploader,domain/image_processor}.dart`, `app/lib/shared/widgets/{post_media,poll_card}.dart`, `app/lib/features/engagement/presentation/bloc/poll_cubit.dart`, `app/android/app/src/main/AndroidManifest.xml`
- `infra/terraform/modules/{media-buckets,vision-quota,iam}`, `infra/terraform/envs/{dev,prod}/main.tf`, `scripts/promotion/flag-ceiling.json`, `docs/releases/v0.4.0.md`

**Run:** `GOWORK=off go test ./internal/engagement/ ./internal/media/ ./internal/posts/`, green.

**Not run:**
- `govulncheck` and `osv-scanner`: not installed on this machine. W6 added no Go module or pub package (`go.mod` and `pubspec.*` are unchanged since 2026-10-28).
- Integration tests, `-race`, Flutter tests.
- No cloud calls. The Vision behaviour on animated WebP (H-2) and the billing of per-image Vision errors (H-3) are therefore unverified.

**Test inputs:**
- `docs/reviews/test-report-w6-gif.md` (W6-18): its D-1 and R-1 are assessed here.
- The polls test report (W6-17) and the client tests (W6-19) do not exist yet.

**Where these features run today:**
- No founder stop is needed: my role's stop rule applies to a Critical finding in code that already serves traffic, and every finding here is High or lower.
- Evidence that real users cannot reach the media findings:
  - `FEATURE_MEDIA`, `FEATURE_GIF`, `FEATURE_POLLS` and `FEATURE_DRAFTS` have dev ceilings of allowlist 6 (`scripts/promotion/flag-ceiling.json`).
  - That file has no `envs.prod` block, and `validate-revision.sh:14` refuses an env without one.
  - The only prod release record, `docs/releases/v0.4.0.md`, lists `FEATURE_POSTS` off and no media flag. There is no later record.
- The live prod value of `FEATURE_MEDIA` cannot be checked from the repo, because the prod tfvars are gitignored. Every repo signal says off. If prod media were on, H-3 would be worth an immediate founder ping.

## 1. Threat model (STRIDE)

**Assets:**
- The pairing of voter and choice (uid → choice).
- Poll integrity (one vote per account; exact counts).
- Per-choice counts before the viewer votes.
- The integrity of public media: the only automated moderation is SafeSearch before the public copy.
- Unsent drafts on a device.
- The cost budget: the INR 25,000 credit cap, the Vision monthly cap, the Firestore free quota.

| STRIDE | Threat | Control in the code | Result |
|---|---|---|---|
| **S**poofing | Voting as someone else; reusing another user's key or vote id | The uid comes from the Firebase ID token. The vote doc id is `{postId}_{uid}` built from the token uid. `RequireVerifiedEmail` runs in VotePoll. Draft rows are read by `(uid, draftId)` only. | Holds |
| **T**ampering | Changing a vote; double voting; inflating counts; **swapping media bytes after screening**; GIF bombs | A `Create` precondition on the natural key, and one atomic batch (Create + Increment + ArrayUnion). The `Exists` precondition on the post. GIF pre-scan limits before any decode. The MD5 re-check of the read bytes. | **H-1** (publish swap), **H-2** (animated WebP accepted as a still) |
| **R**epudiation | A disputed vote | The vote doc keeps uid, choice and createdAt until `closesAt + 30 d`. The user's export lists their votes. | Holds (L-2 export gap) |
| **I**nformation disclosure | Who voted for what; results before voting; a blocked author's poll; drafts on shared devices; logs | Redaction in the one converter, with a guard test over every PostView producer. Hidden counts are 0 (byte-identical). Refusals come after the visibility read. ALREADY_VOTED carries the caller's own choice only. No voter-list RPC. The request line carries no error metadata. Drafts are filtered by uid. | **L-1** (voter list in logs via #530), L-2, L-3, L-4, L-5 |
| **D**enial of service / cost | Vote floods; GIF decode floods; **Vision spend that never counts**; slot starvation | VotePoll bucket and daily cap; one vote per account per poll; the read budget. Upload quota 20/day; one GIF slot per instance; the 2 s decode deadline. `VISION_MONTHLY_CAP` with `reject`; the Vision project quota of 30 req/min. | **H-3** (uncounted Vision spend) |
| **E**levation of privilege | Voting in your own poll; voting in a protected author's poll; voting while the flag is off | Author check; `posts.Viewable` with `Audience.Decide` (protected, blocked, hidden, author not ACTIVE → one NOT_FOUND); flag gate first, 0 reads | Holds |

### Effective limits (per instance × 3 max instances)

| Limit | Per instance | Effective | Store |
|---|---|---|---|
| VotePoll bucket (`RATE_LIMIT_POLL_VOTE_PER_MIN`) | 30/min | 90/min | memory |
| `poll_votes_daily` (`POLL_VOTES_PER_DAY`) | 300/day | 900/day; every call counts, including replays and refusals | memory |
| New-account tier (`POLL_VOTES_PER_DAY_NEW_ACCOUNT`, in the service) | 50/day | 150/day; resets when an instance restarts | memory |
| One vote per account per poll | — | exact | natural key `pollVotes/{postId}_{uid}` |
| Read budget (`READ_BUDGET_PER_UID_PER_DAY`) | 2,000 reads | 6,000 reads/uid/day | memory |
| CreateUpload + FinalizeUpload bucket | 10/min | 30/min; **no daily cap on FinalizeUpload** (H-3) | memory |
| Uploads quota | 20/day, 5 for new accounts | exact | `quotas` |
| GIF screening slot | 1 | 3 at once | memory |
| `VISION_MONTHLY_CAP` (10k; 20k–40k in credit mode, `reject`) | — | exact while units are counted; **bypassed by H-3** | `admin/vision-*` |
| Vision project quota (`safe_search_requests_per_minute`) | — | 30 req/min per project | GCP quota |
| Poll creation | posts quota (100/day) and the CreatePost bucket | exact | `quotas` |

### Cost-amplification scenarios (INR 95/USD, `cost-model.md` §7 prices)

- **VotePoll, worst case for one account:**
  - At most 900 calls a day across 3 instances. At most 2,700 writes a day, and only if the account can see 900 open polls (sockpuppets can create them inside the posts quota).
  - That is $0.0028 a day, about **INR 8 per account-month**; 100 sockpuppets cost about INR 800 a month.
  - Requests stay at 900 a day per account, because the cap also counts refusals.
  - Bounded. No finding.
- **GIF uploads, honest path:**
  - 20 a day × 2 units = 1,200 units per account-month, about INR 171.
  - Capped service-wide by `VISION_MONTHLY_CAP` with `reject`: at most about INR 1,282 a month at 10k, about INR 5,560 at 40k.
  - A ring that exhausts the cap is a denial of service on uploads (GIFs are REJECTED for everyone at the cap). That is pre-existing for photos and unchanged by W6.
- **H-3, uncounted Vision spend:**
  - About **INR 13,000 per account-month**, bounded by the read budget.
  - About **INR 93,600 a month** across about 7 accounts, at the Vision project quota.
  - The counter never moves, so the cap never trips. Details under H-3.

## 2. Findings

### H-1 (High): publish swap after screening (W6-18 R-1); applies to GIFs, thumbnails and photos — **FIXED in PR #PRNUM (W6-25, In review)**: create-only signed PUT (`x-goog-if-generation-match: 0`), generation pinned on the GIF read and on `CopyTo`; a swapped object is REJECTED (`changed_after_verify`).

**Where:**
- `objstore.go:206-238`: the signed PUT binds Content-Type, Content-MD5 and a length range, but no generation precondition. A V4 URL is reusable until it expires (10 min).
- `gcs.go:62-64` → `objstore.go:156-185`: `Publish` is `CopierFrom(src)` with no source generation or condition, so it copies whatever object is live at copy time.
- `vision.go:54`: photos and thumbnails are screened by `gs://` URI, which reads the live object at the moment Vision fetches it.
- `gifscreen.go:104-112`: the GIF is read once and its length and MD5 are compared with what verify approved.
- Pinned by `TestW618_KnownResidual_PublishSwapAfterScreening` (`gif_w618_test.go:437`).

**Attack:**
1. Content-MD5 is signed, so a re-PUT must carry the same MD5 as the declared one. The attacker therefore builds an identical-prefix MD5 **collision twin**: a harmless file A and an explicit file B with the same MD5 and size.
   - Identical-prefix MD5 collisions take seconds with public tools.
   - The published constructions place the collision blocks in GIF comment or application extensions, or in JPEG COM segments, so that A and B render differently. Both formats are covered.
2. CreateUpload declares A's MD5 and size. The attacker PUTs A and calls FinalizeUpload.
3. While the finalize runs, the attacker re-PUTs B with the same signed URL. It must land after the screening read and before the copy.
   - GIF: after the API's full read. The window is the sampling (up to 2 s) plus the Vision call (1–2 s).
   - Photo or thumbnail: after Vision fetched the object. The window is the rest of the Vision call plus the copy.
4. The MD5 re-check at `gifscreen.go:110` cannot see the swap: B has the same MD5. If B lands too early it is screened and REJECTED, which burns 1 of 20 daily uploads. Retries are cheap.
5. `Publish` copies B into the public-read bucket, and the doc is READY.

The test report suggests re-checking the MD5 of the published copy. That would not help, for the same reason as step 4.

**Impact:**
- Explicit content goes into public-read GCS with a READY status, bypassing the only automated moderation. Report-driven review remains the only backstop.
- Legal and reputational exposure (CSAM or pornography on our bucket). It is a rollback trigger in the plan.
- Reachable in the photo pipeline since P4, and in avatars and banners. Not reachable today: media is off in prod and allowlisted to team accounts in dev.

**Cost scenario:** none directly. Each attempt spends the normal 2 Vision units.

**Fix (both parts; the first alone closes it):**
1. **Make the signed PUT create-only.**
   - Add `x-goog-if-generation-match:0` to `SignedURLOptions.Headers` and to the returned headers map. The client already sends exactly the headers the server signed (`media_repository.dart:152-158`).
   - A second PUT to the same object then gets 412 and can never replace the bytes.
   - Client change: treat a 412 on a PUT as "already stored" and continue to FinalizeUpload. Verify still proves size, type and MD5.
2. **Defence in depth: pin the verified generation.**
   - `objstore.Attrs` returns `Generation`, and `verify` records it for both objects.
   - The GIF read uses `ObjectHandle.Generation(g)`.
   - `CopyTo` takes the generation and copies with `src.If(storage.Conditions{GenerationMatch: g})` (rewrite `ifSourceGenerationMatch`). Do not use `src.Generation(g)`: with versioning it could copy a non-live generation.
   - Map a failed source precondition (412) to REJECTED `changed_after_verify`, never to `uploadMissing` or an internal error.
   - Make the emulator `streamCopy` fallback honour the generation too, or the tests cannot prove it.
   - Why this suffices: generations only increase. If the live generation at copy time equals the one verified, nothing was written in between, so Vision (by URI) and the sampler saw the same bytes.
3. **Tests.** Flip `TestW618_KnownResidual_PublishSwapAfterScreening` to REJECTED (its failure message already says so). Add a photo variant and a thumbnail variant.

**Proposed ticket:** W6-25, backend-developer, plus frontend-developer for the 412 handling, S. **Gate:** before `gif` or `media` leaves the dev allowlist, and before `FEATURE_MEDIA` leaves `off` in prod.

### H-2 (High): an animated WebP is accepted as a still image (photo, avatar, banner, and the GIF thumbnail)

**Where:**
- `media/service.go:443-453`: `sniffImage` returns `image/webp` for any `RIFF....WEBP` header. It does not look at the VP8X animation flag or at ANIM/ANMF chunks.
- `media/service.go:218, 254`: WebP is allowed for every purpose and as a GIF's `thumb_content_type` (ADR-0029 D10).
- Lists render `thumbUrl` with `CachedNetworkImage` (`post_media.dart:168`). Flutter plays an animated WebP automatically there, in avatars and in banners.
- No client produces WebP: the only encoder is `img.encodeJpg` (`image_processor.dart:314`), and `git log -S encodeWebP -- app/` is empty. ADR-0029 D10's "the client already encodes WebP" is not true of the code.

**Attack:**
1. Build an animated WebP whose first frame is harmless and whose later frames are explicit or flashing (`img2webp` or `ffmpeg`).
2. Upload it as a POST photo, an AVATAR or a BANNER, or as the thumbnail of a GIF post.
3. Google's supported-files page lists "WEBP" with no note on animation (it says "first frame only" for animated GIF). If SafeSearch reads only the first frame, the file goes READY with no frame sampling at all.
4. Feeds, avatars and banners **autoplay** it. That ignores F10's "static thumbnail, tap to play" and the platform's "Reduce motion".
   - An animated avatar plays on every row the author appears in.
   - A flashing avatar is a photosensitive-seizure harassment vector.
5. For a GIF post, the thumbnail path bypasses the D11 sampler entirely: the sheet screens the GIF, and the thumbnail is only screened by URI.

**Impact:**
- A moderation bypass more direct than the F11 residual the founder accepted: no sampling, no collision and no race needed.
- Autoplay of unmoderated motion everywhere.
- If Vision instead fails on animated WebP, every attempt becomes an H-3 loop.

**Cost scenario:** none beyond H-3.

**Fix:**
- In `verify`, for `image/webp` (full and thumbnail), refuse with REJECTED `invalid` when:
  - the first chunk is `VP8X` and flag byte `head[20] & 0x02` (animation) is set, or
  - the 512-byte head contains an `ANIM` or `ANMF` FourCC.
- The head already read covers this, so there is no extra Class B.
- Better: drop `image/webp` until a client encodes it. That needs an architect note on ADR-0005 and ADR-0029 D10.
- Either fix also closes the GIF-thumbnail path.

**Proposed ticket:** W6-26, backend-developer (plus an architect note if WebP is dropped), XS. **Gate:** as H-1.

### H-3 (High, cost amplification): Vision units spent by a half-failed screen are never counted, and the call can be repeated without limit

**Where:**
- `finalize.go:238-258`: when `screen` returns any error, `s.vision.release(units)` returns **all** reserved units. The doc stays PENDING, the claim is released (`finalize.go:220-224`), and the answer is retryable UNAVAILABLE.
- `finalize.go:471-494`: `screenAll` runs the two Vision calls in parallel and returns an error if either fails, even when the other returned an annotation, which Google bills.
- `vision.go:79-81`: a per-image `r.Error` (for example "Bad image data" on a thumbnail whose first bytes are `FF D8 FF` and the rest garbage) is an error. Verify checks only size, type, MD5 and 3 magic bytes.
- `ratelimit_config.go:150, 171-172`: FinalizeUpload has only the 10/min bucket and no `DailyCap`. The uploads quota counts CreateUpload only. Nothing limits screening attempts per media doc.

**Attack:**
1. A verified account calls CreateUpload once (1 of 20 daily uploads). It uploads a valid full image (or, for a GIF, a valid GIF) and a thumbnail that passes size, type, MD5 and magic bytes but is corrupt inside.
2. It loops FinalizeUpload on that PENDING doc (`PendingTTL` 2 days).
3. Each iteration: the full image (or the GIF's sheet by bytes) is annotated and billed, the thumbnail call fails, all units are released, and the doc stays PENDING.
   - Firestore per iteration: 1 claim write, 1 release write, about 2 reads.
   - `VISION_MONTHLY_CAP` and its `reject` never trip, because nothing is ever counted.
4. Bounds:
   - The per-uid read budget (2,000 reads/day per instance, about 2 reads an iteration) caps one account at about **3,000 billed units a day**.
   - The Vision project quota of 30 requests/min (2 per iteration) caps the project at **21,600 billed units a day**.
   - Whether Google also bills the failed thumbnail call is unverified. The successful half is billed either way.

**Cost scenario:**

| Case | Units/day | INR/day | INR/month |
|---|---|---|---|
| One account (read budget bound) | 3,000 | 428 | **≈ 13,000** |
| About 7 accounts (Vision project quota bound) | 21,600 | 3,078 | **≈ 93,600** |

- The INR 25,000 credit cap goes in about 8 days. After 2026-12-26 it is real money.
- The only signals are the gross-spend budget alert (billing lag of hours to a day) and Vision `RESOURCE_EXHAUSTED`. The latter also blocks every honest upload.
- Firestore adds about 6,000 writes a day per account, about INR 0.6.

**Fix:**
1. **Count what was billed:** add a unit for every Vision call that returned an annotation, even if the other call failed. Release only the units of calls that never got a response.
2. **Treat a per-image Vision error with code INVALID_ARGUMENT** (bad image data) as REJECTED `invalid`, not retryable. A client retry cannot fix a broken file.
3. **Cap screening attempts per media doc:** a `screenAttempts` counter in the claim write that already happens (+0 writes). After 3 attempts the doc is REJECTED.
4. Optional, config: a `media_finalize_daily` `DailyCap` (for example 100).

**Proposed ticket:** W6-27, backend-developer, S. **Gate:** as H-1. It is pre-existing in the photo path (W3-22) and GIFs use the same route (sheet and thumbnail).

### M-1 (Medium): the sampler ignores the browser delay clamp (W6-18 D-1)

- Explicit frames with a delay of 0 or 1 cs can fill about 73 % of real playback and still escape every sample.
- **#521 is correct:** `sampleIndices` now counts a delay under 2 cs as 10 cs. That matches Chrome, Firefox and Safari. If Flutter plays such frames faster, the model over-weights them, which is the conservative direction for screening.
- It does not cover M-2.
- **Gate:** merge #521 before `gif` leaves the dev allowlist.

### M-2 (Medium): the frame a GIF rests on is never forced into the sample

**Where:** `gifscan.go:182-214` samples t = 0, T/4, T/2 and 3T/4 only. With more than 4 frames, the last frame is sampled only if it covers 3T/4.

**Attack:**
- A GIF without a NETSCAPE2.0 loop extension, or with a finite loop count, plays once and then **stays on its last frame**. Browsers and Flutter both honour the loop count.
- Example: 40 harmless frames, then an explicit last frame with a 2 cs delay (no clamp, even after #521). That frame is 20 ms of T, so no sample lands on it, but the viewer sees it indefinitely after one play.
- This widens F11 beyond the accepted residual ("a moment between two samples").

**Fix:**
- Always include the final frame: samples at 0, T/3, 2T/3 and the last frame, or a 3 × 2 sheet of 6 tiles, still 1 unit.
- Update ADR-0029 D11 point 4 and `docs/runbooks/media.md` (architect note).
- Add a test: a harmless loop with an explicit 2 cs last frame and no NETSCAPE block must be REJECTED.

**Proposed ticket:** W6-28, backend-developer plus an architect note, S. **Gate:** with M-1, before `gif` leaves the dev allowlist.

### L-1 (Low): PR #530 puts a voter list per poll in the logs

**Where:** #530 adds `post_hash = logger.HashUID(postID)` to the VotePoll request line and to the `poll_vote_contention` WARN, next to `uid_hash = HashUID(uid)` (`mw.go:146-153`). Both are the unsalted SHA-256 of a public id.

**Scenario:**
- Anyone with `logging.logEntries.list` (project roles; not `tf-plan` since W7-32) can compute `HashUID` of any poll id and of any uid.
- From 30 days of `outcome=voted` lines, they can list who voted in which poll. They cannot see the choice.
- That contradicts F3's "nobody can see who voted" in spirit, and it is the same class as W7 L-7, which W7-34 fixed for conversations with a keyed hash.

**Fix:**
- Key `post_hash` the way `HashConversation` is keyed (`logger/convhash.go`): HKDF from `CURSOR_HMAC_KEY` with its own info label, for example `dzeroth log post_hash v1`.
- Give operators a way to compute it, like `opsctl messages loghash`.
- The W6-21 runbook query then groups by the keyed hash. `printf | sha256sum` no longer maps a post to it; the opsctl helper does.

**Gate:** in #530 before it merges (no new ticket).

### L-2 (Low, privacy): `userLikes.pollVotes` outlives the vote docs and is not in the export

**Where:**
- `repo_polls.go:55-57`: every vote adds `"<postId>:<choice>"` to `userLikes/{uid}.pollVotes`. That list is trimmed only above 600 entries (`service_polls.go:183-200`) and has no age bound.
- `purge.go:169-186`: the engagement export writes likes and reposts only. `purge_polls.go:150` exports the vote docs only.
- After `closesAt + 30 d` the TTL removes the vote doc. The user's own uid→choice record stays in `userLikes`, is erased only with the account, and is in no export.
- So "no residue outlives 37 days" (ADR-0029 D8) holds for other users' data, not for the voter's own record.

**Scenario:**
- A right-of-access request (DPDP Act s.11, GDPR Art. 15) gets an export that omits held personal data.
- For a poll on politics or religion, the choice is special-category data under GDPR Art. 9 (founder item, section 4).

**Fix:**
- Export the `pollVotes` entries in the `poll_votes` section, as `{postId, choice}` rows with no time.
- On the existing trim path (0 reads), also drop entries whose Snowflake post id is older than `POLL_MAX_DURATION + POLL_VOTE_TTL_AFTER_CLOSE` (37 days). A closed poll then loses only the check mark, as D3 already accepts.

**Proposed ticket:** W6-29 (with L-6), backend-developer, S. **Gate:** before `polls` leaves `off` in prod.

### L-3 (Low, product): count deltas can reveal a voter's choice

**Scenario:**
- The author sees live counts. Every voter sees them after voting, with a staleness of at most 60 s.
- On a small poll, for example from a protected account with a handful of approved followers, or a poll shared in a small circle, someone watching the counts can tie a change to the one person who just voted. That person may have said so in a reply, or liked the post at the same moment.
- X has the same property. Nothing in the code is wrong.

**Fix:** copy only. Near the vote buttons, or in the Help and Privacy text: "Votes are anonymous, but in small polls the author may be able to tell how you voted." Founder decision (section 4).

### L-4 (Low): GIF metadata, comments and trailing bytes are published unchanged

**Where:**
- The client uploads the picked bytes unchanged (`image_processor.dart` `prepareGifSync`; F10 forbids re-encoding).
- `scanGIF` (`gifscan.go:107-123`) skips comment (0xFE), plain-text (0x01) and application (0xFF) extensions.
- `scanGIF` stops at the first trailer, so bytes after it are never looked at.

**Scenario:**
- **Privacy:** GIFs exported from Photoshop or GIMP carry an `XMP DataXMP` application block. It can hold the creator's name, the tool, document ids and local file paths, and it is now published on a public URL. Photos do not have this problem, because the client re-encodes them and clears EXIF.
- **Abuse:** comment blocks and trailing bytes host arbitrary data on our public bucket (up to about 2 MiB per upload). The egress is billed to us, as for any hot-linked image.
- They are also where the H-1 collision blocks live.
- The comment text is never rendered (ADR-0029 D11 left this item to this review).

**Fix (byte-level, no re-encode):**
- Client: before computing the MD5, drop 0xFE, 0x01, every 0xFF block except `NETSCAPE2.0` and `ANIMEXTS1.0`, and anything after the trailer.
- Server: the pre-scan refuses those blocks and trailing bytes (REJECTED `invalid`). There are no old GIF clients, because `gif` has never been on.

**Proposed ticket:** W6-30, frontend-developer plus backend-developer, S. **Gate:** before `gif` leaves `off` in prod.

### L-5 (Low): drafts on shared devices

**Where:**
- `app_database.dart:540` keeps `ComposerDraftEntries` outside `clearAll` (F7, accepted).
- `drafts_repository.dart` deletes only by explicit action or `deleteAll(uid)` on a DeleteAccount made from this device (`delete_account_screen.dart:127-141`).

**Scenarios:**
1. **No notice at sign-out.** On a shared computer, common in cyber cafés in India, the drafts stay in IndexedDB/OPFS. Anyone with that browser profile can read them with DevTools. The user is never told.
2. **The kill switch strands them.** With `FEATURE_DRAFTS=off`, `/drafts` redirects Home (`app_router.dart` `_draftsFlagRedirect`), so the user has no way to delete rows that sign-out also keeps.
3. **Orphans.** An account deleted from another device (or by the backstop) leaves its drafts on this device for ever, because no sweep exists.

**Fix:**
- (1) When the signed-out uid has drafts, the sign-out confirmation says "Your unsent posts stay on this device" and offers Delete. At least on web.
- (2) Keep a delete-only path reachable while `drafts` is off (for example Settings → Delete unsent posts on this device), or delete the signed-out uid's rows at sign-out while the flag is off.
- (3) Founder option: an age limit, for example 90 days since the last edit.

**Proposed ticket:** W6-31 (with I-1), frontend-developer, S. **Gate:** (1) and (2) before `drafts` goes beyond the dev allowlist in prod.

### L-6 (Low): poll choices can look identical

**Where:** `NormalizeLabel` (`text.go:369-384`) refuses Cc, U+2028/2029 and bidi controls, but allows zero-width and other default-ignorable characters. `foldKey` (`poll.go:137`) keeps them.

**Scenario:** "Yes" and "Ye\u200Bs" pass the distinctness rule and render the same. The author can split or confuse the vote. The impact is limited, because the author already controls the poll.

**Fix:**
- Strip `Default_Ignorable_Code_Point` inside `foldKey` only (stored labels unchanged, so emoji ZWJ sequences still display).
- Add a row to `testdata/poll_rules.json`, so the Dart mirror agrees.

**Ticket:** W6-29.

### Info (verified, no finding)

- **I-1, correcting the brief: the client does take draft ids from URLs.**
  - The router accepts `/compose?draft=<16 lower-case hex>` (`app_router.dart`, `_draftIdPattern`).
  - It is safe: `_DraftLoader` reads `(uid, draftId)`, and on a miss the composer starts with a fresh `Random.secure` id (`composer_cubit.dart` `_baseDraft`). `loadDraft` refuses a draft whose uid is not the composer's.
  - So `insertOnConflictUpdate` on the `draftId`-only key cannot take over another account's row through a URL.
  - Defence in depth (W6-31): make the key `{uid, draftId}`, or use `DoUpdate(..., where: old.uid == draft.uid)`.
- **"Delete all":** met by Edit → Select all → Delete (`drafts_screen.dart:315-367`). `watch(uid)` returns every row.
- **Draft text never reaches logs:** every storage failure goes to Crashlytics as a fixed `StateError` with its stack (`composer_cubit.dart:448-451`, `drafts_cubit.dart:79-84, 139-143`). `deleteAll`'s raw error binds only the uid. Android Auto Backup and device transfer are excluded (`allowBackup="false"`, `dataExtractionRules`, W7-35). iOS backup exclusion is owed at the Apple launch.
- **Vote privacy, the brief's items confirmed:**
  - The VotePoll request line carries `rpc`, `uid_hash`, `code`, `fs_*` and the fields the service sets: `outcome`, `contention`, the op. It never carries the choice or error metadata (`mw.go:151-172`).
  - ALREADY_VOTED is FailedPrecondition, so it never reaches Error Reporting. Its `metadata["choice"]` is the caller's own stored choice.
  - A blocked, protected, hidden or deleted target, or an author who is not ACTIVE, is the one `notFound()`, before any poll check (`service_polls.go:90-107`).
  - Hidden counts are 0 with `results_visible` false, so the bytes are identical (`convert.go:174-194`). `ApplyWithheld` clears `viewer_poll_choice`. A PROTECTED embed loses `embedded.poll`. `BookmarksOnly` drops choices.
- **New-account vote cap (per instance, in memory, counts replays and refusals): accepted.**
  - Effective limits are 150/day for new accounts and 900/day for others, and an instance restart resets them (ADR-0029 N2).
  - It is a cost control, not an integrity control: the natural key gives one vote per account per poll whatever the counter says.
  - Counting refusals is the right choice for cost: a flood of refused votes is capped at the same 900 calls a day.
- **Sybil voting: an accepted residual.** Verified email (disposable addresses work) and the per-account caps do not stop a ring of real accounts, each voting once. The copy never presents polls as binding.
- **Lifecycle:**
  - The `poll_votes` step and section are registered whatever the flag. The step is appended after `messaging` (N2), so a job already past that point leaves vote docs to the TTL (at most 37 days; no prod data).
  - The TTL field `poll_votes_expire_at` must be applied in each project before `polls` leaves `off` (W6-22; D9). Without it, vote docs never expire.
  - Vote docs hold uid and choice in clear by necessity. `tf-plan` can no longer read entities (W7-32).
- **Poll text:** labels are NFC-normalised, refuse control and bidi characters, and parse no mentions or hashtags. The client renders them as plain `Text` (`poll_card.dart`), never linkified.
- **GIF guards:**
  - Bombs are refused before any decode. Decoding is one frame at a time, behind the slot. Panics are recovered and reported.
  - At the cap a GIF is REJECTED for everyone (F11 point 4).
  - The full object and the thumbnail are typed and sniffed separately, and a GIF thumbnail must be JPEG or WebP (but see H-2).
  - Public objects are served from the GCS origin, so a polyglot cannot script our pages. CSP is enforced.
  - Starving the one-GIF slot needs about 130k at-limit GIFs a day for 3 instances, against an uploads quota of 20 per account. Not practical.
- **F11 sampled-frame residual (an explicit frame strictly between samples):** accepted by the founder. M-1 and M-2 are the two ways the real exposure grew beyond what was accepted.
- **The client never re-encodes GIFs:** server screening is the only moderation. That is correct and intended (F10). The client's pre-checks (2 MiB, 1,280 px, 300 frames) only save units and are not a control.
- **Supply chain:** no new dependency in W6.

## 3. Explicit verdicts on the items handed over

| Item | Verdict |
|---|---|
| R-1 publish swap | **H-1, High.** Create-only signed PUT plus a source-generation precondition on the copy. The MD5 re-check does not close it, because a collision twin keeps the MD5. Gate: before `gif`/`media` leave the dev allowlist; before `FEATURE_MEDIA` leaves `off` in prod |
| GIF sampled-frame residual (F11) | Accepted as decided. But M-1 (#521) and M-2 must land first, because they are wider than the residual the founder accepted |
| New-account vote cap | Accepted (Info). It is a cost control. The natural key is the integrity control |
| Vote privacy | Holds in code (Info). One log-level gap in open PR #530 (L-1) and one export and retention gap (L-2) |
| Drafts (F7, unencrypted, per uid, across sign-out) | Accepted as decided. L-5 makes the risk visible and removable. The `draftId`-only key is defence in depth only (I-1), and the brief's "never from URLs" is corrected there |
| No client re-encode; comment extension passes through | Intended. L-4 strips the non-rendering blocks byte-level, which also covers privacy metadata |
| `poll_vote` logs lack a post id (cost) | #530 adds it. Use a keyed hash (L-1). No PII in any other new line: `gif_screen` carries counts and enums only (`gifscreen.go:137-139`); `engagement_purge_poll_votes` carries `uid_hash` and counts |

## 4. Founder actions

1. **Privacy Policy lines** (extends `docs/plans/roadmap.md` section 9, item 3.18):
   - Polls: your vote is stored with your account so you can vote only once. Nobody else sees who voted for what, but the author sees live totals, and in small polls that can reveal how you voted (L-3). Votes are deleted with your account, and from our records 30 days after the poll closes (the per-user copy once W6-29 lands, L-2). Your export lists them.
   - Drafts: unsent posts stay on the device where you wrote them, including after you sign out. They never reach our servers, are not in your export, and are deleted when you delete your account from that device.
2. **GDPR Art. 9:** decide whether polls may ask about politics or religion while EU users can sign up. If they may, L-2 becomes required before prod, and the policy should name the data. The DPDP Act has no special categories; GDPR does.
3. **Photo pipeline in prod:** H-1, H-2 and H-3 are pre-existing in photos, avatars and banners. They must be fixed before `FEATURE_MEDIA` leaves `off` in prod, not only before `gif`.
4. **L-3 copy:** accept the small-poll inference with the copy line, or ask for a different product rule.
5. **L-5 option (3):** an age limit on drafts, or none.

## 5. Proposed tickets (the planner assigns final numbers; W6-24 is the highest existing)

| ID | Findings | Owner | Size | Gate |
|---|---|---|---|---|
| W6-25 | H-1: create-only signed PUT (`x-goog-if-generation-match:0`), client handles 412, generation pinned on the GIF read and on `CopyTo` (`ifSourceGenerationMatch`), emulator `streamCopy` honours it, flip `TestW618_KnownResidual_PublishSwapAfterScreening` | backend-developer + frontend-developer | S | Before `gif` or `media` leaves the dev allowlist; before `FEATURE_MEDIA` leaves `off` in prod |
| W6-26 | H-2: refuse animated WebP (VP8X animation flag, ANIM/ANMF), or drop WebP with an architect note | backend-developer (+ architect) | XS | As W6-25 |
| W6-27 | H-3: count billed Vision units per call, INVALID_ARGUMENT → REJECTED, a `screenAttempts` cap per doc, optional `media_finalize_daily` cap | backend-developer | S | As W6-25 |
| W6-28 | M-2: always sample the final frame (with #521 for M-1), ADR-0029 D11 note and runbook | backend-developer + architect | S | Before `gif` leaves the dev allowlist |
| W6-29 | L-2: export `userLikes.pollVotes` and age-prune it on the trim path; L-6: `foldKey` ignores default-ignorables | backend-developer | S | Before `polls` leaves `off` in prod |
| W6-30 | L-4: strip non-rendering GIF blocks and trailing bytes on the client; the server pre-scan refuses them | frontend-developer + backend-developer | S | Before `gif` leaves `off` in prod |
| W6-31 | L-5 (1) and (2): sign-out notice and a delete path while `drafts` is off; I-1: `{uid, draftId}` key | frontend-developer | S | Before `drafts` goes beyond the dev allowlist in prod |
| — | L-1: keyed `post_hash` | backend-developer | XS | In PR #530 before it merges |
| — | M-1: D-1 delay clamp | backend-developer | — | Merge PR #521 before `gif` leaves the dev allowlist |
| — | L-3 copy, Art. 9 decision, L-5 (3) | founder | — | Before prod |

## 6. Verdict per flag

"Dev beyond the allowlist" (dev percent) also needs a founder-gated ceiling raise: `max_percent` is 0 for all three flags and for `media`.

| Flag | Dev allowlist (team and test accounts only, ceiling 6) | Dev beyond the allowlist | Prod |
|---|---|---|---|
| `polls` | **GO** | **GO** once L-1 is fixed in #530, W6-17 is green and the `pollVotes` TTL is applied in dev | **GO** from security once W6-29 is done, the TTL and the `posts.poll` / `userLikes.pollVotes` fieldOverrides are live, the section 4 policy lines exist and the Art. 9 decision is made. Never ahead of `engagement` |
| `drafts` | **GO** | **GO** | **GO** once W6-31 (1) and (2) are done and the policy line exists |
| `gif` | **GO**, on condition that W6-25 to W6-28 are ticketed and `gif` and `media` stay on team and test accounts only | **BLOCKED** until H-1, H-2, H-3 (W6-25 to W6-27), M-1 (#521) and M-2 (W6-28) are fixed. The same holds for `media` | **BLOCKED** until all of the above plus W6-30. H-1 to H-3 also block `FEATURE_MEDIA` in prod |

SECURITY: BLOCKED — H-1, H-2, H-3
