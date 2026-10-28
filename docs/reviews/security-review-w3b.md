# Security review: UI wave W3 Part B (private accounts and follow requests, ADR-0025)

Ticket W3-36 of `docs/plans/ui-w3-profile-graph-completion.md`. Reviewed by the security-auditor agent, read-only, on
`git archive origin/main` at **15975e53** (2026-10-28). `main` has since moved to c16debd9 (#399, W3-33d, a client layout
change in `user_list_row.dart` only; the lock badge still requires `user.isPrivate`, so nothing below changes). W3-34 (the
Follow requests screen) was not reviewed: it had no commits when the review ran; a checklist for its PR head is under "Not
performed".

Verdict: **CLEAR WITH FIXES**. There is no Critical or High finding; there are two Major (M-1, M-2), five Low and six Info.
Only **M-1 gates W3-38**, as a precondition: the dev allowlist of 3 may not protect anyone until M-1(c) is met. M-2 lands
before `private_accounts` leaves the dev allowlist in any project. The Lows go in the next backend or client fix PRs.
Severity words follow the W2 and W3 Part A records (Major is their Medium). The tester's W3-35 results did not exist yet;
this review rests on the code and each ticket's own tests. No tests were run.

## Scope
Part B tickets on main: W3-25a/b/c (protos, flag, quota kind, `AuthorSnapshot.is_private`), W3-26a/b (set, loader, toggle,
pin omission, GetMe count), W3-27 (request, withdraw, Block clean-up), W3-28a/b/c (request lists, Respond,
PROTECTED_ACCOUNT lists, the `privacy_public` job, list-row `is_private`), W3-29a/b (`posts.Audience`, GetPost, Viewable,
share refusal, embeds, thread, bookmarks, likes), W3-30 (timelines), W3-31 (notifications), W3-32 (eraser and export), and
client W3-33a/b/c in `app/lib`.

Method: STRIDE per surface; the ADR-0025 D13 limits at per-instance x 3 instances; a cost-attack estimate per finding.
Prices (Part A convention): Firestore $0.035 per 100k reads, $0.104 per 100k writes; GCS Class B $0.0004 per 1k;
INR 95 per USD.

## Threat model (STRIDE)

| Surface | Threat | Control (evidence, origin/main 15975e53) | Residual |
|---|---|---|---|
| Protected set loader | T/I: an unknown set read as "everyone public" | Missing doc = empty set (`identity/repo_privacy_firestore.go`:78-93). Fail closed past `PROTECTED_SET_MAX_STALE` or when never loaded (`identity/protected_set.go`:151-159). Singleflight on a detached context and counter (:136, :162-176) | L-3, L-4 |
| GetPost, Viewable (Like, AddBookmark, Report, reply parent, quote target) | I | `Audience.Decide` on the direct surface; NOT_FOUND is the same `postNotFound()` as a deleted post (`posts/service_delete.go`:189-206, :240-243). Block first (`posts/audience.go`:110-118) | I-1 |
| GetThread | I | Focal through `viewableResolved`; parent and root through `contextAllowed` (tombstone) (`posts/service_thread.go`:131, :237-301); reply rows through `visibleAuthor`, dropped (:179-194) | none |
| Feeds and lists, embeds | I: P's text or media inside a REPOST/QUOTE | REPOST dropped; QUOTE kept with PROTECTED. `ApplyEmbedState` keeps only `post_id`, `unavailable` and `author` (`posts/audience.go`:213-220). `EmbeddedPost` has no hashtags or mentions (`posts.proto`:308-321). Used by Home, profile tabs, bookmarks, likes, GetPost, GetThread (`timeline/service.go`:94-98, :292-295, :307-336; `engagement/list_common.go`:168-177; `posts/server.go`:168, :256) | M-2 |
| GetUserTimeline(P), any tab | I | `checkVisible` runs before the author-recent cache, tokens and removed_ids (`timeline/service.go`:379-388, :454-486) | none |
| Repost/quote of P | T: copies of protected text | `RefuseShare` gives PROTECTED_ACCOUNT, 0 writes (`engagement/service.go`:526-530; `posts/service_engagement.go`:84-87) | none |
| ListFollowers/ListFollowing(P) | I | Blocked-by and missing target first (NOT_FOUND), then `refuseProtectedList`, before any page read (`graph/follows_list.go`:45-68; `graph/follow_requests.go`:139-154) | I-4 |
| GetProfile pin | I | `pinForViewer`: follower from the snapshot, otherwise the set; unknown set or failed follow check omits the pin (`identity/service.go`:331-333, :843-869) | none |
| Follow request | S/D: spam, harassment | Follows quota inside the transaction, `requested` cap 500, bucket (`graph/repo_firestore.go`:384-407); deterministic `follow_request_{requester}` id (`notifications/fanout.go`:76-80) | see limits |
| Protect-vs-follow race | T | Target `users` read inside the Follow transaction (`graph/repo_firestore.go`:332-340) | none |
| Respond | E: IDOR | Request ref built from (requester, **caller**) (`graph/follow_requests.go`:84-85; `graph/repo_requests.go`:138-152) | none |
| ListFollowRequests | I: another user's requests | Path from the token uid; cursor sealed to `caller\|follow-requests`; doc id must end `_caller` (`graph/follow_requests.go`:24, :40) | none |
| `privacy_public` job | S/T: forged or replayed message | OIDC on `/internal/*` (`apiserver/apiserver.go`:463-469). Only the uid is read from the message; the transaction re-reads `users` and the page; acts only on `{follower}_{target}` docs; one page = one transaction (`graph/privacy_public.go`:105-114; `graph/repo_privacy_public.go`:75-116, :146-149) | I-3 |
| Notifications | I: rows and push from P | Mention, reply, quote, repost suppressed unless the recipient may see the actor; unknown set retries (`notifications/fanout.go`:245-257). Rows carry the actor snapshot and post id only (`notifications.proto`:97-110). Generic push text (`notifications/fcm.go`:22-42) | I-2 |
| Toggle | D: storm, hot doc | 4/day both directions; equal value not charged; cap 20,000 checked in the transaction (`identity/repo_privacy_firestore.go`:121-171); the flag gates only `true` (`identity/service.go`:416-423) | I-6 |
| Erasure and export | R/I | `follow_requests` step, outgoing then incoming with `ArrayRemove`, Update only (`graph/purge_requests.go`:70-193). Set entry removed in the identity step (`identity/lifecycle_jobs.go`:443). Export `{sent, received}` (`graph/export_requests.go`). T11 rows (`apiserver/lifecycle_collections_guard_test.go`:72, :87) | none |
| Rollback, traffic split | E/I: an old revision serves protected posts publicly | none | **M-1** |
| Public media objects | I: guessing P's new image URLs | API paths never return them to unapproved viewers | **M-2** |
| Client caches | I | `author_protected` deletes every cached tab of that author (`timeline_repository.dart`:129-135, :303-306). `is_private` is a badge only (`user_list_row.dart`:105-131). `clearSession` clears the protected map (:80-88) | I-2 |

## Effective limits and cost bound (rule 11, x 3 instances)

| Control | Per instance | x 3 | Daily bound |
|---|---|---|---|
| Follow/Unfollow (requests and withdraw) | 30/min (`config.go`:476) | 90/min | follows quota 200/day (50 new), in Firestore; `requested` cap 500 |
| RespondToFollowRequest | 60/min (`config.go`:460) | 180/min | bounded by pending requests |
| ListFollowRequests | graph list 20/min (`config.go`:482) | 60/min | `graph_list_daily` (`ratelimit_config.go`:150), x 3 |
| Unlike/UndoRepost (L-1 probes) | 30/min (`config.go`:433) | 90/min | read budget 2,000/instance, so 6,000 |
| Toggle | `profile_update_daily` + quota 4/day (Firestore) | — | 4 toggles, so at most 2 jobs per account per day |
| Push per requester per target | 1 per 90 d (deterministic id) | — | — |

**Request ring cost.** 100 accounts x 200 request-and-withdraw cycles a day. One cycle is about 6 reads, 5 writes and
1 delete (Follow 4 / 3, fan-out about 2 / 1, withdraw 1 write + 1 delete). Per day: 120k reads, 100k writes, 20k deletes,
about $0.15 (INR 14/day, **INR 420/month**, 1.7% of the INR 25,000 cap). About 20 such accounts exhaust the free 20k
writes a day. A target gets one push per requester account per 90 days. The toggle-and-job loop costs at most
2 x 1,505 writes per protected account per day (about INR 0.3).

## Findings

| ID | Severity | Where | Finding | Fix | Owner | Gates W3-38 |
|---|---|---|---|---|---|---|
| M-1 | Major | `docs/runbooks/rollback.md` (no mention); `docs/runbooks/private-accounts.md` §1-7 (none); `.github/workflows/deploy-dev.yml`:5-6, :219; `scripts/promotion/README.md`:19 | Nothing records or enforces plan rule 10. Automated and manual rollback to `last-good`, and a 10% split, can route traffic to a revision without W3-26a to W3-32, which shows protected posts to everyone | Runbook rule, a guard in `resolve-rollback.sh`, a W3-38 precondition | production-deployer, architect | **Precondition (c)** |
| M-2 | Major | `media/service.go`:105-117; `pkg/platform/snowflake/snowflake.go`:17-24, :42-51, :63-85 | A protected author's new post images are public-read under names derived from a time-ordered Snowflake id; about 7x10^5 anonymous GETs per post window find them | Unguessable public object names for new uploads | architect, backend-developer | No (before `private_accounts` leaves the dev allowlist) |
| L-1 | Low | `engagement/service.go`:242-261, :481-505, :595-620 | Unlike/UndoRepost on any post id return live counts and resolve a REPOST id to its original with no visibility check: an existence and counts oracle, not byte-identical to a deleted post | Return the missing-post shape when the caller can't see the author | backend-developer | No |
| L-2 | Low | `timeline/service.go`:307-336; `posts/service_delete.go`:189-206; `engagement/list_common.go`:168-176 | Plan rule 4 not met in the client: after a viewer stops being approved, their own REPOST, like and bookmark of P disappear from every surface, so the ungated undo RPCs can't be reached | Owner-row escape on the caller's own lists and tab, rendered stripped (ADR-0025 note) | backend-developer, frontend-developer | No |
| L-3 | Low | `identity/protected_set.go`:141-146, :184-187 | A same-instance unprotect during a refresh discards the fresh read; `Current` returns the old copy with no age check, possibly older than `PROTECTED_SET_MAX_STALE` | Re-apply the local delta to the fetched copy, or re-check age after the flight | backend-developer | No |
| L-4 | Low | `timeline/service.go`:295; `posts/server.go`:117, :171, :259; `engagement/list_common.go`:177; `posts/audience.go`:180-183; `identity/protected_set.go`:157 | `ProtectedAuthor` (wire visibility) calls the loader for every row, followed authors included (against D3's "only when needed"); during an outage it sends one ERROR per row (up to 50 per page) | Skip own and followed authors; report unavailability once per request | backend-developer | No |
| L-5 | Low | `posts/audience.go`:28, :66-75; `posts/service.go`:93-97; `timeline/audience.go`:22-25; `graph/follow_requests.go`:140; `identity/service.go`:844-846; `notifications/fanout.go`:103-105; `engagement/service.go`:75-77 | Every module treats a nil loader or audience as "nobody is protected"; a wiring regression fails open silently | Startup assertion in `apiserver.Build`, plus the W3-35a guard asserting the wiring | backend-developer, tester | No |

### M-1. Nothing stops a rollback or traffic split from serving protected posts publicly
- Stored posts stay `PUBLIC` (D2); enforcement exists only in revisions that contain W3-26a to W3-32.
- `deploy-dev.yml` rolls back to `last-good` automatically on any failed verification (:5-6, :219). `resolve-rollback.sh`
  checks only that the tag, digest and ceiling are valid (`scripts/promotion/README.md`:12, :19). Neither `rollback.md`
  nor `private-accounts.md` says "never route to a pre-enforcement revision while any account is protected".
- If an allowlisted dev account protects while `last-good` predates the enforcement tickets, every viewer on that revision
  sees the account's posts, replies, media and REPOST copies. In prod, `promote-prod`'s 10% step leaves 90% of traffic on
  the old revision, so protecting on the candidate is public on the other 90%. The flag cannot fix this: an old revision
  has no enforcement code to switch on.
- **Impact:** full disclosure of protected content; 0 cost.
- **Fix:** (a) a rule in `rollback.md` and `private-accounts.md`: before any rollback, read `privacy/protectedAuthors`
  (1 read); if `uids` is non-empty the target must contain W3-32 (#381) or later, or the rollback is refused.
  (b) `resolve-rollback.sh` refuses a `last-good` image older than a floor recorded next to `PRIVATE_ACCOUNTS` in
  `flag-ceiling.json` whenever that flag is not `off` (gate file: the architect decides where the floor lives).
  (c) W3-38 checks, before the allowlist apply, that 100% of dev traffic **and** `last-good` run post-W3-32 images, and
  records both revision names. (d) Prod: `private_accounts` stays `off` until the first Part B release is at 100% and its
  `last-good` is also post-Part-B.
- **Gate:** (c) before W3-38 changes the flag; (a), (b) and (d) before any prod ramp.

### M-2. New images of a protected account can be found by guessing their public object names
- Media ids come from the same Snowflake generator as posts: 41 bits of milliseconds, 10 bits of node id (random per
  process), and a 12-bit sequence that is almost always 0 at Stage 0. The public copy is `m/<id>.<ext>` (jpg or webp),
  public-read and published at finalize, before the post exists.
- An attacker learns the live node ids (at most 3 instances) from any fresh public post id (`(id >> 12) & 1023`), and the
  window from P's public `posts_count` (about 2 minutes) or an approved follower's public reply (`reply_to_post_id` gives
  the exact millisecond, `posts/convert.go`:22-24).
- A 120 s window is 120,000 ms x 3 nodes x 2 extensions = **7.2x10^5 anonymous GETs**; the hits are every image finalized
  in that window, a handful at Stage 0, one of them P's. Closing bucket listing (W3 Part A M-2) does not help against
  guessing, and the `stage-ladder` skill already treats Snowflake ids as guessable.
- **Cost to the attacker, billed to us as Class B:** about INR 27 per post window.
- **Fix (architect):** new uploads get an unguessable public name, `m/<id>-<128-bit random or HMAC(key,id)>.<ext>`, stored
  in the media doc and `MediaRef` (0 extra reads and writes); update the retire job's name parser (`media/retire.go`:237)
  and the media eraser. Old objects keep their names (founder question B1 stands). The alternative, signed URLs for
  protected authors' media, costs more and complicates caching.
- **Gate:** before `private_accounts` leaves the dev allowlist in any project.

### L-1. The undo RPCs are an existence and counts oracle
An unapproved viewer takes P's post id from a public reply's `reply_to_post_id` or a stripped QUOTE's `post_id` and calls
UnlikePost or UndoRepost. `resolveForCounts` reads the post with no audience check and returns `like_count` and
`repost_count`; a missing post returns `{post_id}` with zero counts, so the answers differ from a deleted post (against
D13), and a REPOST id resolves to the original. The same oracle exists today for blocked-by authors and taken-down posts.
About 1 read cold per probe, 90/min effective. **Fix:** keep the write ungated (rule 4); return the not-found shape when
`Audience.VisibleAuthor` is false or the post is hidden (+0 warm, +1 cold for the caller's snapshot).

### L-2. No way to undo a REPOST, like or bookmark of an account the viewer can no longer see
After the viewer unfollows P, or P protects, the viewer's own REPOST of P is dropped from their Reposts tab, GetPost of it
is NOT_FOUND, and likes and bookmarks of P are dropped (kept, not pruned). The server undo paths stay ungated, but no UI
shows a card to act on, and the REPOST doc (a copy of P's text) stays until account deletion. **Fix:** on the caller's own
Reposts tab, Likes list and Bookmarks list, keep the row as a stripped PROTECTED placeholder with Undo, Unlike or Remove
(an ADR-0025 note; it changes the D4 list row for the owner only; +0 cost).

### L-3. The loader can serve a copy older than PROTECTED_SET_MAX_STALE
`refresh` discards a successful read when `gen` moved (a same-instance `Apply` during the read) and keeps the old
`fetchedAt`; `Current` then returns that set with no age check. After an idle period longer than 10 minutes that one
request decides with a stale set. Likelihood is low (a same-instance unprotect inside a 10-50 ms read). **Fix:** on a
`gen` mismatch, install the fetched copy with the local deltas re-applied, or re-check age after the flight.

### L-4. The wire-visibility hint reads the set for every row
`ProtectedAuthor` calls `Current` for every row, own and followed authors included, so a Home page triggers a refresh;
background reads stay at most 1 per instance per minute (W3-37: take about 4,320/day as the continuous-traffic maximum).
During an outage `fallback` sends an ERROR per call, up to 50 per page, and "Error Reporting is quiet" is a rollback
check (`rollback.md`:132), so a set outage could prompt a rollback (M-1's hazard). **Fix:** skip own and followed authors;
report `protected_set_unavailable` once per request, WARN after that.

### L-5. Every module fails open when no loader is wired
A nil loader or audience means "nobody is protected" (by design for tests). `apiserver` wires them all today
(`apiserver.go`:137, :150, :198, :247, :308, :333, :353), but a refactor that wraps `postsSvc` (`AudienceOf` returns nil
for anything but the concrete type) would silently drop protection from ListBookmarks and ListLikedPosts. **Fix:**
`Build` fails startup if any of the seven seams is nil outside `ENV=local` tests; W3-35a's guard asserts the wiring.

## Info
- **I-1. Set-outage oracle.** During an outage longer than 10 minutes, GetPost of an existing post by a non-followed author
  is UNAVAILABLE while a missing id is NOT_FOUND (`posts/audience.go`:204-208). Only in a fail-closed outage. Accept.
- **I-2. Residuals already on devices.** A profile feed cached on disk shows on a cold app start until the first refresh
  returns `author_protected` (the map is memory-only, `timeline_repository.dart`:74, :114-119); QUOTE embeds cached in
  Home keep their unstripped copy; delivered notifications stay; post-image URLs seen while public keep working (B1).
  All content the viewer already received. Accept; document in the privacy notice.
- **I-3. `privacy_public` ceiling.** 5,000 requests per delivery and 10 delivery attempts on `jobs` give about 50,000
  before the DLQ; requesters at the following cap stay pending (`skipped_cap`). Both in `private-accounts.md` §6. Accept.
- **I-4. P's graph is visible elsewhere.** P's own follow edges still appear in public accounts' follower lists, and P's
  likes in public counts (X behaviour, accepted by the ADR). Only Block removes an existing follower.
- **I-5. 60 s window.** After unprotect, posts stay hidden (fail closed); after protect, other instances may show them for
  up to 60 s (D3).
- **I-6. Cap filling.** 20,000 bot accounts protecting would fill `PROTECTED_AUTHORS_MAX` and block new protects. Out of
  reach at Stage 0; the stage-ladder trigger is 10,000. Consider requiring email-verified accounts older than 24 h for
  protect if the trigger is approached.

## Questions for the founder
1. M-2: accept unguessable public names for new uploads (an architect note on ADR-0005 and ADR-0025, 0 cost), or accept
   guessable new images of protected accounts as a documented residual?
2. M-1: is a rollback floor in `flag-ceiling.json` (a gate file) acceptable, or are the runbook rule plus the W3-38 check
   enough for Stage 0?

## Verified sound
- **W2 L-2 is closed by `Audience.Decide`**, not by a stored-`visibility` test (`list_common.go`:129-131, :168-176). The
  only stored-visibility hits left are write sites and comments.
- **One predicate.** Written once (`identity/protected_set.go`:62-64); posts, graph, identity and notifications delegate
  to it.
- **Embed strip is complete.** Text, media (URL, thumb, alt, size), labels, reply policy and timestamp are removed; only
  `post_id`, `unavailable` and the author snapshot are kept; the snapshot is one level deep.
- **Oracle order.** Blocks first everywhere; NOT_FOUND text shared; PROTECTED_ACCOUNT only after the NOT_FOUND checks, so it
  reveals only `is_private`.
- **Races.** Follow vs protect (in-transaction read), accept vs withdraw (transaction vs `Exists` batch), accept vs block,
  job vs re-protect, AQ4. I-R and I-X kept by every writer read, including Block.
- **Undo gating.** Unfollow, withdraw, `is_private=false` and Respond for a protected caller while globally off are
  ungated. The client gap is L-2.
- **Toggle.** One transaction for user doc, set and quota; cap checked on the fresh doc; refusals write 0.
- **GetMe count.** Protected callers only, `Limit(1000)`, cached 30 s, an error answers 0 and is not cached.
- **Caches across viewers.** Author-recent and post caches filtered per viewer after the cache; `checkVisible` before the
  cache; the pin decided after the profile cache; per-uid keys for snapshots, pending count and `userLikes`; suggestions
  drop requested users.
- **Erasure and export.** Both request directions erased with I-R repair and Update only; the set entry removed before
  `users/{uid}`; `follow_request` and `follow_accepted` rows set `actorIds`; the export section has handles and
  timestamps only; other users' exports carry post ids and their own text only.
- **Logs.** Part B lines use hashes or counts; errors go through `logger.RedactErr`; no raw uids or text found.
- **Client.** `author_protected` replaces every tab of the cached feed; `is_private=false` draws nothing; the optimistic
  REQUESTED label comes only from `Profile.is_private`; the PROTECTED embed shows the author only.

## Not performed
- The tester's W3-35 authz, budget and race matrix (in progress when this review ran).
- No tests, `govulncheck` or `osv-scanner` runs. Part B adds no Go dependency that was seen (not verified against go.mod).
- Cloud state: the `privacy.uids` fieldOverride READY, the dev flag value, the current dev `last-good` revision (needed
  for M-1(c)).
- **W3-34** at its PR head: Accept and Decline reachable for a protected caller while the flag is globally off; the badge
  only from `pending_follow_request_count`; the `follow_request` push routes to `/follow-requests` and `follow_accepted` to
  the actor's profile; the requests list cleared in `clearSession`; "Follow back" uses the Respond response;
  FEATURE_DISABLED hides the drawer entry with the 10-minute backoff.

SECURITY: CLEAR WITH FIXES
