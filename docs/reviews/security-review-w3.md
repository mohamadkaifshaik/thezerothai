# Security review: UI wave W3 Part A (profile extras, profile tabs, likes list, "Follows you", who to follow)

Ticket W3-22 of `docs/plans/ui-w3-profile-graph-completion.md` (ADR-0024). Reviewed by the security-auditor agent,
read-only, on `main` 3a4e175 (2026-10-27), after W3-5 to W3-16 had merged (#329 to #343). `main` has since moved to
533e9dc (#341, docs only; #344, W3-18, reviewed at its branch head fee1c0d). The open client branches were reviewed at
`feat/ui-w3-17` f4dcec5 and `feat/ui-w3-19` fb1ce73. Verdict: **CLEAR WITH FIXES**. There is no Critical or High
finding; there are three Major (M-1 to M-3), five Low and six Info. None blocks W3-24 (the 3-uid dev allowlist). M-1, L-1,
L-2, L-3 and L-5 land before their flags leave the dev allowlist; M-3 lands before `media` or `profile_extras` widen past
an allowlist in prod; M-2 lands with the founder's prod apply; L-4 goes in the next backend fix PR. Severity words follow
the W2 record (Major is its Medium).

## Scope

The new Part A surface:
- `UpdateProfile` banner, location, website and `pinned_post_id` (W3-6), and their rendering (W3-14, W3-15, W3-17);
- `MEDIA_PURPOSE_BANNER` and its Vision path (W3-5);
- `posts.hasMedia`, the `PinChecker`, the tab queries and `opsctl backfill-has-media` (W3-7, W3-8);
- `GetUserTimeline` MEDIA and REPOSTS (W3-9, W3-16);
- `ListLikedPosts` (W3-10, W3-18);
- `GetProfileRelationship` (W3-11, W3-14);
- `ListSuggestedUsers` (W3-12, W3-19);
- the export fields and right-to-delete coverage;
- the `profile_extras` kill switch.

Method: STRIDE per surface (`security-checklist` skill), the ADR-0024 D10 rate-limit arithmetic at per-instance x 3
instances, and a cost-attack estimate per finding.

Prices:
- Firestore asia-south1: $0.035 per 100k reads, $0.104 per 100k writes.
- Vision: $1.50 per 1,000 units past the free 1,000.
- GCS us-central1: Class A $0.005 per 1k operations, Class B $0.0004 per 1k.
- Egress: $0.12/GiB. Exchange rate: INR 95 per USD.
- Sources: the plan's Cost section and `docs/reviews/cost-model.md`:275.

The tester's W3-20 authz results do not exist yet (W3-20 is Open). This review rests on the code and on each ticket's
own tests.

**W3-24 criterion.** A finding blocks W3-24 only if two things are true: the 3-uid dev cohort can reach it through the
four W3 flags, and it makes that rollout or its flag-off smoke unsafe. Some findings sit on paths that are already live
without any W3 flag: media finalize, UpdateProfile's text fields, the media bucket IAM, and `GetProfileRelationship`
under `graph`. Those are tracked on their own gates. The plan's rule for W3-22 ("fixed or ticketed before any dev
allowlist") is met once the fix tickets below are filed.

## Threat model (STRIDE)

| Surface | Threat | Control (evidence) | Residual |
|---|---|---|---|
| Website | S: homograph host | Client shows the lower-case ASCII host, punycode for non-ASCII labels, and launches a URL rebuilt from that same host (`app/lib/shared/format/profile_website.dart`:39-68, :70-83), so what the viewer reads is what opens | ASCII look-alikes (paypa1) are out of scope; L-2(b) |
| Website | T: `javascript:`, userinfo, control/bidi, `\` | Server: http/https only, host required, no userinfo, no Cc/space/bidi, <= 100 code points (`backend/internal/identity/validate.go`:114-137). Client re-check: `%`, `\`, `@`, `[` never rendered (`profile_website.dart`:24-26, :47, :79). Launcher blocks `javascript:` and opens `_blank` with `noopener,noreferrer` (url_launcher_web 2.4.3 `url_launcher_web.dart`:87; `app/lib/shared/widgets/post_card.dart`:36-46) | L-3 (LAN hosts) |
| Website | I: Referer, SSRF | Hosting `Referrer-Policy: strict-origin-when-cross-origin` (`firebase.json`:33); the server never fetches the URL | none |
| Website, banner, location | E: content outlives the kill switch | Only the pin is omitted while globally off (`identity/service.go`:286-291) | **M-1** |
| Location, name, bio | S: line breaks, bidi reordering | Location rejects Cc and bidi controls (`validate.go`:98-108) | **L-2** |
| Banner upload | T: oversize, wrong type, someone else's media | Byte caps bound in the signed URL and re-verified with size, MD5, type and magic bytes (`backend/internal/media/service.go`:130-135, :170-175, :210; `media/finalize.go`:294-332). ResolveBanner requires owner, BANNER purpose and published, one MEDIA_NOT_READY (`media/attach.go`:107-121; `identity/service.go`:376-391) | I-4 (pixels) |
| Banner content | S: explicit image | SafeSearch on full and thumb with the avatar Racy rule (`finalize.go`:336-338, :374-379) | I-5 (unscreened at the cap); M-1(d) (no narrow takedown) |
| Banner, Vision | D: cost and cap exhaustion | 20/day uploads quota, `VISION_MONTHLY_CAP`, `reject` policy available | **M-3** |
| Replaced banners | I: old images | Kept until account deletion (ADR-0024 D1 Option 5A), public by URL | **M-2** (listable); founder question 2 |
| Pin | I: existence oracle | One VALIDATION answer for every cause (`identity/service.go`:296-299, :358-360, :392-406; `backend/internal/posts/pin.go`:27-44) | I-2 (timing) |
| Pin | T: forged `post_delete` clears a live pin | OIDC push. Fresh existence read that bypasses caches (`backend/internal/apiserver/media_wiring.go`:70-77). Clears only that exact id; `Update`, never `Set` (`identity/pin_job.go`:53-79; `identity/repo_firestore.go`:377-384) | none |
| Pin | D: one GetPost per profile view | Omitted from every `Profile` while globally off (`identity/service.go`:174, :214, :221, :279, :504, :553 feed all five `toProtoProfile` sites, `identity/server.go`:112, :134, :152, :175, :187); list rows carry `AuthorSnapshot` only (`backend/internal/graph/server.go`:72-92) | none |
| Tabs | I: scraping, blocked or suspended author | NOT_FOUND identical to GetProfile for a missing, non-ACTIVE or blocked-by target, overflow included (`backend/internal/timeline/service.go`:427-455). `isPublic` (:521). Embed filter with overflow fail-closed (:294-335) | none |
| Tabs | T: token reused across caller, target or tab | AEAD binding `tl\|user\|caller\|target\|tab` (`timeline/tokens.go`:66-69); parse costs 0 reads (:128-156); unknown tab is VALIDATION and the flag is checked before any read (`timeline/service.go`:402-421) | none |
| Likes list | I: someone else's likes | No user id in the request; the path comes from the token uid (`backend/internal/engagement/server_likes_list.go`:44-63) | none |
| Likes list | T: cursor forgery | Sealed to `likes\|<uid>`, 24 h TTL, payload validated, 0 reads on failure (`engagement/service_likes_list.go`:52-76; `engagement/list_common.go`:41-52). Drop rules incl. overflow and `privateToViewer` (:64-142) | none |
| Follows you | I: block oracle, arbitrary pair | One target-to-caller edge only. Blocked-by is NOT_FOUND before any Directory or edge read (`graph/relationship.go`:48-90); bytes identical (`identity/service.go`:108-111). Pair cache cleared by this instance's Follow, Unfollow and Block, both directions on Block (`graph/rpcs.go`:60, :111, :154-155) | I-1 (timing) |
| Suggestions | I: blocker shown, enumeration | Exclusion matrix twice (`graph/suggester.go`:156-161; `graph/suggestions.go`:104-119). Overflow suggests nothing (`suggester.go`:68-71). No cursor, no target, <= 5 rows | **L-1** |
| Suggestions | T: steering | Rank by co-follow count, then a daily hash | **L-5** |
| UpdateProfile | D: write flood, link rotation | Default 60/min bucket only | **L-4** |
| Export, delete | R/I | Export profile section adds bannerUrl, location, website, pinnedPostId and never status, snapshotVersion or deletionJob (`identity/lifecycle_export.go`:58-84). The media eraser removes every media doc and both public names, purpose-agnostic (`media/purge.go`:39-77). `users/{uid}` goes last | founder question 2 |
| opsctl backfill | T: unintended prod run | `--project` required; typed confirmation for any `-prod` id, the dry run included (`backend/cmd/opsctl/main.go`:200-218, :262-269); field-level `Update`, <= 5,000 writes per run | none |
| Rollout | T: an old revision rewrites the users doc | none | I-3 |

## Effective limits and read-cost bound (rule 11, `stage-ladder`)

| RPC | Per instance (config) | x 3 instances | Daily bound | Worst reads per call |
|---|---|---|---|---|
| `GetUserTimeline` MEDIA / REPOSTS | 30/min (`pkg/platform/config/config.go`:432), shared with Posts and Replies (`apiserver/ratelimit_config.go`:104) | 90/min | read budget | 54 at page 50 |
| `ListLikedPosts` | 10/min (`config.go`:441) | 30/min | read budget | 53 (owner's own data) |
| `GetProfileRelationship` | 60/min (`config.go`:442) | 180/min | read budget | 3 cold (+1 overflow), 0 warm |
| `ListSuggestedUsers` | 10/min (`config.go`:440) | 30/min | 50 per instance (`config.go`:489, `ratelimit_config.go`:150), so 150/day | 42 cold, 1 warm |
| `CreateUpload` + `FinalizeUpload` | 10/min shared (`ratelimit_config.go`:98, `config.go`:433) | 30/min | uploads quota 20/day (5 for new accounts), per item | 2 Vision units per BANNER finalize (M-3) |
| `UpdateProfile` | 60/min default (`config.go`:407) | 180/min | none (L-4) | 4 cold |
| Read budget (all of the above) | 2,000 reads per uid per instance per day (`config.go`:497) | 6,000 | IST midnight; in memory, so a new instance starts at 0 | single-flight hold M = 269 (`config.go`:51) |

- **Worst read cost per account** at the read budget: 6,000 x 30.42 x $0.035/100k ≈ INR 6 a month. A 100-account ring
  costs about INR 607 a month (2.4% of the INR 25,000 credit cap).
- **Suggestions are not an enumeration channel.** The per-viewer 1 h entry allows at most 72 fresh computations a day,
  and the daily hash keeps the order stable within an IST day. The rows are a subset of the followees' `ListFollowing`
  pages, which `graph_list_daily` already bounds.
- **Tabs add no new scraping surface.** Media rows are a subset of the Replies tab, and both share the Posts and Replies
  bucket.

## Findings

| ID | Severity | Component | Where | Finding | Fix | Owner | Blocks W3-24 |
|---|---|---|---|---|---|---|---|
| M-1 | Major | `profile_extras` kill switch and moderation levers | `identity/service.go`:286-291, :337-344; `pkg/platform/flags/flags.go`:157-161; `cmd/opsctl/main.go`:159-161; `moderation/service.go`:182-187 | Flag off hides only the pin. Website, location and banner keep rendering. Clears are refused outside the cohort. No lever narrower than `suspend-user`. ACCOUNT reports keep no evidence. | D9 note. Website hidden while globally off. Clears always allowed. Remove in the app. `opsctl clear-profile-fields`. ACCOUNT evidence. Runbook row. | architect, backend-developer, frontend-developer | No (before the flag leaves the dev allowlist) |
| M-2 | Major | Public media bucket IAM | `infra/terraform/modules/media-buckets/main.tf`:67-71 | `allUsers` `roles/storage.objectViewer` includes `storage.objects.list`. Every public object can be enumerated: replaced and removed banners and avatars, and taken-down post images. | `roles/storage.legacyObjectReader`, or a custom role with only `storage.objects.get`; verify with the dev plan | production-deployer | No (founder OK for prod) |
| M-3 | Major | Vision cap path | `media/finalize.go`:35, :133-135, :150-161, :208-216; `ratelimit_config.go`:98 | Concurrent FinalizeUpload calls for one PENDING doc each run SafeSearch. About 7x to 21x the units (2 per banner), so the monthly cap is reached early. | Per-instance single-flight per media id, plus a preconditioned claim write before `reserve` | backend-developer | No (before `media` or `profile_extras` widen in prod) |
| L-1 | Low | Suggestions block staleness | `graph/suggestions.go`:124-128; W3-19 `suggestions_repository.dart`:16, :229-234 | On a snapshot cache miss, a warm hit serves cached rows unfiltered for up to 1 h; the client keeps them 24 h | Load the snapshot on a miss (1 read), fail closed; client drops a row on NOT_FOUND | backend-developer, frontend-developer | No (before `follow_suggestions` leaves the dev allowlist) |
| L-2 | Low | Profile text rules | `validate.go`:42-49, :98-108, :122-136; `profile_extras_rules.dart`:47-63; `profile_website.dart`:24-26; `profile_header.dart`:735 | Location accepts U+2028/U+2029. The server stores websites the client never renders. Display name and bio have no Cc or bidi rule. | Shared fixture under `testdata/`, aligned sets, Zl/Zp rejected, name and bio rule | backend-developer, frontend-developer | No |
| L-3 | Low | Website host class | `validate.go`:127-136; `profile_website.dart`:28, :70-83 | IP-literal, decimal or hex IPv4, `localhost` and `*.local` hosts are accepted, so a tap opens the viewer's LAN | TLD-shaped last label; reject local suffixes (both sides, in the L-2 fixture) | backend-developer, frontend-developer | No |
| L-4 | Low | UpdateProfile write flood | `ratelimit_config.go`:100-162 (no entry); `identity/repo_firestore.go`:364 | No daily cap, and the whole doc is rewritten on every call: about INR 24 a month per account (pre-existing) | `profile_update_daily` DailyCap; 0-write no-op | backend-developer | No |
| L-5 | Low | Friends-of-friends steering | `graph/suggester.go`:107-150; `graph/suggestions.go`:79-92 | One very active followee fills the 30-edge window. Suspended followees still feed it. | Cap per followee; skip non-ACTIVE followees known to the cache | backend-developer | No |
| I-1 | Info | Follows-you timing | `graph/relationship.go`:60-77 | Bytes identical; the blocked-by path skips the Directory read | Accept | none | No |
| I-2 | Info | Pin oracle and race | `identity/service.go`:296-299, :392-406; `posts/pin.go`:24-26 | One answer for every cause. Timing differs only for a post in this instance's 60 s cache. A pin to a post deleted in the race is hidden by the client. | Accept | none | No |
| I-3 | Info | Rollout | `identity/repo_firestore.go`:364 | A pre-#335 revision's whole-doc `Set` erases the five extras | 100% of dev traffic on a revision with #335 before `profile_extras` goes on; never in the rollout that first ships W3-6 | production-deployer | **Precondition** |
| I-4 | Info | Banner pixels | `media/finalize.go`:294-332; `profile_cover_band.dart`:27, :42, :60 | No server pixel check (ADR-0005). Our client decodes at most the display width. EXIF is stripped on the device. | Accept | none | No |
| I-5 | Info | Vision cap edges | `media/finalize.go`:177-188; `media/server.go`:58-73; `docs/runbooks/media.md`:55 | With 1 unit left a banner takes the exhausted path. Finalize does not re-check `profile_extras`. Under `unscreened_established`, unscreened banners appear on every profile view. | Ramp `profile_extras` past an allowlist only with `reject`, or after M-1(d) | production-deployer | No |
| I-6 | Info | Location as personal data | ADR-0024 D2; `identity/lifecycle_export.go`:58-84 | User-published and public, outside `users/{uid}/private`; covered by export and deletion | Accept; mention it in the privacy notice | none | No |

## Finding details

### M-1. The `profile_extras` kill switch does not stop the phishing surface, and owners cannot clear their own fields

**Exploit.**
- A user in a `profile_extras` cohort sets `website` to a credential-phishing page styled as the app's sign-in. They
  drive profile visits with follows and replies.
- The founder sets `FEATURE_PROFILE_EXTRAS=off`, because the plan names this flag as the phishing kill switch
  (`docs/plans/ui-w3-profile-graph-completion.md`:221).
- From the next revision the pin disappears, but the website keeps rendering and opening on every profile view.
  `present()` blanks only `pinned_post_id` (`identity/service.go`:286-291), and the runbook says so
  (`docs/runbooks/identity.md`:39).
- No operator command is narrower than `suspend-user` (`cmd/opsctl/main.go`:159-161 lists them all).
- An ACCOUNT report stores no evidence (`moderation/service.go`:182-187), so the attacker can swap the link right after
  a report.

**The owner's side.** Some users can no longer remove their own location, website, banner or pin: anyone removed from
the cohort, anyone in a shrinking percent cohort, and everyone once the flag is globally off.
- Any of the four fields, `""` included, is FEATURE_DISABLED for a caller outside the cohort
  (`identity/service.go`:337-344; `docs/runbooks/identity.md`:15).
- The W3-15 screen hides the fields as well. The values stay public.
- This breaks the platform rule that a caller outside a rollout cohort may still undo what they created
  (`pkg/platform/flags/flags.go`:157-161; W2's RemoveBookmark).
- A DPDP or GDPR rectification or erasure request is then left to account deletion.

**Cost.** None (0 reads). This is a harm and moderation finding.

**Fix.** The architect writes the ADR-0024 D9 note first; then:
- (a) `present()` also blanks `website` while `profile_extras` is globally off (0 reads), so the switch kills the link.
- (b) `""` for banner, location, website and pin is accepted from any authenticated caller whatever the flag (1 read,
  1 write, as today). Setting a value stays gated.
- (c) Edit profile offers Remove for an existing banner, location and website while the flag is off for the caller.
- (d) A new command, `opsctl clear-profile-fields --uid U --fields website,location,banner,avatar,bio [--report R]
  [--dry-run]`: field-level `Update`, typed prod confirmation.
- (e) ReportContent for an ACCOUNT copies display name, bio, location, website, avatar and banner URLs into `evidence`.
  This costs 0 extra reads: `prof` is already loaded at `moderation/service.go`:183.
- (f) A "malicious profile link or banner" row in `docs/runbooks/abuse-spike.md`.

Owners: architect (D9), backend-developer (a, b, d, e, f), frontend-developer (c).

**Gate.** Before `profile_extras` leaves the dev allowlist in any project.

### M-2. The public media bucket can be listed by anyone

**Exploit.**
- `allUsers` holds `roles/storage.objectViewer` on `<proj>-media`
  (`infra/terraform/modules/media-buckets/main.tf`:67-71; `docs/runbooks/cloud-bootstrap.md`:329, :346).
- That role grants `storage.objects.list` as well as `storage.objects.get`.
- So anyone can page through `https://storage.googleapis.com/storage/v1/b/<proj>-media/o` without credentials and get
  every public object's name, size and time. That includes:
  - every live post image;
  - every replaced or removed avatar and banner, which Option 5A keeps until account deletion
    (`docs/runbooks/media.md`:60-61);
  - the images of taken-down posts, which stay public until an operator deletes them by hand
    (`docs/runbooks/moderation.md`:105-114).
- ADR-0024 accepted replaced banners as "publicly reachable by URL" (`docs/adr/0024-profile-graph-completion.md`:522).
  Listing removes the "you must already know the URL" premise.
- On a listable bucket, Part B cannot keep its promise that private accounts leak nothing through media URLs.
- Live in dev and prod today.

**Cost.**
- Listing is a Class A operation billed to us. GCS has no per-client throttle, and Stage 0 has no Cloud Armor.
- 1M anonymous list calls ≈ $5 ≈ INR 475 in operations alone (`cost-model.md`:275), plus the egress of the listing
  JSON (not estimated here).
- The only signal is the gross-spend budget alert, which lags by hours.

**Fix.**
- Change the binding to `roles/storage.legacyObjectReader`, which holds only `storage.objects.get` and is the IAM
  equivalent of an object READER ACL.
- Whether it can be granted on a uniform bucket-level access bucket is not settled; verify it in the dev plan. If it is
  refused, use a project custom role with only `storage.objects.get`.
- Check after the dev apply: an anonymous list returns 401/403, and an object URL still returns 200.
- Update `docs/runbooks/cloud-bootstrap.md`:329 and :346 and the ADR-0022 pause step
  (`docs/adr/0022-credit-funded-runway.md`:288).
- The runtime SA keeps `objectAdmin`, and nothing in the app lists the bucket. Fix cost: INR 0.

Owner: production-deployer.

**Gate.** Dev apply with or before W3-24 (recommended, not required). Prod apply needs the founder's OK (ADR-0019,
plan-then-OK). See founder question 2.

**Status (2026-10-27): applied in dev and in prod; closed.**
- Fix: `infra/terraform/modules/media-buckets/main.tf` now binds `allUsers` to `roles/storage.legacyObjectReader`
  (`storage.objects.get` only; `gcloud iam roles describe` confirms), with `create_before_destroy` because `role` forces a
  replacement. GCS accepted it on a uniform bucket-level access bucket, so no custom role is needed.
- Dev (`dzeroth-dev-media`): applied 2026-10-27 (state serial 57 to 58 at 07:34 UTC; the only resource changed was
  `module.media_buckets.google_storage_bucket_iam_member.media_public_read`). A targeted plan afterwards reports
  "No changes". Checked anonymously the same day: JSON API list 401 and XML API list 403 (`storage.objects.list` denied),
  GET of an existing object 200, GET of a missing object **404** `NoSuchKey` (not 403, so the review's expectation of a 403
  was wrong and clients can key on 404).
- Prod (`dzeroth-prod-media`): applied 2026-10-27 at about 13:36 UTC with the founder's OK, from a saved targeted plan
  ("Plan: 1 to add, 0 to change, 1 to destroy."; apply: "Apply complete! Resources: 1 added, 0 changed, 1 destroyed.";
  prod state serial 26 to 27). Before the apply an anonymous list returned 200 on both APIs. After it: JSON API list 401,
  XML API list 403, missing object 404. The bucket IAM policy shows `allUsers` only under `roles/storage.legacyObjectReader`.
  The "existing object 200" check could not be run in prod because the bucket holds 0 objects (no image uploaded there
  yet); it returns 200 in dev with the same binding.

### M-3. Concurrent FinalizeUpload calls screen one image several times

**Exploit.**
- `FinalizeUpload` decides "not yet screened" from the document loaded at the start of the call
  (`media/finalize.go`:35, :133-135).
- It then reserves Vision units (:150-155) and calls SafeSearch (:161), all before the `UpdateTime`-preconditioned
  `Resolve` (:208).
- Nothing claims the document in between: there is no in-flight guard in `media/server.go`:107-135 or in the service.
- So N concurrent calls for one PENDING media id each pay for screening. The losers converge on the winner's result
  (:210-216) after their units are spent and recorded (:68-73).
- A BANNER always costs 2 units (:336-338).

**How many calls run at once.** Two limits apply:
- the shared Create/Finalize bucket allows a burst of 10 per instance (`ratelimit_config.go`:98);
- the read budget's single-flight hold admits about 7 calls per uid per instance at the start of a day:
  `count + (inflight+1) x 269 <= 2,000` (`pkg/platform/ratelimit/daily_cap.go`:126; M = 269 at `config.go`:51;
  `docs/code-map.md` still says 369).

So about 7 run at once on one instance and 21 at max-instances 3. For one established account (20 uploads a day), that
is 280 to 840 Vision units a day instead of 40.

**Cost and impact.**
- The cap bounds the spend: (10,000 − 1,000 free) x $1.50 per 1,000 = $13.50 ≈ INR 1,283 a month at the Stage 0 cap.
  At the credit-mode 40,000 cap it is ≈ INR 5,558 (22% of INR 25,000).
- The harm is that the cap is reached early. One account burns 10,000 units in about 12 days across 3 instances, or
  about 36 account-days on one instance; 12 to 36 accounts do it in a day.
- After that, every new account's upload is REJECTED.
- Under `unscreened_established`, every established account publishes unscreened for the rest of the month,
  attacker-aged accounts included (`media/finalize.go`:177-188).
- Pre-existing for POST and AVATAR since P4; banners double the units per finalize.

**Fix.**
- (a) A per-instance single-flight keyed by media id around `finalizeOne`, using `golang.org/x/sync/singleflight` (in
  `go.mod`) or the `engagement/flight.go` pattern. 0 Firestore cost.
- (b) A claim before `reserve`: one `UpdateTime`-preconditioned write stamps `screeningUntil = now + 30 s` on the
  PENDING doc. A loser hits the conflict before any Vision call and returns the existing retryable "upload not complete
  yet" MEDIA_NOT_READY. This adds 1 write per finalize, under INR 1 a month at 3,000 DAU.
- (c) An emulator test: 10 concurrent finalizes of one BANNER spend exactly 2 units.

Owner: backend-developer.

**Gate.** Before `media` or `profile_extras` widen past an allowlist in prod. It does not block W3-24: it is reachable
with `media` alone, which is already on in dev.

### L-1. Suggestions can show a user who blocked the viewer for up to 1 h (server) and 24 h (client)

**Exploit.**
- X blocks viewer V on another instance, or after V's 60 s snapshot entry has expired.
- V's next `ListSuggestedUsers` on the instance that holds V's 1 h entry is a warm hit.
- `refilterCached` re-checks only when the snapshot is already in the 60 s cache; otherwise it returns the rows
  unchanged (`graph/suggestions.go`:124-128).
- So X's row (handle, display name and avatar, as cached) can be served for up to `SUGGESTIONS_CACHE_TTL` (1 h). That
  contradicts ADR-0024 D8 ("never suggests anyone in blockedBy") and the 60 s bound of every other read path.
- W3-19 then keeps the row on the device for 24 h (`suggestions_repository.dart`:16, :229-234 at fb1ce73). The client
  cannot see `blockedBy`.
- Nothing newer than the cache entry is shown, and Follow is still refused on the server.

**Fix.**
- Server: on a warm hit with no cached snapshot, call `s.Snapshot` (1 read, then cached 60 s). Fail closed on an error
  and on overflow.
- W3-19 client: when GetProfile or Follow returns NOT_FOUND for a suggested uid, drop the row from memory and from the
  disk entry.
- Cost: at most +1 read per warm call, about INR 0.3 a month at 300 DAU.

Owners: backend-developer, frontend-developer. Gate: before `follow_suggestions` leaves the dev allowlist.

**Status:** server fixed in #350; client fixed (PR pending): `FollowButton.onGone` and `SuggestionsRepository.drop` remove the row on NOT_FOUND, silently, from memory and the disk entry. The card has no profile fetch, so Follow is the only NOT_FOUND path.

### L-2. Profile text rules are incomplete, and the server and client disagree

- **(a) Location line breaks.**
  - Location accepts U+2028 and U+2029 on both sides. The server tests `unicode.IsControl` (Cc only,
    `validate.go`:98-108), and the client does the same (`profile_extras_rules.dart`:47-63).
  - The header renders location with no line limit (`profile_header.dart`:735).
  - So a 30-code-point location can draw up to 15 lines into the header, for example a fake "Verified account" line
    under the handle.
- **(b) Websites stored but never shown.**
  - The server stores websites the client never renders: LRM U+200E, RLM U+200F and ALM U+061C, percent-encoded
    non-ASCII hosts, and IPv6 literals (server `validate.go`:122-136; client `profile_website.dart`:24-26, :47, :79).
  - This fails safe, but the user's saved website silently disappears.
- **(c) Display name and bio (pre-existing).**
  - Neither has a control-character or bidi rule (`validate.go`:42-49; `identity/service.go`:150, :331-336, :449-452).
    No interceptor validates them either: there is no protovalidate and no text interceptor in `apiserver` or
    `pkg/platform`.
  - The client isolates bidi only in post text (`app/lib/features/posts/domain/post_text_parser.dart`:60-68).
  - So an RLO (U+202E) in a display name reorders text in the header and in every post row's author snapshot.
  - ADR-0024 D2 assumed "the bio text rules" already existed.

**Fix.**
- Location rejects Zl and Zp.
- The server's website character set equals the client's, and a host the client cannot render is VALIDATION.
- Display name and bio get NFC, no Cc (the bio may keep `\n`) and no bidi controls, for new writes only.
- One shared fixture, `testdata/profile_text/`, is read by both the Go and Dart tests, as the post-text grammar is.
- Cost: none.

Owners: backend-developer, frontend-developer. Gate: (a) and (b) before `profile_extras` leaves the dev allowlist; (c)
with the next identity change.

**Status:** server fixed in #350; client fixed (PR pending): `profile_extras_rules.dart` and `profile_website.dart` pass every row of `testdata/profile_text/` (`profile_text_fixture_test.dart`), and Edit profile now applies the display name and bio rules.

### L-3. The website accepts hosts on the viewer's own network

**Exploit.**
- Both sides accept IPv4 literals, `localhost` and single-label or `*.local` hosts (`validate.go`:127-136;
  `profile_website.dart`:28, :70-83).
- The client's label rule also passes decimal and hex IPv4 forms (`3232235777`, `0x7f.1`), which browsers treat as
  addresses.
- A profile website such as `http://192.168.1.1/apply.cgi?...` is shown as that host. On a tap, the viewer's browser
  sends a top-level GET to their own LAN (router CSRF by navigation) or an intranet name.
- It needs a tap and a vulnerable device. The server never fetches, so there is no SSRF.

**Fix.**
- The last label must be TLD-shaped (`[a-z]{2,63}` or `xn--...`).
- Reject `localhost`, `*.localhost`, `*.local`, `*.internal` and `*.home.arpa`.
- The TLD rule also rules out the numeric and hex IPv4 forms. Put these vectors in the L-2 fixture.
- Cost: none.

Owners: backend-developer, frontend-developer. Gate: with L-2.

**Status:** server fixed in #350; client fixed (PR pending): the host needs two labels and a TLD-shaped last label, and `localhost`, `local`, `internal` and `home.arpa` (with their subdomains) are refused, in `parseProfileWebsite`, so Edit profile refuses them and the header no longer shows a stored one.

### L-4. UpdateProfile has no daily cap and always writes (pre-existing)

**Exploit.**
- `UpdateProfile` has only the default 60/min bucket: no PerProcedure or DailyCaps entry
  (`apiserver/ratelimit_config.go`:100-162; `config.go`:407).
- It rewrites the whole `users` doc on every call, even when nothing changed (`identity/repo_firestore.go`:364).
- A script that saves the same profile in a loop is bounded only by the read budget: about 2,000 calls per instance per
  day, 6,000 at 3 instances.
- With W3, a phishing website can also be rotated every few seconds to stay ahead of a report.

**Cost.**
- 6,000 writes plus 6,000 reads a day per account ≈ INR 18 + 6 ≈ INR 24 a month per account.
- 10 accounts ≈ INR 240 a month, and 3.3 accounts use the whole free quota of 20k writes a day.
- More when instances cycle: the in-memory counters restart, as in W2-14 M-1.
- W3-6 added four fields and two resolver reads to this call.

**Fix.**
- A `profile_update_daily` DailyCap on UpdateProfile, for example 100 a day, with a guard-test entry. 0 Firestore cost.
- Skip the `Set` when the mutation changed nothing (0 writes).

Owner: backend-developer. Gate: not W3-24 (live without any W3 flag); the next backend fix PR.

### L-5. One account can steer friends-of-friends suggestions

**Exploit.**
- The query takes the newest 30 follow edges across the viewer's newest 30 followees (`graph/suggester.go`:107-118).
- With one edge per candidate, the order is the daily hash (:121-150).
- One very active account that many people follow, such as a follow-back bait account, follows 30 promotion accounts in
  a minute (Follow allows 30/min). That fills the whole window.
- Every follower whose newest followees include it then sees its picks in "Who to follow" for the day.
- Followees who are now SUSPENDED or DELETING still feed edges: the sample is not status-checked, and only candidates are
  hydrated (`graph/suggestions.go`:79-92). So a suspended spam account keeps steering until its purge.

**Fix (0 reads).**
- Cap each sampled followee at 3 candidates per window.
- Skip sampled followees that the Directory cache already knows as non-ACTIVE (cache only).
- W3-23 watches `source=fof` with `candidates` <= 3.

Owner: backend-developer. Gate: before `follow_suggestions` leaves the dev allowlist (product quality and spam, not a
leak).

## Info

- **I-1. Follows-you timing.**
  - Every NOT_FOUND is `identity.ProfileNotFoundError` (`graph/relationship.go`:65, :76; `identity/service.go`:108-111).
  - The blocked-by answer skips the Directory read (`relationship.go`:60-66). On a cold profile cache it can therefore
    return one Firestore round trip sooner than a suspended or deleting target. GetProfile checks in the opposite order
    (`identity/service.go`:260-278).
  - A blocked caller learns nothing else: no relationship, no `followed_by`, no edge read. Accept.
- **I-2. Pin oracle and race.**
  - Every refusal gets one VALIDATION answer.
  - Timing differs only between a post in this instance's 60 s cache and one that is not; a public post is readable
    through GetPost anyway.
  - A pin set during the 60 s window in which its post is deleted (`posts/pin.go`:24-26) is hidden by the client on
    NOT_FOUND (W3-17 `pinned_post_cubit.dart`:77) and replaced by the next UpdateProfile. Accept.
- **I-3. Rollout precondition.**
  - `UpdateProfile` and `ChangeHandle` rewrite the whole doc (`identity/repo_firestore.go`:364).
  - A revision older than #335 serving any of them during a traffic split erases banner, location, website and pin.
  - W3-24: 100% of dev traffic must be on a revision with #335 before `profile_extras` goes on.
  - Prod: never turn the flag on in the rollout that first ships W3-6 (the W2 I-9 class).
- **I-4. Banner pixels.**
  - The server checks size, MD5, type and magic bytes, but not pixels (ADR-0005; `media/finalize.go`:294-332).
  - Our client decodes at most the display width (`profile_cover_band.dart`:27, :42, :60), so a 1 MiB banner with very
    large dimensions is bounded.
  - EXIF is stripped on the device (`app/lib/features/media/domain/image_processor.dart`:83-84). Accept.
- **I-5. Vision cap edges.**
  - With 1 unit left, a banner (2 units) takes the exhausted path (`docs/runbooks/media.md`:55).
  - FinalizeUpload does not re-check `profile_extras` for a BANNER. `guardPurpose` runs only on CreateUpload
    (`media/server.go`:58-73); the uploads quota bounds it.
  - Under `unscreened_established`, an established account's unscreened banner appears on every profile view.
  - Recommendation: ramp `profile_extras` past an allowlist only where `VISION_EXHAUSTED_POLICY=reject`
    (`infra/terraform/envs/prod/variables.tf`:722-729), or after M-1(d) exists.
- **I-6. Location is public personal data.**
  - It is user-published and public, stored in `users/{uid}` rather than `users/{uid}/private`; ADR-0024 D2 treats it
    like bio.
  - It is in the export (`identity/lifecycle_export.go`:58-84) and goes with the users doc at deletion.
  - Accept; mention it in the privacy notice.

## Questions for the founder

1. **M-2 prod apply.** Change the `allUsers` role on `dzeroth-prod-media` to object-get only. This is a Terraform
   change: plan, then your OK. **Done 2026-10-27:** applied and verified in dev and in prod (see the M-2 status).
2. **ADR-0024 Option 5A versus DPDP and GDPR.** Should "Remove banner" and a replacement delete the old public image
   (5B for removes and replaces, avatars too)? Today it stays reachable until account deletion. Once listing is closed
   it stays reachable only by URL.
3. **M-1.** Accept the ADR-0024 D9 amendment (website hidden while globally off; clears always allowed) by merging the
   architect's note.

## Verified sound

- **Website.**
  - Server: scheme allowlist, host required, userinfo rejected, Cc, space and bidi rejected, <= 100 code points, and
    the URL is never fetched (`validate.go`:114-137).
  - Client: re-parses, shows the punycode host and launches the URL rebuilt from that host
    (`profile_website.dart`:39-83).
  - External open: `noopener,noreferrer`; `Referrer-Policy` set (`firebase.json`:33).
- **Banner.**
  - CreateUpload checks `media` and `profile_extras` before any read (`media/server.go`:58-73).
  - Exactly one item, 3:1 within 2%, at most 1500 x 500, caps 1 MiB and 128 KiB, re-verified at finalize
    (`media/service.go`:130-175, :210; `finalize.go`:294-332).
  - Both images screened with the Racy rule. The Vision reserve takes both units or none
    (`finalize.go`:150-155, :336-379).
  - The resolver is owner-, purpose- and status-bound, with one answer (`media/attach.go`:107-121).
  - The media eraser is purpose-agnostic (`media/purge.go`:39-77).
  - Each banner gets a new object name, so no stale CDN copy.
- **Flag gate and pin omission.**
  - The flag is checked before any validation or read (`identity/service.go`:337-344).
  - `pinned_post_id` is omitted on all five Profile responses while globally off. List rows carry `AuthorSnapshot`
    only, so the extras never leave through lists.
  - `GloballyOff` semantics: `flags.go`:157-172.
- **Tabs.**
  - Flag checked first, unknown tab VALIDATION, tab-bound AEAD tokens, 0-read token failures.
  - NOT_FOUND identical for missing, non-ACTIVE and blocked-by targets, overflow included.
  - `isPublic`, the embed filter with overflow fail-closed, `Limit(page)` <= 50, and the bucket shared with
    Posts and Replies.
  - Budget: 24 / 54 cold, asserted (`internal/apiserver/profile_tabs_integration_test.go`).
- **Likes list.**
  - Owner-only by construction; token bound to `likes|<uid>` with a 24 h TTL.
  - The anchor resume rule never reads more than one page (`engagement/service_likes_list.go`:88-172).
  - Drop rules shared with bookmarks (W2-14 L-1 and L-2 fixed in `list_common.go`:64-142); 0 writes.
- **GetProfileRelationship.**
  - Only `follows/{target}_{caller}` is read, never an arbitrary pair; the order is as documented
    (`graph/relationship.go`:48-90).
  - Pair-cache eviction on this instance's Follow, Unfollow and Block (`graph/rpcs.go`:60, :111, :154-155).
- **ListSuggestedUsers.**
  - Flags checked before reads (`graph/suggestions.go`:56-66). Exclusion matrix applied in the suggester and again in
    the service. Overflow suggests nothing.
  - Query bounds: <= 30 followers, limit <= 50, valid uids (`graph/repo_suggestions.go`).
  - Hydration <= `HYDRATE_MAX` and non-ACTIVE users dropped. This instance's Follow, Block (both directions) and Mute
    evict (`graph/rpcs.go`:66, :161-162, :232).
  - `SUGGESTED_USER_IDS` validated (`infra/terraform/envs/prod/variables.tf`:499-514); logs carry counts only.
- **post_delete identity step.**
  - Fresh existence read (`apiserver/media_wiring.go`:70-77); a live post is refused.
  - Clears the exact id only; NotFound acknowledged; never recreates the doc (`identity/pin_job.go`:53-79).
- **Export and erasure.**
  - The profile section adds the four extras and no internal field. The media section lists banner docs.
  - The `users` doc is deleted last. No new collection, and no T11 row needed.
- **opsctl backfill.** `--project` required, typed confirmation for prod (the dry run included), field-level
  `Update`, <= 5,000 writes per run.
- **Client branches.**
  - W3-18 `LikesRepository`: session memory only, epoch-guarded, <= 5 calls per fetch, its own per-minute hold
    (`likes_repository.dart`:27, :123, :196 on `main`).
  - W3-19: the disk cache lives under the `account:` prefix, which `clearAll` wipes, and writes are epoch-guarded
    (`app_database.dart`:398-409 at fb1ce73).
  - W3-17: hides the pinned row on NOT_FOUND (`pinned_post_cubit.dart`:77 at f4dcec5).
- **Platform.**
  - No new Go or Dart dependency in W3 (`app/pubspec.yaml` and `backend/go.mod` unchanged since 46b9e0f, apart from
    W2's).
  - Firestore rules still deny-all. The five `users` extras are index-exempt (fieldOverrides).

## Not performed

- Cloud state:
  - indexes READY, the backfill run, the targeted flag plan (all W3-24);
  - an anonymous list against the dev and prod media buckets: done 2026-10-27 by the production-deployer (dev now 401 and
    403; prod 401 and 403 after the founder-approved apply the same day, 200 before it; see the M-2 status).
- The tester's W3-20 authz and budget matrix (W3-20 is Open).
- A real-browser check on the dev Hosting site of IDN and punycode rendering and of the website open.
- `govulncheck` and `osv-scanner` beyond the CI job (no new dependencies).
- W3-17 and W3-19 were reviewed at f4dcec5 and fb1ce73. Re-check if either changes before merge.
  - W3-17 must keep hiding the row on NOT_FOUND.
  - W3-19 should drop a row on NOT_FOUND (L-1).

SECURITY: CLEAR
