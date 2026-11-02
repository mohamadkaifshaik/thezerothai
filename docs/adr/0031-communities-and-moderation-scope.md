# 0031. Communities and their moderation scope at Stage 0 (W5 Part B)
Status: Accepted (founder, 2026-11-01, by merging #583; F1 and F6 to F14 at the defaults)
Date: 2026-11-01
Deciders: architect (proposal); the founder accepts by merging the PR. The Part B founder questions (F1, F6 to F13 of
the plan, and the new F14 below) were taken at their defaults when the founder merged #583 on 2026-11-01. **Each one has a recommended default, which this ADR applies,
and the founder may override any of them at acceptance** (table "Founder decisions"). The architect's own calls (table
"Architect's calls") can be overridden the same way. No default bends a `CLAUDE.md` non-negotiable rule, adds a fixed
cost or changes a founder-gated file.

Plan: `docs/plans/ui-w5-lists-communities.md`, Part B, ticket W5-20 (this ADR). It gates W5-21 to W5-40. The plan asked
for "ADR-0028 (or the next free number)". 0028 went to W4 and 0030 to Part A, so this is **0031**.

Related ADRs:
- ADR-0002: modules talk only through Go interfaces. ADR-0003: data model, Snowflake ids, idempotency documents.
- ADR-0004 and ADR-0010: pull-on-read; D5 (per-uid read budget, `ReadBudgetMaxCallReads` 269); D6 (feed filtering);
  D9 (text rules); D13 and D14 (sealed, bound, settle-windowed tokens); D18 (19-digit ids: id order is time order).
- ADR-0005 and ADR-0016: report-driven platform moderation, `opsctl`, `posts.moderation`, `Hidden()` and `Visible()`,
  the D10 `removed_ids` contract.
- ADR-0008: D2 (`blockedBy` overflow fails closed), D6 (flags are env vars), D9 (block semantics, no block oracle).
- ADR-0011: the T11 lifecycle guard, eraser steps, export sections.
- ADR-0021: an inherited reply restriction and `viewer_reply_permission` (UNKNOWN when it would need a read).
- ADR-0025: protected authors, `posts.Audience`.
- ADR-0027: the `_deleted` uid marker in rewritten records.
- ADR-0029: the composer (drafts keep the audience).
- **ADR-0030 (lists):** the patterns reused here: the idempotency document on every mutation (D7), one byte-identical
  NOT_FOUND, export redaction (`lists_member_of`), the eraser shape, the `opsctl lists hide` lever and the LIST report
  target (W5-44).
- ADR-0022: credit mode. **Nothing here depends on a credit-mode item.**

## Context
X's Communities let people who do not follow each other talk about one interest in one place, under rules that the
community's own moderators enforce. `docs/plans/roadmap.md` lists W5 as "Lists and Communities" and calls out the
missing piece: a **moderation story for communities**. This ADR is that story, plus the smallest data model and feed
that match X's core.

The Stage 0 constraints come from `CLAUDE.md`:
- pull-on-read with a `since` cursor and no write fan-out (rule 2);
- `FieldValue.Increment` counters (rule 3);
- idempotency on every mutation (rule 4);
- opaque cursors and a `Limit` on every query (rule 5);
- a documented worst-case read count per RPC (rule 6);
- a right-to-delete path for every collection (rule 10);
- caps as config (rule 11);
- no fixed cost.

The X captures (`docs/x_research/screens/communities.md`, desktop MEASURED; `mobile/screens.md` §6, OBSERVED) show:
- an Explore page with category chips;
- posts carrying a **community label row** (a people icon and the community name over the avatar column), whose
  accessible name starts with the community name;
- a "My Communities" region.

Not captured: the community page, joining, moderator tools and creation. Those follow X-like defaults, as the plan says.

**Cost baseline** (`docs/reviews/cost-model.md` §3 and §5, the 2026-10-31 W5 Part A block, all flags on):
- per DAU per day: 385.4 reads, 41.34 writes and 9.11 deletes;
- per DAU-month: 1,875 Cloud Run requests and 187.5 vCPU-s;
- free reads run out at about **130 DAU**, writes at about 484, deletes at about 2,194, vCPU-s at about 960 and
  requests at about 1,067 DAU;
- the Stage 0 bill is about **INR 552 / 1,847 / 4,992** a month at 300 / 1,000 / 3,000 DAU.

**What changed against the plan, one line each with its reason.** Each Part B ticket this changes (W5-21 to W5-29,
W5-34, W5-39 and W5-40) carries an "ADR-0031 changes" note in the plan, added in this PR. Where a ticket's text and this
ADR differ, the ADR wins.
1. **A1 is proven on the dev Firestore** (D3, run 2026-11-01 04:34 UTC): the community feed runs on the automatic
   single-field index in all three of the plan's forms, so **no index-file change**. `posts.Reader.ByCommunity` must not
   reuse `FirestoreRepo.run()`: that helper orders `createdAt DESC, __name__ DESC`, which is exactly the shape the dev
   check proved needs a composite index.
2. **A hide removes the post from the community's query** instead of filtering a flag at read time (D5, A12). Under a
   raid of hidden posts, the plan's filter would read and throw away every hidden row and serve short or empty pages.
   `communityHidden` stays, but only as the label switch, and **never feeds `Post.Hidden()` or `Visible()`**: those mean
   a platform takedown that drops the post everywhere (ADR-0016 D3).
3. **`modlogged[]` covers targets as well as actors** (D2, I-L). Take a member who is banned, then unbanned (the member
   doc is deleted and the community leaves `banned[]`), then deletes the account. The modlog still names them as a
   target, and the plan's actor-only set misses it.
4. **The member document stores a state, not a role.** It is `JOINED` with `joinedAt`, or `BANNED` with `bannedAt`.
   OWNER and MODERATOR come from the community doc only, so the two never disagree. W5-25b's "`role == BANNED`"
   equality plus an order on another field is a composite-index shape (dev control C2 in D3 failed with "requires an
   index"). The members page orders by `joinedAt` and the banned page by `bannedAt`: **field presence is the filter**,
   which the dev check proved on the automatic index.
5. **Every mutation stores the standard idempotency document** (ADR-0030 D7). The plan gave a key to CreateCommunity
   only. That covers all seven mutations: CreateCommunity, UpdateCommunity, JoinCommunity, LeaveCommunity,
   HideCommunityPost, RestoreCommunityPost and SetMemberRole.
6. **CreateCommunity has no daily quota.** The owned cap of 2 is exact and lifetime (there is no delete), so the
   `quotas` read and write are dropped: 3 reads and 4 writes, not 5 and 5.
7. **GetCommunityTimeline reads the viewer's member doc.** It returns `viewer_role` and decides the members-only reply
   permission on every row at +0. The cost is +1 read: 25 and 55 at pages 20 and 50, not 24 and 54.
8. **Removals truncation uses a floor field, `removalsTruncatedAt`.** A restore deletes its entry, so the plan's test
   ("a token older than the oldest entry while the array is full") gives a wrong answer after a restore.
9. **No new `ReplyPermission` value** (A7). An older client reads an unknown enum value as 0, UNSPECIFIED, which means
   "allowed". It would show a reply box that the server refuses. `NOT_ALLOWED` on a post that carries `community` is
   unambiguous, because community posts take no reply policy (D5).
10. **Replies inherit the community** in a new `conversationCommunityId` field (D5). The plan read the root's
    `communityId`, but a reply to a reply does not read the root (ADR-0021 D2 keeps unrestricted conversations at +0),
    and a hidden root no longer carries `communityId`.
11. **Protected accounts can join and read but cannot post into a community** (F6). A community post is public by
    definition; a protected author's post would be dropped for most of the community by ADR-0025.
12. **New founder question F14: moderators and blocks** (D7). If a member's block of a moderator also hides that
    member from the moderator, a raider who blocks the owner and every moderator becomes impossible to moderate.
13. **BAN accepts a non-member**, so a moderator can ban a raider who already left. UNBAN deletes the record.
14. **The Join transaction never reads the community doc.** It increments `memberCount` blindly, so a join burst
    does not abort concurrent joins on a read lock (D2, hot doc).
15. **Caches are sized for Stage 0**, where at most 20 communities exist (10 creators × 2): `CACHE_COMMUNITIES_ENTRIES`
    200 (plan 2,000; a community doc can reach about 50 KB) and `CACHE_COMMUNITY_FEED_ENTRIES` 100 (plan 500).
16. **ListModerationLog is paged** (at most 25 entries a page, with a sequence cursor), so a page hydrates at most 50
    profiles.
17. **Re-priced on the W5 Part A baseline:** about **20.3 reads per DAU** (the plan said 16.0) and **INR 6 / 36 / 114**
    (the plan said 6 / 22 / 114).
    - Reads are higher because the open is priced all-cold (Part A's measured lesson), the directory at 22 reads an
      open, and the timeline gained the `viewer_role` read.
    - The 1,000 DAU column is higher because the product now passes the free vCPU-s at about 960 DAU, so Part B's
      Cloud Run line is fully billed there.
18. **The skill rows ship in this PR, as the ticket asks** (unlike ADR-0030, which left them as follow-ups): a
    "Communities" section in the `stage-ladder` skill (with the "Community feed" and "Community moderation" rows), and
    the `firestore-data-model` rows, including the `quotas` fields `communityJoins` and `communityPosts`. `.claude/` is
    code-owned by the founder, so the founder reviews them with this ADR.
19. **The dev ceiling is allowlist 3**, the plan's Flags table and the LISTS precedent (#546). W5-22's "6" is
    corrected.
20. **Error reasons added:** FORBIDDEN `reason=not_owner`; FAILED_PRECONDITION `reason=owner` (the owner leaving),
    `reason=moderator` (the owner banning a moderator: remove the role first), `reason=community_archived`, and
    `PROTECTED_ACCOUNT`. These join the plan's `banned`, `not_member` and `not_moderator`.
21. **A new opsctl lever, `community archive`** (D14). An owner cannot leave, and an owner by hand-over (F12) never
    chose the role, so support needs a way to retire a community on the owner's request.
22. **The shared feed entry's fills read at most the request's page size** (D6). Filling the plan's 30-post entry on a
    cold or stale page-20 open reads 30 posts. That is 35 reads with item 7's member doc, not 25 (the plan priced 24).
    Bounding each fill by `page_size` keeps the worst at page + 5 (25 and 55).

## Founder decisions (Part B)
INR are per month, the Part B increment over the `docs/reviews/cost-model.md` §5 baseline above, priced at the margin
with `cost-model.md` §7 prices (Cost impact), at 300 / 1,000 / 3,000 DAU. "Default" = applied by this ADR; **the
founder may override at acceptance.**

| # | Question | Options | Decision | INR 300 / 1,000 / 3,000 |
|---|---|---|---|---|
| F1 | Who may create a community | (a) a `COMMUNITY_CREATORS` config list (≤ 10 uids, a Terraform variable like `SUGGESTED_USER_IDS`), at most 2 owned each; (b) a third flag `FEATURE_COMMUNITY_CREATE` (a founder-gated ceiling row); (c) open creation with an account-age gate and a quota | **(a), default.** CreateCommunity checks the list first (FORBIDDEN, 0 reads beyond the interceptor); clients learn it from `ListMyCommunitiesResponse.can_create` (0 reads). Open creation is a later decision with its own security review (Stage ladder) | (a) and (b): 0 / 0 / 0. (c): reads about 0, but moderation load lands on the founders (no INR line; the cost is time) |
| F6 | Visibility | (a) public only; (b) restricted or private communities | **(a), default.** Any signed-in user reads a community; members post. Community posts are ordinary public posts. **A protected account can join and read but cannot post into a community** (FAILED_PRECONDITION `PROTECTED_ACCOUNT`, 0 reads). An account that becomes protected later keeps its old community posts under ADR-0025 (dropped for viewers it has not approved). The `visibility` enum holds PUBLIC only | (a): in the totals. (b): a members-only filter on every read path that can show a community post, about +2 reads per DAU: **+0.6 / +2.0 / +6.1** plus a visibility-matrix review like ADR-0025 |
| F7 | Community posts outside the community | (a) also on the author's profile and in followers' Home, with the label; (b) community-only | **(a), default.** Home and profile queries are unchanged and nothing is read only to be thrown away | (a): 0. (b): Firestore cannot query for a missing field, so Home and profile need a new flag field and composite indexes, and they read and drop rows: about +3 reads per DAU, **+0.9 / +3.0 / +9.1**, plus founder-gated index changes |
| F8 | Replies to community posts | (a) members only (X); (b) anyone | **(a), default.** Non-members can still read, like, repost, quote and bookmark. Community posts take no reply policy of their own (`reply_policy` other than EVERYONE is VALIDATION) | (a): +0.05 reads per DAU, **≈ 0 / 0.05 / 0.15**. (b): 0 |
| F9 | Moderator powers | (a) the plan's scope (D4): hide and restore in the community view, ban and unban, the owner appoints moderators (≤ 10) and edits the text; never delete, never act outside the community, never see reports; (b) platform-only moderation; (c) moderators with platform takedown power | **(a), default.** A ban does not hide the member's earlier posts (moderators hide them one by one, within the action cap). Every action is in the moderation log (newest 100) | (a): about 0.03 reads and 0.02 writes per DAU, **≈ 0 / 0.1 / 0.3**. (b) and (c): 0 in Firestore; (b) moves all load to the founders; (c) is refused (abuse) |
| F10 | Discovery | (a) a directory sorted by member count (top 50); (b) categories or chips (curation); (c) community search (needs the W4 engine) | **(a), default.** No chips, no search | (a): 2.2 reads per DAU, in the totals (**0.7 / 2.2 / 6.7**). (b): 0 in Firestore, curation time. (c): W4's own line |
| F11 | Caps | the plan's numbers, or tighter or looser | **The plan's numbers, default** (D11): joined ≤ 50, owned ≤ 2, joins 20 a day (new accounts 5), community posts 50 a day (new accounts 10) on top of posts 100, 20 posts per community per uid per day (in memory, × 3), rules ≤ 10, name ≤ 30, description ≤ 160 | 0 / 0 / 0 (config). They bound the abuse cost (Cost impact) |
| F12 | The owner deletes their account | (a) hand over to the longest-serving ACTIVE moderator, else archive (read-only, out of the directory, `ownerId` cleared); (b) always archive; (c) on archive, also clear the description and rules | **(a), default, keeping the text.** The name, description and rules are the community's shared context. Once `ownerId` is cleared they no longer link to the deleted user, and the owner's export already holds them. A live owner cannot leave or transfer (out of scope). An owner by hand-over is in the same position, so on an owner's request support runs `opsctl community archive` (D14) | 0 / 0 / 0 (about 5 reads per owned community, once, at erasure) |
| F13 | Images | (a) none, a default tile; (b) a community banner (W3's banner media kind) | **(a), default.** 0 Vision units | (a): 0. (b): about 2 Vision units per community, once, plus banner views on community pages: **0 / 0 / ≈ 18** (GCS egress past the free pool at 3,000 DAU) |
| **F14 (new)** | Blocks and moderators | (a) **a block never hides a member from that community's moderators:** on the community's own feed and member page, the owner and moderators see rows of members who block them; everywhere else ADR-0008 D9 holds; (b) the block wins everywhere | **(a), default.** Without it, a raider who blocks the owner and the ≤ 10 moderators (11 blocks, inside the blocks quota) is invisible to all of them, and only member reports to the platform remain. **Residual:** a moderator can infer that a member who posts in their community blocks them, because the member's profile answers NOT_FOUND (the D9 oracle, limited to that community's own surfaces). The member can see who moderates (About lists the owner and moderators to everyone) before posting. Under (b) the residual is "an unmoderatable raider" | 0 / 0 / 0 |

## Architect's calls (Part B; the founder may override)
| # | Call | Decision (section) |
|---|---|---|
| A1 | The feed query | `posts where communityId == X ORDER BY __name__ DESC`, windows as document-id bounds, on the automatic single-field index, **proven on dev** (D3). No index-file change |
| A2 | The posting gate | `posts.CommunityGate`, consumer-side in posts and implemented by communities, inside CreatePost's transaction: member doc fresh, community status from the 60 s cache, `communityPosts` quota in the existing quota write (D5) |
| A3 | Removals in cached feeds | `recentRemovals` (≤ 50) plus `removalsTruncatedAt` on the community doc become `removed_ids` at 0 extra reads; moderator hides, platform takedowns and suspensions append (D6, D14) |
| A6 | Memberships | `communities/{cid}/communityMembers/{uid}` plus `communityMemberships/{uid}`; I-M and I-L (D2) |
| A7 | Members-only reply permission | no new enum value; `NOT_ALLOWED` on a post that carries `community` (D5) |
| A8 | Owner deletion | inside the `communities` eraser step, one transaction per community, resumable and idempotent (D9) |
| A9 | Caches | D12 |
| A12 | How a hide works | delete `communityId` (the post leaves the query), set `communityHidden` (the label goes); restore reverses both (D5) |
| A13 | Idempotency | the standard document on all seven mutations (D8) |
| A14 | Dev ceiling | allowlist 3 (D10) |

## Options
### A. Where membership lives (plan A6)
- **(a) A member subcollection plus a per-user memberships doc (chosen).**
  - `communities/{cid}/communityMembers/{uid}` pages the member list, ordered by `joinedAt` on the automatic index.
  - `communityMemberships/{uid}` answers "my communities", the caps and the eraser in 1 read.
  - No index file, no collection-group query.
- (b) A `memberIds[]` array on the community doc (the lists pattern):
  - a community has no 150 cap, and an array of thousands of uids nears the 1 MiB doc limit;
  - every join becomes a read-modify-write of the hottest doc;
  - every feed read would carry the whole member list.
- (c) The subcollection only: "my communities" and the eraser need a collection-group query on `uid`, which needs a
  COLLECTION_GROUP fieldOverride (founder-gated) and pays one read per membership on every ListMyCommunities.
- (d) Top-level edges `communityMembers/{cid}_{uid}` (the `follows` pattern): the member page `cid == X ORDER BY
  joinedAt` needs a composite index.

### B. How the community feed is built
- **(a) `communityId == X` ordered by document id, plus a shared per-instance entry (chosen).** It runs on the
  automatic index (D3). A refresh costs 1 + new posts. The entry is shared by every viewer of the community on an
  instance and refilled incrementally.
- (b) The same query ordered by `createdAt DESC, __name__ DESC`: the same reads, but a composite index in a
  founder-gated file. It is the fallback only if a later Firestore change breaks (a).
- (c) A pull-merge over the members (the list timeline): members are unbounded, so the chunk count is unbounded.
- (d) Write fan-out into a per-community feed document: breaks rule 2.

### C. Moderation scope
- **(a) The owner and up to 10 appointed moderators, with community-view powers only; the platform overrides (chosen).**
  Communities moderate themselves; a rogue moderator cannot touch a post outside the community.
- (b) Platform-only (opsctl): every community's spam lands on the founders, and the report-driven SLA (ADR-0016 D5)
  becomes the community's.
- (c) Moderators with takedown power: a moderator could remove a post from the author's profile and from Home. Refused.

### D. How a hide works (A12)
- **(a) Delete `communityId` and set `communityHidden` (chosen).** The post leaves the community query: no wasted
  reads, no short pages. The label goes. Restore puts `communityId` back from the `community` snapshot.
- (b) A `communityHidden` flag filtered at read time (the plan): each hidden post costs a read on every cold open and
  shortens pages, which is worst exactly during a raid.
- (c) Delete the post: beyond F9, which leaves the post on the author's profile and in Home.

### E. Removals for cached feeds (A3)
- **(a) A capped `recentRemovals` array plus `removalsTruncatedAt` on the community doc (chosen).** The doc is read on
  every feed call anyway, so this is 0 extra reads.
- (b) The ADR-0016 `postRemovals` log: its window query is per author (≤ 180 authors), and a community's author set is
  unbounded. A per-community window query would need a new composite index.
- (c) None: a hidden post stays on every device that holds it, until a cold open.

### F. Idempotency (A13)
- **(a) The standard idempotency document on every mutation (chosen):** rule 4 as written, as ADR-0030 D7.
- (b) "State-setting, replay 0 writes" (the plan's sketch): a late retry of a hide after a restore re-hides the post.
  That is a **rule-4 bend** the founder would have to accept, for a saving under INR 1 a month.

## Decision
### D1. Module and seams
A new **`communities` module** (`backend/internal/communities`) owns `communities/{cid}`,
`communities/{cid}/communityMembers/{uid}`, `communityMemberships/{uid}` and `dzeroth.communities.v1.CommunityService`.
No other module touches these collections.

**Seams.** Each one is a Go interface, so a later store changes no caller.

| Interface | Kind | Contract |
|---|---|---|
| `communities.Service` | owned by communities | The `CommunityService` RPC surface behind the Connect handler: CreateCommunity, UpdateCommunity, GetCommunity, ListCommunities, ListMyCommunities, JoinCommunity, LeaveCommunity and ListCommunityMembers. The moderation RPCs delegate to `communities.Moderation`. The handler holds only this interface, so a split into its own Cloud Run service changes no caller. |
| `communities.Reader` | owned by communities | `Get(ctx, cid)`: cache-first community view (status, header, `ownerId`, `moderatorIds`, `recentRemovals`, `removalsTruncatedAt`), NOT_FOUND as one sentinel. `Role(ctx, cid, uid)`: the viewer's role (D4) from the cached member doc plus the community doc. `Memberships(ctx, uid)`. |
| `communities.Moderation` | owned by communities | Hide, Restore, SetMemberRole, ListModerationLog. The capped arrays sit behind it, so a later `modlog` collection changes no caller. |
| `communities.Directory` | owned by communities | The top 50 by member count. The W4 engine can replace it later. |
| `communities.PlatformRemovals` | owned by communities | `Append(ctx, cid, postID, at)`, for opsctl only (D14). |
| `communities.Events` | owned by communities | The emitter seam (D15); a no-op at Stage 0. |
| `communities.Eraser`, `communities.Exporter` | owned by communities | Wired through identity's lifecycle adapters (D9). |
| `posts.CommunityGate` | consumer-side, declared in posts, implemented by communities | `CheckPost(ctx, tx, uid, cid) (CommunityRef, error)`: inside CreatePost's transaction (A2). `CanReply(ctx, uid, cid) error`: cache-first (F8). |
| `posts.Reader.ByCommunity(ctx, cid, window, limit)` | owned by posts | The A1 query, its own code path, never `run()` (D3). |
| `posts.CommunityModerator` | owned by posts, called by communities inside its moderation transaction | `SetCommunityListing(ctx, tx, postID, cid, listed bool)`: the hide and restore writes (A12). |

**Who imports whom.** There is no cycle:
- communities imports `posts`, for the two posts-side interfaces;
- communities imports `identity` (`Directory`) and `graph` (`Reader`);
- posts never imports communities;
- `timeline` gains `communities.Reader`;
- `moderation` reaches communities only through `communities.Reader`;
- opsctl wires `communities.PlatformRemovals`.

A gate that reads another module's document inside the caller's transaction has a precedent: `identity.TxProfiles`
inside the lists transaction (ADR-0030 L-4).

### D2. Data model
**`communities/{cid}`** (cid is a 19-digit Snowflake, rule 1):

| Field | Type | Notes |
|---|---|---|
| `name` | string | 1-30 code points after NFC and trim. Single-line rules: `identity.singleLineIssue` (ADR-0030 L-2) |
| `description` | string | 0-160 code points, the bio rules (ADR-0010 D9) |
| `rules` | array of `{title, text}` | ≤ 10. Title 1-60 code points (single-line rules); text 0-300 (bio rules) |
| `ownerId` | uid, or `""` | `""` only when ARCHIVED with no successor (F12) |
| `moderatorIds` | array of uid | ≤ 10, in appointment order, so the first is the longest-serving. Never holds the owner |
| `memberCount` | int | `Increment` (rule 3). Counts JOINED members, including the owner and moderators; never BANNED |
| `status` | `ACTIVE` / `ARCHIVED` / `SUSPENDED` | SUSPENDED only by opsctl (D14) |
| `visibility` | `PUBLIC` | the only accepted value (F6); the seam for restricted communities |
| `recentRemovals` | array of `{postId, at}` | ≤ 50, newest kept. Moderator hides and platform removals (A3). A restore deletes its entry |
| `removalsTruncatedAt` | timestamp, absent = never | the `at` of the newest entry the cap ever dropped |
| `modlog` | array of `{seq, at, actor, action, target, postId}` | ≤ 100, newest kept. `actor` is a uid or `_deleted`. `target` is a uid (role changes and bans only) or `_deleted`. `postId` is set for hides and restores, and the author's uid is never stored. `action` is one of `HIDE`, `RESTORE`, `BAN`, `UNBAN`, `MAKE_MODERATOR`, `REMOVE_MODERATOR`, `EDIT`, `MODERATOR_LEFT`, `OWNER_HANDOVER` |
| `modlogSeq` | int | the last `seq` written; it is the modlog page cursor |
| `createdAt`, `updatedAt` | timestamp | |

- **Size.** About 20 KB typical; at most about 53 KB, with ten 300-code-point rules and 100 modlog entries naming
  128-character uids. That is far under 1 MiB. Index entries are about 200, far under 40,000. No fieldOverride is
  required; exempting `modlog`, `recentRemovals`, `rules` and `description` is optional (FU-5, founder-gated).
- **Hot doc.** The doc is written by joins and leaves (blind `Increment`, never read in the join transaction),
  moderation actions (read-modify-write of the capped arrays), UpdateCommunity and opsctl. Posting never writes it:
  there is no per-community post counter.
  - **Signal:** `community_txn_attempts` and `ABORTED` on the request line of JoinCommunity, LeaveCommunity,
    HideCommunityPost, RestoreCommunityPost, SetMemberRole and UpdateCommunity. A join burst on a viral community can
    abort moderators' transactions, which retry.
  - **Fallback (Stage ladder):** move `memberCount` to 10 shards `communities/{cid}/memberCountShards/{0..9}`, summed
    into the cached view, or to Pub/Sub-batched increments. Either one also takes the joins off the doc the moderators
    write. This is a traffic shape, not a DAU: one viral community breaks rule 3 at any DAU.

**`communities/{cid}/communityMembers/{uid}`**. The subcollection is named `communityMembers`, not `members`: the T11
name scan and the residue sweep key on the collection id, and W7 may want `members`.

| Field | Type | Notes |
|---|---|---|
| `uid` | uid | for the residue sweep |
| `state` | `JOINED` / `BANNED` | never a role: OWNER and MODERATOR come from the community doc |
| `joinedAt` | timestamp | present only while JOINED. **Its presence is the members page's filter** |
| `bannedAt` | timestamp | present only while BANNED. **Its presence is the banned page's filter** |

Moving between states rewrites the doc as a field-level update that sets one timestamp and deletes the other. UNBAN
deletes the doc.

**`communityMemberships/{uid}`** (the per-user index; written only in the same transaction as the member doc or
community doc it mirrors):

| Field | Type | Notes |
|---|---|---|
| `joined` | array of cid | ≤ 50 (F11). Exact: the doc is read in the join transaction |
| `owned` | array of cid | ≤ 2 for creation. A hand-over may exceed it: the cap applies to CreateCommunity only |
| `banned` | array of cid | bounded by the number of communities (≤ 20 at Stage 0). The Stage ladder asks for a cap before creation opens |
| `modlogged` | array of cid | **every community whose modlog has ever named this uid, as actor or target** (I-L). Never shrinks |
| `updatedAt` | timestamp | |

**Invariants** (the tester's oracle; every writer keeps them inside one transaction):
- **I-M.** For a uid U, a community C and C's member doc for U:
  - the doc is `JOINED` ⇔ C ∈ `U.joined`;
  - the doc is `BANNED` ⇔ C ∈ `U.banned`;
  - `C.ownerId == U` ⇔ C ∈ `U.owned`, and then U is JOINED;
  - U ∈ `C.moderatorIds` ⇒ U is JOINED and is not the owner.
- **I-L.** If an entry in C's `modlog` names U (as `actor` or `target`), then C ∈ `U.modlogged`. So the eraser's find
  set, `joined ∪ owned ∪ banned ∪ modlogged`, contains every community that holds U's uid.
- **I-C** (posts). `communityId` is present ⇔ `community` is present ∧ `communityHidden` is absent ∧ the post is a
  root POST or QUOTE. `conversationCommunityId` equals `community.id` on the root, and is inherited by every reply in
  its conversation.

**`posts/{postId}`, additive fields** (no backfill: absent means not a community post):

| Field | Written | Notes |
|---|---|---|
| `communityId` | CreatePost into a community; deleted by a hide, restored by a restore | **the feed query key.** Root POST and QUOTE only; never a REPOST or a reply |
| `community` | CreatePost into a community | a `{id, name}` snapshot, the label. Kept while hidden. The name is a snapshot at post time: a rename does not rewrite old posts. The community's own feed and page show the current name |
| `communityHidden` | hide, removed by restore | absent = false. **The label switch only.** It never feeds `Post.Hidden()` or `Post.Visible()` (ADR-0016 D3). Backend accessors: `Post.CommunityListed()` and `Post.CommunityLabelVisible()` |
| `conversationCommunityId` | the community root; inherited from the parent by every reply | **the members-only reply key** (F8). Fixed at creation; a hide or restore never changes it |

**`quotas/{uid}`** gains `communityJoins` and `communityPosts`. Both are daily, and their `Record` `valueFor` and
`increment` cases ship in the same PR (ADR-0021 I-3, W5-22).

### D3. Queries and indexes (A1, proven on the dev Firestore)
Every query is one of the two shapes the automatic single-field indexes serve:
- (i) one equality, ordered by `__name__` only;
- (ii) an order on one field, with no equality.

Each has a `Limit` of at most 50.

| Use | Query | Shape |
|---|---|---|
| Community feed: page 1, the shared entry's fill | `posts where communityId == C ORDER BY __name__ DESC LIMIT n` | (i) |
| Feed `since` and the entry's incremental refill | the same + `EndBefore(ref)` (or `__name__ > ref`) | (i) |
| Feed older page and gap window | the same + `StartAfter(ref)` (or `__name__ < ref`), with both bounds for a window | (i) |
| Members page | `communities/C/communityMembers ORDER BY joinedAt DESC, __name__ DESC LIMIT n` (+ `StartAfter(ts, ref)`) | (ii) |
| Banned page (moderators) | `communities/C/communityMembers ORDER BY bannedAt DESC, __name__ DESC LIMIT n` | (ii) |
| Directory | `communities ORDER BY memberCount DESC, __name__ DESC LIMIT 50`. Non-ACTIVE rows are filtered in memory (a short list is allowed) | (ii) |
| My communities, caps, the eraser, the export, the moderation log | document gets (`communityMemberships/{uid}`, `GetAll` of community docs, member docs by path, the modlog array) | no query |

**The dev check (the plan's acceptance criterion: who, when, each of the three forms).**
- **Who:** the architect agent (W5-20), using the local `gcloud` user credential (`gcloud auth print-access-token`;
  active project `dzeroth-dev`).
- **When:** 2026-11-01, 04:34:00 to 04:34:09 UTC. Each response's server `readTime` falls in that window.
- **Where:** the real dev Firestore, `projects/dzeroth-dev/databases/(default)`, through the Firestore REST
  `documents:runQuery`. It was not the emulator, and nothing touched prod.
- **Read-only:** no write of any kind, and `limit` 5 on every query.
  - The probe filters `communityId == "w5-20-a1-probe"`. No document carries `communityId` yet, so every match is empty.
  - An empty query still plans against the indexes and returns `[{"readTime": ...}]`. That is at most 13 billed reads.
- **Bounds:** post ids `1000000000000000000` (A) and `9000000000000000000` (B), as document references.
- **The draft's earlier run:** the first draft of this ADR recorded a run at 04:04 to 04:05 UTC the same day, with
  limits 20 to 50. That run was not re-verifiable, so this run, with its raw responses checked, is the record. The two
  agree.

| # | Form (all on `posts`, `communityId == probe`, `ORDER BY __name__ DESC`, `LIMIT 5` unless stated) | Result |
|---|---|---|
| **F1** | **Form 1, page 1**: no bound | **HTTP 200**, 0 documents |
| **F2a** | **Form 2, `since`**: filter `__name__ > A` | **HTTP 200**, 0 documents |
| F2b | Form 2, `since`, cursor variant: `endAt {A, before: true}` = the Go client's `EndBefore(A)` | HTTP 200, 0 documents |
| **F3a** | **Form 3, older page**: filter `__name__ < B` | **HTTP 200**, 0 documents |
| F3b | Form 3, older page, cursor variant: `startAt {B, before: false}` = `StartAfter(B)` | HTTP 200, 0 documents |
| F4 | gap window: both cursors, `StartAfter(B)` and `EndBefore(A)` | HTTP 200, 0 documents |
| F5 | settle sentinel: `endAt {A, before: false}` = an inclusive `EndAt(A)` | HTTP 200, 0 documents |
| **C1 (control)** | `ORDER BY createdAt DESC, __name__ DESC` (the shape of `FirestoreRepo.run()`) | **HTTP 400 FAILED_PRECONDITION "The query requires an index. You can create it here: …"** |
| M1, M2 | under `communities/1000000000000000001`: `communityMembers ORDER BY joinedAt DESC, __name__ DESC`, and the same with `startAt {(timestamp, ref), before: false}` | HTTP 200, 0 documents |
| M3 | the same parent: `communityMembers ORDER BY bannedAt DESC, __name__ DESC` | HTTP 200, 0 documents |
| **C2 (control)** | the same parent: `communityMembers where state == "BANNED" ORDER BY joinedAt DESC, __name__ DESC` (the plan's W5-25b shape) | **HTTP 400 FAILED_PRECONDITION "The query requires an index…"** |
| D1 | `communities ORDER BY memberCount DESC, __name__ DESC` | HTTP 200, 0 documents |

What the check shows:
- **The controls prove that the method detects a missing index on an empty match.** So the passes are not an
  emulator-style "everything runs".
- **Result: all three forms, their cursor variants, the members and banned pages and the directory pass on the
  automatic single-field indexes.**
  - There is no composite index and no fieldOverride.
  - `firebase/firestore.indexes.json` and `field-overrides.ack` are untouched, and **W5-21 adds no index**.
  - This settles Datastore's old rule that "a descending sort on keys needs a composite index": it does not apply here.
- **Re-run before W5-40's flag change, on real data.** W5-40's dev smoke runs F1, F2b, F3b and M1 again with real
  community posts and members. A "requires an index" error at that point means stop and ask the founder. The fallback
  is the composite `posts (communityId ASC, createdAt DESC)` (Option B (b)), a founder-gated change.

**`ByCommunity` contract for backend-developer.**
- Its own query: `Where("communityId", "==", cid).OrderBy(firestore.DocumentID, firestore.Desc)`. Cursors are document
  refs. **Never** `run()`.
- `posts` converts a `Window` position to an id bound. ADR-0010 D18 makes id order equal `(createdAt, id)` order,
  because ids are fixed-width 19-digit strings.
  - `Before{t, id}` becomes `StartAfter(posts/id)`.
  - `After{t, id}` becomes `EndBefore(posts/id)`.
  - The settle watermark `After{W, "0000000000000000000"}` (ADR-0010 D13) becomes **`EndAt(posts/<the smallest
    Snowflake of millisecond W>)`, inclusive**.
- That sentinel case is a required unit test.
- Reads: `len(result)`, minimum 1, charged with `AddQueryReads`. Results fill the posts cache.
- Unfiltered, as every `posts.Reader` method: no visibility, block, mute or audience filtering. The caller drops
  `!Visible()` rows.

### D4. Roles and the moderation scope (F9, F14)
The viewer's role in a community is one of these:
- **OWNER**: `ownerId`.
- **MODERATOR**: in `moderatorIds`.
- **MEMBER**: the member doc is JOINED.
- **BANNED**: the member doc is BANNED.
- **NONE**: anyone else.

It is returned as `viewer_role` by GetCommunity and in GetCommunityTimeline's header. The client never infers a role.

| Action | Owner | Moderator | Member | Banned | Outsider | Platform (opsctl) |
|---|---|---|---|---|---|---|
| Read the community, its feed and members | yes | yes | yes | yes | yes | n/a |
| Join | already a member: 1 write (the idempotency doc, D8) | same | same | FORBIDDEN `banned` | yes (cap, quota) | n/a |
| Leave | FAILED_PRECONDITION `owner` | yes (leaves `moderatorIds`, logged `MODERATOR_LEFT`) | yes | not a member: 1 write (the idempotency doc) | same | n/a |
| Post into the community (root, quote) | yes | yes | yes | FORBIDDEN `banned` | FORBIDDEN `not_member` | n/a |
| Reply in a community conversation | yes | yes | yes | FORBIDDEN `not_member` | FORBIDDEN `not_member` | n/a |
| Hide or restore a post in this community's view | yes | yes | FORBIDDEN `not_moderator` | same | same | takedown-post (everywhere; ADR-0016) |
| Ban or unban a plain member or a non-member | yes | yes | FORBIDDEN `not_moderator` | same | same | suspend-user (everywhere) |
| Ban a moderator | FAILED_PRECONDITION `moderator` (remove the role first) | FORBIDDEN `not_owner` | FORBIDDEN `not_moderator` | same | same | — |
| Ban the owner | VALIDATION `target` (themselves) | FORBIDDEN `not_owner` | FORBIDDEN `not_moderator` | same | same | — |
| Make or remove a moderator (≤ 10, target JOINED) | yes | FORBIDDEN `not_owner` | same | same | same | — |
| Edit the name, description or rules | yes | FORBIDDEN `not_owner` | same | same | same | — |
| Read the moderation log | yes | yes | FORBIDDEN `not_moderator` | same | same | the community doc |
| See reports | no | no | no | no | no | yes (`opsctl reports`) |
| Delete a post, or act outside the community | no | no | no | no | no | yes |
| Suspend, restore or archive the community | no | no | no | no | no | yes (D14) |

- **What a hide is:** the post leaves the community's feed and loses its label (A12). It stays on the author's profile,
  in Home and in search, with its thread, likes and reposts unchanged. It is never `Hidden()`.
- **What a ban is:**
  - the member doc becomes BANNED;
  - the community moves from `joined` to `banned`;
  - `memberCount` drops by 1 if the member was JOINED.

  A ban never hides earlier posts. A banned user cannot join, post or reply into that community, and can still read it.
- **Limits:**
  - `COMMUNITY_MOD_ACTIONS_PER_DAY` (200 per actor per instance, 600 effective) covers hide, restore and every
    SetMemberRole.
  - Every action writes one modlog entry and one log line (D13).
  - The owner removes a rogue moderator; the platform suspends a rogue owner's community.
- **What platform moderation overrides:**
  - `takedown-post` and `suspend-user` hide posts everywhere, community posts included, whatever a moderator did.
  - `community suspend` takes the whole community offline (NOT_FOUND to everyone but the owner; posting, joining and
    replying refused).
  - The COMMUNITY and POST report targets go to the platform only. Moderators never see reports.

### D5. Posting, replies and the label (F6, F7, F8, A2, A7, A12)
**Posting.** `CreatePostRequest.community_id` is accepted on a root post or a quote:
- with `posts` and `communities` on for the caller;
- not with a reply (VALIDATION `community_id`; replies follow the root);
- not with a `reply_policy` other than EVERYONE (VALIDATION `reply_policy`, F8);
- not on SchedulePost (VALIDATION `community_id`).

`posts.CommunityGate.CheckPost` decides in this order:
1. The caller is protected: FAILED_PRECONDITION `PROTECTED_ACCOUNT` (F6). 0 reads: the interceptor's profile is held.
2. The community is missing or SUSPENDED: the one byte-identical NOT_FOUND. ARCHIVED: FAILED_PRECONDITION
   `community_archived`. The status comes from `communities.Reader.Get`, cached 60 s.
3. Inside CreatePost's transaction, the caller's member doc is read **fresh**. Not JOINED: FORBIDDEN `not_member`;
   BANNED: FORBIDDEN `banned`. A ban on another instance stops the next post at once.
4. `quotas.communityPosts` (50 a day, new accounts 10) is reserved in the same quota write as `posts`. Then the
   in-memory `COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY` `DailyCap` keyed `uid|cid` applies.

The post doc gets `communityId`, `community {id, name}` (the cached name) and `conversationCommunityId`, in the
CreatePost write: +0 writes.

**Replies (F8).** On the reply path, the parent is already read, so `conversationCommunityId` is known at +0.
- When it is set and `communities` is not globally off, `CanReply` checks:
  - community status: SUSPENDED is NOT_FOUND, ARCHIVED is `community_archived`;
  - the caller's member doc (cache 60 s): not JOINED is FORBIDDEN `not_member`.
- A ban reaches the reply path of other instances within 60 s.
- Cost: +2 cold, +0 warm.
- The existing reply rules (blocks either way NOT_FOUND, ADR-0021 policies) apply first and are unchanged.

**`viewer_reply_permission` (A7, no new enum value).** For a post whose conversation carries `conversationCommunityId`:
- **GetCommunityTimeline:** `ALLOWED` or `NOT_ALLOWED` from the viewer's role, already read (+0).
- **GetPost and GetThread:** +1 cold (the member doc) and +0 warm (ADR-0021 D2 precedent).
- **Home, profile, list and search timelines:** `UNKNOWN` (+0). The client shows the composer and CreatePost decides.

The client words `NOT_ALLOWED` on a post carrying `community` as "Only members of <name> can reply". For a hidden
root, which has no label, it says "You can't reply to this conversation".

**The label (`ToView`).** `Post.community` is set on the wire only when all three hold:
- the post carries `community`;
- `communityHidden` is absent;
- `communities` is not globally off (`Registry.GloballyOff`, 0 reads).

With the flag globally off, community posts behave as ordinary posts: no label, no reply gate. That is the kill switch.
A REPOST shows "reposted" and never the community label (W5-33). Embedded snapshots carry no label at Stage 0.

**Hide and restore (A12).** Both run through `posts.CommunityModerator.SetCommunityListing` inside the moderation
transaction, which reads the post fresh.
- **Hide:** a field-level update that deletes `communityId` and sets `communityHidden`.
- **Restore:** a field-level update that sets `communityId = community.id` and deletes `communityHidden`.
- The post must carry `community.id == cid`, else NOT_FOUND.
- A hide of a hidden post, or a restore of a listed one, writes only the idempotency document.

### D6. The community feed (`TimelineService.GetCommunityTimeline`)
In a new `backend/internal/timeline/service_community.go`:
1. `communities.Reader.Get(cid)`. Missing or SUSPENDED is NOT_FOUND for everyone, at ≤ 2 reads. ARCHIVED is
   readable.
2. `communities.Reader.Role(cid, viewer)` gives `viewer_role` for the header and row reply permissions.
3. Rows come from the **shared community entry**, then `posts.Reader.ByCommunity` for anything the entry does not
   cover.
4. `keep` drops:
   - every `!Visible()` row;
   - every row whose id is in the current `recentRemovals`;
   - rows by authors the viewer blocks or mutes, or who block the viewer (`allowedAuthor`, ADR-0010 D6), **except**
     that for an OWNER or MODERATOR viewer the "blocks the viewer" drop is waived (F14);
   - rows `posts.Audience` refuses (SurfaceList; protected authors not approved).

   A viewer whose `blockedBy` overflowed keeps only their own and followed authors (the W4 fail-closed rule), unless
   they moderate the community. The protected-set refresh is detached (`protected_set_reads`, +0 to the caller), and
   ADR-0025 D3's fail-closed rule applies.
5. `toViews`, then tokens bound to `tl|community|<uid>|<cid>|since` and `...|page`. A Home, user or list token on a
   community, or a community token on another community or for another caller, is VALIDATION with 0 reads. The
   community feed has the same 30-day TTL, settle window, gap token and `next_page_token` rule as Home: the token
   follows the query, not the filtered count.

**The shared community entry** (one per community per instance, `cache.LRU`, `CACHE_COMMUNITY_FEED_ENTRIES` 100):
- **Contents:** the newest ≤ 30 posts by id, with `loadedAt` and `newestId`. It is shared by every viewer and filtered
  per viewer after the cache, like Home's author-recent entries.
- **Every fill reads at most the request's page size, n** (1 to 50), so a call never reads more post rows than it
  could return:
  - **Cold fill:** with no entry, the call runs `ByCommunity(none, n)`. The entry keeps the newest ≤ 30 rows.
  - **Refill:** when the entry is older than `CACHE_TTL` (60 s), it refills **incrementally** with
    `ByCommunity(After = newestId, n)`, which costs 1 + new posts. If n come back, the rows in between are unknown, so
    the entry is replaced by those n rows (newest ≤ 30 kept) and the page is served from them.
  - **Older rows:** a page that needs rows below the entry reads them with `ByCommunity(Before = the entry's oldest,
    n − served)`.
  - **Bound:** the post reads per call are at most n (at least 1 for an empty query). The worst call is n + 5:
    25 at page 20 and 55 at page 50.
- **Charging:** the refill is charged to the request that triggers it.
- **Settle watermark:** W = min(request start, `loadedAt`) − `TIMELINE_SETTLE_WINDOW` (ADR-0010 D13).
- **Eviction:** a hide, restore or new post on this instance updates the entry at once. Other instances learn a hide
  through `recentRemovals` (the community doc is cached ≤ 60 s) and a new post at the next refill.

**`removed_ids` (A3, gated by `communities`, not by `removed_ids`):**
- On a `since` refresh, `removed_ids` = the `recentRemovals` entries with `at` newer than the token's cutoff. That is 0
  extra reads: the doc is already held.
- If `removalsTruncatedAt` is newer than the cutoff, the token is rejected exactly as an expired token is (ADR-0016 D10
  contract), and the client cold-opens.
- A restore deletes its entry, so it is never listed. A device that dropped the card gets it back at the next cold open,
  as with `restore-post` on Home.
- The author's own DeletePost is not listed, as on Home.

**Home tabs (W5-27, ADR-0030 D6).**
- SetHomeTabs accepts a COMMUNITY tab for any ACTIVE or ARCHIVED community. Membership is not required, because
  communities are public. A missing or SUSPENDED community is VALIDATION `tabs`.
- Each new tab costs +1 read, through the community cache.
- `title` is always `""`; the client labels the tab from the timeline header.
- GetMe omits COMMUNITY tabs while `communities` is off for the caller, and keeps them in storage.
- Leaving a community does not unpin it.

### D7. Blocks and private accounts in a community (F14, ADR-0008 D9, ADR-0025)
A = the caller. "A blocks B" and "B blocks A" are as in ADR-0008 D9. NOT_FOUND is byte-identical to a missing post or
user.

| Situation | Outcome | Why |
|---|---|---|
| Feed rows by B, A blocks B or B blocks A or A mutes B (A not a moderator of this community) | dropped for A | Home's `allowedAuthor` |
| Same, A is the community's OWNER or a MODERATOR | B's rows are **kept** when B blocks A (F14); A's own blocks and mutes still drop | moderation must see raiders |
| Members page row of B, B blocks A or A blocks B (A not a moderator) | dropped; a muted B is shown (mute is silent) | D9's user-list rule |
| Same, A moderates the community | B is shown either way, so A can ban | F14 |
| GetCommunity's owner and moderators list | **every role holder is shown to every viewer**, with the usual relationship fields | knowing who moderates is part of the rules (F14), and dropping a role holder would itself be a block oracle |
| A joins a community whose owner or a moderator blocks A, or whom A blocks | allowed | refusing would be a block oracle (D9) |
| A posts into such a community | allowed; moderators can hide and ban | same |
| A replies to a community root whose author blocks A, or whom A blocks | NOT_FOUND (the existing reply rule) | unchanged |
| A (moderator) hides, restores or bans B, B blocks A | allowed | moderation is a community function (F14) |
| A reports a community whose owner blocks A | allowed (the community is public) | no oracle |
| A is protected and posts into a community | FAILED_PRECONDITION `PROTECTED_ACCOUNT` | F6 |
| B is protected (became so after posting) | B's community rows follow `posts.Audience` (SurfaceList): kept only for viewers B approved; moderators do not see through protection | ADR-0025 is a privacy choice by the author, not a block aimed at one person |

The two D9 residuals F14 creates: (1) a moderator can infer that a member who posts in their community blocks them,
because the member's profile is NOT_FOUND to them; (2) a member who blocked a moderator still has their community posts
seen by that moderator. Both are confined to that community's own feed and member page, and the member can see the
moderators before posting.

### D8. Idempotency (rule 4, A13)
All seven mutations take `idempotency_key` and store the standard `idempotency/{sha256(uid|rpc|key)}` document
(`pkg/platform/idempotency`, 24 h TTL) in the same transaction as their effect:
- CreateCommunity, UpdateCommunity;
- JoinCommunity, LeaveCommunity;
- HideCommunityPost, RestoreCommunityPost;
- SetMemberRole.

How replays and edge cases behave:
- **Replay:** returns the stored outcome with 0 writes. The record holds ids only; a replay re-reads the community for
  its current header, as ADR-0030 L-3.
- **Same key, another body:** `IDEMPOTENCY_KEY_REUSED`.
- **A call that changes nothing still stores the document** (1 write), so a late retry cannot undo a newer change.
  Examples: Join by a member, Leave by a non-member, a repeated hide.
- **This keeps rule 4 as written: no bend.**

CreatePost's existing idempotency covers community posts.

### D9. Lifecycle (rule 10, ADR-0011, F12, A8)
**Eraser step `communities`**:
- **Placement:** `BeforeIdentity`, appended after the last step registered when W5-24 merges (today `lists`).
- **Properties:** resumable, idempotent and never flag-gated.
- **Order of work:** it reads `communityMemberships/{uid}`, sorts the union `joined ∪ owned ∪ banned ∪ modlogged`, and
  then runs one transaction per community. The checkpoint is the index into that sorted list. Each transaction does
  this:
1. Read the community doc and U's member doc fresh.
2. Delete U's member doc. If it was JOINED, `memberCount` −1.
3. `ArrayRemove(U)` from `moderatorIds`.
4. **Owned community (F12):** take the first uid in `moderatorIds` whose profile is ACTIVE (`identity.Directory`,
   cache-first, ≤ 10 reads).
   - **Found:** set `ownerId` to it, remove it from `moderatorIds`, add C to its `owned` and `modlogged`, and append
     `OWNER_HANDOVER` (actor `_deleted`, target the new owner).
   - **None:** `status = ARCHIVED`, `ownerId = ""`. The text stays (F12).
5. **Modlog scrub:** every entry whose `actor` or `target` is U gets `_deleted` (the ADR-0027 marker). Entries keep
   their action and time, so the owner still sees that something happened.
6. `recentRemovals` holds post ids only, so nothing to do. U's community posts go with the posts eraser by `authorId`,
   as today.

Then delete `communityMemberships/{uid}`. A rerun reads, finds nothing that names U, and writes 0.

**Export section `communities`:**
```
{
  "joined":   [{communityId, name, role, joinedAt}],
  "owned":    [{communityId, name, description, rules, createdAt}],
  "banned":   [{communityId, name, bannedAt}],
  "moderationActions": [{communityId, action, at}],
  "redactedCount": N
}
```
- `moderationActions` holds U's own modlog entries as actor, with no target and no post id.
- **No other user's uid appears anywhere**: no moderator ids, no modlog targets.
- A joined or banned community that is now SUSPENDED (and not owned by U) only raises `redactedCount`, as
  `lists_member_of` does for lists a viewer cannot read (ADR-0030 D8). The count does not say which cause applied.
- U's posts keep their `community {id, name}` in the posts section.

**T11 rows** in `lifecycle_collections_guard_test.go`:
- `communities`, erased by step `communities`; residue fields `ownerId`, `moderatorIds`, `modlog` actor and target;
- `communityMembers`, a subcollection of `communities`, erased by step `communities`, field `uid`;
- `communityMemberships`, doc id = uid, erased by step `communities`.

The step and the section go in `lifecycle_wiring_test.go`. The first PR that names a collection registers both (W5-23
with W5-24). The new posts fields hold no uid.

### D10. Flag, creation allowlist and rollout
**`FEATURE_COMMUNITIES`** (wire name `communities`, default off) gates:
- every `CommunityService` RPC;
- `GetCommunityTimeline`;
- `CreatePost.community_id` (FEATURE_DISABLED `feature=communities`, 0 reads beyond the interceptor, while off for the
  caller);
- COMMUNITY entries in `SetHomeTabs` and `GetMe.home_tabs`;
- the client's community screens, audience picker and tabs.

Related gating:
- The `REPORT_TARGET_TYPE_COMMUNITY` target needs `reports` on and `communities` not globally off.
- `posts` stays required for the feed.
- The label and the reply gate follow `Registry.GloballyOff` (D5).

**Creation (F1)** is not a flag: CreateCommunity needs `communities` on and the caller in `COMMUNITY_CREATORS`. That
config holds ≤ 10 uids, each validated with `ids.ValidUID`; a bad uid fails startup, and only the count is logged.

**Ceiling:** `scripts/promotion/flag-ceiling.json` gets `COMMUNITIES` in `flags` and the dev entry
`{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}` (A14). There is no prod raise: the prod apply is held,
ADR-0019. That file is founder-gated, so the entry is in W5-22 (FU-1), not in this PR.

**Ramp.**
- Dev: allowlist 3 (W5-40), after W5-36, W5-38 and W5-39.
- Prod, at the founder's MVP launch decision: allowlist → percent 5 → 25 → 100 → `on`. Each step is a Terraform change
  plus a tagged revision (ADR-0019).
- `communities` never ramps ahead of `lists`, and only once W5-38's moderator-abuse findings are closed.
- `COMMUNITY_CREATORS` holds the founders' uids at launch.

**Kill switches.**
- `FEATURE_COMMUNITIES=off` (a deploy): the RPCs and community posting reject, labels and the reply gate go, and tabs
  hide. The data stays and the pins return with the flag.
- `opsctl community suspend`: one community, no deploy.

**Rollback triggers:**
- a W5 Part B RPC error rate above 2 % for 15 min;
- community feed reads per DAU above twice the model for a day (27.3, from 13.65);
- a moderator-abuse or raid incident: suspend the community first, else turn the flag off.

### D11. Caps, quotas and rate limits (rule 11, F11)
Config is validated > 0 at startup. In-memory limits are per instance, so the effective limit is × 3 instances.

| Config | Default | Effective | Notes |
|---|---|---|---|
| `COMMUNITY_CREATORS` | ≤ 10 uids | exact | F1 |
| `COMMUNITIES_MAX_OWNED` / `COMMUNITIES_MAX_JOINED` | 2 / 50 | exact | the memberships doc in the transaction |
| `COMMUNITY_MAX_MODERATORS` / `COMMUNITY_MAX_RULES` | 10 / 10 | exact | |
| Name / description / rule title / rule text | 30 / 160 / 60 / 300 code points | exact | D2 text rules |
| `QUOTA_COMMUNITY_JOINS_PER_DAY` | 20 (new accounts 5) | exact | `quotas.communityJoins`; against mass-join spam and ban evasion |
| `QUOTA_COMMUNITY_POSTS_PER_DAY` | 50 (new accounts 10) | exact | `quotas.communityPosts`, on top of `posts` 100 |
| `COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY` | 20 | 60 | `DailyCap` keyed `uid\|cid` |
| `COMMUNITY_MUTATIONS_PER_DAY` | 200 | 600 | `community_mutation_daily` `DailyCap` over Create, Update, Join and Leave. Without it, 20/min × 3 × 1,440 UpdateCommunity calls would be about 86k writes a day |
| `COMMUNITY_MOD_ACTIONS_PER_DAY` | 200 | 600 | `DailyCap` per actor over Hide, Restore and SetMemberRole |
| `COMMUNITY_RECENT_REMOVALS_MAX` / `COMMUNITY_MODLOG_MAX` | 50 / 100 | exact | the capped arrays |
| `RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN` | 20 | 60 | the seven mutations |
| `RATE_LIMIT_COMMUNITIES_READ_PER_MIN` | 30 | 90 | GetCommunity, ListCommunities, ListMyCommunities, ListCommunityMembers, ListModerationLog |
| `RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN` | 12 | 36 | tabs switch quickly; Home stays 6 |
| Read budget (ADR-0010 D5) | 2,000 reads per uid per day per instance | 6,000 | binds the read side first |

### D12. Caches and staleness (A9)
| Cached read | Bound |
|---|---|
| Community doc (status, header, `moderatorIds`, `recentRemovals`), per instance, `CACHE_COMMUNITIES_ENTRIES` 200 | 60 s. A write updates the writing instance at once; others see it within 60 s. A suspension reaches every read path within 60 s; posting into a just-suspended community can succeed for up to 60 s on a warm instance (the same bound as an account suspension, ADR-0016 D4) |
| Member doc `(cid, uid)`, per instance, `CACHE_COMMUNITY_MEMBERS_ENTRIES` 5,000 | 60 s on read paths (role, replies). **Posting reads it fresh in the transaction** |
| Memberships doc, per instance (with the member cache) | 60 s; evicted on this instance's writes |
| Shared community entry (newest 30) | 60 s, refilled incrementally; filtered per viewer and by `recentRemovals` at serve time |
| Directory (top 50), per instance | 5 min |
| Home tabs | as ADR-0030 D11. COMMUNITY tabs store `title ""` (no other user's text on `users/{uid}`, ADR-0030 D6); the client labels them from the community header |
| Client | community feeds persist in drift like Home (`FeedKey.community(id)`, `since` refreshes, the new-posts pill, ≥ 60 s auto-refresh, `removed_ids`); directory, member and modlog pages are session memory; ListMyCommunities is cached for the session (the audience picker) |

Memory: at most about 10 MB of community docs, 6 MB of entries and 1 MB of member docs per instance. Every cache sits
behind `cache.LRU` and a module interface, so Memorystore can replace it by ADR.

### D13. Observability
Request-line fields carry counts and enums only, **never ids, names, descriptions or rule text**.
- `community_op` (`create`, `update`, `get`, `join`, `leave`, `my`, `directory`, `members`, `hide`, `restore`,
  `set_role`, `modlog`), `outcome`, `fs_reads`, `fs_writes`, `cache_hit`, `community_txn_attempts`.
- `mod_action` (the modlog action enum).
- `timeline_op=community`, `items_returned`, `items_filtered`, `removed`, `gap`, `rows_dropped` by cause (`blocked`,
  `muted`, `blocks_viewer`, `inactive`, `protected`, `moderated`).
- On CreatePost: `community_post` (bool) and `community_gate`. On the reply path: `community_reply_gate`.
- The eraser: `account_job` with `step=communities`, `memberships`, `handovers`, `archived`.

Error Reporting covers internal errors. There is no new log-based metric or alert policy. W5-39 adds a Logs Explorer
query for `timeline_op=community` and `fs_reads`.

### D14. Platform levers (W5-29)
- **ReportContent, `REPORT_TARGET_TYPE_COMMUNITY`:**
  - `target_id` is the community id.
  - Missing or SUSPENDED is the one NOT_FOUND "community not found". The caller's own community is VALIDATION
    `target_id`. ARCHIVED is reportable.
  - `targetOwnerId` is the owner (`""` when archived).
  - The evidence is kept in the report doc (`reports.evidence` is already index-exempt): `authorHandle` (the owner's),
    `communityName`, `communityDescription`, `communityRules [{title, text}]` and `postCreatedAt` (the community's
    `createdAt`). No member id, no child doc.
  - Quota `reports` as today.
  - Reports of community posts use the existing POST target.
- **`opsctl community suspend CID --project P [--report R] [--note N] [--dry-run]` and `opsctl community restore CID`:**
  - field-level `Update` of `status` and `updatedAt`, never `Set`;
  - restore sets ACTIVE when `ownerId` is non-empty, else ARCHIVED;
  - `--report` checks the report is a COMMUNITY report of exactly this id and resolves it as TAKEDOWN (the
    `lists hide` precedent).
- **`opsctl community archive CID --project P [--dry-run]`** (an owner's support request; F12):
  - one transaction sets `status = ARCHIVED` and `ownerId = ""`, and removes C from the owner's `owned` (I-M). The
    former owner stays a JOINED member.
  - It appends `OWNER_HANDOVER` with target `""` to the modlog, and adds C to the former owner's `modlogged`.
  - Field-level updates, never `Set`. 3 reads (community, the owner's memberships, the owner's member doc), 2 writes;
    a repeat writes 0.
  - Irreversible by `restore`, which keeps an ownerless community ARCHIVED.
- **`opsctl takedown-post` of a community post** also appends `{postId, now}` to that community's `recentRemovals`
  through `communities.PlatformRemovals`. It reads `community.id` from the post it already reads: +1 read and +1 write.
- **`suspend-user`'s hide loop** (ADR-0016 D4) collects the community ids of the community posts on each page, and
  appends once per community per page: +1 read and +1 write per community.
- `restore-post` and `unsuspend-user` do not list (D6).

### D15. Events (the bus seam)
`communities.Events` emits:
- `JOINED`, `LEFT`;
- `POST_HIDDEN`, `POST_RESTORED`;
- `MEMBER_BANNED`, `MEMBER_UNBANNED`;
- `MODERATOR_ADDED`, `MODERATOR_REMOVED`;
- `COMMUNITY_SUSPENDED`.

Each event carries ids and the actor, and is sent after the commit.
- **At Stage 0 the emitter is a no-op:** no Pub/Sub topic and 0 publishes. Community activity notifications are out
  of scope.
- A future notifications or realtime subscriber gets a Pub/Sub-backed emitter by its own ADR, with no caller change.
- Mentions, replies and quotes inside community posts already notify through posts' existing events, unchanged.

## Cost impact
- **Fixed monthly cost added: INR 0.**
  - No new GCP service, Pub/Sub topic, Scheduler job or TTL policy (the idempotency TTL exists).
  - No composite index and no fieldOverride (D3).
  - Nothing depends on ADR-0022.
- **Storage:** about 20 KB per community (≤ 20 at Stage 0), about 150 B per member doc and about 1 KB per memberships
  doc: well inside the free 1 GiB.
- **Vision units:** 0 (F13). **GCS:** no new objects.

**Per RPC.** Worst reads include the account-status interceptor. Every call is charged to the ADR-0010 D5 per-uid
budget and stays under `ReadBudgetMaxCallReads` 269; the worst is 103.

| RPC | Reads worst (cold) | Reads warm / planning | Writes | Deletes | Notes |
|---|---|---|---|---|---|
| CreateCommunity | 3 (interceptor, idempotency, memberships) | 2 | 4 (community, owner member doc, memberships, idempotency) | 1 TTL | not a creator: FORBIDDEN, 0 beyond the interceptor; cap 0 writes; replay 3 (interceptor, idempotency, the community), 0 writes |
| UpdateCommunity | 4 (interceptor, idempotency, community fresh, owner memberships) | 3 | 2 (+1 the first modlog naming the owner); unchanged 1 | 1 TTL | owner only |
| GetCommunity | 15 (interceptor, community, viewer member doc, caller graph, owner + ≤ 10 moderator profiles) | 0 / 4 | 0 | 0 | SUSPENDED: NOT_FOUND except to the owner |
| ListCommunities (directory) | 52 (interceptor, ≤ 50 shared refill, viewer memberships); ≤ 22 at Stage 0 (≤ 20 communities) | 0–2 / 22 | 0 | 0 | |
| ListMyCommunities | 52 (interceptor, memberships, ≤ 50 community docs) | 1 / 4 | 0 | 0 | `can_create` from config, 0 |
| JoinCommunity | 6 (interceptor, community (cache), idempotency, member doc, memberships, quotas) | 4 | 5 (member doc, memberships, `memberCount` blind `Increment`, quotas, idempotency); already a member 1 | 1 TTL | banned: FORBIDDEN, 0 writes |
| LeaveCommunity | 5; a moderator 6 (+ community fresh) | 3 | 3 (memberships, `memberCount` −1 or the moderator's community write, idempotency); not a member 1 | 1 (member doc) + 1 TTL | owner: FAILED_PRECONDITION `owner`, 0 writes |
| ListCommunityMembers, page 20 / 50 | 43 / 103 (interceptor, community, query ≤ p, profiles ≤ p, caller graph) | 21 / 51; planning 30 | 0 | 0 | sealed 24 h token `community_members\|<uid>\|<cid>\|<filter>`; BANNED filter only for moderators |
| GetCommunityTimeline | 25 at page 20, 55 at page 50 (interceptor, community, viewer member doc, query ≤ p, caller graph, `userLikes`) | refresh 1 + new warm, 3.5 + new planning; open 25 | 0 | 0 | empty `since`, cold 4; NOT_FOUND ≤ 2 |
| CreatePost into a community (over CreatePost) | +2 (community via cache, member doc fresh in the transaction) | +1 / +1.5 | +0 (`communityPosts` rides the quota write) | 0 | refusals: 0 writes |
| Reply in a community conversation (over the reply) | +2 (community, member doc, both cached) | +0 / +1 | 0 | 0 | F8 |
| `viewer_reply_permission` on GetPost / GetThread of a community conversation | +1 (member doc) | +0 / +0.5 | 0 | 0 | timelines +0 |
| HideCommunityPost / RestoreCommunityPost | 5 (interceptor, idempotency, community fresh, post fresh, actor memberships) | 4 | 3 (post field-level, community, idempotency) (+1 the actor's first entry in this community); no change 1 | 1 TTL | |
| SetMemberRole | 7 (interceptor, idempotency, community fresh, target member doc, target memberships, actor memberships, target profile) | 6 | BAN 4, UNBAN 3 (+1 delete), MAKE or REMOVE_MODERATOR 2-3; +1 the actor's first entry; worst 5 | ≤ 1 + 1 TTL | |
| ListModerationLog (≤ 25 entries) | 52 (interceptor, community, ≤ 50 profiles) | 0 | 0 | 0 | owner and moderators only; sealed `seq` token |
| SetHomeTabs with COMMUNITY tabs | +1 per new community tab (cache) | +0 | as ADR-0030 | | worst stays ≤ 19 |
| ReportContent, COMMUNITY target | 5 (interceptor, community, owner profile, report doc, quotas) | 2 | 2 | 0 | |
| Eraser step `communities` | 1 (memberships) + 2 per community (+ ≤ 10 profiles per owned community) | | 1 per community (+1 per hand-over) | 1 per member doc + 1 (memberships) | reference account (2 joined): 5 reads, 2 writes, 3 deletes |
| Export section `communities` | 1 + the communities (cache-first) | | 0 | 0 | reference account: 3 |
| `opsctl community suspend` / `restore` / `archive` | 1 / 1 / 3 (+1 `--report` check, +1 resolve) | | 1 / 1 / 2 (+1 resolve) | 0 | repeat 0 writes |
| `opsctl takedown-post` of a community post, `suspend-user` per page | +1 per community | | +1 per community | 0 | |

**Per DAU per day.** These are the plan's assumptions, to be replaced by W5-39's measurements:
- 30 % of DAU are in a community, refresh it 3 times a day, open it once, and see 10 new posts a day;
- 0.1 community posts and 0.05 replies in community conversations per DAU.

The open is priced all-cold, at 25, because Part A measured its cold open above its plan (`cost-model.md` §17).

| Call | Calls/DAU | Typical reads | Reads/DAU | Writes/DAU | Deletes/DAU |
|---|---|---|---|---|---|
| GetCommunityTimeline refresh | 0.9 | 3.5 + new (3.0 new in total) | 6.15 | 0 | 0 |
| GetCommunityTimeline open or older page | 0.3 | 25 | 7.5 | 0 | 0 |
| GetCommunity | 0.3 | 4 | 1.2 | 0 | 0 |
| ListMyCommunities | 0.3 | 4 | 1.2 | 0 | 0 |
| ListCommunities | 0.1 | 22 | 2.2 | 0 | 0 |
| ListCommunityMembers | 0.05 | 30 | 1.5 | 0 | 0 |
| JoinCommunity / LeaveCommunity | 0.02 / 0.01 | 6 / 5 | 0.17 | 0.13 | 0.04 |
| Community posts and replies (extra over CreatePost) | 0.1 / 0.05 | +1.5 / +1.0 | 0.2 | 0 | 0 |
| `viewer_reply_permission` on GetPost / GetThread | 0.2 | +0.5 | 0.1 | 0 | 0 |
| Moderation, CreateCommunity and UpdateCommunity | 0.005 | 5 | 0.03 | 0.02 | 0.005 |
| **Part B total** | **≈ 2.0 new requests** | | **≈ 20.3** | **≈ 0.15** | **≈ 0.05** |

Per DAU-month: 616 reads, 4.6 writes, 1.5 deletes, 60.8 requests and 6.1 vCPU-s, at the 0.1 s convention of
`cost-model.md` §1. The API responses add about 2.4 KB a day, derived from Part A's measured 2.8 KB for 2.29 requests.

**Free quotas that move** (whole product with Part B on for every DAU):

| Quota | Runs out at (was) | Part B increment at 2× that DAU | at 10× |
|---|---|---|---|
| Firestore reads 50k/day (405.7 per DAU) | **≈ 123 DAU** (130) | 246 DAU: INR 5.0 | 1,233 DAU: INR 25 |
| Firestore writes 20k/day (41.49 per DAU) | ≈ 482 DAU (484) | 964 DAU: INR 0.4 | 4,820 DAU: INR 2.2 |
| Firestore deletes 20k/day (9.16 per DAU) | ≈ 2,183 DAU (2,194) | 4,366 DAU: INR 0.1 | 21,830 DAU: INR 0.4 |
| Cloud Run requests 2M/month (1,936 per DAU-month) | ≈ 1,033 DAU (1,067) | 2,066 DAU: INR 4.8 | 10,330 DAU: INR 24 |
| Cloud Run vCPU-s 180k/month (193.6 per DAU-month) | ≈ 930 DAU (960) | 1,860 DAU: INR 26 | 9,300 DAU: INR 129 |

**INR per month.** Each line is the Part B increment, priced at the margin with the Mumbai prices of `cost-model.md`
§7: $0.035 / $0.104 / $0.012 per 100k reads / writes / deletes, $0.40 per million requests, $0.000024 per vCPU-s,
egress to India $0.12/GiB, INR 95 per USD. A quota the product already exhausts bills Part B in full.

| Line | 300 DAU | 1,000 DAU | 3,000 DAU |
|---|---|---|---|
| Firestore reads (all billed: the product is past the free reads) | 6.1 | 20.5 | 61.4 |
| Firestore writes (billed past about 482 DAU) and deletes (past about 2,183) | 0 | 0.5 | 1.4 |
| Cloud Run vCPU-s (past about 930 DAU) and requests (past about 1,033) | 0 | 13.9 | 48.5 (41.6 + 6.9) |
| Egress to India, API JSON (about 2.4 KB per DAU a day) | 0.2 | 0.8 | 2.3 |
| **Part B total** | **≈ 6** | **≈ 36** | **≈ 114** |
| Upper bound: community image views additive to Home (+10 % of image GETs, the ADR-0030 figure) | 6 | 36 (inside the free 100 GB) | ≈ 306 (+≈ 16.8 GiB GCS egress, INR 192; community browsing mostly **replaces** Home browsing, so this is a ceiling, not a forecast) |
| **Stage 0 bill with Part B** | 552 → **≈ 558** | 1,847 → **≈ 1,883** | 4,992 → **≈ 5,106** |

- **Verdict: the budget holds in the sense `CLAUDE.md` sets for Stage 0.** There is no fixed fee and no step change.
  Part B adds about 1.1 % / 1.9 % / 2.3 % to the bill.
- **Quotas at the 300 DAU target.** Reads were already past the free quota before Part B (approved pay-per-use,
  ADR-0022). Writes stay inside the 80 % line: 12.4k of 16k a day, +45 a day.
- **Trigger share:** community feed reads are 13.65 of 405.7 reads per DAU (3.4 %). The 15 % trigger fires at about
  69 reads per DAU, 5.1× the model.
- **Abuse as cost** (one account, one day, worst):
  - reads are bounded by the read budget (6,000 reads, INR 0.2);
  - writes by `community_mutation_daily` and `COMMUNITY_MOD_ACTIONS_PER_DAY` (600 calls each, at most about 4,300
    writes, INR 0.42) and the exact join and post quotas;
  - a join-leave loop is bounded by 20 exact joins (about 160 writes).
  - A public community feed is a scraping vector like a hashtag page: 36 calls a minute effective, under the same
    per-uid read budget.
- **Credit window (ADR-0022):** nothing here uses a credit-mode item; the lines are the same with or without it.
- **Trigger that justifies it:** none (no fixed cost). The scale-up triggers are in the Stage ladder.

## Stage ladder
These rows are copied into the `stage-ladder` skill's "Communities" section in this PR. Triggers are measured and
sustained 7 days.

| Concern | Stage 0 (this ADR) | Seam to protect now | Stage 2/3 target (ADR) | Trigger |
|---|---|---|---|---|
| Community feed | `communityId ==` ordered by id on the automatic index; a shared per-instance entry (30 posts, 60 s, incremental) | the `timeline` interface; `posts.Reader.ByCommunity`; the opaque `community` token binding | a dedicated feed store (a Memorystore sorted set per community, or a Postgres table) with a ranked Top tab | community feed reads > 15 % of daily Firestore reads, or one community above 1 post/s |
| Community counters | `Increment` on `communities/{cid}.memberCount`, blind and outside the join read set | one counter helper; `community_txn_attempts` and `ABORTED` per op | 10 shards `memberCountShards/{n}` summed into the cached view, or Pub/Sub-batched increments (also frees moderation transactions from join contention) | sustained `ABORTED`, or attempts > 3, on a community doc; any community above 1 join/s (a traffic shape: one viral community breaks rule 3 at any DAU) |
| Membership storage | member subcollection + per-user memberships doc | `communities.Reader` (`Role`, `Memberships`); member pages by sealed token | unchanged at Stage 2; a membership table in Spanner or Postgres at Stage 3 | joined cap above 500, or a memberships doc above 64 KB |
| Community moderation | the owner + ≤ 10 moderators with community-view powers only (hide and restore, ban and unban; the owner appoints moderators and edits the text); capped arrays on the community doc (modlog 100, `recentRemovals` 50, a truncation floor); reports, takedowns and suspension stay platform-only (opsctl) | `communities.Moderation` (the capped arrays sit behind it); the `removed_ids` contract; `posts.CommunityModerator`; the report target enum | a `modlog` collection with a TTL and a moderator console; a per-community removal log; a queue of community-post reports routed to the community's moderators, appeals, keyword automod | more than 50 removals per community per day (token resets), more than 20 COMMUNITY or community-post reports a week, a dispute needing older history, a community doc above 256 KB, or opening creation (F1) |
| Creation | `COMMUNITY_CREATORS` (≤ 10 uids, ≤ 2 owned each) | one creation check function; `can_create` on the wire | open creation: account age ≥ 30 days, verified email, a creation quota, a `banned[]` cap, a label lookup so a suspended community's name leaves labels | founder decision after W5-38 and 30 days of allowlist operation with no open High finding |
| Visibility | public only | the `visibility` enum; `posts.Audience` surfaces | restricted or private communities: a members-only filter on every read path | founder demand, with its own visibility-matrix ADR |
| Discovery | a directory by member count (top 50) | `communities.Directory` | search through the W4 engine; categories | more than 50 active communities, or directory opens above 1 per DAU |
| Community ids | Snowflake, time-ordered | ids opaque to clients | hash-prefixed ids | creation near 500/s (unreachable under the owned cap) |

## Follow-ups (gate files are not edited in this PR; the two `.claude/` skill files are)
- **FU-1 (W5-22, founder-gated):**
  - `scripts/promotion/flag-ceiling.json`: `COMMUNITIES`, dev allowlist 3, no prod raise;
  - Terraform `feature_communities*`, `community_creators` and the D11 config in `envs/dev` and `envs/prod`, default
    `off` and empty, not applied.
- **FU-2 `stage-ladder` skill (done in this PR):** a "Communities (ADR-0031)" section with the rows above.
- **FU-3 `firestore-data-model` skill (done in this PR):**
  - rows for `communities/{cid}`, `communities/{cid}/communityMembers/{uid}` and `communityMemberships/{uid}` [communities, ADR-0031];
  - the `posts` row's four new fields;
  - the `quotas` row's `communityJoins` and `communityPosts`. This row is where the quotas doc shape is documented. The
    code (`quota.Record` with its `valueFor` and `increment` cases) is W5-22 (ADR-0021 I-3);
  - the `reports` row's COMMUNITY evidence;
  - the per-RPC rows above;
  - in the Indexes section: "communities: none (D3, proven on dev)".
- **FU-4 `docs/reviews/cost-model.md` (sre-performance, W5-39):**
  - the Part B rows and the moved crossovers above;
  - a k6 `community_feed` scenario;
  - the Logs Explorer query.
- **FU-5 (optional, founder-gated, not required):**
  - fieldOverrides exempting `communities.modlog`, `communities.recentRemovals`, `communities.rules`,
    `communities.description`, `posts.community` and `posts.conversationCommunityId` from single-field indexing;
  - `field-overrides.ack` re-hashed;
  - nothing queries them. Worth bundling with another override PR only.
- **FU-6 `docs/code-map.md`:** `communities.Reader`, `Moderation`, `Directory`, `PlatformRemovals`, `Events`,
  `posts.CommunityGate`, `posts.CommunityModerator`, `ByCommunity` and `communityFeed`, with the PRs that add them.
- **FU-7 (planner):** `docs/plans/roadmap.md` W5 row: ADR-0031, and Part B's re-priced line.
- **FU-8 (W5-27):** a dated implementation note on ADR-0025 adding GetCommunityTimeline to the D4 matrix (SurfaceList,
  and F14's moderator waiver is a block rule, not an audience rule).

## Consequences
**Positive.**
- Communities ship with **no index change and no fixed cost**, at about INR 6 / 36 / 114 a month.
- The feed is one equality query on an automatic index plus a shared incremental entry, so a refresh costs 1 + new
  posts.
- Moderation is self-service for the community and bounded:
  - a moderator can only remove a post from the community view, never from the author's profile;
  - every action is logged and capped;
  - the platform keeps every global lever.
- Rule 4 holds on all seven mutations.
- Every Stage 2 move (feed store, sharded counter, modlog collection, open creation) is a swap behind a named seam.

**Negative.**
- A post's community label is a snapshot: after a rename, and after a suspension, labels on Home keep the old name.
  This is acceptable while creators are allowlisted (F1). Opening creation needs a label lookup (Stage ladder).
- Community pages can be shorter than the member count suggests (blocks, mutes, protected authors).
- F14 gives moderators a narrow block oracle (D7).
- An owner, including one by hand-over, cannot step down through the app. Support runs `opsctl community archive` on
  request; an ownership-transfer RPC is out of scope until such requests recur.
- A hidden root keeps its conversation members-only.
- The 60 s cache lets a just-suspended community accept posts briefly on a warm instance.
- The community doc is the one hot doc; a viral join burst slows moderation until the counter moves (Stage ladder).

**Revisit when:**
- a Stage ladder trigger fires;
- W5-39 measures reads per call more than 25 % off this table;
- W5-38 finds a practical raid or moderator-abuse path;
- the founder answers an F differently;
- creation opens.

## Handoff
- **architect:**
  - W5-21: `communities.proto` (`CommunityService`), with `idempotency_key` on all seven mutations and opaque tokens.
  - `posts.proto`: `CreatePostRequest.community_id`, `Post.community` (`CommunityRef {id, name}`), and a comment on
    `SchedulePost` and on `ReplyPermission.NOT_ALLOWED` (no new value).
  - `moderation.proto`: `REPORT_TARGET_TYPE_COMMUNITY` (LIST shipped in W5-44).
  - `timeline.proto`: `GetCommunityTimeline` (the Home response shape + a `Community` header with `viewer_role`).
  - `common.proto`: the COMMUNITY comment on `HomeTabKind`.
  - Enums are additive; `CommunityVisibility` holds PUBLIC only.
  - `buf breaking` clean, **no index file**.
  - FU-2 and FU-3 ship with this ADR (the `.claude/` code-owner review is the founder's).
- **backend-developer:**
  - **W5-22:** `make proto`; `FEATURE_COMMUNITIES`; `COMMUNITY_CREATORS`; the D11 config with `config_test.go` bounds;
    `quota.Record` `communityJoins` and `communityPosts` with their cases; the buckets and the two `DailyCap`s; FU-1;
    the `internal/communities` skeleton naming no collection constant (T11); `CreatePost.community_id` →
    FEATURE_DISABLED while off.
  - **W5-23 + W5-24 in one PR:** D2 writes for Create, Update and Get; the D9 eraser, export and T11 rows;
    `docs/runbooks/communities.md`.
  - **W5-25 and W5-25b:** Join and Leave (blind `Increment`, never read the community doc in the join transaction),
    ListMyCommunities, the directory, and the member pages by `joinedAt` and `bannedAt` presence.
  - **W5-26 and W5-26b:** `posts.CommunityGate` (D5 order), the four post fields, `conversationCommunityId`
    inheritance on every reply path, `ToView` label rules, and **`ByCommunity` per D3 (its own query, never
    `run()`; unit-test the `(W, 0…0)` sentinel)**.
  - **W5-27:** D6 in `service_community.go`, the incremental shared entry (every fill bounded by `page_size`),
    `communityFeed` in `tokens.go`, the F14 waiver, and COMMUNITY tabs in SetHomeTabs.
  - **W5-28:** D4 and A12 through `posts.CommunityModerator`; I-L on every modlog append.
  - **W5-29:** D14.
  - **Seams:** `communities.Service`, `Reader`, `Moderation`, `Directory`, `PlatformRemovals`, `Events` (no-op);
    `posts.CommunityGate`, `posts.CommunityModerator`, `posts.Reader.ByCommunity`. Posts never imports communities;
    timeline names only the posts, graph, identity, lists and communities seams.
- **frontend-developer:**
  - **W5-30 to W5-35.** Map FORBIDDEN `banned`, `not_member`, `not_moderator` and `not_owner`; FAILED_PRECONDITION
    `owner`, `community_archived` and `PROTECTED_ACCOUNT`; LIMIT_REACHED; QUOTA_EXCEEDED; FEATURE_DISABLED
    `feature=communities`.
  - **Roles:** take them from `viewer_role` only.
  - **Composer (W5-34):** hide the audience pill in reply and schedule mode and while the caller is protected (F6: the
    server answers `PROTECTED_ACCOUNT`), and hide the reply-audience control when a community is chosen. A draft keeps the community id (ADR-0029 F8); reset it to Everyone if the user is no longer a
    member.
  - **Replies:** show "Only members of <name> can reply" for `NOT_ALLOWED` on a labelled post.
  - **Tabs:** label community tabs from the timeline header.
  - **Moderators:** they also see members who block them on their community's member page (F14).
- **tester (W5-36, W5-37):**
  - the D4 role matrix;
  - D7, every row;
  - I-M, I-L and I-C after every mutation and after the eraser, including the banned-then-unbanned-then-deleted case;
  - D8 replays and `IDEMPOTENCY_KEY_REUSED` on all seven mutations;
  - the A12 hide and restore (the post leaves and re-enters the query, `Hidden()` stays false);
  - `removalsTruncatedAt` rejection;
  - the ban race (fresh read wins);
  - token bindings;
  - the budgets above;
  - load shapes: one community at 50 posts a minute, and a 20-joins-a-second burst on one community doc with the
    `ABORTED` metric.
- **security-auditor (W5-38):** the creators allowlist; public user text and its report path; moderator abuse (D4
  scope, caps, log, the rogue-owner residual); F14's oracle; ban evasion (join quota, new-account tiers); raids
  (post quotas, the per-community `DailyCap`, members-only replies, BAN of non-members); the feed as a scraping
  vector (36/min effective, read budget); the label as false attribution (cleared on hide); the hand-over; the
  export (no other uid); logs. Confirm that no community-only content exists (F6), so no read path can leak.
- **sre-performance (W5-39):** FU-4. Measure the refresh, the cold open (all-cold and entry-warm), the directory refill
  and the join burst. Watch the 15 % trigger and `community_txn_attempts`.
- **production-deployer (W5-40):**
  - Show the founder a targeted dev plan for `feature_communities*`, `community_creators` (the founder's dev uid) and
    the D11 config; apply on OK, with an allowlist of 3.
  - The smoke **re-runs D3's F1, F2b, F3b and M1 on real data first**. Then: create, join from a second account,
    post, see the label in Home, pin the tab, hide, ban, report, `opsctl community suspend`, flag state restored.
  - Prod: nothing until the held release (ADR-0019).

## As-built notes, 2026-11-01: the W5-21 protos (#590)

These notes record what the protos fixed where this ADR is silent or cannot be expressed on the wire. They are notes
only: the decision text, F1 to F14 and the architect's calls stay as written. The proto comments are the contract;
source: #590 (`87b046b0`), `proto/dzeroth/communities/v1/communities.proto` and the `posts`, `common`, `moderation` and
`timeline` changes in the same PR.

### N1. FORBIDDEN and COMMUNITY_STATE on the wire
Two new `ErrorReason` values in `common.proto`: `ERROR_REASON_FORBIDDEN = 21` (PERMISSION_DENIED) and
`ERROR_REASON_COMMUNITY_STATE = 22` (FAILED_PRECONDITION), both with `metadata["reason"]`. Without them the client's
mapper turns PERMISSION_DENIED into AccountRestricted and FAILED_PRECONDITION into ProfileRequired. CreateCommunity by
a caller outside `COMMUNITY_CREATORS` is FORBIDDEN `reason=not_creator`.

### N2. The `Community` header is light
`Community` carries no rules, owner or moderators (0 extra reads), so the timeline, directory and My Communities budgets
are unchanged. Rules, owner and moderators come only in `GetCommunityResponse`; rules also in the Create and Update
responses. GetCommunity leaves out a role holder whose account is not ACTIVE, for every viewer.

### N3. Status rules
- ARCHIVED is read-only: every write except LeaveCommunity answers COMMUNITY_STATE `community_archived`, Join and the
  moderator actions included.
- SUSPENDED is the one NOT_FOUND "community not found" for everyone, its owner included, except in GetCommunity and
  ListMyCommunities, which show it to its owner with status SUSPENDED.

### N4. SetMemberRole
MAKE_MODERATOR or REMOVE_MODERATOR on a target who has not joined is VALIDATION `user_id`; a target that is missing or
not ACTIVE is NOT_FOUND "user not found". The "VALIDATION `target`" of the owner banning themselves is field `user_id`,
the request field's name.

### N5. Paging
ListModerationLog: `page_size` 0 means 25, max 25. ListCommunities and ListMyCommunities carry `page_size` and
`page_token` by the common list convention; `next_page_token` is always "" at Stage 0.

### N6. Limit, quota and reason names
- RATE_LIMITED `metadata["limit"]`: `community_mutation_daily`, `community_mod_actions_daily`,
  `community_posts_per_community_daily`.
- QUOTA_EXCEEDED `metadata["quota"]` (the key every other quota uses): `community_joins`, `community_posts`. The plan's
  `limit_name` spelling was stale and is corrected there.
- LIMIT_REACHED: `communities_owned`, `communities_joined`, `community_moderators`.
- CreatePost checks FEATURE_DISABLED `communities` after `polls`.

### N7. D5's SchedulePost refusal has no field to refuse
`SchedulePostRequest` has no `community_id` (a comment only, as ADR-0029 F5 did for polls), so the "VALIDATION
`community_id`" in D5 cannot happen: a scheduled post is always an ordinary post. W5-26 tests nothing for it.

### N8. Older clients
A build without W5-30 shows FORBIDDEN as the generic "restricted" message and COMMUNITY_STATE as the profile-required
flow. The reply gate runs whenever `communities` is not globally off, so W5-30 is in every served or distributed build
before the flag leaves `off` anywhere (plan W5-30).

## As-built notes, 2026-11-02: W5-26 and W5-28 wiring

### N9. communities never imports posts
The package `communities` does not import `posts`. Each module declares the interface it consumes, with primitives and
`*firestore.Transaction` only, and `apiserver` wires the two:

- `posts.CommunityGate` (declared in posts, W5-26 and W5-26b) is implemented by `communities.PostGate` (`NewPostGate`).
- `communities.PostModerator` (declared in communities, W5-28, set with `FirestoreRepo.WithPostModerator`) is the identical
  shape as `posts.CommunityModerator`, which `posts.NewCommunityModerator` implements for the Hide and Restore post write.

The reason is a cycle: posts' in-package integration test imports communities, so a communities import of posts would
close the loop. D1's text "communities imports posts" is superseded on this point. This is an as-built note only: no new
decision and no status change.
