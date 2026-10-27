# 0024. Profile and graph completion (W3 Part A)
Status: Accepted (founder, 2026-10-27, by merging PR #325 with every recommended default); Amendment 1 Proposed (2026-10-27, W3-22 M-1); Amendment 2 Proposed (2026-10-27, W3-23 who-to-follow read trigger)
Date: 2026-10-27
Deciders: architect (proposal); the founder accepts by merging. The first W3 implementation PR flips the status, as
#306 did for ADR-0023. Nine founder questions are listed below, each with a recommended default.

Plan: `docs/plans/ui-w3-profile-graph-completion.md`, Part A, tickets W3-1 (this ADR) and W3-2 (protos and indexes,
mechanical from D13 and D14). D12 answers the plan's "Questions for the architect", except the ADR-0025 one.
Related ADRs:
- ADR-0003: data model and indexes.
- ADR-0005: media and moderation. `docs/plans/media-uploads.md` D10 covers replaced avatars.
- ADR-0008: graph snapshot, D4 GetRelationships, D6 flags, D7 limits, D9 block matrix.
- ADR-0010: D5 read budget, D6 visibility, D14 tokens, D15 caches, D16 paging, D19 indexes.
- ADR-0011: erasers and export.
- ADR-0016: `postRemovals`, `removed_ids`.
- ADR-0018: `userLikes`.
- ADR-0021: `hasMedia` on the publish sweep.
- ADR-0023: list drop rules, bookmarks.

Part B (private accounts) is ADR-0025. Nothing here depends on it. Where both touch a path, this ADR names the hook and
ADR-0025 fills it.

## Amendment 1 (2026-10-27, Proposed): kill switch hides the website, clears always allowed, operator lever (W3-22 M-1); old banner and avatar objects deleted (D1 Option 5B)

**Status: Proposed.** Merging its PR accepts A1 to A5. A4 records the founder's answer to question 2 of the W3-22
review: **Option 5B** (founder decision, 2026-10-27, relayed to the architect by the coordinator; the founder's merge of
this PR is the acceptance). It amends D1. Source: the W3-22 security review (merged #348,
`docs/reviews/security-review-w3.md`), findings M-1 and M-2 and its "Questions for the founder". Gate: A1 to A3 are
built before `profile_extras` leaves the dev allowlist in any project (the M-1 gate); A4 has its own rollout order
(below). There is no proto contract change, no new flag, index or Terraform resource (A4 adds one lifecycle rule to the
existing media bucket, free), and no fixed cost.

**What is wrong today** (`main` d33d827):
- `present()` blanks only `pinned_post_id` while `profile_extras` is globally off (`identity/service.go`). The website,
  the phishing surface the plan names this flag for, keeps rendering and opening on every profile view.
- Any of the four fields, `""` included, is FEATURE_DISABLED for a caller outside the cohort, and for everyone once the
  flag is globally off. The values stay public, and only account deletion removes them.
- No operator command is narrower than `suspend-user`. An ACCOUNT report stores no evidence, so a reported link can be
  swapped before triage.

### A1. Kill switch scope (amends D3 "Kill switch" and D9 "Rendering stays ungated")

| | A. Pin only (today) | **B. Pin and website (recommended)** | C. All four | D. A fifth flag for the website |
|---|---|---|---|---|
| Stops the phishing link | no (M-1) | yes | yes | yes |
| What else disappears | nothing | nothing | every user's banner and location | nothing |
| Cost, INR/month idle / 300 / 3,000 DAU | 0 / 0 / 0 | 0 / 0 / 0 (0 reads: `GloballyOff` is in memory) | 0 / 0 / 0 | 0 / 0 / 0, plus a registry entry, a ceiling in a gate file and a Terraform var |

**Decision: B.** While `profile_extras` is globally off (`Registry.GloballyOff`: mode `off`; an allowlist or a percent,
even an empty one or 0, is a rollout, not the switch), `present()` blanks `pinned_post_id` **and `website`** in every
`Profile` identity returns: GetMe, GetProfile, UpdateProfile, ChangeHandle and CreateProfile, the owner's own view
included. 0 reads. The stored values, the instance cache and the export (D11 reads the stored document) are untouched.
Turning the flag back on in any other mode shows both again with no write.
- **Why the website.** It is the only field that sends a viewer somewhere else, so it is the phishing surface.
- **Why not the banner.** It is SafeSearch-screened (D1), and a bad one is handled per account (A3, and the Vision
  `reject` policy). Hiding every banner to stop one is a product-wide regression that makes the switch harder to pull.
- **Why not the location.** At most 30 code points of single-line text with no link: the same class as the bio, which
  has never been gated.
- **D rejected.** `profile_extras` is already the switch the plan names for phishing. A fifth flag adds a gate-file
  ceiling and a var for no new behaviour.
- **Consequence: while the switch is pulled the owner does not see their own website or pin either**, so the client
  cannot offer Remove for them (A2). They render to nobody in that state. Clearing stays possible through `opsctl
  clear-profile-fields` on request (A3), through account deletion, and by the owner once the flag is back. The export
  still lists the stored website and pin. An owner-view exception was considered and rejected: one rule with no viewer
  branch is checked at the five call sites with one assertion, and the switch is an emergency state measured in hours
  or days.

### A2. Clears always allowed (amends D9 "Fields sent while off")
- **Rule.** The exact string `""`, as sent, for `banner_media_id`, `location`, `website` or `pinned_post_id` is accepted
  from any authenticated caller the account-status interceptor lets through, whatever the state of `profile_extras`,
  globally off included. A non-empty value, whitespace-only included, is a set and stays gated: FAILED_PRECONDITION +
  FEATURE_DISABLED `feature=profile_extras`, checked before validation and before any read, 0 writes. A request from a
  caller outside the cohort that mixes a clear with a set is refused whole, as today. `DEGRADED_MODE=readonly` still
  refuses the write, as it does every write.
- **Convention.** W2's RemoveBookmark lets a caller outside the cohort undo, but only while `bookmarks` is not globally
  off (`engagement/server_bookmarks.go`, `notGloballyOff`). This goes one step further on purpose. Bookmarks are
  private and stop rendering when their flag is globally off. Location and banner stay public in that state (A1), and a
  DPDP or GDPR rectification or erasure request must not wait for a flag.
- **Abuse.** No new surface: a clear is the same 1 read and 1 write as a bio edit, which has never been gated, under the
  same default bucket (60/min per instance, 180/min at 3 instances). The review's L-4 daily cap and 0-write no-op apply
  when they land.
- **Idempotency and replay.** Unchanged: `UpdateProfile` takes its `idempotency_key`. Clearing an empty field rewrites
  the same values (0 writes once L-4's no-op lands).
- **Cost.** 1 read and 1 write per clear (+1 interceptor read cold), unchanged. A clear is one of the 0.03
  `UpdateProfile` calls per DAU already in the Cost impact table, not a new call: INR 0 at idle, 300 and 3,000 DAU.
- **Client.** While the flag is off for the caller, Edit profile shows each existing banner, location and website
  read-only with Remove (sends `""`); setting stays hidden. Banner Remove needs neither `media` nor `profile_extras`.
  The own pinned post's menu offers "Unpin from profile" whenever a pin is shown; "Pin to your profile" still needs the
  flag. While the flag is globally off only the banner and the location can appear (A1).

### A3. Operator lever and ACCOUNT report evidence
**(a) `opsctl clear-profile-fields --project P --uid U --fields website,location,banner,avatar,bio [--report R]
[--note N] [--dry-run]`.**
- `--fields` takes one or more of the five names, comma-separated. An unknown or repeated name is a usage error
  (exit 2). `banner` clears `bannerUrl` and `bannerThumbUrl`, `avatar` clears `avatarUrl` and `avatarThumbUrl`, and the
  others clear their own field. The display name (it must stay 1-50 characters) and the pin are not in the list: a bad
  name is `suspend-user`, and a bad pinned post is `takedown-post` (a hidden post stops showing as the pin, D3).
- **One transaction.** Read `users/{U}`: the stored values, not the presented view. NotFound is exit 1. `DELETING` is
  refused (exit 1), because the deletion job's `UpdateTime`-preconditioned checkpoints must not race an operator write.
  Then one field-level `Update` sets each named field to `""` and `updatedAt`. Never `Set`, so it cannot recreate a
  purged document. Already-empty fields are skipped, so nothing to clear is 0 writes and a rerun writes 0. No
  `snapshotVersion` bump and no snapshot job, as in `UpdateProfile`.
- **Safety.** `--dry-run` prints the stored values and the plan and writes nothing. `--project` is required, and a
  `-prod` project asks for the typed confirmation, the dry run included (the existing `confirmed` path). The command
  joins the `--dry-run`, `--report` and `--note` allowlists.
- **`--report R`** resolves R after the write with a new resolution `PROFILE_CLEARED` (a Go and Firestore string in
  `moderation`, in no proto) and the note. R must be a report whose `targetOwnerId` is U, else exit 1 before any write.
- **Images.** Clearing `banner` or `avatar` retires the old image through the A4 retire step, called in process (no
  Pub/Sub), so the objects go after the grace. Until then the URL stays live, and the user's older posts keep the avatar
  URL in `AuthorSnapshot`. For an explicit image that must go at once, the command prints the two object names and the
  runbook deletes them by hand, as `docs/runbooks/moderation.md` "Media on takedown" does.
- **Staleness.** Each API instance's profile cache serves the old values for up to 60 s (3 instances at most), then
  clients' cached profiles until they refresh. opsctl cannot evict a running instance's cache.
- **Cost.** 1 read and at most 1 write per run; `--report` adds the resolve (1 read, 1 write). Operator runs only: INR 0
  at every DAU.

**(b) ACCOUNT report evidence.** `ReportContent` for an ACCOUNT copies `authorHandle`, `displayName`, `bio`,
`location`, `website`, `avatarUrl` and `bannerUrl` into `evidence` from the `prof` it already loads
(`moderation/service.go`, the `TargetAccount` case). 0 extra reads and the same single report write; the document grows
by at most about 1.3 KB, and `evidence` is already index-exempt.
- The copy is the **presented** profile, which is what the reporter saw: while the switch is pulled it holds no website
  and no pin. A reopened report refreshes its evidence, as for posts (ADR-0016).
- No field holds a uid (media URLs are `m/{mediaId}`), so the T11 guard needs no allowlist entry. Retention and export
  follow ADR-0016 D5: resolved + 90 days, then TTL; never exported to the reported user.
- `opsctl reports show` prints the new fields. The `ReportContent` proto comment gains the ACCOUNT evidence (a
  comment-only change, `buf breaking` clean).

**(c) Runbook.** A "Malicious profile link or banner" row in `docs/runbooks/abuse-spike.md`:
- **One account:** `reports show`, then `clear-profile-fields --fields website [--report R]`. For an image, add `banner`
  or `avatar` and delete the printed objects. A repeat is `suspend-user`.
- **A wave:** `FEATURE_PROFILE_EXTRAS=off` through the pinned-traffic procedure (`docs/runbooks/cost-spike.md`). From
  that revision no `Profile` carries a website or a pin. Banners still need per-account clears and the Vision `reject`
  policy.

`docs/runbooks/identity.md` §1 ("even to clear a field") and its kill-switch paragraph change with the code.

### A4. Old banner and avatar objects: delete on Remove and replace (founder decision: D1 Option 5A → 5B)
**Decision (founder, 2026-10-27).** Removing or replacing a banner deletes the old public objects, full and thumb, after
a grace of at least 24 h. The same rule applies to a removed or replaced avatar. Retention until account deletion
remains only for an image that is never replaced or removed, which the media eraser deletes with the account as today.
This amends D1 "Replaced and removed banners" (Option 5A → 5B for removes and replaces) and supersedes, for avatars,
`docs/plans/media-uploads.md` D10. It also supersedes D1's 50% bucket trigger, the Stage-ladder row's "Delete on
replace (Option 5B)" target and founder question 10's "Keep": 5B is now the Stage 0 behaviour.

| | 5A. Keep until account deletion (was D1) | **5B. Delete on Remove and replace, after the grace (decided)** |
|---|---|---|
| Privacy | the image a user removed stays public by URL indefinitely; erasure only by hand or by deleting the account | gone from our bucket 24-48 h after the change |
| Ops per change | 0 | 2 Firestore reads (fresh `users`, the media doc), 1 write (mark retired), 1 TTL delete later; 2 Class A (one `customTime` patch per object); the object deletes themselves are free operations (ADR-0005) |
| Retained storage | about 120 KB per banner change, about 30 KB per avatar change | 0 after the grace |
| INR/month idle / 300 / 3,000 DAU | 0 / about 0.2 / about 1.6, after a year (storage past the free 5 GB) | 0 / about 0.1 / about 1.0 (operations) |

Inputs: 0.005 banner and 0.005 avatar changes per DAU per day, $0.02/GB-month, Class A $0.005 per 1,000, Firestore
reads $0.035, writes $0.104 and deletes $0.012 per 100k, INR 95 per USD. Both round to INR 0; the decision is about
privacy. (Option 5B under Options said about 1.8 GB a year of banners at 3,000 DAU; 0.005 × 3,000 × 365 × 120 KB is
about 0.66 GB.)

**Why.**
- **DPDP and GDPR.** A profile photo or banner is often the user's own image, so it is personal data. Once the user
  removes or replaces it, serving it has no remaining purpose. DPDP Act 2023 s. 8(7) (erase once the purpose is no
  longer served) and s. 12 (erasure on request), and, for EU users, GDPR Art. 5(1)(e) (storage limitation) and Art. 17
  point that way. This is not legal advice; the privacy notice should say a removed image is deleted within about 2 days.
- **M-2.** The bucket can be listed today (`allUsers` holds `roles/storage.objectViewer`). Even after the M-2 fix closes
  listing, a kept image stays public to anyone who has its URL: old client caches, old posts' avatar snapshots,
  notification actors, report evidence.

**Retire step (the grace mechanism).** No delayed-delete job exists today: `post_delete` is scoped to one post and runs
at once (`media/jobs.go`), and the media eraser is scoped to an account (`media/purge.go`). The step is a new kind,
`profile_media_retired`, on the existing `jobs` topic, routed by identity's job router like `post_delete`. There is no
new topic, Scheduler job, collection or index.
1. **Publish.** After an `UpdateProfile` commit that changed or cleared the avatar or banner, identity calls a new
   consumer-side `identity.MediaRetirer` (implemented by `media.Jobs`, the `BannerResolver` pattern). It sends
   `{uid, purpose, oldUrl, oldThumbUrl, changedAt}`, with 0 extra reads: the old URLs are in the document the
   transaction already read. Publishing is best effort: a failure is logged at ERROR and the image falls back to 5A
   (deleted with the account). `opsctl clear-profile-fields` calls the same step in process.
2. **Handle (media; it never acts on the message's word alone).**
   - Media parses its own object names (`m/{id}.{ext}`, `m/{id}_t.{ext}`) to get the media id, so `users` needs no new
     field and images set before this change are covered. An unparseable URL is acked and left to the account eraser.
   - It reads `users/{uid}` fresh. If the old URL is still the current avatar or banner, the message is refused.
   - It reads the media doc and requires the message's uid as owner, the matching AVATAR or BANNER purpose and no
     `retiredAt`. Otherwise it acks: a redelivery is 0 writes and no GCS call.
   - Objects first: it sets `customTime = changedAt` on the full and thumb objects (2 Class A).
   - Document last: it sets `retiredAt = changedAt` and `expireAt = changedAt + 72 h` on the media doc (1 write,
     `LastUpdateTime` precondition, never `Set`). `expireAt` is the media TTL field the PENDING path already uses.
3. **Delete.** A bucket lifecycle rule on `<proj>-media`, delete when `daysSinceCustomTime >= 1`, removes the objects.
   Lifecycle deletes are free, and lifecycle acts within about a day of the condition, so an object goes 24-48 h after
   the change. The doc's TTL removes it later. Until then the doc keeps the image inside the purpose-agnostic media
   eraser and the export, so an account deleted during the grace still loses its objects at once. Nothing else in the
   app sets `customTime`, and a test pins that invariant.
4. **Resolvers.** `ResolveAvatar` and `ResolveBanner` refuse a doc with `retiredAt` (the one MEDIA_NOT_READY answer), so
   a retired image can never be set again.
5. **Switch and order.** Config `PROFILE_MEDIA_RETIRE=off|banner|all` (Terraform var, default `off`). It is per-project
   retention, not a cohort feature, so it is not a `FEATURE_` flag. Both the publish and the handler check it, and
   `off` acks without action.
   - `banner` is set only after the lifecycle rule exists in that project. Without the rule, tagged objects would
     outlive their TTL'd docs and escape the account eraser.
   - `all` is set only after the app release with the `AppAvatar` load-error placeholder.

**Consequences.**
- **Avatars on old rows.** Posts, quote and repost embeds and notification actors copy the avatar URL (`AuthorSnapshot`).
  Only a display-name or handle edit refreshes snapshots, and only for the newest 100 posts. So after the grace, older
  rows show the placeholder instead of the old photo. Refreshing snapshots on an avatar change (up to 100 writes per
  change, behind `profile_snapshot`) is a possible later ADR, not part of this one.
- **Cached copies.** Public objects carry `max-age=31536000, immutable`. The delete stops our bucket serving the image;
  it cannot recall copies already in browsers or intermediate caches.
- **Evidence.** The grace is shorter than ADR-0016 D5's 48 h triage SLA, and A3(b) copies image URLs into evidence. For a
  reported image, the runbook has the operator save a copy as soon as the report is seen, if it is needed past the grace.

### A5. Cost-table corrections (no decision changes)
- **Pin clean-up: 2 reads per deleted post, not 1.** The W3-6 step reads the post fresh (a job never acts on a message's
  word alone), then `users/{uid}` in its transaction (`identity/pin_job.go`). That is +0.10 reads per DAU, not +0.05.
  The Part A total stays at about 40.2 (40.17). This note corrects D3's "1 read"; the Cost impact row is updated.
- **Backfill:** 1 write per post lacking `hasMedia` (D4 and W3-8's `opsctl backfill-has-media`), not "per post with
  images lacking the field". The Cost impact row is updated.

### Cost impact (Amendment 1)

| Decision | Reads / writes | INR/month idle / 300 / 3,000 DAU |
|---|---|---|
| A1: website omitted while globally off | 0 / 0 | 0 / 0 / 0 |
| A2: clears always allowed | 1 / 1 per clear, inside the existing `UpdateProfile` row | 0 / 0 / 0 |
| A3: opsctl and ACCOUNT evidence | operator runs only; evidence 0 extra reads, the same write, at most about 1.3 KB per report | 0 / 0 / 0 |
| A4: retire step per removed or replaced image (0.01 per DAU per day) | 2 reads, 1 write, 1 TTL delete; 2 Class A (one per object); object deletes free; 1 Pub/Sub message and 1 Cloud Run request | 0 / about 0.1 / about 1.0, against about 0.2 / 1.6 a year later for keeping them |
| A5: pin clean-up correction | +0.05 reads per DAU over the earlier row | 0 / about 0.02 / about 0.2 |

- **Fixed monthly cost added: INR 0.** No new service, topic, Scheduler job, flag or index. The one Terraform change is a
  lifecycle rule on the existing media bucket (free). The credit window (ADR-0022) lifts nothing.
- **Free-tier quota:** no measurable change (A4 adds 0.02 reads, 0.01 writes and 0.01 deletes per DAU per day). The
  whole product's free read line stays at about 173 DAU.

### Stage ladder (Amendment 1)

| Concern | Stage 0 | Seam | Stage 2/3 target | Trigger |
|---|---|---|---|---|
| Profile link and image abuse | the global `profile_extras` switch (pin and website) and per-account `opsctl clear-profile-fields` | identity `present()` behind `flags.Registry`; report `evidence` | a moderator console, and a link-reputation check when a website is set (its own ADR; Web Risk bills per call) | more than a few malicious-link reports a week, sustained, or more moderation time than the founder can give |
| Old profile images | retire step + bucket lifecycle on `customTime` (24-48 h) | `identity.MediaRetirer`; `media.Jobs`; object names owned by media | CDN with invalidation at Stage 3 (the delete then also purges the edge) | the Stage 3 CDN ADR (GCS egress above the §6 line) |

### Handoff (Amendment 1)
- **backend-developer** (one fix PR, before `profile_extras` leaves the dev allowlist in any project):
  - `present()` blanks `Website` under the pin's condition (`s.extras == nil || GloballyOff`), with its doc comment.
    Tests: all five RPCs with mode `off` versus an allowlist; the stored value and the cache untouched.
  - The `UpdateProfile` gate counts only non-empty values, so `""` passes for the four fields. Confirm that
    `normalizeLocation("")` and `normalizeWebsite("")` accept `""`. Whitespace-only stays FEATURE_DISABLED; a mixed
    request is refused. `budgettest`: 1 read / 1 write for a clear by a caller outside the cohort and under global off.
  - `opsctl clear-profile-fields` per A3(a). Tests: unknown field, NotFound, DELETING, dry run 0 writes, prod
    confirmation, report target mismatch, rerun 0 writes.
  - ACCOUNT evidence per A3(b), `reports show`, the `ReportContent` proto comment, `make proto` green.
  - Runbooks: the abuse-spike row (A3(c)); `identity.md` §1 and its kill-switch paragraph.
- **backend-developer, A4 implementation** (its own PR, any time; nothing is deleted until `PROFILE_MEDIA_RETIRE`
  leaves `off`):
  - The media delete-on-replace path:
    - `identity.MediaRetirer` and its publish after the `UpdateProfile` commit, for the avatar and the banner, change
      and clear;
    - the `profile_media_retired` handler in `media.Jobs`, wired into identity's job router;
    - the media-owned object-name parser;
    - the fresh `users` check behind a consumer-side interface in `apiserver` (the `PostGone` pattern);
    - the objects-first, document-last order;
    - `retiredAt` refused by `ResolveAvatar` and `ResolveBanner`;
    - `opsctl clear-profile-fields` calling the step in process.
  - Config: `PROFILE_MEDIA_RETIRE` in `pkg/platform/config` with `config_test.go`, and the Terraform var default `off`.
  - Eraser coverage: purge tests with a retired AVATAR and a retired BANNER doc inside the grace (objects and doc
    deleted at once). The export still lists a retired doc until its TTL.
  - Tests:
    - replace and remove, for banner and avatar;
    - a still-current URL refused;
    - another owner's or the wrong purpose's doc acked with 0 writes;
    - a redelivery 0 writes and no GCS call;
    - an unparseable URL acked;
    - `off` acks;
    - a crash between the patch and the doc write converges;
    - no other code path sets `customTime`;
    - `budgettest` at 2 reads and 1 write per message, 0 extra on `UpdateProfile`.
  - Observability: job outcome (`retired`, `still_current`, `duplicate`, `unparseable`, `disabled`) in the job log;
    publish failures at ERROR.
  - Runbook: `docs/runbooks/media.md` (the replaced-image line, the switch, and a missed retire falling back to the
    account eraser); the `moderation.md` note to copy a reported image at triage.
- **frontend-developer:**
  - Edit profile (follow-up to W3-15): while `profile_extras` is off for the caller, show the existing banner, location
    and website read-only with Remove (`""` through `buildUpdateProfileRequest`). Banner Remove works without `media`;
    W3-15's "without media a saved banner is shown read-only" gains Remove. A FEATURE_DISABLED answer to a clear (a
    revision without the backend fix) hides Remove and shows the generic error.
  - W3-17 (merged #347) follow-up: "Unpin from profile" is ungated whenever a pin is shown; "Pin to your profile"
    stays behind the flag. This supersedes the plan's "the menu rows need `profile_extras`" for Unpin.
  - Widget tests for the flag-off state with and without each value.
  - A4: an `AppAvatar` placeholder on a load error (`onBackgroundImageError` or equivalent), and the same for the
    profile banner band. It ships in a release before `PROFILE_MEDIA_RETIRE=all`, with widget tests for a 404 image.
- **tester:** the A1 matrix (mode off, allowlist, percent 0 × the five RPCs × the owner and another viewer); the A2
  matrix (in the cohort, outside it, globally off × clear, set, mixed, whitespace-only, and `readonly`); the opsctl
  cases; ACCOUNT evidence with the switch on and off; A4 on the emulators: a banner replace and remove, then an avatar
  replace and remove, with the job delivered twice. The lifecycle deletion itself is checked in dev with a short-lived
  test object.
- **security-auditor:** re-check M-1 against the fix PRs, and A4's handler against forged messages (a message never
  retires a current image or another user's image).
- **sre-performance:** in `docs/reviews/cost-model.md`, the pin clean-up row at 2 reads (0.10 per DAU), the backfill
  wording, and an A4 row: 0.02 reads, 0.01 writes, 0.01 deletes and 0.02 Class A per DAU per day, and the storage that
  is no longer retained.
- **production-deployer:**
  - No Terraform for A1 to A3. The backend fix serves 100% of dev traffic before `profile_extras` widens past the
    3-uid allowlist. M-2 is separate.
  - A4: a `lifecycle_rule` on `google_storage_bucket.media` (delete, `days_since_custom_time = 1`). Dev first, then
    the prod plan to the founder (ADR-0019 plan-then-OK).
  - Then `PROFILE_MEDIA_RETIRE`, per project: `banner` after the rule is applied there, `all` after the client
    placeholder release.
- **Flag:** no new flag. `FEATURE_PROFILE_EXTRAS` keeps its ceiling (dev allowlist 3, no prod raise). A4's `PROFILE_MEDIA_RETIRE` is per-project config (rule 11), not a cohort flag.

## Amendment 2 (2026-10-27, Proposed): who to follow back under its own 10% read line (W3-23); 48 h client cache and `SUGGESTIONS_EDGE_LIMIT` 20

**Status: Proposed.** Merging its PR accepts B1 to B3. Source: the W3-23 cost report (merged #352,
`docs/reviews/cost-model.md` §1 "Who-to-follow call mix", the §2 W3 notes, §6 "ADR-0024 triggers" and §9). It amends
D8 ("Hard read cap", "Caches"), D10 (the `SUGGESTIONS_EDGE_LIMIT` default and the storm arithmetic), the
`ListSuggestedUsers` row of the Cost impact table and the Stage-ladder row "Who to follow". **Gate:**
`follow_suggestions` does not leave the dev allowlist in any project until B1 and B2 are built, the new edge limit is
applied in that project, and the app release with B1(a) and B2 is the one that project's cohort runs (Handoff). No proto
change, no new flag, index, collection or Terraform resource, no fixed cost. `FEATURE_FOLLOW_SUGGESTIONS` keeps its
ceiling (dev allowlist 3, no prod raise).

**What is wrong today** (`main` ead41ce6):
- D8 planned 25 reads per call, which assumed about half the calls warm. The W3-19 client keeps an answer 24 h per
  account (memory and disk), and the server's per-viewer entry lives 1 h on one instance, so a DAU's one call a day is
  almost always cold. W3-23 restates the line at **35.7 reads/DAU**: 95% cold, of those 85% friends of friends at the
  42 cap and 15% curated at 12, and 5% warm at 1 to 2.
- That is **11.9%** of the product's 300.2 reads/DAU, above the 10% Stage-ladder line before a single real user. The
  money is small: the line is INR 10.8 / 36.1 / 108.3 a month at 300 / 1,000 / 3,000 DAU, +3 / +11 / +34 over the
  ADR. The trigger is the problem: a line that reads "fired" from the first day guards nothing.

### B1. Levers (amends D8 "Hard read cap" and "Caches", D10 `SUGGESTIONS_EDGE_LIMIT`)

**Method** (W3-23's call mix, every cold call at its cap):
- **Reads per call.** M = 0.95 × (0.85 × fof cap + 0.15 × curated cap) + 0.05 × 1.5. The fof cap is 2 + `EDGE_LIMIT`
  + `HYDRATE_MAX`; the curated cap is 2 + `HYDRATE_MAX`.
- **Reads per DAU and share.** S = calls per DAU × M. The rest of the product stays at 264.5 reads/DAU, so the share is
  S / (264.5 + S) and the line fires at S = 264.5 / 9, about **29.4**.
- **Money.** INR = S × DAU × 30.42 × $0.035 per 100k × 95. Every read is billed: the product passes the free quota at
  about 167 DAU (`cost-model.md` §5).
- **Free reads.** They end at 50,000 / (264.5 + S) DAU.
- **Calls per DAU at 48 h.**
  - An active account calls unless it fetched the day before. If p is the share of today's DAU who were also active
    yesterday, the calling share f satisfies f = 1 − p·f, so f = 1 / (1 + p).
  - p = 1 gives W3-23's 0.5, the best case. Planning uses p = 2/3: **0.6**.
  - An account active every other day gains nothing: its cache is 48 h old when it returns.
  - At 24 h every active day after a day's gap is a call, so W3-23's 1.0 stands.

| Option | Calls/DAU × reads per call | Reads/DAU | Share of all reads | The line, INR/month at 300 / 1,000 / 3,000 DAU | Product's free reads end at | Room to the 10% line |
|---|---|---|---|---|---|---|
| Today: 24 h client, edge 30 (cap 42) | 1.0 × 35.7 | 35.7 | 11.9% | 10.8 / 36.1 / 108.3 | 167 DAU | over (0.82×) |
| (a) 48 h client cache | 0.6 × 35.7 (best 0.5) | 21.4 (17.8) | 7.5% (6.3%) | 6.5 / 21.7 / 65.0 | 175 | 1.37× (1.65×) |
| (b) `SUGGESTIONS_EDGE_LIMIT` 20 (cap 32) | 1.0 × 27.6 | 27.6 | 9.5% | 8.4 / 27.9 / 83.8 | 171 | 1.06× |
| (c) `SUGGESTIONS_EDGE_LIMIT` 15 (cap 27) | 1.0 × 23.6 | 23.6 | 8.2% | 7.2 / 23.9 / 71.6 | 174 | 1.25× |
| (d) `SUGGESTIONS_HYDRATE_MAX` 6 (caps 38 / 8) | 1.0 × 31.9 | 31.9 | 10.8% | 9.7 / 32.3 / 96.8 | 169 | over (0.92×) |
| (a) + (b) | 0.6 × 27.6 (best 0.5) | 16.6 (13.8) | 5.9% (5.0%) | 5.0 / 16.8 / 50.3 | 178 | 1.77× (2.13×) |
| **(a) + (b) + the B2 guards (decided; the planning value)** | **0.6 × 27.6 + 0.66** | **17.2** | **6.1%** | **5.2 / 17.4 / 52.3** | **177** | **1.71×** |

**Not chosen:**
- **(c) Edge limit 15.** Alone it leaves 1.25× of room. With (a) and B2 it would save 2.5 more reads/DAU (14.7, 5.3%)
  for a window another quarter smaller, and 20 already gives 1.7×.
- **(d) Hydrate max 6.** Alone it is still over the line. Hydration goes through the shared 60 s profile cache (W3-23
  measured 33 instead of 42 when other viewers had just cached the candidates), while edges are never cached, so the
  edge window is the cleaner cut. It stays the next lever (Decision).
- **(e) A lower `SUGGESTIONS_SAMPLE_FOLLOWEES`.** It saves 0 reads: the query reads the newest `EDGE_LIMIT` edges of
  the sampled followees, and 10 followees fill a window of 20 or 30 as easily as 30 do. It also narrows the card and
  makes the L-5 steering easier.
- **(f) A longer server cache** (`SUGGESTIONS_CACHE_TTL`, at most 24 h).
  - It is per instance: at most 3, scaled to zero, emptied by every deploy, an LRU of 2,000 viewers.
  - The same device asks again only after its own client TTL, so only a second device or a re-login could hit it.
  - It would serve suspended, deleted or renamed accounts for up to 24 h: only the snapshot facts are re-checked
    (W3-22 L-1).
- **(g) Fetch only when the card is on screen.** The card is a Home header sliver, under the push opt-in card, and the
  desktop side column, so it is on screen at nearly every Home open. Revisit if the card moves into the feed, where X
  places it.
- **(h) The card only for accounts that follow fewer than N.** In a network of a few hundred DAU few accounts follow
  many, so it saves little, and it takes the card from the accounts whose graphs give friends of friends the most to
  work with.
- **(i) Curated only below 10 followees.** It saves 28.5 × s reads/DAU, where s is the share of DAU with 3 to 9
  followees (unknown; at s = 0.3 the line is 27.1, 9.3%). It shows the same 20 accounts to exactly the users the card
  is for: those still building a graph.
- **(j) The precomputed table now** (the Stage-ladder target).
  - Computing it per user from Firestore costs the same friends-of-friends reads plus a write per user per day, for
    inactive users too.
  - It needs a Scheduler job, a new collection, an eraser step and an export section.
  - It pays only from an export or SQL at Stage 2, so it stays the next rung.
- **(k) Moving the line.** See B3.

**Decision: (a) + (b), with B2.**
- **(a)** `kSuggestionsTtl` goes from 24 h to **48 h** for a non-empty answer. B2 sets the other lifetimes.
- **(b)** `SUGGESTIONS_EDGE_LIMIT` goes from 30 to **20** in four places: the config default, the graph module's own
  default, and the literal in each env's `main.tf` (dev and prod).
  - Hard caps: friends of friends 42 → **32**; curated **12** and warm **1 to 2** are unchanged.
  - `config.Load`'s bound stays 1 to 50.
- **Unchanged:** `SUGGESTIONS_SAMPLE_FOLLOWEES` 30, `SUGGESTIONS_HYDRATE_MAX` 10, `SUGGESTIONS_MAX_RESULTS` 5,
  `SUGGESTIONS_CACHE_TTL` 1 h, the curated list, `RATE_LIMIT_SUGGESTIONS_PER_MIN` 10 and `SUGGESTIONS_CALLS_PER_DAY`
  50.
- **Walk-back.** A project may set the edge limit anywhere from 20 to 30 by a reviewed config PR that cites the B3 fill
  check. At 30, with (a) and B2, the line is 22.1 reads/DAU, 7.7%, still under 10%. Above 30 needs an ADR.
- **Next lever, not used now.** `SUGGESTIONS_HYDRATE_MAX` 6 (the client keeps 5 rows) would take the decided package to
  about 14.9 reads/DAU, 5.3%.

**Why.**
- **Neither lever is enough alone.**
  - (b) alone leaves 9.5%. A 6% drift in the mix fires the line again: more accounts on friends of friends, or fewer
    warm hits.
  - (a) alone is 7.5% at planning (1.37×), and it reaches only as far as the app build each user runs.
- **(a) goes at the cause; (b) covers every client.**
  - The cause is call frequency, which (a) halves at best.
  - (b) is server-side, so it applies on the next revision to every client: old mobile builds, the web app and a
    modified client.
- **(b) lowers the abuse ceiling.**
  - One account's worst day is 50 calls × 32 reads × 3 instances = 4,800 reads. That is under the 6,000 per-uid read
    budget (2,000 × 3), so the call cap now binds instead of the read budget.
  - The cost is INR 4.9 per account-month (was 6.1), and INR 485 for a ring of 100 accounts (was 607).
- **Together: 1.7× of room at planning,** 2.1× in the best case. The saving is INR 5.6 / 18.7 / 56.0 a month at
  300 / 1,000 / 3,000 DAU, plus about 7 of Cloud Run at 3,000 DAU.

**UX and abuse, per lever.**

| | (a) 48 h client cache | (b) Edge limit 20 |
|---|---|---|
| Staleness | A card can be up to 48 h old (was 24 h), with names and avatars as of then. The server reshuffles ties each IST day; a device now shows one draw for up to two days. Rows the viewer follows, blocks or mutes still go at once (local graph state). | None added. |
| Fewer candidates | None. | The window holds the newest 20 edges of the 30 sampled followees, at most 3 per followee. In a small, dense network, where many friends of friends are already followed, up to a third fewer usable candidates reach hydration. More cards then come back with 3 or 4 rows, or with curated rows after the friends of friends (B3 watches the fill). |
| New users and empty cards | An empty answer, or a card emptied by follows, would last 48 h: B2. | Unchanged: an account that follows fewer than 3 never runs the query. |
| Abuse | None: the TTL is a client constant, not a control. The server limits bound a modified client: 10/min and 50/day per instance, 30 and 150 effective at 3 instances. | Cap 42 → 32 (above). An account that steers the window (L-5) needs 20 fast follows instead of 30, both far under the 200/day follows quota, and the per-followee cap still holds it to 3 rows. |
| Privacy | Someone who blocks the viewer after the list was built stays on the viewer's device until the TTL ends or a tap gets NOT_FOUND, which drops the row for good (L-1). That is up to 48 h, was 24 h; the server's own answer is re-checked within 60 s. The row shows only the public profile as of the build, and the profile and Follow are refused. | Fewer edges read. |

### B2. Client guards (amends the W3-19 cache rules in `SuggestionsRepository`)
Without them (a) doubles the time a new account looks at an empty or used-up card, and the card exists for new
accounts.
1. **Non-empty answer: 48 h** (`kSuggestionsTtl`).
2. **Empty answer from the server: 6 h** (`kSuggestionsEmptyTtl`, new; it was 24 h).
   - Cases: a new account whose first Home open came before its third follow, a project with an empty
     `suggested_user_ids`, or `source=none`.
   - Such an account sees friends of friends within 6 h of following 3 accounts.
   - Cost: at most 4 calls a day for such an account. With fewer than 3 followees each call is 2 reads, so 8 a day,
     within the curated row's 12 planning reads even when the curated list is empty. With 3 or more followees and
     nothing usable, each is at most 22 (2 + the edges); that case is rare.
3. **Limit answer: 24 h** (`kSuggestionsLimitBackoff`, new, today's value). This is RESOURCE_EXHAUSTED for a rate
   limit, a quota or a limit reached. The short in-flight hold is different and keeps `kSuggestionsFailureBackoff`. The
   24 h backs off past the IST-day reset of the 50/day cap.
4. **Refill once.** When a confirmed follow from the card removes its last visible row, the repository discards the
   entry, in memory and on disk, and asks again. Dismissals and NOT_FOUND drops never trigger it.
   - At most once per session per account.
   - Within the hour on the same instance, the server answers from its per-viewer entry: it hydrated 10 rows, and its
     own Follow removed the followed ones. That is 1 to 2 reads; otherwise it is a cold call at most 32.
   - Planning: 0.02 calls/DAU × 32 = 0.64 reads/DAU.
- **Storage.** The disk entry records which lifetime applies, as an optional field; it stays `v: 1`, because a new
  version would make every stored entry a miss on upgrade and an older build would discard a newer entry. An entry
  without the field (an older build wrote it) is judged by content: non-empty 48 h, empty 6 h. Sign-out still wipes
  everything.
- **Bound.** Every rule stays under the server's 10/min and 50/day per instance. B2 adds at most one call per session
  (rule 4) and four a day for an account whose answer is empty (rule 2).
- **Cost.** +0.66 reads/DAU (0.64, plus about 0.02 for empty answers), already in B1's decided row.

### B3. The 10% line stays (the trigger)
- **Keep it.**
  - The card is one secondary surface. Once it costs more than a tenth of all reads, the precomputed table at 1 read
    per call is the better design, and that is the next rung.
  - Moving the line to fit the model would leave a line that never meant anything.
  - The 15% for tabs plus the likes list is a different case: two primary surfaces.
- **Re-measured.**
  - After B1 and B2 the model is **17.2 of 281.7 reads/DAU = 6.1%** (5.0% in the best case).
  - With the rest of the product at 264.5, the line fires at about **29.4 suggestion reads per DAU**, 1.7× the plan,
    sustained 7 days.
  - Measure it with `sug_share_pct` from `cost-model.md` §9, against `document/read_count`, and read it against 6.1%,
    not 11.9%.
  - Dev shares with 3 allowlisted users mean nothing.
- **Regression checks** (not stage triggers; the same §9 queries, no new alert or metric):
  - **Cold reads per call.** `mean_cold_reads` above 32 is a config regression; the model is 29.0
    (0.85 × 32 + 0.15 × 12).
  - **Calls per DAU.** The suggestion calls a day from the §9 mix query, divided by the DAU figure §8 uses (request
    lines carry no uid). Above 0.8 for 7 days means the 48 h cache is not holding: old builds, second devices, cleared
    web storage or a refill loop. Fix the client before reading the share. The model is 0.63.
  - **Fill.** If cold `source=fof` calls with `candidates` below 5 are more than 30% of cold fof calls for 7 days, the
    20-edge window is starving the card. Walk the limit back toward 30 (B1).

### Cost impact (Amendment 2)

| Line | Reads / writes per DAU | INR/month idle / 300 / 1,000 / 3,000 DAU |
|---|---|---|
| `ListSuggestedUsers`, before (W3-23) | 35.7 / 0 (1.0 call: 95% cold at 42 or 12) | 0 / 10.8 / 36.1 / 108.3 |
| `ListSuggestedUsers`, after B1 and B2 | **17.2** / 0 (0.63 calls: 0.6 at 48 h, 0.02 refills, about 0.01 empty refetches; 27.6 reads per call) | 0 / **5.2 / 17.4 / 52.3** |
| Change | **−18.5 reads** and −0.37 requests per DAU per day | 0 / −5.6 / −18.7 / −56.0, plus about −7 of Cloud Run at 3,000 (requests and vCPU-s, billed past about 1,500 DAU) |

- **Whole product** (with W2 and Part A):
  - 300.2 → **281.7 reads/DAU**; Part A goes from 51.5 → 33.0.
  - Free reads end at about **177 DAU** (was 167), and the 80% line at about 142 (was 133).
  - The Stage 0 bill with W2 and Part A is about INR 465 / 1,692 / 3,710 at 300 / 1,000 / 3,000 DAU (was
    471 / 1,711 / 3,773).
- **At 2× and 10× the new crossing** (355 and 1,775 DAU): the line costs INR 6.2 and 30.9 a month (was 12.8 and 64.1).
  On its own it would use up the free 50k reads at about 2,900 DAU (was 1,400).
- **Abuse:** INR 4.9 per account-month at the call cap (was 6.1 at the read budget).
- **Writes, deletes, Vision, GCS and egress:** unchanged.
- **Fixed monthly cost added: INR 0.** No new service, flag, index, collection or Terraform resource; two existing env
  literals change, one per env. The credit window (ADR-0022) lifts nothing.

### Stage ladder (Amendment 2)

| Concern | Stage 0 | Seam | Stage 2/3 target | Trigger |
|---|---|---|---|---|
| Who to follow | Friends of friends at query time, cold cap 32, 1 h per-viewer instance cache, curated fallback. The client keeps an answer 48 h (6 h when empty, 24 h after a limit) and refills once when follows empty the card | `graph.Suggester` on the server (no caller knows the source); `SuggestionsRepository` on the client, the only caller and the only place the lifetimes live; no cursor on the wire | Unchanged: a precomputed table refreshed by a batch over a Firestore export (or SQL), served at 1 read, then a ranking ADR | Unchanged: suggestion reads above 10% of daily reads (modelled 6.1%, fires at about 29.4 reads/DAU), or the §6 Firestore trigger, sustained 7 days |

### Handoff (Amendment 2)
**Order.** The four W3 flags reach the dev allowlist through W3-24 today; `follow_suggestions` goes no further until
step 5.
1. **Now, W3-24:** apply its saved targeted dev plan as reviewed, with `SUGGESTIONS_EDGE_LIMIT=30`. Do not re-plan for
   this amendment: the founder's OK covers that plan, and 3 users at 42 reads is noise.
2. **The founder merges this PR** (acceptance).
3. **backend-developer and frontend-developer** work in parallel, one PR each.
4. **production-deployer,** once the backend PR serves 100% of dev: a targeted dev apply of the `api` service with the
   `main.tf` literal 20.
   - Re-plan from `main`; the 3.10 drift stays out of the target.
   - Then check that the serving revision's env has `SUGGESTIONS_EDGE_LIMIT=20` and that a cold dev call logs
     `fs_reads` of at most 32.
   - Prod's literal rides the next prod plan the founder approves (ADR-0019 plan-then-OK; prod applies are on hold
     until the MVP).
5. **Ramp past dev** (any percent, or prod) only after steps 3 and 4 are done in that project and the app release with
   B1(a) and B2 is the one the cohort runs.
   - This amendment does not change the `flag-ceiling.json` entry.
   - The PR that raises it (founder review) lists these steps as done.

- **backend-developer** (one PR, B1(b)):
  - Defaults:
    - `backend/pkg/platform/config/suggestions.go`: `SUGGESTIONS_EDGE_LIMIT` default 30 → 20 (bound 1 to 50
      unchanged); in the doc comment the cap goes 42 → 32.
    - `TestLoad_ProfileGraphDefaults` in `suggestions_test.go` wants 30 / 20 / 10 / 5 / 1h.
    - `backend/internal/graph/suggester.go` `normalized()`: `boundedOr(l.EdgeLimit, 20, maxEdgesLimit)`. In
      `suggester_test.go` the "zero is the config default" row gets EdgeLimit 20.
  - Comments:
    - `graph/suggestions.go`: the `ListSuggestedUsers` comment and the `SuggestionLimits` field comments (cold cap 32,
      curated 12, warm 1 to 2, planning 27.6 per call).
    - `graph/suggester.go`: the `Suggester` interface comment ("42 reads cold").
    - `config/limits.go`: the `SuggestionsCallsPerDay` comment. The storm is 50 × 32 × 3 = 4,800 reads a day, under
      the 6,000 per-uid read budget, so the call cap binds.
  - Terraform: in `infra/terraform/envs/dev/main.tf` and `envs/prod/main.tf`, `SUGGESTIONS_EDGE_LIMIT` goes "30" →
    "20". Their "Must match the config.go defaults" comment still holds. No validator pins the literal today
    (`scripts/promotion` and `apiserver/guard_test.go` do not name it); if one is added first, it changes in the same PR.
  - Tests:
    - `w320_suggestions_integration_test.go`:
      - `TestW320_SuggestionsHardCap42` pins `c.Suggestions.EdgeLimit = 30` through its `mutate`, so the 30-edge bound
        stays tested.
      - A new `TestW320_SuggestionsHardCap32` runs the same 30-followee fixture at the config default. The newest 20
        edges hold 12 distinct candidates and hydration stops at 10, so the call is exactly 32. The dense-graph case
        is at most 32.
    - The other default-config ceilings take 32: the `Budget{Reads: 42}` of the "16 edges" and "friends of friends
      then curated" cases, and the one in `w320_budget_table_integration_test.go`. Better: derive them from
      `2 + cfg.Suggestions.EdgeLimit + cfg.Suggestions.HydrateMax`, as `cfgCap` does for bookmarks.
    - `suggestions_chain_integration_test.go` asserts 41 to 42 reads and `candidates` = 10 on a 32-edge fixture.
      - At 20 the window holds only followees 3, 2 and 1, and the per-followee cap leaves 9 candidates (31 reads).
      - Fix: pin `EdgeLimit = 30` in its `configure`, or reseed so that at least 4 followees fall in the newest 20
        edges with 10 or more distinct candidates, and assert 32.
    - `graph/suggestions_integration_test.go` and the `suggester_test.go` budget test set `EdgeLimit: 30`
      explicitly; they stay as the 30 case.
  - Docs:
    - `docs/runbooks/graph.md` §6: the cap 32, planning 17.2 reads/DAU, a regression above 32, the B2 client
      lifetimes and the B3 checks.
    - In its "Cache and staleness" paragraph and its symptoms table: on a device, a blocker is bounded by the client
      TTL (48 h, or until a tap gets NOT_FOUND). "More than a minute" applies to the server's answer only.
    - The `firestore-data-model` skill row for ListSuggestedUsers: cap 32, planning 27.6 per call.
  - `make ci` and `make test-int` green.
- **frontend-developer** (one PR, B1(a) and B2):
  - Shipping: it reaches users in an app release, like Amendment 1's placeholder. Old mobile builds keep 24 h until
    users update.
  - `app/lib/features/graph/data/suggestions_repository.dart`:
    - `kSuggestionsTtl` becomes 48 h;
    - new `kSuggestionsEmptyTtl` (6 h) and `kSuggestionsLimitBackoff` (24 h);
    - the entry records its lifetime on disk (an optional field, still `v: 1`);
    - the RESOURCE_EXHAUSTED branch uses `kSuggestionsLimitBackoff`;
    - a new `followed(uid, userId)`: it hides the row and, when no visible row is left, discards the entry and reports
      a refill (once per session, reset with the session);
    - the doc comments.
  - `SuggestionsCubit.followed` reloads on a refill, and `onFollowed` in `who_to_follow_card.dart` calls it instead of
    `hide`. The comments in `bootstrap.dart` and in the cubit say 48 h.
  - Tests in `app/test/features/graph/data/suggestions_repository_test.dart`:
    - Use the constants instead of hours. Today these cases hard-code 24 h: the call at 23:59, "within 24 h", "after
      24 h" (+25 h), the drop rewrite at 20 / 23 / 25 h, and the RESOURCE_EXHAUSTED window at 3 h and TTL + 1 min.
    - New cases:
      - 47:59 is a hit and 48:01 a call;
      - an empty answer is refetched after 6 h and not before;
      - a limit answer is kept 24 h;
      - an older disk entry is judged by content;
      - the refill: one RPC after the last row is followed, none on a second exhaustion in the session, none after
        dismissals or a drop, and the flag is reset on sign-out.
  - Cubit and card tests for `followed`.
  - `flutter analyze` and `flutter test` green.
- **sre-performance** (`docs/reviews/cost-model.md`, after the merge; no need to wait for the code):
  - §1: the call-mix row at 0.6 calls/DAU at 48 h, with the 1 / (1 + p) derivation (p = 2/3; best case 0.5), plus 0.02
    refills and about 0.01 empty refetches.
  - §2: the friends-of-friends row at cap 32 and the planning mix at 27.6 per call, 17.2 reads/DAU. Part A becomes 33.0
    and the total 281.7.
  - §3: free reads end at about 177 DAU, the 80% line at about 142.
  - §4: the suggestions storm row at 150 × 32 = 4,800 reads (the call cap binds), INR 4.9 per account-month and 485 for
    a ring of 100.
  - §5: the W3 block's "of which who to follow" line at 5.2 / 10.5 / 17.4 / 52.3, and the bill lines.
  - §6: the trigger row at 6.1%, firing at about 29.4 reads/DAU.
  - §9: `mean_cold_reads` expected 29.0, calls per DAU 0.63, and the fill check (B3).
  - A note that the W3-23 rows are superseded from the dev apply of step 4.
- **production-deployer:**
  - Step 1 unchanged.
  - Step 4 in dev: a targeted plan, then the apply through the same approval path W3-24 used, then the env and
    `fs_reads` checks.
  - Prod waits for the next founder-approved plan.
- **tester:**
  - Re-run the W3-20 suggestions matrix and budget table at the new default, and the 30 case through the pin.
  - Then the client tests above, at 360 dp, with the card in Home and in the side column sharing one refill.
- **security-auditor:** three checks:
  - the client bound for a blocker (48 h on a device) and the runbook's wording of it;
  - that the refill cannot loop (once per session, under 10/min and 50/day);
  - that the 20-edge window keeps the L-5 bound (3 rows per followee).

## Context
On X a profile shows these things, all captured in `docs/x_research/screens/profile.md`:
- a 3:1 cover image;
- location, website and "Joined Month YYYY";
- one pinned post;
- the tabs Posts · Replies · Reposts · Media (Highlights and Articles are premium);
- "Follows you" next to the handle;
- a "Who to follow" card.

Likes moved to the owner's History screen in 2024. Our profile today has the 3:1 band with no image, name, handle,
bio, counts, and two tabs (Posts, Replies).

**Stage and numbers.** Stage 0, about 300 DAU. Per `docs/reviews/cost-model.md` §3 the whole product with W2 on uses:

| Per DAU per day | Free quota runs out at |
|---|---|
| 248.7 reads | about 201 DAU (80% line about 161) |
| 33.5 writes | about 597 DAU |
| 8.4 deletes | about 2,390 DAU |

Every added read is therefore billed at Stage 0. The bill is about INR 434 / 1,626 / 3,396 a month at
300 / 1,000 / 3,000 DAU (ADR-0022). Targets: p95 warm < 400 ms for lists and tabs, < 150 ms for
GetProfileRelationship, < 500 ms for UpdateProfile.

**What the code has today** (`main` 180080f):
- **Media.** `MediaPurpose` has POST = 1 and AVATAR = 2. The Racy rule applies to avatars only
  (`media/finalize.go` `blockedBySafeSearch`). The global byte caps are full ≤ 2 MiB and thumb ≤ 256 KiB.
- **Replaced avatars.** They are kept until account deletion, and the media eraser removes every `media` doc a user
  owns whatever its purpose (`media-uploads.md` D10, `runbooks/media.md`).
- **Identity.** `UpdateProfile` resolves an avatar through the consumer-side `identity.AvatarResolver` before its
  write. `Profile` uses fields 1-12. `UpdateProfileRequest` uses 1-5.
- **Timeline.** `GetUserTimeline(include_replies)` serves Posts and Replies from the two `posts` composite indexes
  (ADR-0010 D19 Q-P, Q-R). Tokens are bound to `tl|user|{caller}|{target}|{posts|replies}|…` (D14).
- **Media field.** `posts.media` is exempt from indexing, so "has an image" cannot be queried today.
- **Likes.** `userLikes/{uid}.recent[]` holds the last 1,000 liked post ids, newest last, with no timestamps. It is
  trimmed best effort at the oldest end. An unlike is an `ArrayRemove`. A re-like appends at the newest end.
- **Relationships.** `GetRelationships` never reports `followed_by`; ADR-0008 D4 says so because it would cost one
  read per user.
- **Follows index.** `follows (followerId ASC, createdAt DESC)` exists.
- **Post deletes.** Every deleted post publishes one `post_delete` job. Identity's job router hands it to the
  registered handler.

## Options
**(1) Where "Follows you" comes from.**

| | A. New `GraphService.GetProfileRelationship(user_id)` (**recommended**) | B. Fold into `GetProfileResponse` | C. Add `followed_by` to `GetRelationships` |
|---|---|---|---|
| Reads | 3 cold (interceptor, caller graph, `follows/{target}_{caller}`) / 0 warm. Over the header's current `GetRelationships([uid])` call, +1 cold read, cached 60 s per pair | +1 cold read on **every** GetProfile, including mention taps and the caller's own profile, which never show the chip | up to +50 reads per call (one per id). This is what ADR-0008 D4 refused |
| Requests | 0 added: it replaces the header's `GetRelationships([uid])` | -1 per profile open: the header no longer calls GetRelationships | 0 |
| Boundaries | graph-owned data stays in graph, behind `FEATURE_GRAPH` | identity's response carries graph data, so identity needs a new consumer interface into graph, and GetProfile depends on the graph flag | breaks D4's 1-read contract |
| INR/month at 300 / 3,000 DAU | about 0.3 / 3.0 | about 0.9 / 9.1 (3 GetProfile per DAU), minus 0 / about 6.9 of Cloud Run requests (free below about 1,743 DAU) | n/a |

A and B are within about INR 1 a month of each other at every scale (B is about INR 0.8 cheaper at 3,000 DAU, once
Cloud Run requests are billed). A wins on the seams: B couples identity's response to graph data and the graph flag,
and charges the edge read to callers that never render the chip. B rejected.

**(2) Profile tabs: what to query.**
- **A. Two new composite indexes (recommended).**
  - Media: `posts (authorId, hasMedia, createdAt DESC)`, with a new `hasMedia` bool.
  - Reposts: `posts (authorId, kind, createdAt DESC)`.

  A page costs exactly `3 + page (+1 userLikes)` reads. Two index entries per post: about 2 × 120 B, cents a year at
  Stage 0.
- **B. Filter the Replies-tab query in memory.** Media and reposts are a small fraction of posts, so a page needs
  many over-read pages: 5-20× the reads, unbounded. Rejected (rule 6).
- **C. Index `media` itself.** It is a map array (url, thumb, blurhash, alt), so indexing it makes every post's index
  much larger, and "non-empty" is still not a query. Rejected.

**(3) Likes list source.**
- **A. `userLikes.recent[]`, resume-by-id cursor (recommended, plan default).** 0 new index, 0 new writes. The list is
  capped at the newest 1,000 likes and has no `liked_at`.
- **B. A `likes (uid ASC, createdAt DESC)` composite index.** Full history and timestamps, about +1 read per row for
  the query on top of the post reads (43 vs 23 cold at page 20). An index entry on every like (the highest-volume
  write), and a gate-file change. Rejected at Stage 0; it is the Stage 2 row.

**(4) Who to follow** (founder question 2; the plan's table is restated, not reopened):
- **A. Friends of friends with a curated fallback (recommended).**
  - Planning 25 reads, 42 worst per call.
  - About INR 7.6 / 76 a month at 300 / 3,000 DAU.
- **B. Recent active authors.** One shared per-instance `posts orderBy createdAt desc limit 50` refreshed hourly.
  - About INR 4 / 13. It costs reads even with no traffic.
  - It ignores the graph, so it is less relevant.
  - It is a public "who posted lately" feed, a scraping aid.
- **C. Curated only.** Planning 12 reads.
  - The same small set of accounts for everyone, forever.

  A stays the default. The `graph.Suggester` seam makes B, C or a precomputed source a swap.

**(5) Replaced banner objects.**
- **A. Keep them until account deletion: the existing `media-uploads.md` D10 retention path (recommended).** 0 code,
  0 extra reads or writes.
  - About 120 KB per replaced banner pair, against about 30 KB per avatar.
  - The old URL stays publicly reachable, though no profile links it.
- **B. Delete the previous banner on change.** This needs a `bannerMediaId` field, 1 extra read, and a job message per
  change.
  - Storage saved: 120 KB × banner changes. At 0.005 changes per DAU per day and 3,000 DAU, that is about 1.8 GB a
    year in the free 5 GB US bucket.
  - Better privacy for a user who replaces an image they regret.

  A now, and B behind D10's storage trigger, restated in D1.

## Decision
**D1. Banner: `MEDIA_PURPOSE_BANNER = 3`.**
- **Upload.** `CreateUpload(purpose=BANNER)` takes exactly 1 item. It needs `media` **and** `profile_extras` on for
  the caller, else FEATURE_DISABLED `feature=profile_extras` with 0 reads.
- **Sizes.** The client crops to 3:1 and encodes WebP q75 (JPEG fallback): full 1500 × 500 and thumb 600 × 200.
  - Per-purpose byte caps, bound into the signed URL's `x-goog-content-length-range`: full ≤ 1 MiB (well above a
    1500 × 500 WebP q75 at about 60-150 KB) and thumb ≤ 128 KiB.
  - Declared width ≤ 1500, height ≤ 500, and `3·h·0.98 ≤ w ≤ 3·h·1.02`; otherwise VALIDATION `field=width`.
  - The declared dimensions are layout hints. The server checks magic bytes, not pixels (ADR-0005 unchanged).
- **Moderation.** SafeSearch on full and thumb (2 Vision units) with the avatar's stricter Racy rule:
  `blockedBySafeSearch` gains `|| p == PurposeBanner`.
  - At `VISION_MONTHLY_CAP` the existing `VISION_EXHAUSTED_POLICY` applies unchanged. That means READY_UNSCREENED for
    established accounts, or REJECTED.
  - The 20/day `uploads` quota is shared with every other upload.
- **Resolver.**
  - `UpdateProfile.banner_media_id` resolves through a new consumer-side `identity.BannerResolver`, mirroring
    `AvatarResolver` and adapted from `media.Reader.ResolveBanner`. The resolver accepts only a READY or
    READY_UNSCREENED BANNER owned by the caller (1 read). Anything else is `MEDIA_NOT_READY`, one answer for every
    cause.
  - `""` removes the banner.
  - Stored as `users.bannerUrl` and `users.bannerThumbUrl`. Both are index-exempt (D14).
- **Replaced and removed banners** keep their objects until account deletion (Option 5A). The media eraser already
  deletes every media doc and object of the user, so rule 10 holds.
  - The D10 trigger is restated: when the `<proj>-media` bucket passes 50% of 5 GB, delete on replace (Option 5B).
- **The banner is not in `AuthorSnapshot`.** A banner change bumps no `snapshotVersion`, spends no `snapshotEdits`
  and enqueues no snapshot job.
- **Caching.** A new banner has a new object name, so the immutable CDN headers never serve a stale image.

**D2. Profile meta.**
- **Location.** `users.location`, ≤ 30 code points after NFC and trim, single line. The bio text rules apply: no
  control characters, no bidi formatting controls (ADR-0010 D9). Otherwise VALIDATION `field=location`.
- **Website.** `users.website`, ≤ 100 characters after trim. It must parse as an absolute URL:
  - scheme `https` or `http` (the scheme is lower-cased on store);
  - a non-empty host;
  - no userinfo (`user@`), no control, whitespace or bidi characters.

  Otherwise VALIDATION `field=website`. It is stored as typed, minus the case of the scheme.
  - The client shows the host only, in punycode for a non-ASCII host (homograph), and opens it outside the app.
  - The server never fetches it (no previews, no SSRF surface).
- **Clearing.** `""` clears either field.
- **Indexing.** Both fields are index-exempt.
- **"Joined Month YYYY"** is client-only, from the existing `Profile.created_at`.
- **No birthday.** It is PII, and rule 10 keeps PII in Firebase Auth and `users/{uid}/private`.

**D3. One pinned post.**
- **Field.** `users.pinnedPostId` (index-exempt). It is set by `UpdateProfile.pinned_post_id`; `""` unpins.
- **Validation.** Through a consumer-side `identity.PinChecker`, implemented by `posts` (the `BlockChecker` pattern,
  so identity never imports posts).
  - The post is read cache-first (1 cold / 0 warm).
  - It must be the caller's own POST, QUOTE or REPLY, `Visible()`, and not a REPOST.
  - Every other case is one answer, INVALID_ARGUMENT + VALIDATION `field=pinned_post_id`, so the call is no existence
    oracle.
- **Unpin on delete.** This overrides the plan's question 6 default ("no clean-up write"); the brief asked for it.
  - The existing `post_delete` job handler chain gains one identity step, `identity.Pins.ClearIfPinned(ctx, uid,
    postID)`.
  - It runs one transaction: read `users/{uid}` fresh (1 read). Only when `pinnedPostId == postID`, `Update` it to
    `""` (1 write).
  - The transaction never touches a newer pin. `Update` (not `Set`) cannot recreate a purged `users` doc: NotFound is
    acked.
  - The `post_delete` message carries only uid, post id and media ids, so the step runs for every deleted post,
    REPOSTs included (they can never be pinned, so it writes nothing for them). Adding the kind to the message to
    skip them is not worth a contract change.
  - It costs 1 read per deleted post (0.05 deletes per DAU, so +0.05 reads per DAU).
- **Takedown.** A takedown does **not** unpin: a restore brings the pin back. While the post is hidden, GetPost
  answers NOT_FOUND and the client hides the Pinned row (the plan's client rule stays, as the backstop for a job
  still in flight).
- **Rendering.** The client renders the pin with the existing `GetPost` (4 cold / 0 warm, planning 1).
- **Kill switch.** While `profile_extras` is **globally** off (`Registry.GloballyOff`, 0 reads), identity omits
  `pinned_post_id` from every `Profile`, so clients stop that call.
- **Hook for ADR-0025.** For a protected account and a non-follower, identity omits `pinned_post_id`.

**D4. `posts.hasMedia`.**
- **Writes.** Every create path writes `hasMedia = len(stored media) > 0` in the same write (+0 writes):
  - CreatePost root, reply and quote;
  - the ADR-0021 publish sweep;
  - RepostPost's REPOST doc (always `false`; its original's images live in `embedded`).
- **One definition.** It is defined once, in the posts repo helper that both create paths and the backfill use. The
  write is never flag-gated, so the field is right before `profile_tabs` turns on.
- **Backfill.** `opsctl backfill-has-media --project P [--dry-run]`:
  - pages `posts` by `__name__`, ≤ 500 per page, with a printed checkpoint;
  - sets `hasMedia` field-level (`Update`, never `Set`) only where it is missing;
  - writes ≤ 5,000 per run;
  - asks for confirmation on prod.

  A rerun writes 0. Cost: 1 read per post and 1 write per post that lacks the field. Dev: a few hundred. Prod before
  launch: about 0.
- **Rollout gate.** `profile_tabs` never leaves `off` in a project before the backfill has run there and the D14
  indexes are READY.

**D5. Profile tabs: `GetUserTimelineRequest.tab` (`UserTimelineTab`).**
- **Precedence.** `tab = UNSPECIFIED` (the default, and every pre-W3 client) means "use `include_replies`" exactly as
  today. Any other value **wins**, and `include_replies` is ignored with no error. Rule 9: the old field stays and is
  never renumbered.
- **Tabs.**
  - **POSTS:** root posts (Q-P). It keeps the author-recent first-page cache.
  - **REPLIES:** all posts (Q-R).
  - **MEDIA:** `authorId == A && hasMedia == true ORDER BY createdAt DESC, __name__ DESC`. It includes the author's
    replies and quotes with their own images, as on X. It excludes REPOSTs, whose `hasMedia` is false.
  - **REPOSTS:** `authorId == A && kind == "REPOST" ORDER BY createdAt DESC, __name__ DESC`.

  Both new queries use `Limit(page_size)` (D16 paging) and no instance cache: every open reads Firestore.
- **Rules.** Identical to the Posts tab (ADR-0010 D6 GetUserTimeline column):
  - NOT_FOUND byte-identical to GetProfile for a missing, SUSPENDED, DELETING or blocking author;
  - a blocker and a muter still get the posts.

  REPOST and QUOTE rows follow Home's embed rules: a REPOST whose embedded author the caller blocks or mutes, or who
  blocks the caller, is dropped; a QUOTE gets `embed_viewer_state`. ADR-0025 adds the protected-author rule through
  the same predicate.
- **Tokens (D14 bindings).** The tab part of the binding is the **effective** tab:
  - `UNSPECIFIED + include_replies=false` and `POSTS` both bind `posts`;
  - `UNSPECIFIED + true` and `REPLIES` both bind `replies`. Every pre-W3 token stays valid.
  - `media` and `reposts` are new binding values.
  - A token used on another tab is INVALID_ARGUMENT + VALIDATION `field=page_token|since_token` with 0 reads, and the
    client replaces that feed.
- **`since_token`, `gap_page_token` and `removed_ids`** behave as for the Posts tab. The removal log is scoped to the
  author (ADR-0016 D10).
- **Flag.** MEDIA and REPOSTS need `profile_tabs` on for the caller, else FEATURE_DISABLED `feature=profile_tabs`
  with 0 reads. POSTS and REPLIES stay ungated.

**D6. `EngagementService.ListLikedPosts` (owner-only).**
- **Request.** No user id: the source is `userLikes/{caller}`, read through engagement's 60 s cache.
- **Response.** Most recently liked first, from the newest end of `recent[]`. Each row is the **live** post via one
  cache-first `posts.Reader.GetMany` of the page's ids, with viewer flags from the same `userLikes` read (0 extra
  reads).
- **Drop rules.** As ListBookmarks (ADR-0023 D2, the ADR-0010 D6 Home column), plus ADR-0025's predicate:
  - missing;
  - `!Visible()`;
  - author or QUOTE/REPOST embedded author in `blocked`, `blockedBy` or `muted`.

  **No pruning:** the like path owns the array. Short pages are expected, so the client follows `next_page_token`
  while it is non-empty.
- **Page size.** 20 by default, clamped to 1..50.
- **Cursor: resume by id, never by index alone.** The token is sealed (`cursor.Encode`) and bound to `likes|<uid>`,
  with the 24 h TTL. It carries `{nextId, lastId, nextIndexFromNewest}`. `nextId` is the first id not yet returned
  (the one just older than the last returned row).
  - **Resume order:**
    1. If `nextId` is in `recent[]` **and** sits older than `lastId` (or `lastId` is gone), resume at it.
    2. Else, if `lastId` is in `recent[]`, resume at the entry just older than it.
    3. Else, resume at offset `nextIndexFromNewest` counted **from the newest end**, clamped. If that offset is past
       the oldest end, return `""`.
  - **Why this holds:**
    - A trim removes entries only at the oldest end, so the anchors' positions relative to each other never change.
    - An unlike removes one id. If it was `nextId`, rule 2 resumes just older than `lastId`, which is exactly where
      `nextId` stood. Nothing is skipped or repeated.
    - A re-like moves an id to the newest end, above every page already read. If that id was `nextId`, its new
      position is newer than `lastId`, so rule 1 would re-show it. Rule 1 therefore accepts `nextId` only when it
      sits **older than `lastId`**, or `lastId` is gone; otherwise rule 2 applies.
    - A trim that reaches `nextId` has also removed everything older, so rule 2 lands past the oldest end and the
      list ends (`""`), which is correct.
    - The residual: two changes to the page boundary between two scrolls (both anchors unliked, or `lastId` unliked
      and `nextId` re-liked) can skip or repeat at most the rows changed in that window. Rule 3 bounds it.
  - A tampered, foreign or expired token is VALIDATION `field=page_token` with 0 reads.
- **Reads.** Interceptor 1 + `userLikes` 1 + `GetMany` ≤ page + caller graph 1. That is **23 cold at page 20** (the
  plan said 24) and 53 at page 50. Warm (posts cached): 20 / 50. An empty `recent[]` costs 2. `NO_SIDE_EFFECTS`.
- **Flag.** `likes_list` on for the caller, and `posts`. The list shows likes made with `engagement` on; it needs no
  `engagement` itself.

**D7. `GraphService.GetProfileRelationship(user_id)` ("Follows you").** Option 1A.
- **Response.** The caller's `Relationship`, exactly as `GetRelationships` computes it from the cached snapshot
  (ADR-0008 D4), plus `followed_by`: whether `follows/{target}_{caller}` exists.
  - The edge read is cached 60 s per (caller, target) in a new small graph LRU: 5,000 entries, about 200 B each,
    about 1 MiB.
- **Rules.**
  - Target blocked the caller (snapshot `blockedBy`; +1 read on overflow, ADR-0008 D2): NOT_FOUND byte-identical to
    GetProfile, and the edge is never read.
  - Target missing or not ACTIVE: the same NOT_FOUND, through `identity.Directory` (cache-first).
  - Caller's own id: NONE and false, 0 extra reads.
  - A caller who blocks the target gets `blocking=true` and `followed_by=false`, because Block removed both edges.
- **Staleness.**
  - On this instance, the pair is evicted when the target follows or unfollows the caller, and on a Block either way.
  - Other instances converge within 60 s.
  - The caller's own Follow and Unfollow never change this edge.
- **Reads.** 3 cold (interceptor, caller graph, edge doc), +1 on overflow, plus `Directory` for the target (shared
  with the header's GetProfile, usually warm). 0 warm.
- **Request count.** It replaces the header's `GetRelationships([uid])`, so no request is added.
- **Flag.** `GetRelationships` is unchanged. Gated by `graph` like every GraphService RPC.
- **Not computed for list rows.** Rows would cost 1 read each (plan question 8).

**D8. `GraphService.ListSuggestedUsers` (who to follow).** Option 4A, behind the `graph.Suggester` interface.
1. Read the caller graph (cached).
2. Friends of friends. One query over the newest `SUGGESTIONS_SAMPLE_FOLLOWEES` (30) entries of `following`:
   `follows where followerId in [≤ 30] ORDER BY createdAt DESC, __name__ DESC LIMIT SUGGESTIONS_EDGE_LIMIT (30)`.
   - This is the ADR-0010 D19 Q-H shape (`in` on the first index field, then `createdAt DESC`). Home already runs it
     on `posts`, and here it runs on the existing `follows (followerId ASC, createdAt DESC)` index. No index change.
     W3-12 asserts it in an emulator test rather than treating it as an open risk.
   - The "newest 30" is the tail of the `following` array, which `ArrayUnion` appends in follow order.
3. Rank candidates (the `followeeId`s) by how many sampled followees follow them. Break ties by a stable hash of
   `(caller, candidate, IST day)`, so the card changes daily but not on every call. W3-22 L-5 (0 reads): a sampled
   followee that the identity profile cache already knows is not ACTIVE is left out of the step-2 follower list, and each
   sampled followee counts for at most its newest 3 usable edges, so one account that follows 30 others in a minute cannot
   pick the whole card.
4. Drop, at 0 reads from the snapshot: self, `following`, `requested`, `blocked`, `blockedBy`, `muted`.
5. Hydrate at most `SUGGESTIONS_HYDRATE_MAX` (10) through `identity.Directory.GetProfiles`, which drops non-ACTIVE
   users. Return at most `max_results` (default and maximum `SUGGESTIONS_MAX_RESULTS` = 5) `UserListItem`s with
   `relationship` and no `since`.

- **Fallback (option c).** `SUGGESTED_USER_IDS` (≤ 20 uids, a Terraform var, not a secret) is used when the caller
  follows fewer than 3 accounts, or when step 3 yields fewer than 3. The same step-4 filter applies; curated rows fill
  after the friends-of-friends rows, up to the hydrate cap.
- **Hard read cap.**
  - Friends of friends: 1 (interceptor) + 1 (graph) + 30 (edges) + 10 (hydration) = **42**. Amendment 2 B1 (proposed): 32 at
    `SUGGESTIONS_EDGE_LIMIT` 20.
  - Curated: 1 + 1 + 10 = **12**.
  - Planning 25. It never scans: no cursor, no target parameter, ≤ 5 results.
- **Caches.**
  - Per viewer on the instance for `SUGGESTIONS_CACHE_TTL` (1 h). A warm call costs 1 read, the interceptor, plus 1 when the
    viewer's 60 s snapshot has expired: every warm hit is re-filtered against `graph/{uid}` (W3-22 L-1 amendment, 2026-10-27), so
    a blocker added on another instance is hidden within 60 s. The 42 cold cap and the planning 25 do not change.
  - This instance's Follow removes the followed uid from the cached entry.
  - The client caches the result 24 h per uid (W3-19). Amendment 2 B1 and B2 (proposed): 48 h for a non-empty answer, 6 h for an
    empty one, 24 h after a limit, and one refill when follows empty the card.
- **Privacy.** It reveals follow edges of accounts the caller already follows, which `ListFollowing` already shows.
  It never suggests anyone in `blockedBy`. ADR-0025: a protected followee's edges are visible to the caller because
  the caller is its approved follower; protected candidates may be suggested, and following them creates a request.

**D9. Flags (ADR-0008 D6 pattern; wire names in brackets).**

| Flag | Gates | Ceiling in `flag-ceiling.json` (dev) | Prod |
|---|---|---|---|
| `FEATURE_PROFILE_EXTRAS` (`profile_extras`) | `UpdateProfile` banner, location, website and pin fields; `CreateUpload(BANNER)`, which also needs `media` | `{"mode":"allowlist","max_allowlist":3,"max_percent":0}` | no raise (prod apply on hold, `pending.md` 1.2) |
| `FEATURE_PROFILE_TABS` (`profile_tabs`) | `GetUserTimeline` tab MEDIA and REPOSTS | same | none |
| `FEATURE_LIKES_LIST` (`likes_list`) | `ListLikedPosts` (and `posts`) | same | none |
| `FEATURE_FOLLOW_SUGGESTIONS` (`follow_suggestions`) | `ListSuggestedUsers` (and `graph`) | same | none |

- **Fields sent while off.** Any of the four `profile_extras` fields sent while that flag is off for the caller →
  FAILED_PRECONDITION + FEATURE_DISABLED `feature=profile_extras`, 0 writes. The name and bio path is unchanged.
- **Rendering stays ungated.** Data set while a flag was on keeps rendering after a ramp-down, except the pin, which
  is omitted while `profile_extras` is globally off (D3).
- **Never gated:** the `hasMedia` write, the backfill, the pin clean-up and the export fields.
- **`GetMe.enabled_features`** lists the names. Each flag ramps off → dev allowlist (3) → the founder's MVP decision
  for prod.

**D10. Rate limits and quotas** (config, rule 11). Per instance, so the effective limit is ×3 at max instances.

| Key | Value | Effective (×3) | Notes |
|---|---|---|---|
| `RATE_LIMIT_SUGGESTIONS_PER_MIN` | 10 | 30/min | |
| `SUGGESTIONS_CALLS_PER_DAY` | 50 | 150/day | `DailyCaps` entry `limit_name=suggestions_daily`. Worst cold 42 × 150 = 6,300 reads/day per account, already bounded by the 2,000 read budget per uid per instance (ADR-0010 D5); Amendment 2 (proposed): 32 × 150 = 4,800, under the budget, so the call cap binds |
| `SUGGESTIONS_SAMPLE_FOLLOWEES` / `_EDGE_LIMIT` / `_HYDRATE_MAX` / `_MAX_RESULTS` / `_CACHE_TTL` | 30 / 30 / 10 / 5 / 1h | n/a | `config.Load` rejects edge > 50, hydrate > 50, sample > 30; Amendment 2 (proposed): edge limit 20 |
| `RATE_LIMIT_LIKES_LIST_PER_MIN` | 10 | 30/min | |
| `RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN` | 60 | 180/min | 0 reads warm |

- **Tabs** share the existing `GetUserTimeline` bucket.
- **Banner uploads** use the 20/day `uploads` quota.
- **UpdateProfile** keeps its existing limits.
- **Read budget.** Every new RPC is charged to the per-uid daily read budget (ADR-0010 D5). Every cold ceiling here
  (42, 53, 54) is under `readBudgetMaxCallReads` (269), so the constant is unchanged.

**D11. Deletion and export (rule 10, T11 guard).**
- **No new collection.**
  - The new `users` fields go with `users/{uid}` (deleted last).
  - Banner media and objects go in the existing `media` step, which is purpose-agnostic; W3-5 adds a BANNER case to
    the purge tests.
  - `hasMedia` goes with its post.
- **The T11 guard** needs no new row.
- **Export.** The profile section adds `bannerUrl`, `location`, `website` and `pinnedPostId` (golden file updated).
  The media section already lists banner media.
- **ListLikedPosts** reads only the caller's own data. The likes list stores nothing.

**D12. Answers to the plan's architect questions.**

| Question | Answer |
|---|---|
| "Follows you" RPC shape | `GetProfileRelationship` (D7, Option 1A): 3 cold / 0 warm, and it replaces the header's `GetRelationships` |
| `include_replies` vs tab | A set tab wins and `include_replies` is ignored; UNSPECIFIED means today's behaviour. Tokens bind the effective tab (D5) |
| Likes-list cursor | Resume by anchor ids, with a newest-end offset as the last fallback (D6) |
| Replaced banner objects | Kept until account deletion, per the `media-uploads.md` D10 retention path; trigger restated (D1) |
| Banner sizes | Full 1500 × 500, thumb 600 × 200, WebP q75; byte caps 1 MiB / 128 KiB; 3:1 ± 2% (D1) |
| ADR-0025: read time or visibility job | Decided in ADR-0025 (read time) |

**D13. Proto additions (W3-2; all additive, `buf breaking` clean, no number reused).**
- `identity.v1.Profile`:
  - `string banner_url = 13;` (1500 px; empty if none)
  - `string banner_thumb_url = 14;` (600 px)
  - `string location = 15;`
  - `string website = 16;`
  - `string pinned_post_id = 17;` (empty if none, or omitted per D3)
- `identity.v1.UpdateProfileRequest`:
  - `optional string banner_media_id = 6;` (`""` removes it)
  - `optional string location = 7;`
  - `optional string website = 8;`
  - `optional string pinned_post_id = 9;` (`""` unpins)
- `media.v1.MediaPurpose`: `MEDIA_PURPOSE_BANNER = 3;` (exactly 1; full 1500 × 500, thumb 600 × 200).
- `timeline.v1`:
  - a new enum `UserTimelineTab { USER_TIMELINE_TAB_UNSPECIFIED = 0; USER_TIMELINE_TAB_POSTS = 1;
    USER_TIMELINE_TAB_REPLIES = 2; USER_TIMELINE_TAB_MEDIA = 3; USER_TIMELINE_TAB_REPOSTS = 4; }`;
  - `GetUserTimelineRequest.tab = 6` (`UserTimelineTab`). The token-contract comment names "the target and tab" as
    today, now meaning the effective tab.
- `engagement.v1`:
  - `rpc ListLikedPosts(ListLikedPostsRequest) returns (ListLikedPostsResponse)` with `NO_SIDE_EFFECTS`;
  - `ListLikedPostsRequest { int32 page_size = 1; string page_token = 2; }`;
  - `ListLikedPostsResponse { repeated dzeroth.posts.v1.PostView posts = 1; string next_page_token = 2; }`. There is
    no `liked_at`: `recent[]` has no timestamps.
- `graph.v1`:
  - `rpc GetProfileRelationship(GetProfileRelationshipRequest) returns (GetProfileRelationshipResponse)` with
    `NO_SIDE_EFFECTS`;
  - `GetProfileRelationshipRequest { string user_id = 1; }`;
  - `GetProfileRelationshipResponse { Relationship relationship = 1; bool followed_by = 2; }`;
  - `rpc ListSuggestedUsers(ListSuggestedUsersRequest) returns (ListSuggestedUsersResponse)` with `NO_SIDE_EFFECTS`;
  - `ListSuggestedUsersRequest { int32 max_results = 1; }` (0 → 5, clamped 1..5);
  - `ListSuggestedUsersResponse { repeated UserListItem users = 1; }` (`since` unset).
- **RPC comments.** Each carries its reads and writes from the Cost impact table, its flag, its rate limit and its
  NOT_FOUND rule. `UpdateProfile`'s comment gains the new fields' rules and its new budget: 2 cold / 1 warm reads, +1
  per banner resolve, +1 per pin check, 1 write.

**D14. Indexes and field overrides (W3-2; `firebase/firestore.indexes.json` and `firebase/field-overrides.ack`, both
founder-gated).**
- **Composite indexes (additive):**
  - `posts (authorId ASC, hasMedia ASC, createdAt DESC)`, COLLECTION scope (Media tab);
  - `posts (authorId ASC, kind ASC, createdAt DESC)`, COLLECTION scope (Reposts tab).

  `__name__ DESC` follows the last field (ADR-0010 D19), so the queries order `createdAt DESC, __name__ DESC`.
- **fieldOverrides `indexes: []`:** `users.bannerUrl`, `users.bannerThumbUrl`, `users.location`, `users.website`,
  `users.pinnedPostId`.
  - These remove indexing on fields that no query uses and no serving revision indexes today, so the expand/contract
    note in the ack file is satisfied.
  - The `field-overrides.ack` hash is recomputed in the same PR.
- **`hasMedia` and `kind`** stay indexed (bools and short strings, needed by the composites).
- **`firestore-data-model` skill.** W3-2 updates the `users` and `posts` rows, the Indexes list, and the operation-cost
  rows from the table below.

## Cost impact
Convention as ADR-0008 A2 and ADR-0023: "cold" includes the account-status interceptor's read. Planning values are
what the model multiplies.

| RPC | Reads cold / warm (planning) | Writes | Deletes | Calls per DAU | Reads per DAU |
|---|---|---|---|---|---|
| `GetUserTimeline` MEDIA, page 20 / 50 | 24 / 54 cold (interceptor, target `users`, caller graph, page, `userLikes`); 20 warm (20) | 0 | 0 | 0.3 | 6.0 |
| `GetUserTimeline` REPOSTS, page 20 / 50 | same: 24 / 54; 20 warm (20) | 0 | 0 | 0.15 | 3.0 |
| `GetPost` of a pinned post (existing RPC) | 4 / 0 (1) | 0 | 0 | 0.6 | 0.6 |
| `UpdateProfile` with banner, meta or pin | 2 / 1 + 1 banner resolve + 1 pin check (4 worst cold, planning 2) | 1 | 0 | 0.03 | 0.06 |
| `CreateUpload` + `FinalizeUpload`, BANNER | 2 / 1 + 5 / 1.7 (existing rows) | 3.3 + 4.4 (the finalize was 2.7 before W3-22 M-3 added the screening claim write; the whole-product writes per DAU move by under 0.01) | 1 (TTL) | 0.005 | 0.01 |
| `ListLikedPosts`, page 20 / 50 | 23 / 53 cold; 20 / 50 warm; empty 2 (22) | 0 | 0 | 0.2 | 4.4 |
| `GetProfileRelationship` (replaces the header's `GetRelationships`) | 3 cold (+1 overflow) / 0 warm (1; +0.5 net over the replaced call) | 0 | 0 | 2 | 1.0 |
| `ListSuggestedUsers` | 42 friends of friends / 12 curated cold, 1 warm, 2 when the 60 s snapshot expired (W3-22 L-1) (25) | 0 | 0 | 1.0 (Amendment 2, proposed: 0.63 at 27.6 reads each) | 25.0 (Amendment 2: 17.2) |
| Pin clean-up in the `post_delete` job | 2 (the post, fresh, then `users/{uid}` in the transaction; Amendment 1 A5) | ≤ 1 (only when the deleted post was the pin) | 0 | 0.05 | 0.10 |
| `opsctl backfill-has-media` (one-off per project) | 1 per post | 1 per post lacking the field | 0 | n/a | n/a |
| **Part A total** | | | | **≈ 2.3 new requests** | **≈ 40.2** |

**Per DAU per day.**
- Firestore: **+40.2 reads** (+16% over 248.7), +0.06 writes, +0.005 deletes.
- Vision: +0.30 units per DAU-month (0.005 banners per DAU per day × 2 units × 30.42).
- GCS egress: 1.34 MB per DAU-month. That is one uncached banner a day, 70% of them at the 20 KB thumb and 30% at the
  100 KB full image.
- Cloud Run: 0.42 MB egress and 7.0 vCPU-s per DAU-month.

**Whole product with W2 and W3 Part A** (288.9 reads per DAU):
- Free reads run out at about **173 DAU** (was 201); the 80% line at about 138.
- Writes at about 596 DAU, unchanged in practice.
- Deletes are unchanged.

**Quota table.**

| Quota | W3 Part A alone runs out at | INR/month at 600 DAU (2×) | at 3,000 DAU (10×) |
|---|---|---|---|
| Firestore reads 50k/day | about 1,244 DAU (the product: about 173) | 24.4 | 122.0 |
| Firestore writes 20k/day | about 333,000 DAU (the product: about 596) | 0.1 | 0.5 |
| Firestore deletes 20k/day | never in practice | 0 | 0 |
| Vision 1,000 units/month (2 per banner) | about 3,300 DAU (the product: about 82, cap about 822) | 25.7 | 0 at the cap; displaces about 913 post-image units a month to `VISION_EXHAUSTED_POLICY` |
| GCS egress 100 GB/month | about 74,600 DAU (the product: about 2,133) | 0.6 (Class B) | 49.3 |
| Cloud Run requests and CPU | not binding alone (the product: about 1,566-1,743) | 2.9 | 70.3 |
| Storage | banner pairs about 120 KB per user who sets one (US bucket, shared 5 GB), plus 2 index entries per post | 0 | 0 |
| **Total** | | **≈ INR 54** | **≈ INR 242** |

**Monthly bill, Part A.** This confirms the plan's estimate with the method of `cost-model.md` §5 and §7: INR 95/USD,
reads $0.035 per 100k, writes $0.104 per 100k, Vision $1.50 per 1,000 units, egress $0.12/GiB.

| DAU | Firestore | Vision | GCS | Cloud Run | **Total** | vs Stage 0 baseline |
|---|---|---|---|---|---|---|
| 300 | 12.2 | 13.0 | 0.3 | 1.4 | **≈ INR 27** | 434 → 461 (+6%) |
| 1,000 | 40.7 + 0.2 | 0 (cap) | 1.2 | 4.8 | **≈ INR 47** | 1,626 → 1,673 (+3%) |
| 3,000 | 122.0 + 0.5 | 0 (cap) | 49.3 | 70.3 | **≈ INR 242** | 3,396 → 3,638 (+7%) |

The pin clean-up (+0.10 reads per DAU at 2 reads per deleted post, Amendment 1 A5) and the GetProfileRelationship
cold-count correction (3, not 2) move no total by more than INR 0.5.
- **Fixed monthly cost added: INR 0.** No new GCP service, topic, Scheduler job or Terraform resource. There are two
  composite indexes and five fieldOverrides. The credit window (ADR-0022) lifts nothing.
- **Largest line:** who to follow (25 of 40.2 reads; 35.7 of 51.5 as W3-23 restated it). Amendment 2 (proposed) takes the
  first two levers. Its levers, cheapest first:
  - a 48 h client cache (−12.5);
  - `SUGGESTIONS_EDGE_LIMIT` 20 (−5 worst);
  - curated-only below 3 followees;
  - Option 4B.
- **Trigger:** none for Stage 0 (pay-per-use). The stage-ladder triggers are below.

## Stage ladder

| Concern | Stage 0 (this ADR) | Seam | Stage 2/3 target | Trigger |
|---|---|---|---|---|
| Who to follow | Friends of friends at query time, hard cap 42, per-viewer 1 h instance cache, curated fallback | `graph.Suggester` (no caller knows the source); no cursor on the wire | A precomputed table, refreshed by a batch job over a Firestore export (or SQL) and served at 1 read; later a ranking ADR | Suggestion reads above 10% of daily reads, or the §6 Firestore trigger, sustained 7 days (Amendment 2, proposed: cap 32, 48 h client cache, modelled 6.1%) |
| Profile tabs | One `Limit`ed indexed query per page, no cache (the Posts tab keeps author-recent) | `timeline` interface; tab-bound opaque tokens | A per-tab instance cache, then Memorystore with the Stage 2 timeline | Tab reads above 15% of daily reads |
| Likes list | `userLikes.recent[]`, newest 1,000, resume-by-id cursor | `engagement.LikesList`; opaque `likes|uid` token | A `likes (uid, createdAt)` index or a SQL `likes` table with timestamps and full history | User demand, or most active users at the 1,000 cap |
| "Follows you" | 1 cached point read per (caller, target) | `GetProfileRelationship` (single target by contract) | Served from the Stage 2 graph store (SQL edge table or Memorystore) | The §6 trigger |
| Banner storage and delivery | Keep replaced objects; GCS public-read | `identity.BannerResolver`; URLs opaque to clients | Delete on replace (Option 5B), then CDN at Stage 3 | Bucket > 50% of 5 GB; GCS egress above the §6 line |
| Hot spots and counters | No new counter, no new hot doc; `hasMedia` rides the post write | n/a | n/a | None at any DAU |

## Consequences
- **Positive.**
  - Every new read path has a hard cap: 24 / 54 / 23 / 53 / 3 / 42.
  - No new collection, fan-out, counter, cost-bearing service or fixed fee.
  - Old clients and old tokens keep working (UNSPECIFIED tab, effective-tab binding).
  - Banner moderation reuses the avatar path.
- **Negative.**
  - Part A adds about 16% to daily reads, and who to follow is most of it.
  - Free reads now end at about 173 DAU.
  - The likes list stops at 1,000 and has no dates.
  - Replaced banners stay publicly reachable by URL until account deletion (superseded by Amendment 1 A4: deleted 24-48 h after a remove or replace).
  - Tabs read Firestore on every open.
  - The website field is a phishing surface (scheme and host rules, client punycode, W3-22 review).
- **Follow-up.**
  - W3-2: protos, indexes, overrides, ack, skill rows.
  - sre-performance: the cost-model rows.
  - `docs/runbooks/media.md`: the banner line.
  - A new runbook entry for the backfill.
- **Revisit when:**
  - any Stage-ladder trigger fires;
  - Vision is at its cap for 2 months running and banner displacement matters;
  - ADR-0025 is accepted. The pin omission, the tabs and the likes list then call its predicate.

## Questions for the founder
The plan's decisions, each with this ADR's recommended default.

| # | Question | Recommended default |
|---|---|---|
| 2 | Who-to-follow source: (a) friends of friends + (c) curated fallback, (b) recent active authors, or curated only | **(a) + (c)**: planning 25 reads, about INR 7.6 / 76 a month at 300 / 3,000 DAU; Amendment 2 (proposed) restates it at 17.2 reads per DAU |
| 3 | Likes visibility: owner only, newest 1,000 | **Yes**: no new index, no public scraping vector |
| 4 | Tabs: Posts · Replies · Reposts · Media | **Yes**: dropping Reposts saves one index and 3 reads per DAU |
| 5 | Location and website, no birthday | **Yes** (D2 rules) |
| 6 | One pin; own POST, QUOTE or REPLY; unpinned automatically when the post is deleted (not on takedown) | **Yes**: overrides the plan's "no clean-up write" at +0.05 reads per DAU |
| 7 | "History" with tabs Bookmarks \| Likes | **Yes** (client only) |
| 8 | "Follows you" on the profile header only, plus "Follow back" | **Yes**: list-row chips cost 1 read per row |
| 9 | One-off `opsctl backfill-has-media` per project before `profile_tabs` leaves `off` there | **Yes** |
| 10 | Replaced banners: keep until account deletion (D10 path), or delete on replace | **Keep**, with the 50% bucket trigger |

Question 1 (Part B) is ADR-0025.

## Handoff
- **architect (W3-2, after this merges):**
  - the D13 proto additions with their budget comments, then `buf lint` and `buf breaking`;
  - the D14 indexes, fieldOverrides and ack hash (founder review);
  - the `firestore-data-model` rows.
- **backend-developer:**
  - **W3-4:** register the four flags, the D10 config and rate limits, `config_test.go`, Terraform vars default
    `off`, and the `flag-ceiling.json` entries (founder review).
  - **W3-5:** `PurposeBanner`:
    - the per-purpose byte caps and the 3:1 check;
    - the Racy rule;
    - `ResolveBanner`;
    - purge tests.
  - **W3-6:** identity:
    - the fields and validation;
    - `BannerResolver` and `PinChecker`;
    - `Pins.ClearIfPinned` wired into the `post_delete` handler chain;
    - the global-off pin omission;
    - the export fields;
    - log `profile_fields_changed` (names only).
  - **W3-7:** posts:
    - `hasMedia` on all four create paths;
    - `PinChecker`;
    - `Reader.ByAuthorMedia` and `Reader.ByAuthorKind`.
  - **W3-8:** the backfill.
  - **W3-9:** the tab enum, the effective-tab binding and the drop rules; log `tab`.
  - **W3-10:** `ListLikedPosts` with the D6 cursor; log `rows_dropped` by cause and `fs_reads`.
  - **W3-11:** `GetProfileRelationship` and its pair LRU; log `followed_by_cache_hit`.
  - **W3-12:** `Suggester`, the Q-H emulator test, and log `source=fof|curated` and `candidates`.
  - Every RPC is asserted with `budgettest` at the cold ceilings above.
- **frontend-developer:** W3-13 to W3-19 per the plan, plus:
  - the banner encoder's sizes and byte caps (D1);
  - the website rendered as its host, in punycode;
  - the `FeedKey.user(uid, tab)` cache replaced on a rejected token;
  - the likes list following `next_page_token` through short pages;
  - the header calling `GetProfileRelationship` instead of `GetRelationships`.
- **tester:**
  - the tab token matrix, including pre-W3 tokens on POSTS and REPLIES;
  - the D6 cursor cases: unlike of `nextId`, re-like of `nextId`, trim, a double unlike;
  - the pin matrix: delete, takedown, restore, another user's post, REPOST;
  - the follows-you block matrix;
  - the suggestions exclusion matrix and cap;
  - a backfill rerun writes 0.
- **production-deployer:**
  - indexes READY and the backfill run before `profile_tabs` leaves `off`;
  - a targeted dev Terraform plan to the founder;
  - prod unchanged.
- **sre-performance:**
  - the Cost impact rows into `cost-model.md` (+40.2 reads, +0.06 writes, +0.005 deletes per DAU, +0.30 Vision units
    per DAU-month, banner egress);
  - the read quota line moving to about 173 DAU;
  - the Stage-ladder triggers as dashboard notes.
- **security-auditor (W3-22):**
  - website rendering and homographs;
  - banner moderation at the Vision cap;
  - suggestions enumeration (no cursor, ≤ 5, the 150/day effective cap);
  - follows-you as an oracle (NOT_FOUND bytes);
  - the pin check as an existence oracle;
  - the export fields.
