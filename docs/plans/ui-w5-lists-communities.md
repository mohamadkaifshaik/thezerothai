# UI W5: Lists, Communities and custom Home tabs
Plan owner: planner · Date: 2026-10-26 · Stage 0 (free tier, per use past it; about INR 441/month at 300 DAU with W2, `docs/reviews/cost-model.md` §5, ADR-0022) · **Two parts.** Part A is Lists and custom Home tabs: a new `lists` module, a new `dzeroth.lists.v1.ListService`, one new collection (`lists`), a list timeline and the Home tab order in `timeline`, and one `users/{uid}` field written through identity's interface. Part B is Communities: a new `communities` module, a new `dzeroth.communities.v1.CommunityService`, two new collections and a subcollection, community posting in `posts`, a community feed in `timeline`, and report targets in `moderation`. Each part has its own ADR, flag and rollout, so Part B can be held or dropped without touching Part A. **No new GCP service, no fixed cost, and no index-file change in the default design** · Flags: new `FEATURE_LISTS` (Part A) and `FEATURE_COMMUNITIES` (Part B); existing `posts`, `engagement`, `bookmarks`, `reports`, `removed_ids`, `ui_shell`
Source: `docs/plans/roadmap.md` (W5 row "Lists and Communities, custom Home tabs | lists + communities modules | moderation scope for communities", section 3 row P2 Lists and Communities, section 5 W5 capture row, "W5 to W8 follow in order of dependency and risk"), `docs/x_research/screens/lists.md`, `communities.md`, `home.md` §3, `composer.md` §3, `mobile/screens.md` §5-§6, `14_mvp_structured_plan.md` (W5 row, cost row 68) (all local and git-ignored), ADR-0004, ADR-0008, ADR-0010 (D5 read budget, D6 filtering, D13/D14 tokens), ADR-0011, ADR-0016 (D10 removal log), ADR-0018, ADR-0021, ADR-0023, the W3 and W4 plans (file boundaries, ADR numbers), the protos and modules on `main` d2ff011.
Branches: `feat/ui-w5-N-<slug>` off `main` (not stacked); one ticket per PR except where a ticket says "same PR as" (the T11 lifecycle guard); merge `origin/main` into the branch.

## Questions for the founder (proposed default in bold; nothing blocks the ADR or proto tickets)
- **F1. Who may create a community at Stage 0?** `FEATURE_COMMUNITIES` cannot express this alone. Its allowlist gates the whole feature per uid, so the flag cannot be on for readers and allowlist-only for creators at the same time. **Default: a config list `COMMUNITY_CREATORS` (at most 10 uids, a Terraform variable like `SUGGESTED_USER_IDS`, not a secret).** CreateCommunity checks the caller is in the list (0 reads), and the client learns it from `ListMyCommunitiesResponse.can_create` (0 reads). Each creator owns at most 2 communities. Open creation later is its own decision, made with a security review: an account-age gate, a creation quota and the moderation load. Alternative: a third flag `FEATURE_COMMUNITY_CREATE` (the `quotes` sub-flag precedent), which adds a founder-gated ceiling row.
- **F2. Members per list (`LIST_MAX_MEMBERS`).** **150.** The list timeline is Home's pull-merge over the members, and each refresh pays one read per 30 members even when nothing is new (table in Non-functional targets). At 150 a list is at most 5 chunks. Raising the cap later is a config change and is safe; lowering it would strand lists that are already larger, so start low. Alternatives: 500 (17 chunks) or 5,000 (X's limit), which fails the per-call read hold of 269.
- **F3. Lists per user and the default visibility.** **At most 20 lists per user, created private.** The owner can make a list public. X creates lists public by default, but a public list of people is a harassment surface, so we default to private.
- **F4. Being added to a list.** **No notification**, so there is no spam or harassment vector and no cost. Nobody can add a user who blocks them (NOT_FOUND, byte-identical to a missing user). If a member later blocks the list owner, that member is hidden from the list's member page and timeline for every viewer at read time. This costs 0 writes; the owner's next write to that list drops them. A "Lists you're on" page is out of scope.
- **F5. Custom Home tabs.** **Following stays first and fixed, followed by up to 5 pinned tabs (Lists and Communities) in the user's own order (`HOME_TABS_MAX_PINNED` 5).** The order syncs across devices: it is stored on `users/{uid}` and returned by `GetMe`, which the app already calls, so reading it costs 0. "For you" is not in scope (founder 2026-10-22). Alternative: the order stays on the device only (drift), with no sync and no proto change.
- **F6. Community visibility.** **Public communities only.** Any signed-in user can read a community. Only members can post. Community posts are ordinary PUBLIC posts. Restricted or private communities would need a visibility filter on every read path, the same problem as W3 Part B; they are Out of scope, with a trigger.
- **F7. Community posts outside the community.** **They also appear on the author's profile and in their followers' Home, with a context label row ("<community name>").** This is the cheapest option: the Home and profile queries are unchanged, and nothing is read only to be thrown away. Alternative: community-only posts (F6's Out-of-scope item).
- **F8. Replies to community posts.** **Members only, as on X.** Each reply into a community conversation costs one membership read (cold; it is cached for 60 s). Non-members can still read, like, repost, quote and bookmark the post. Alternative: anyone can reply, at 0 reads.
- **F9. Moderator powers.** **Owners and moderators can:**
  - hide a post from the community view, and restore it;
  - ban and unban a member;
  - (owner only) appoint and remove moderators, at most 10;
  - (owner only) edit the name, description and rules.

  **They cannot:**
  - delete a post or act on it outside the community (the post stays on the author's profile and in Home);
  - see reports;
  - act on the owner, and moderators cannot act on other moderators.

  Platform `reports` and opsctl takedowns still apply to every post. The community can be reported (new report target), and opsctl can suspend a community. Every action goes into a moderation log (the newest 100 entries) that the owner and moderators can read.
- **F10. Discovery.** **"Explore Communities" is a directory sorted by member count (top 50).** There are no categories, no chips and no community search; search comes with the W4 engine, and categories need curation. For Lists there is no "Discover new Lists", no list following and no follower counts. **Pinning someone's public list to Home is how you follow it**, and you reach it from that user's profile ("Lists").
- **F11. Community caps.**
  - Joined communities: at most 50 per user.
  - Owned communities: at most 2 per creator.
  - Joins: 20 a day.
  - Community posts: 50 a day per user across all communities, 10 for new accounts. This is Firestore-exact and counted on top of the existing 100 posts a day.
  - Posts per community per uid: 20 a day (in memory, × 3 instances).
  - Rules: at most 10. Name: at most 30 code points. Description: at most 160.
- **F12. A community whose owner deletes their account.** **Ownership passes to the longest-serving moderator. If there is none, the community is archived:** it becomes read-only, leaves the directory, and its `ownerId` is cleared. The owner cannot leave or transfer the community while the account is live; transfer is Out of scope.
- **F13. Images.** **No list or community images at Stage 0.** They use a flat default tile with an icon, as in X's default list tiles (`lists.md` §3). This adds 0 Vision units. Community banners can reuse W3's banner media kind later.

## What exists already (verified on `main` d2ff011)
| Piece | State | W5 delta |
|---|---|---|
| Lists, Communities | **nothing:** no module, proto, collection or flag (roadmap section 3: MISSING) | two modules, two protos |
| Home timeline | `timeline.homeSources(authors, tok, limit, start)` reads author-recent entries first, then chunks of 30 (`posts.MaxByAuthors`) at `k = ceil(2p/C')` with ≤ 4 in flight; `Merge`, `Compare`, `PositionOf`; `allowedAuthor`, `embedAllowed`; `removedIDs(ctx, tok, authors)`; tokens bound by `homeFeed` / `userFeed` in `tokens.go` (`backend/internal/timeline/service.go`, `merge.go`, `tokens.go`, `removed.go`) | **reuse all of it** for the list timeline; a new `listFeed` binding |
| Post query for a community | `posts.Reader.ByAuthors` (root posts, `isReply == false`), `ByAuthor`, `GetMany`; no community field on posts | `communityId` on root community posts; `Reader.ByCommunity` |
| Home tabs | `HomeScreen` has a one-tab "Following" `AppTabBar` (W1-5); `AppTabBar` already scrolls content-sized tabs and takes a trailing widget (`docs/ui-catalog.md`) | Following + pinned tabs, "+" → Manage pinned |
| Post context label | `PostCard` has a private `_RepostedBy` row (`app/lib/shared/widgets/post_card.dart:463`) | generalise it into one context-label row (repost, community) |
| Navigation | `AppDrawer` rows Profile / History / Settings / Sign out ("add Lists here in a later wave"); `MainShell` bar and rail Home, Notifications, Profile (W4-17 adds Explore) | Lists and Communities rows (drawer, desktop rail) |
| Reports, takedowns | `ReportContent` with `ReportTargetType` POST and ACCOUNT (`moderation.proto`); opsctl `takedown-post`, `suspend-user`; `postRemovals` log for `removed_ids` (ADR-0016) | targets COMMUNITY and LIST; opsctl community suspend and list hide |
| Composer | a "Choose audience" pill is captured on X (`composer.md` §3: "Everyone" plus "My Communities") and is not built; `composer-w15-w6.md` lists "Communities audience" as out of its scope | the audience picker (W5-34) |
| Lifecycle | `lifecycle_collections_guard_test.go` (T11) fails when code **names** a collection with no row, so the module's first PR that names `lists` or `communities` must also register its eraser and export (W2-3/W2-5 learned this) | W5-4 with W5-5, and W5-23 with W5-24, each in one PR |
| Captures | Lists index (desktop MEASURED, mobile 500 dp MEASURED), Communities explore (desktop MEASURED, mobile OBSERVED), Home tabs + "Manage timelines" button (MEASURED; dialog contents UNKNOWN), composer audience popover (OBSERVED + A11Y) | the roadmap's "W5 Lists and Communities on mobile" capture is **partly done**; still UNKNOWN: list detail, create-list flow, list members, community page and About, join flow, create community, the Manage timelines dialog, moderator tools |

## Goal & user value
- **Lists:** follow a topic or a circle without following everyone in it, and read just those people, chronologically, as a tab on Home.
- **Communities:** talk with people about a shared interest in one place, whether or not you follow each other, under rules that the community's own moderators enforce.
- **Custom Home tabs:** Home stays chronological and Following-first (founder 2026-10-22), and the user can pin the feeds they care about next to it.

All of it is pull-on-read at Stage 0, behind two flags, with hard caps on every read path.

## Scope / Out of scope
**In scope (Stage 0 rung):**
- **Lists:**
  - create, edit and delete a list (name ≤ 25, description ≤ 100, private or public);
  - add and remove members, capped (F2), with the block rules of F4;
  - a member page;
  - your own lists, and another user's public lists;
  - "Add to Lists" from a profile;
  - the **list timeline**: Home's pull-merge over the members, the same `since` cursor, author-recent cache, ADR-0010 D6 filtering and `removed_ids` scoped to the member authors;
  - pin and unpin a list as a Home tab.
- **Communities:**
  - create (F1) with a name, description and up to 10 rules;
  - join and leave;
  - roles OWNER / MODERATOR / MEMBER / BANNED;
  - the community page (feed and About);
  - My Communities and the directory (F10);
  - posting into a community from the composer's audience picker;
  - a **community feed**, a community-scoped query over posts with the same token contract as Home;
  - members-only replies (F8);
  - the moderation scope of F9;
  - platform report targets and opsctl levers;
  - pin a community as a Home tab.
- **Custom Home tabs:** Following + up to 5 pinned tabs, synced (F5), a Manage pinned screen with reorder, unpin and add.
- **Caps and quotas** as config (rule 11), and **eraser and export** for every new collection.

**Out of scope, with the Stage 2/3 version and its trigger (`stage-ladder`; the ADRs add these rows to the skill):**
| Concern | Stage 0 (this plan) | Seam to protect | Stage 2/3 target | Trigger |
|---|---|---|---|---|
| List timeline | pull-merge over ≤ 150 members, `homeSources` + `Merge`, author-recent cache, instance cache of the list doc (60 s) | the `timeline` interface; the opaque `list\|<uid>\|<listId>` token; the merge stays behind the interface | **the Home hybrid fan-out** (Memorystore per-feed materialisation, write fan-out for authors below N followers): a list becomes one more materialised feed, with the same contract | list timeline reads > 15 % of daily Firestore reads, or the `free-tier-budget` §6 trigger (> 1.5M reads/day or > $30/month), sustained 7 days; or a member cap above 500 is wanted |
| Community feed | `posts where communityId == X` ordered by post id (A1), a shared per-instance entry of the newest 30 posts (60 s) | `timeline` interface; `posts.Reader.ByCommunity`; opaque `community\|<uid>\|<cid>` token | **a dedicated feed store** (a Memorystore sorted set per community, or a Postgres table with a ranked "Top") | community feed reads > 15 % of daily reads sustained 7 days, or one community above 1 post/s sustained |
| Community counters | `FieldValue.Increment` on `communities/{cid}.memberCount` (rule 3) | the counter helper; the `ABORTED` metric | sharded or Pub/Sub-batched counters (the counters row) | sustained `ABORTED` on a community doc, or joins above 1/s on one community (a viral community breaks rule 3 at tiny DAU) |
| Moderation log and removals | capped arrays on the community doc: `recentRemovals[]` (50) and `modlog[]` (100) | `communities.Moderation` interface; `removed_ids` semantics | a `modlog` collection with TTL plus a moderator console | more than 50 removals per community per day (token resets), or a moderation dispute that needs older history |
| Restricted or private communities | public only (F6) | a community `visibility` enum present from day one, with PUBLIC the only accepted value | a members-only visibility filter on every read path, the W3 Part B policy function | founder demand, after ADR-0025 (private accounts) has shipped its visibility policy |
| Discovery | directory by member count; no list discovery | `communities.Directory` interface | community and list search through the W4 engine | W4's full-text trigger, or directory opens > 1 per DAU |

**Not built in W5:**
- "For you" and any ranked tab;
- list following with subscriber counts, "Discover new Lists" and "Lists you're on";
- list and community share links (W2-9's deep-link allowlist is unchanged);
- notifications for list adds or community activity;
- community categories, chips and search;
- community and list images (F13);
- ownership transfer while the owner is live;
- community invites or join approval;
- scheduled posts into a community (SchedulePost rejects `community_id`);
- a Top or Media tab inside a community (Latest only);
- private and restricted communities (F6).

## Non-functional targets (Stage 0, 0–300 DAU; credit mode to ~3k DAU changes no target, and nothing here depends on a min instance of 1, ADR-0022)
- **Latency (warm p95):**
  - GetListTimeline and GetCommunityTimeline < 400 ms (the timeline target);
  - list and community mutations < 500 ms;
  - GetList, GetCommunity, ListUserLists, ListMyCommunities < 300 ms;
  - SetHomeTabs < 300 ms;
  - GetMe unchanged.

  Cold start < 1.5 s (`CLAUDE.md`).
- **What bounds the list timeline: Home reads at most F + 1 authors.** F ≤ 5,000 is the graph's `following` cap, so Home has C ≤ 167 chunks, and its worst call is 2 + C + 2p = 269 at page 50. That is `config.ReadBudgetMaxCallReads`. A list reads only its members (≤ `LIST_MAX_MEMBERS`, so C = ceil(members / 30)). Its fixed reads are the interceptor, the list doc, the caller graph, `userLikes`, and the owner's graph for a non-owner viewer (F4): 5 in all.

  | Member cap | Chunks C | Empty refresh, owner, cold (3 + C) | Page 20, worst (5 + C + 40) | Page 50, worst (5 + C + 100) | With the removal-log window (+107, feeds ≤ 180 authors only) |
  |---|---|---|---|---|---|
  | **150 (default)** | **5** | **8** | **50** | **110** | **217 ≤ 269** |
  | 500 | 17 | 20 | 62 | 122 | n/a (a too-old token is rejected, so the client cold-opens) |
  | 1,000 | 34 | 37 | 79 | 139 | n/a |
  | 5,000 (X) | 167 | 170 | 212 | **272 > 269: fails the per-call hold** | n/a |

- **Community feed (worst):** interceptor + community doc + query `Limit(p)` + caller graph + `userLikes` = 4 + p, so 24 at page 20 and 54 at page 50. An empty refresh costs 3: interceptor, community doc and a query that bills 1 even when empty.
- **Staleness bounds (every cached read):**

  | Cached read | Bound |
  |---|---|
  | List doc (members, name, visibility; per instance) | 60 s. An add or remove shows at once on the writing instance and within 60 s on the others. A list made private stops serving non-owners within 60 s. |
  | Community doc (status, rules, moderators, `recentRemovals`; per instance) | 60 s. A suspension or a hide reaches other instances within 60 s. |
  | Membership doc `(cid, uid)` (per instance) | 60 s on read paths (reply check, role badge). **Posting reads it fresh in CreatePost's transaction**, so a ban stops posting at once. |
  | Community entry (newest 30 posts, per instance, shared across viewers, filtered per viewer after the cache) | 60 s. Hidden and taken-down posts are filtered at serve time (`communityHidden`, `!Visible()`, post cache ≤ 60 s). |
  | Directory (top 50, per instance) | 5 min |
  | Home tabs | exact: `GetMe` reads `users/{uid}` through the existing 60 s profile cache, and SetHomeTabs evicts it on the writing instance. On another device the new order shows at the next `GetMe`, within 60 s. A tab's title is a snapshot taken at pin time; the list or community header (in each timeline response, 0 extra reads) updates it on the device. |
  | Client | List and community feeds persist in drift like Home (`FeedKey.list(id)`, `FeedKey.community(id)`), with `since` refreshes, the "N new posts" pill, ≥ 60 s auto-refresh and `removed_ids`. Directory and member pages are session memory only. |

## Cost (required)
Method: `free-tier-budget` §2 and `docs/reviews/cost-model.md`. **Baseline: the W2 total, 248.7 reads, 33.5 writes, 8.4 deletes, 37.7 requests per DAU per day. Free reads are exhausted at about 201 DAU, writes at about 597, deletes at about 2,390 (cost-model §3).** Prices are from §7: asia-south1 $0.035 per 100k reads and $0.104 per 100k writes; egress to India $0.12/GiB, always billed; Cloud Run $0.40 per million requests and $0.000024 per vCPU-s past the free tier; INR 95 per USD. Each line below is **the W5 increment only**, priced at the margin as §5 does for W2. W3 (+40.1 reads) and W4 (+36.6) are separate plans and are not in these numbers.

**Per-RPC.** Worst-case reads include the account-status interceptor, and every call is charged to the ADR-0010 D5 per-uid read budget, under the per-call hold of 269.

| RPC | Reads worst (cold) | Reads warm | Writes | Deletes | Notes |
|---|---|---|---|---|---|
| CreateList | 4 (interceptor, idempotency, quotas, owner's lists query for the 20-list cap: `ownerId ==`, `Limit(21)`, counted as 1 + n) → 24 at 20 lists | 3 | 3 (list, idempotency, quotas) | 1 TTL (idempotency) | replay 2 / 0 writes |
| UpdateList / DeleteList | 2 / 2 | 1 / 1 | 1 / 0 | 0 / 1 | owner only; a foreign id is NOT_FOUND, byte-identical |
| AddListMember | 5 (interceptor, list in txn, quotas in txn, target `users`, caller graph) | 2 | 2 (list `ArrayUnion` + `memberCount`, quotas) | 0 | state-setting, so a replay is 0 writes; cap 150 = LIMIT_REACHED |
| RemoveListMember | 2 | 1 | 1 | 0 | no quota |
| GetList | 3 (interceptor, list, owner graph for F4) | 0–1 | 0 | 0 | private list → NOT_FOUND for non-owners |
| ListUserLists (an owner's lists, `contains_user_id` optional) | 1 + n (n ≤ 20) + 1 graph = 22 | 0–2 | 0 | 0 | public lists only for non-owners; `contains` is answered from `memberIds` at 0 reads |
| ListListMembers, page 20 / 50 | 24 / 54 (interceptor, list, `identity.Directory` GetMany of the page, caller graph, owner graph) | 2 + misses | 0 | 0 | sealed cursor (position in `memberIds`) |
| GetListTimeline | 50 at page 20, 110 at page 50; 217 with the removal-log window | refresh 3 + C + new | 0 | 0 | table above |
| SetHomeTabs | 7 (interceptor, ≤ 5 list or community docs, cached) | 1 | 1 (`users/{uid}.homeTabs`, field update through identity) | 0 | replay with the same content: 0 writes |
| `GetMe.home_tabs` | +0 (same `users/{uid}` read) | +0 | 0 | 0 | |
| CreateCommunity | 5 (interceptor, idempotency, quotas, memberships, owned count from memberships) | 3 | 5 (community, owner member doc, memberships, idempotency, quotas) | 1 TTL | allowlist (F1) checked first, 0 reads |
| UpdateCommunity | 3 (interceptor, community in txn, caller member) | 2 | 1 (+1 modlog in the same doc) | 0 | owner only |
| GetCommunity | 3 (interceptor, community, caller member doc) | 0–1 | 0 | 0 | |
| JoinCommunity / LeaveCommunity | 5 / 3 | 4 / 2 | 4 (member doc, memberships, `memberCount`, quotas) / 2 + 1 delete | 0 / 1 | a BANNED member gets FORBIDDEN `reason=banned`; the owner cannot leave |
| ListMyCommunities | 2 + n (memberships doc + `GetMany` of ≤ 50 community docs) = 52 | 1 | 0 | 0 | |
| ListCommunities (directory) | 51 (interceptor + `orderBy memberCount desc Limit(50)`) | 0–1 (shared entry, 5 min) | 0 | 0 | non-ACTIVE are filtered in memory (short list allowed) |
| ListCommunityMembers, page 20 / 50 | 24 / 54 | 2 + misses | 0 | 0 | BANNED rows shown only to moderators |
| GetCommunityTimeline | 24 at page 20, 54 at page 50; empty refresh 3 | 0–3 (shared entry) | 0 | 0 | |
| CreatePost with `community_id` (over CreatePost) | +2 (community doc cold, member doc fresh in the txn) | +1 | +0 (`quotas.communityPosts` rides the existing quota write; `communityId` is on the post doc) | 0 | |
| CreatePost reply into a community conversation | +1 (member doc, cached 60 s) | +0 | 0 | 0 | F8 |
| HideCommunityPost / RestoreCommunityPost | 4 (interceptor, caller member in txn, community in txn, post) | 2 | 2 (post `communityHidden` through the posts seam, community doc `recentRemovals` + `modlog`) | 0 | |
| SetMemberRole (ban, unban, promote, demote) | 4 | 3 | 3–4 (target member doc, community doc, target memberships, `memberCount` on a ban) | 0 | |
| ListModerationLog | 1 (interceptor) + 1 (community doc, cached) | 0 | 0 | 0 | owner and moderators only |

**Calls per average DAU per day (assumptions, to be replaced by W5-18 and W5-39 measurements):**
- **Lists:** 30 % of DAU have a pinned list (average 40 members, so C = 2). They refresh it 4 times a day, open or scroll it once, and see 12 new list posts a day.
- **Communities:** 30 % of DAU are in a community. They refresh it 3 times a day, open it once, and see 10 new posts a day. There are 0.1 community posts and 0.05 replies to them per DAU.

| Call | Calls/DAU | Typical reads | Reads/DAU | Writes/DAU |
|---|---|---|---|---|
| GetListTimeline refresh (overhead: list doc 1, C 2, interceptor and graph 0.5 each) | 1.2 | 4 + new posts (3.6/DAU in total) | 8.4 | 0 |
| GetListTimeline cold open / older page (Home's planning 30) | 0.3 | 30 | 9.0 | 0 |
| GetList | 0.1 | 3 | 0.3 | 0 |
| ListListMembers | 0.1 | 24 | 2.4 | 0 |
| ListUserLists (Lists screen, the Add-to-Lists sheet) | 0.3 | 4 | 1.2 | 0 |
| AddListMember / RemoveListMember | 0.2 / 0.05 | 3 / 1 | 0.65 | 0.45 |
| CreateList / UpdateList / DeleteList | 0.022 | 3 | 0.07 | 0.04 |
| SetHomeTabs | 0.02 | 3 | 0.06 | 0.02 |
| **Part A subtotal** | **≈ 2.3 requests** | | **≈ 22.1** | **≈ 0.51** |
| GetCommunityTimeline refresh (overhead 2.5 + new posts 3.0/DAU in total) | 0.9 | 2.5 + new | 5.25 | 0 |
| GetCommunityTimeline open / older page (24 cold, shared entry) | 0.3 | 20 | 6.0 | 0 |
| GetCommunity | 0.3 | 3 | 0.9 | 0 |
| ListCommunities (directory) | 0.1 | 5 | 0.5 | 0 |
| ListMyCommunities | 0.3 | 6 | 1.8 | 0 |
| ListCommunityMembers | 0.05 | 24 | 1.2 | 0 |
| Join / Leave | 0.02 / 0.01 | 4 | 0.12 | 0.10 |
| Community posting and members-only replies (extra) | 0.1 / 0.05 | 2 / 1 | 0.25 | 0 |
| Moderation actions | 0.003 | 4 | 0.01 | 0.01 |
| **Part B subtotal** | **≈ 2.0 requests** | | **≈ 16.0** | **≈ 0.11** |
| **Total W5** | **≈ 4.3 requests** | | **≈ 38.1 reads** | **≈ 0.62 writes, ≈ 0.02 deletes** |

- **Quota crossings.** On top of the W2 baseline the product reads 286.8 per DAU, so **the free 50k reads/day run out at about 174 DAU** (was 201). With W3 and W4 also on, it reads 363.5 per DAU and they run out at about 138 DAU. Writes: 34.1 per DAU, so the free 20k/day run out at about 586 DAU (was 597).
- **Share check for the triggers:** list feeds are 17.4 of 286.8 reads (6.1 %); community feeds are 11.3 (3.9 %). Both are well under the 15 % trigger.

**Wave total (W5 increment, Stage 0 as configured; reads are already past the free quota at all three columns, writes from about 590 DAU, Cloud Run from about 1,566 DAU vCPU and 1,743 DAU requests):**

| DAU | Reads/day | Firestore INR/month (reads + writes) | Cloud Run (requests + vCPU) | Egress to India (≈ 35 KB/DAU/day) | **W5 total INR/month** | Upper bound with list/community image views additive to Home (+20 % of image GETs) |
|---|---|---|---|---|---|---|
| 300 | 11,430 | 11.6 + 0 | 0 | 3.6 | **≈ 15** | 15 (GCS egress is inside the free 100 GB) |
| 1,000 | 38,100 | 38.5 + 1.9 | 0 | 11.3 | **≈ 52** | 52 |
| 3,000 | 114,300 | 115.6 + 5.6 | 14.9 + 89.5 | 33.9 | **≈ 260** | ≈ 581 (+28 GB GCS egress, INR 321; list and community browsing mostly **replaces** Home browsing, so this is a ceiling, not a forecast) |

- **Stage 0 bill with W2 + W5:**
  - 300 DAU: INR 441 → **≈ 456**;
  - 1,000 DAU: 1,653 → **≈ 1,705**;
  - 3,000 DAU: 3,498 → **≈ 3,758**.

  W3 (+27 / 47 / 242) and W4 (+15 / 50 / 169) are their own lines.
- **Part A alone:** ≈ INR 9 / 30 / 146. **Part B alone:** ≈ INR 6 / 22 / 114. The split follows the reads, writes and requests above (egress and Cloud Run split by requests).
- **Deletes:** about 0.02 per DAU, INR 0. **Vision units:** 0 (F13).
- **Storage:** a list doc is at most about 6 KB (150 uids). The `memberIds` array is indexed, at about 150 index entries per full list (cents). A community doc is at most about 25 KB (rules, 100 modlog entries, 50 removals). Members are 1 small doc each. All of it sits well inside the free 1 GiB at Stage 0.
- **No new GCP service, Scheduler job, Pub/Sub topic, TTL policy or fixed cost (INR 0 fixed).** There is no index-file change unless A1's check against the dev Firestore fails (then W5-21 adds one composite index: index storage cents, a founder-gated file).
- **Credit window:** nothing here depends on ADR-0022 items.

## Flags: FEATURE_LISTS, FEATURE_COMMUNITIES
| Flag (wire name) | Gates | Dev ceiling (`flag-ceiling.json`) | Prod |
|---|---|---|---|
| `FEATURE_LISTS` (`lists`) | every `ListService` RPC; `GetListTimeline`; LIST entries in `SetHomeTabs` and in `GetMe.home_tabs`; the client's Lists screens, drawer row, "Add to Lists" and list tabs | `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}` | no raise (prod apply on hold, `docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.2) |
| `FEATURE_COMMUNITIES` (`communities`) | every `CommunityService` RPC; `GetCommunityTimeline`; `CreatePost.community_id` (FEATURE_DISABLED `feature=communities` when set while off); COMMUNITY entries in `SetHomeTabs` and `GetMe.home_tabs`; the client's community screens, audience picker and community tabs | same | none |
| `posts` (existing) | both timelines need it, as Home does | unchanged | unchanged |
| `reports` (existing) | the new COMMUNITY / LIST report targets | unchanged | unchanged |
| `removed_ids` (existing) | `removed_ids` on list-timeline refreshes (the ADR-0016 log). The community feed's `recentRemovals` is gated by `communities` | unchanged | unchanged |

- **Creation (F1)** is not a flag: CreateCommunity needs `communities` and membership of `COMMUNITY_CREATORS`.
- **Render rules.** Community labels on posts render whenever the post carries `community`. With `communities` **globally** off (`Registry.GloballyOff`, 0 reads), `ToView` omits the label, so clients make no community calls; that is the kill switch for those calls. A pinned tab whose flag is off for the caller is omitted from `GetMe.home_tabs` but kept in storage, so it comes back when the flag does.
- **Ceilings.** `scripts/promotion/flag-ceiling.json` gets `LISTS` (W5-3) and `COMMUNITIES` (W5-22) in `flags` and dev entries, with **no prod raise**. **That file is founder-gated (CODEOWNERS).**
- **Terraform.** `feature_lists*` and `feature_communities*` variables, plus `community_creators`, go in `envs/dev` and `envs/prod`, default `off` / empty (copy `feature_bookmarks`). Nothing is applied by the build tickets.
- **Ramp.** Dev allowlist (3 uids) → the founder's MVP launch decision for prod: allowlist → percent 5 → 25 → 100 → `on`, each a Terraform change plus a tagged revision (ADR-0019). `communities` ramps after `lists` and only once W5-38's moderator-abuse findings are closed.

## Abuse & security surface
- **New public reads (signed-in only, App Check + ID token like every RPC; all `NO_SIDE_EFFECTS`, so they keep working under `DEGRADED_MODE=readonly`):**
  - a public list and its members and timeline;
  - another user's public lists (≤ 20, no paging);
  - communities, their members, feed and directory (≤ 50, no paging).

  Private lists answer NOT_FOUND to everyone but the owner, byte-identical to a missing list. Every cursor is sealed (`cursor.Cursor`) and bound to `<feed>|<uid>|<id>`, with the timeline's 30-day TTL for feeds and 24 h for member pages. A foreign or tampered token is VALIDATION with 0 reads.
- **Enumeration and scraping (`stage-ladder` vectors):**
  - List and community ids are Snowflakes (time-ordered, so guessable). A private list must therefore be indistinguishable from a missing one, and a guess costs the guesser's read budget.
  - Member pages are ≤ 50 per call, behind the rate limits below and the read budget.
  - Author `in` queries are bounded by the 150-member cap. A public list is a ready-made "scrape these authors" query, but it reads only what Home would read for a user following them, under the same per-uid budget.
- **New writes and their caps (config, rule 11; in-memory limits are per instance, so the effective limit is × 3 instances):**

  | Config | Default | Notes |
  |---|---|---|
  | `LISTS_MAX_PER_USER` | 20 | exact, from the owner query |
  | `LIST_MAX_MEMBERS` | 150 | F2 |
  | `QUOTA_LIST_CREATES_PER_DAY` | 10 (new accounts 3) | `quotas.listCreates` |
  | `QUOTA_LIST_ADDS_PER_DAY` | 300 (new accounts 50) | `quotas.listAdds`; the follows quota precedent |
  | `HOME_TABS_MAX_PINNED` | 5 | F5 |
  | `COMMUNITY_CREATORS` | ≤ 10 uids | F1 |
  | `COMMUNITIES_MAX_OWNED` / `COMMUNITIES_MAX_JOINED` | 2 / 50 | |
  | `COMMUNITY_MAX_MODERATORS` / `COMMUNITY_MAX_RULES` | 10 / 10 | |
  | `QUOTA_COMMUNITY_JOINS_PER_DAY` | 20 | `quotas.communityJoins`, against mass-join spam |
  | `QUOTA_COMMUNITY_POSTS_PER_DAY` | 50 (new accounts 10) | `quotas.communityPosts`, on top of `posts` 100 |
  | `COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY` | 20 | `ratelimit.DailyCap` keyed `(uid, cid)`, ≤ 60 effective |
  | `COMMUNITY_MOD_ACTIONS_PER_DAY` | 200 | `DailyCap` per moderator |
  | `RATE_LIMIT_LIST_TIMELINE_PER_MIN` / `RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN` | 12 / 12 | tabs switch quickly; Home stays 6 |
  | `RATE_LIMIT_LISTS_WRITE_PER_MIN` / `RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN` | 30 / 20 | |
  | `RATE_LIMIT_LISTS_READ_PER_MIN` / `RATE_LIMIT_COMMUNITIES_READ_PER_MIN` | 30 / 30 | members, directory, user lists |
  | Read budget (ADR-0010 D5) | 2,000 reads/uid/day | binds first |

- **Private lists:** only the owner sees the name, members or timeline. Members are never told (F4), so a private list reveals nothing to its members either.
- **Block rules:**
  - You cannot add a user who blocks you, or one you block. Both answer NOT_FOUND, byte-identical to a missing user, so the call is no block oracle.
  - Members who block the viewer, whom the viewer blocks, or whom the viewer mutes are dropped from timelines (`allowedAuthor`) and from member pages for that viewer.
  - Members who block the owner are dropped for every viewer (F4).
  - `blockedByOverflow` fails closed as in W4: no per-row graph read, and only the caller's own and followed authors are kept.
- **Community-only posts and who reads them:** there are none at Stage 0 (F6). Community posts are PUBLIC posts that anyone signed in can read, so no read path needs a new visibility check. The community label is not an access boundary. Membership gates writing only: posting, replying (F8), and moderation.
- **Moderator abuse:**
  - A moderator's power is limited to the community view (F9). A hide never deletes or takes down a post, and the author keeps it on their profile and in Home.
  - Moderators cannot act on the owner or on each other. Only the owner appoints and removes moderators.
  - Every action is in the modlog (actor, action, target, time), readable by the owner and moderators, and in a structured log line. The log line carries counts and enums only; the ids live in the modlog.
  - `COMMUNITY_MOD_ACTIONS_PER_DAY` bounds a rogue moderator.
  - The platform can report and suspend a community, and the owner can remove a moderator.
  - Residual: a rogue owner can hide everything in their own community. The platform lever is suspension (Risks).
- **Platform moderation still applies:** `ReportContent` covers posts in communities as today, plus the new COMMUNITY and LIST targets. Community and list names, descriptions and rules are public user-generated text, and the report carries a snapshot as evidence. Opsctl adds `community suspend|restore` and `list hide|restore`. An opsctl `takedown-post` of a community post also appends to that community's `recentRemovals`, so cached feeds drop it.
- **Text rules:** names, descriptions and rules follow the bio text rules: NFC, length in code points, and no control or bidi formatting characters (ADR-0010 D9).
- **Privacy:**
  - Logs never carry list, community or user ids, names or rule text: counts, enums and `fs_reads` only.
  - Export sections: `lists` (own lists with member ids), `communities` (memberships, roles, owned communities), and `home_tabs` (in the profile section).
  - Every collection has an eraser step (W5-5, W5-24).

## Dependencies & open questions
**Dependencies:**
- **W3 (ADR-0024 / ADR-0025).** If private accounts (W3 Part B) ship, ADR-0025's visibility matrix must include GetListTimeline and GetCommunityTimeline. If W5 ships first, both feeds call the same posts-side policy function once it exists. W5-8 and W5-27 name the hook (the `keep` predicate), and W3-35's matrix gets the two feeds.
- **W4.** Community posts are public and appear in hashtag search with no change.
- **W1.5 / W6 composer work.** The audience picker (W5-34) and the composer files are shared; see the shared-files table.
- **The founder's answers to F1 to F13.**
- **Captures (optional, non-blocking):** list detail, create-list flow, community page and About, join flow, the Manage timelines dialog, moderator menus. They are UNKNOWN today, so the UI tickets use X-like defaults and say so.

**Questions for @architect:**
- **ADR-0030 (Part A, W5-1; answered there, see the ADR for each item):**
  - **A4. Home tab storage.** Default: `users/{uid}.homeTabs` (≤ 5 `{kind, id, title}`), written through a consumer-side `timeline.HomeTabsStore` that identity implements, and returned in `GetMeResponse.home_tabs` (0 reads). Alternatives: a `homeTabs/{uid}` doc (+1 read per session, its own eraser) or device-only drift.
  - **A5. The lists data model.**
    - `memberIds[]` is **not** index-exempt: the eraser needs `array-contains`, so there is no gate file.
    - The owner query is `ownerId == uid Limit(21)` with doc-id (creation) order on the automatic single-field index, so there is no composite index.
    - The doc size bound.
    - The `members` cursor as a position in `memberIds`.
    - The F4 lazy drop of members who block the owner, on the owner's next write.
  - **A9 (lists part).** Cache sizes, `CACHE_LISTS_ENTRIES`, staleness as in the table above.
  - **A10.** The `keep` hook for ADR-0025.
  - **A11.** The `stage-ladder` "List timeline" row.
- **ADR-0028 or the next free number (Part B, W5-20):**
  - **A1. The community feed query** is `posts where communityId == X` with `ORDER BY __name__ DESC` and the window expressed as post-id bounds. Post ids are fixed-width 19-digit Snowflakes, so id order is time order.
    - This is expected to run on the **automatic single-field index** on `communityId`. **Verify it against the real dev Firestore before the ADR is final**, including the `since` (`__name__ >`) and page (`__name__ <`) forms. **The emulator cannot settle this:** it runs every query without requiring an index, so an emulator pass proves nothing. Only a dev query that succeeds (or fails with "requires an index") counts. The architect runs it if they have dev access; otherwise production-deployer runs a direct dev query (a throwaway `opsctl`/`gcloud` read, no data written) and records the result in the ADR PR before W5-21's index decision is final.
    - Only **root** community posts carry `communityId`; replies inherit nothing, so a single equality suffices.
    - If the check fails, the fallback is the composite `posts (communityId ASC, createdAt DESC)` in `firebase/firestore.indexes.json`, added in W5-21. That is a founder-gated file, serialised with W3-2 and W4-9.
  - **A2. The posting gate.** A consumer-side `posts.CommunityGate` (implemented by communities) runs inside CreatePost's transaction. It covers membership read fresh, ban, community status, and the `communityPosts` quota in the existing quota write. Root posts and quotes are allowed; `community_id` on a reply is rejected (replies follow the root), and SchedulePost rejects it. The `community {id, name}` snapshot goes on the post, and `communityHidden` makes `ToView` omit it.
  - **A3. Removals in cached feeds.** `recentRemovals[]` (≤ 50 `{postId, at}`) on the community doc becomes `removed_ids` on a `since` refresh, at 0 extra reads (the doc is read anyway). A token older than the oldest entry when the array is full is rejected exactly like an expired token (the ADR-0016 D10 contract). A restore is not listed. Opsctl `takedown-post` appends.
  - **A6. The membership model.** `communities/{cid}/communityMembers/{uid}` (role, joinedAt, `uid` field for the residue sweep; the subcollection is named `communityMembers`, not `members`, because collection-group queries, the T11 name scan and the residue sweep key on the collection id, and W7's conversations will likely want `members`) plus `communityMemberships/{uid}` (`joined[]` ≤ 50, `banned[]`, `owned[]`, `modlogged[]`), so ListMyCommunities is 1 read and the eraser finds every community, including bans. `modlogged[]` lists every community whose `modlog[]` has ever named this uid as the actor. Leaving does not clear it, so the eraser still finds a moderator who acted and then left. Modlog entries name a post id for hides (never the author's uid) and the target uid only for role changes, whose target is already in `joined[]` or `banned[]`.
  - **A7. The members-only reply check point (F8).** In the posts reply path, from the root's `communityId` (already read). Decide whether `ReplyPermission` gains an additive `COMMUNITY_MEMBERS_ONLY` value.
  - **A8. Owner deletion (F12)** inside the eraser step: resumable and idempotent; it clears `ownerId` when archiving.
  - **A9 (communities part).** Shared community entry size (30), directory cache (5 min), membership cache (60 s).
  - **A11.** The `stage-ladder` "Community feed" and "Community moderation" rows.

## Milestones
1. **M5.1 Contracts:** W5-1, W5-2 (Part A) and W5-20, W5-21 (Part B). The ADRs are accepted by the founder's merge.
2. **M5.2 Lists backend:** W5-3 to W5-9. Flags off; dev check by allowlist.
3. **M5.3 Lists client:** W5-10 to W5-14.
4. **M5.4 Lists verify and roll:** W5-15 to W5-19, with W5-17 and W5-18 done before `lists` leaves `off` in dev.
5. **M5.5 Communities backend:** W5-22 to W5-29.
6. **M5.6 Communities client:** W5-30 to W5-35.
7. **M5.7 Communities verify and roll:** W5-36 to W5-40, with W5-38 and W5-39 done before `communities` leaves `off` in dev.

Prod for both parts waits for the held prod apply (`docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.2) and the founder's MVP launch decision.

| ID | Ticket | Owner | Size | Depends | Parallel with W3 Part A / W4? | Status |
| --- | --- | --- | --- | --- | --- | --- |
| W5-1 | ADR-0030 "Lists and custom Home tabs at Stage 0" | architect | M | — | **yes, start now** (new file) | In review (PR #485) |
| W5-2 | Part A protos: new `lists.proto`; `common.proto` `HomeTab`; `timeline.proto` GetListTimeline + SetHomeTabs; `identity.proto` `GetMeResponse.home_tabs` | architect | S | W5-1 drafted | `timeline.proto` and `identity.proto` serialise with W3-2 | In review (PR #485) |
| W5-3 | `make proto`; `FEATURE_LISTS`, list config, quota fields, rate limits, ceiling, Terraform vars; `internal/lists` skeleton (no collection constant yet) | backend-developer | M | W5-2 | shared plumbing files: merge one at a time with W3-4 / W4-3 | In review (PR #495) |
| W5-4 | Lists write path: CreateList / UpdateList / DeleteList (**same PR as W5-5**) | backend-developer | M | W5-3 | yes (new module) | In review |
| W5-5 | Lists lifecycle: `lists` eraser step, export section, T11 rows, runbook (**same PR as W5-4**) | backend-developer | M | W5-3 | lifecycle wiring files serialise with W3-32 / W4-9 | In review |
| W5-6 | AddListMember / RemoveListMember | backend-developer | S | W5-4 | yes | In review |
| W5-7 | GetList, ListUserLists, ListListMembers + `lists.Reader` | backend-developer | M | W5-4 | yes | In review (PR #518) |
| W5-8 | `GetListTimeline` (reuse `homeSources`, `Merge`, `removedIDs`; `listFeed` token) | backend-developer | M | W5-7 | timeline `server.go` / `tokens.go` serialise with W3-9 | Open |
| W5-9 | SetHomeTabs + `users.homeTabs` through identity + `GetMe.home_tabs` | backend-developer | M | W5-3, W5-7 | identity files: after W3-6 | Open |
| W5-10 | Client data layer A: `ListsRepository`, `HomeTabsRepository`, `FeedKey.list`, `kFeatureLists` | frontend-developer | S | W5-3 | `feed_key.dart` serialises with W3-16 | Done (#517) |
| W5-11 | Lists screen `/lists`, create/edit sheet, drawer row and rail destination | frontend-developer | M | W5-10 | shell nav files serialise with W4-17 | Done |
| W5-12 | List detail `/lists/:id`: header, list timeline, members page, Pin | frontend-developer | M | W5-10 | yes | Open |
| W5-13 | "Add to Lists" from a profile; "Lists" of another user | frontend-developer | S | W5-11, W3-14 | **after W3-13 / W3-14** (`profile_header.dart`) | Open |
| W5-14 | Home tab bar (Following + pinned) and Manage pinned | frontend-developer | M | W5-10, W5-12 | `home_screen.dart` serialises with W3-19 | Open |
| W5-15 | Part A backend tests | tester | M | W5-6 to W5-9 | yes | Open |
| W5-16 | Part A client tests | tester | S | W5-11 to W5-14 | yes | Open |
| W5-17 | Part A security review | security-auditor | S | W5-6 to W5-9, W5-13 | yes | Open |
| W5-18 | Part A cost and performance budget: list timeline hot path, load smoke | sre-performance | S | W5-8, W5-9 | yes | Open |
| W5-19 | Part A dev rollout | production-deployer | S | W5-15, W5-17, W5-18, ADR-0030 merged | serialise dev applies with W3-24 / W4-24 | Open |
| W5-20 | ADR-0028 (or next free) "Communities and their moderation scope at Stage 0" | architect | M | — | **yes, start now** (new file) | Open |
| W5-21 | Part B protos: new `communities.proto`; `posts.proto` `community_id` / `community`; `moderation.proto` targets; `timeline.proto` GetCommunityTimeline (+ the A1 fallback index if needed) | architect | S | W5-20 drafted | `timeline.proto` after W5-2 and W3-2; the index file (only if needed) serialises with W3-2 / W4-9 | Open |
| W5-22 | `make proto`; `FEATURE_COMMUNITIES`, `COMMUNITY_CREATORS`, community config, quota fields, rate limits, ceiling, Terraform vars; `internal/communities` skeleton | backend-developer | M | W5-21 | shared plumbing files: one at a time (after W5-3) | Open |
| W5-23 | Communities write path: CreateCommunity / UpdateCommunity / GetCommunity (**same PR as W5-24**) | backend-developer | M | W5-22 | yes (new module) | Open |
| W5-24 | Communities lifecycle: eraser step (memberships, member docs, counts, owner hand-over, modlog scrub), export, T11 rows, runbook (**same PR as W5-23**) | backend-developer | M | W5-22 | lifecycle wiring files serialise | Open |
| W5-25 | Join / Leave (a leaving moderator leaves `moderatorIds`) / ListMyCommunities | backend-developer | M | W5-23 | yes | Open |
| W5-25b | ListCommunities (directory) / ListCommunityMembers | backend-developer | S | W5-25 | yes | Open |
| W5-26 | Posting into a community: `posts.CommunityGate`, `communityId`, label snapshot, SchedulePost reject, `Reader.ByCommunity` | backend-developer | M | W5-23, W5-25 | **after W3-7** (every create path) | Open |
| W5-26b | Members-only replies (F8) and the `ToView` label rules | backend-developer | S | W5-26 | reply path after W3-7 | Open |
| W5-27 | `GetCommunityTimeline` + COMMUNITY kind in Home tabs | backend-developer | M | W5-26, W5-9 | timeline files after W5-8 | Open |
| W5-28 | Community moderation: Hide / Restore post, SetMemberRole, ListModerationLog | backend-developer | M | W5-26 | yes | Open |
| W5-29 | Platform levers: report targets COMMUNITY / LIST; opsctl community suspend / restore, list hide / restore; takedown appends `recentRemovals` | backend-developer | M | W5-23, W5-4, W5-28 | moderation module only | Open |
| W5-30 | Client data layer B: `CommunitiesRepository`, `FeedKey.community`, `kFeatureCommunities` | frontend-developer | S | W5-22 | after W5-10 (`feed_key.dart`) | Open |
| W5-31 | Communities screen `/communities` (My Communities + directory) and Create community | frontend-developer | M | W5-30 | shell nav files after W5-11 | Open |
| W5-32 | Community page `/communities/:id`: header, Join / Joined, Posts, About | frontend-developer | M | W5-30 | yes | Open |
| W5-33 | One context-label row on `PostCard` (repost, community) | frontend-developer | S | W5-30 | `post_card.dart` serialises with W3-17 / W4-16 | Open |
| W5-34 | Composer audience picker (Everyone / a joined community) | frontend-developer | M | W5-30 | composer files serialise with W1.5 / W6 tickets | Open |
| W5-35 | Moderation UI (hide, restore, members, roles, modlog) + report community / list | frontend-developer | M | W5-32, W5-33 | post menu file after W3-17 | Open |
| W5-36 | Part B backend tests | tester | M | W5-25 to W5-29 | yes | Open |
| W5-37 | Part B client tests | tester | S | W5-31 to W5-35 | yes | Open |
| W5-38 | Part B security review incl. moderator abuse | security-auditor | M | W5-25 to W5-29, W5-34 | yes | Open |
| W5-39 | Part B cost and performance budget: community feed hot path, load smoke | sre-performance | S | W5-27, W5-28 | yes | Open |
| W5-40 | Part B dev rollout | production-deployer | S | W5-36, W5-38, W5-39, ADR-0028 merged | serialise dev applies | Open |

**Order:**
1. **Start now:** W5-1 and W5-20 (new ADR files only).
2. Once each is drafted: W5-2, then W5-21 (proto PRs; `timeline.proto` and `identity.proto` one at a time with W3-2).
3. **Part A:**
   - backend: W5-3 → (W5-4 + W5-5 in one PR) → W5-6 ‖ W5-7 → W5-8 ‖ W5-9;
   - client: W5-10 → W5-11 ‖ W5-12 → W5-13 (after W3-14), W5-14;
   - then W5-15 to W5-19.
4. **Part B:**
   - backend: W5-22 → (W5-23 + W5-24 in one PR) → W5-25 → W5-25b ‖ W5-26 → W5-26b ‖ W5-27 ‖ W5-28 → W5-29;
   - client: W5-30 → W5-31 ‖ W5-32 ‖ W5-33 → W5-34, W5-35;
   - then W5-36 to W5-40.

Part B can run alongside Part A once W5-21 is in; only the shared files below serialise.

**Shared files that must serialise (with W3 Part A, W4, and inside W5):**
| Shared file | W5 tickets | Other waves | Rule |
|---|---|---|---|
| `backend/pkg/platform/config/config.go` (+ `config_test.go`), flag registry and wiring in `backend/internal/apiserver/apiserver.go`, `ratelimit_config.go`, Terraform `feature_*` vars (`envs/dev`, `envs/prod`, `modules/cloud-run-api`) | W5-3, W5-22 | W3-4, W3-25, W4-3 | one flag/plumbing PR at a time; the later one merges `origin/main` |
| `scripts/promotion/flag-ceiling.json` (**founder-gated**) | W5-3, W5-22 | W3-4, W3-25, W4-3 | same; the founder reviews each |
| `backend/pkg/platform/quota/quota.go` (`Record` fields must ship with their `valueFor` / `increment` cases, ADR-0021 I-3) | W5-3, W5-22 | W3-26 (Part B toggle quota) | one at a time |
| `proto/dzeroth/timeline/v1/timeline.proto` | W5-2, W5-21 | W3-2 (tab enum) | one proto PR at a time; field numbers re-checked on merge |
| `proto/dzeroth/identity/v1/identity.proto`, `proto/dzeroth/common/v1/common.proto` (`HomeTab`) | W5-2 | W3-2 (identity); any wave adding a shared message (common) | same |
| `proto/dzeroth/posts/v1/posts.proto`, `moderation.proto` | W5-21 | — (W1.5 / W6 may touch posts) | W5 owns them during W5-21 |
| `backend/internal/timeline/{server.go,tokens.go}` (Deps, feed bindings) | W5-8, W5-27 | W3-9 | new logic goes in new files (`service_list.go`, `service_community.go`); only the Deps and bindings lines conflict |
| posts create path (CreatePost transaction, reply path) | W5-26 | W3-7 (`hasMedia` on every create path), W6 polls | W5-26 after W3-7 |
| `backend/internal/identity` (profile write, `GetMe`) | W5-9 | W3-6, W4-4, W4-11 | W5-9 after W3-6 |
| `backend/internal/apiserver/lifecycle_wiring.go`, `lifecycle_collections_guard_test.go`, the residue sweep | W5-5, W5-24 | W3-32 (Part B), W4-9 (trends row) | one at a time |
| `firebase/firestore.indexes.json`, `firebase/field-overrides.ack` (**founder-gated**) | none by default; W5-21 only if A1 fails | W3-2, W4-9 | one index PR at a time |
| `app/lib/features/timeline/domain/feed_key.dart` (+ drift keys) | W5-10, W5-30 | W3-16 (`FeedKey.user(uid, tab)`) | one at a time |
| `app/lib/features/home/presentation/home_screen.dart` (Home tab bar) | W5-14 | W3-19 (who-to-follow in `headerSlivers`), W2-12 (merged) | W5-14 after W3-19 or rebases |
| `app/lib/core/router/main_shell.dart`, `app_router.dart`, `app/lib/core/widgets/app_drawer.dart`, the bottom bar and rail | W5-11, W5-31 | W4-17 (Explore), W3-18 | one nav PR at a time |
| `app/lib/shared/widgets/post_card.dart` (context label, post menu) | W5-33, W5-35 | W3-17 (pinned label, pin menu), W4-16 (hashtag tap) | one at a time |
| `app/lib/features/profile/presentation/widgets/profile_header.dart` (overflow menu) | W5-13 | W3-13, W3-14 | after W3-14 |
| composer files (`app/lib/features/compose/...`) | W5-34 | W1.5 composer conformance, W6 | one at a time |
| `docs/code-map.md`, `docs/ui-catalog.md` | every ticket | every wave | trivial merges |

**Definition of done per ticket:**
- Backend: Go unit tests plus emulator integration (`make test-int`, `budgettest.Assert` on every RPC).
- Client: widget tests in light and dark at 360 / 600 / 1200 via `test/support/theme_harness.dart` for every new screen or widget, at text scale 1.0 / 1.3 / 2.0. Pixel goldens are deferred (B-01).
- `make ci` green.
- `docs/code-map.md` / `docs/ui-catalog.md` updated; this table's Status updated in the PR.

## Tickets

### W5-1 — ADR "Lists and custom Home tabs at Stage 0"  [owner: architect] [size: M] [depends: —]  Status: In review (PR #485)
- **Description.** `docs/adr/0030-lists-and-custom-home-tabs.md` (Proposed). 0024 and 0025 went to W3, 0026 to W8, 0027 to W7, 0028 to W4 and 0029 to W6, so Part A is 0030. It decides:
  - the `lists` collection and doc shape (A5);
  - the member cap (F2) with the chunk arithmetic above, and the per-user caps and quotas;
  - the visibility and block rules (F3, F4);
  - the list timeline as a call into `homeSources` / `Merge` with a `listFeed` binding, `removed_ids` scoped to the members, and the ADR-0010 D6 filter plus the F4 owner rule;
  - Home tab storage (A4, F5);
  - caches and staleness (A9);
  - the per-RPC cost table above, the flag, and the eraser and export;
  - the ADR-0025 hook (A10).

  In the same PR:
  - add the `stage-ladder` "List timeline" row (A11);
  - add `firestore-data-model` rows for `lists`, `users.homeTabs` and the new queries;
  - add `quotas` fields `listCreates` and `listAdds`.
- **Acceptance criteria.**
  - Given the ADR, then F2 to F5 each have options, a default and an INR line at 300 / 1,000 / 3,000 DAU that cites `cost-model.md` §5 and §7.
  - Given the member cap, then the ADR shows the worst case at page 50 against `ReadBudgetMaxCallReads` (269).
  - Given A5, then it states that `memberIds` is not exempt and why (the eraser), and that no index file changes.
- **Test notes.** None (docs). `code-reviewer` checks the seam and trigger lines.
- **Observability.** The ADR lists the log fields: `timeline_op=list`, `list_members`, `timeline_chunks`, `authors_from_cache`, `items_filtered`, `fs_reads`, `list_op`, `rows_dropped` by cause.
- **Budget.** The ADR's table is the source for W5-4 to W5-9.
- **Flag.** None (docs); it names `FEATURE_LISTS` and its ceiling.
- **Seam.** It defines `lists.Service`, `lists.Reader` (`Members(ctx, viewer, listID)`) and `timeline.HomeTabsStore`; the list timeline sits behind the `timeline` interface.
- **Parallel with W3 Part A / W4:** yes.

### W5-2 — Part A protos  [owner: architect] [size: S] [depends: W5-1 drafted]  Status: In review (PR #485)
- **Description.** All changes are additive; `buf lint` and `buf breaking` are clean; field numbers are the architect's.
  - New `proto/dzeroth/lists/v1/lists.proto`, `ListService`:
    - CreateList(idempotency_key, name, description, private);
    - UpdateList(list_id, optional name / description / private);
    - DeleteList(list_id);
    - GetList(list_id) → `List {list_id, owner (UserListItem), name, description, private, member_count, pinned_by_viewer}`;
    - ListUserLists(owner_id, contains_user_id) → `repeated List` + `contains[]` (no paging, ≤ 20);
    - AddListMember / RemoveListMember(list_id, user_id) (state-setting);
    - ListListMembers(list_id, page_size, page_token) → `repeated dzeroth.graph.v1.UserListItem`.
  - `common.proto`: `HomeTab {kind (LIST, COMMUNITY), id, title}` with its `HomeTabKind` enum. It lives in `common`, not in `timeline`, so that identity does not import timeline (and, through it, posts). Today `identity.proto` imports nothing internal and `common.proto` imports only well-known types, so this adds no new dependency edge and no cycle (`buf` rejects cycles).
  - `timeline.proto`:
    - `GetListTimeline(list_id, page_size, page_token, since_token)` → the Home response shape plus `List list` (header, 0 extra reads); `timeline.proto` then imports `lists.proto` for `List` (lists imports only `common` and `graph`);
    - `SetHomeTabs(repeated dzeroth.common.v1.HomeTab tabs)`.
  - `identity.proto`: `GetMeResponse.home_tabs` (repeated `dzeroth.common.v1.HomeTab`), its first import of `common`.

  Every RPC comment carries worst and warm reads, writes, caps and the error contract: VALIDATION `field=...`, NOT_FOUND byte-identical, LIMIT_REACHED `limit=list_members|lists|home_tabs`, FEATURE_DISABLED `feature=lists`, RATE_LIMITED, QUOTA_EXCEEDED.

  **As built (ADR-0030, 2026-10-30), where it differs from the sketch above:** the header message is `ListInfo` (a message named `List` would shadow Dart's `dart:core` `List`), with `is_private` (and `CreateListRequest.is_private` is `optional`: absent = private, F3) and no stored member counter (`member_count` = the `memberIds` length); **every** mutation, SetHomeTabs included, takes `idempotency_key` and stores the standard idempotency document (ADR-0030 D7, rule 4 kept); `ListUserLists` has `page_size` / `page_token` / `next_page_token` and `contains_user_id` only for the caller's own lists, answering `containing_list_ids`; `HomeTab.title` is output only and stored only for the caller's own lists (D6); `AddListMember` of a protected account the owner does not follow is `PROTECTED_ACCOUNT` (D4). Numbers claimed: `GetMeResponse.home_tabs = 8`; `HomeTab` fields 1-3; `HomeTabKind` 0-2; `GetListTimelineResponse.list = 6` after Home's 1-5; no new `ErrorReason`.
- **Acceptance criteria.**
  - Given `make proto` (run in W5-3), then Go and Dart generate.
  - Given `buf breaking` against `main`, then it is clean.
  - Given the comments, then every RPC states its budget from W5-1.
- **Test notes.** `buf breaking`.
- **Observability.** —
- **Budget.** Copied from W5-1.
- **Flag.** None (contract); the comments name `lists` as the FEATURE_DISABLED metadata.
- **Seam.** `HomeTab.kind` is an enum (a new kind is additive); every cursor is opaque.
- **Parallel with W3 Part A / W4:** `timeline.proto` and `identity.proto` serialise with W3-2; `lists.proto` is a new file.

### W5-3 — Generate, `FEATURE_LISTS`, config, module skeleton  [owner: backend-developer] [size: M] [depends: W5-2]  Status: Open
- **Description.**
  - `make proto`, with the generated Go and Dart committed.
  - Register `FEATURE_LISTS` in `config.go` and `flags.NewRegistry` (follow `FEATURE_BOOKMARKS`).
  - Config with `config_test.go` entries: `LISTS_MAX_PER_USER` 20, `LIST_MAX_MEMBERS` 150, `HOME_TABS_MAX_PINNED` 5, `CACHE_LISTS_ENTRIES` 5,000, and the rate limits from the abuse section, mapped in `ratelimit_config.go`.
  - `quota.Record` gets `listCreates` and `listAdds` with their `valueFor` / `increment` cases and new-account tiers.
  - `flag-ceiling.json`: `LISTS` dev allowlist 6 (every flag since #463) (**founder-gated file**).
  - Terraform `feature_lists*` in `envs/dev` and `envs/prod`, default `off`, not applied.
  - `internal/lists`: `api.go` (interfaces) and a Connect server whose handlers return FEATURE_DISABLED or Unimplemented, wired in `apiserver.Build`. **Name no collection constant here** (the T11 guard); W5-4 adds it with W5-5.
  - Timeline gets the two RPC handlers, flag-guarded and Unimplemented.
- **Acceptance criteria.**
  - Given `FEATURE_LISTS` unset, when any list RPC, GetListTimeline or SetHomeTabs with a LIST entry is called, then FAILED_PRECONDITION `FEATURE_DISABLED` `feature=lists` with 0 reads.
  - Given allowlist mode with a uid, then `GetMe.enabled_features` contains `lists` for that uid only.
  - `check-flag-registry.sh` passes, and `guard_test.go` sees the new RPCs in the read budget.
  - The config rejects zero or negative caps.
- **Test notes.** Flag modes off / allowlist / percent / on; the config bounds; the quota `Record` round trip (a missing field must not zero another, ADR-0021 I-3).
- **Observability.** The startup `feature_flags` line lists `lists`.
- **Budget.** 0 reads on the rejection paths.
- **Flag.** Adds `FEATURE_LISTS` (default `off`; dev ceiling allowlist 3).
- **Seam.** `lists.Service` Go interface; handlers call only it.
- **Parallel with W3 Part A / W4:** logic yes; the shared plumbing files merge one PR at a time with W3-4 / W4-3.

### W5-4 — Lists write path  [owner: backend-developer] [size: M] [depends: W5-3]  Status: In review  (**ships in one PR with W5-5**)
- **Description.** `lists.FirestoreRepo` owns `lists/{listId}` (Snowflake id): `ownerId`, `name`, `description`, `private`, `memberIds[]`, `memberCount`, `hidden` (platform, W5-29), `createdAt`, `updatedAt`.
  - **CreateList:**
    - the idempotency doc (rule 4);
    - a transaction with `quotas.listCreates`;
    - the 20-list cap from `ownerId == uid Limit(21)` (an equality-only query with the implicit doc-id order, which Firestore serves from the automatic single-field index; the emulator never reports a missing index, so the W5-19 dev smoke is where this is first proven, and any "requires an index" error there means stop and ask);
    - name and description validated by the bio text rules, NFC, code points.
  - **UpdateList:** owner only; a field mask of optional fields. Making a list private evicts it from the instance cache.
  - **DeleteList:** owner only; `Delete(Exists)`, a no-op success. It also drops the list from the owner's `homeTabs` through `timeline.HomeTabsStore` when W5-9 has landed (otherwise a later GetMe drops it lazily).
  - A foreign or missing id is one NOT_FOUND for every cause.
- **Acceptance criteria.**
  - Given 20 lists, when CreateList, then LIMIT_REACHED `limit=lists` with 0 writes.
  - Given a replayed key, then the same list and 0 writes.
  - Given another user's list id, then NOT_FOUND byte-identical to a missing id.
  - Given a name with a bidi control, then VALIDATION `field=name`.
  - Given `DEGRADED_MODE=readonly`, then rejected before any read (existing interceptor).
- **Test notes.** Emulator integration; `budgettest` per the W5-1 table (CreateList 4 + n cold); replay; quota tiers for new accounts.
- **Observability.** One slog line per RPC: `list_op`, `fs_reads`, `fs_writes`, outcome enum. Never names or ids. Error Reporting on internal errors.
- **Budget.** CreateList ≤ 24 reads (at 20 lists), 3 writes; UpdateList 2 / 1; DeleteList 2 / 0 + 1 delete.
- **Flag.** `FEATURE_LISTS`.
- **Seam.** `lists.Service`; only `lists` touches the collection.
- **Parallel with W3 Part A / W4:** yes (new package).

### W5-5 — Lists lifecycle  [owner: backend-developer] [size: M] [depends: W5-3]  Status: In review  (**ships in one PR with W5-4**)
- **Description.**
  - **Eraser step `lists`** (BeforeIdentity, after `bookmarks`; resumable; pages of ≤ 500; never flag-gated):
    - delete the user's own lists (`ownerId == uid`);
    - then remove the uid from other users' lists (`memberIds array-contains uid`, `ArrayRemove` + `memberCount` −1, guarded by `LastUpdateTime`).
  - **Export section `lists`:** own lists with name, description, private and member ids.
  - **T11:** a `lists` row in `lifecycle_collections_guard_test.go`, the residue sweep fields `ownerId` and `memberIds`, and the `lifecycle_wiring_test.go` lists.
  - `homeTabs` lives on `users/{uid}` and goes with it; dangling pins to deleted lists are dropped lazily by GetMe (W5-9).
  - **Runbook `docs/runbooks/lists.md`:** the kill switch, caps, a stuck eraser page, the F4 rule, and how to hide an abusive public list (W5-29).
- **Acceptance criteria.**
  - Given a user who owns 2 lists and is a member of 3 others, when the account is erased, then their 2 lists are gone, the 3 lists no longer name them, the counts are right, and a rerun writes 0.
  - Given the export, then the `lists` section matches the golden file.
  - Given the guard test, then it passes with the new constant.
- **Test notes.** Emulator lifecycle and residue sweep; resume from a checkpoint mid-page.
- **Observability.** The existing `account_job` line with `step=lists`, `docs_deleted` and `docs_updated`.
- **Budget.** 1 read + 1 delete per own list; 1 read + 1 write per list they are on; 1 read when empty.
- **Flag.** None (never flag-gated).
- **Seam.** `lists.Eraser` / `lists.Exporter` behind identity's `StepEraser` / `ExportSection` adapters.
- **Parallel with W3 Part A / W4:** lifecycle wiring files serialise with W4-9's guard row and W3-32.

### W5-6 — List members  [owner: backend-developer] [size: S] [depends: W5-4]  Status: In review
- **Description.**
  - **AddListMember**, owner only. The target must exist and be ACTIVE (`identity.Directory`, cached), and must not block or be blocked by the caller (the caller graph has both directions; the overflow rule fails closed). Inside the transaction: `quotas.listAdds`, the cap 150 and `ArrayUnion` + `memberCount`. Adding an existing member is success with 0 writes.
  - **RemoveListMember:** `ArrayRemove`; a missing member is success with 0 writes.
  - Both lazily drop members found in the owner's `blockedBy` (F4) in the same write.
  - The instance cache is updated from the written data.
- **Acceptance criteria.**
  - Given a list at 150, then LIMIT_REACHED `limit=list_members`.
  - Given a target who blocks the caller, then NOT_FOUND byte-identical to a missing user.
  - Given a replay, then 0 writes.
  - Given 301 adds in a day, then QUOTA_EXCEEDED.
- **Test notes.** `budgettest` 5 / 2; the block matrix; the cap; concurrency (two adds race at 149).
- **Observability.** `list_op=add
- **Built as (W5-6).** The proto and ADR-0030 win over the wording above: no stored `memberCount` (it is `len(memberIds)`); a no-op add or remove writes the idempotency doc only (1 write, not 0); the whole `memberIds` array is written (not `ArrayUnion`) so the lazy drop shares the write. Target verdict is computed before the transaction and applied after the idempotency and ownership reads (a replay still answers). Measured service reads (interceptor excluded): add 5 cold / 6 on overflow, already-member 4, replay 3, remove 3 (graph read only for a real removal), non-member 2, remove replay 1. Warm floor of the service is 3 (idempotency, list, quotas), not 2.|remove`, outcome, `fs_reads`, `fs_writes`.
- **Budget.** Add 5 cold / 2 warm, 2 writes; Remove 2 / 1, 1 write.
- **Flag.** `FEATURE_LISTS`.
- **Seam.** Block checks only through `graph.Reader.Snapshot`; the users check only through `identity.Directory`.
- **Parallel with W3 Part A / W4:** yes.

### W5-7 — List reads  [owner: backend-developer] [size: M] [depends: W5-4]  Status: In review (PR #518)
- **Description.**
  - **GetList:** private → NOT_FOUND for non-owners. A non-owner viewer also reads the owner graph for F4. `hidden` (W5-29) → NOT_FOUND for non-owners. `pinned_by_viewer` comes from the caller's `homeTabs` (0 reads).
  - **ListUserLists(owner, contains_user_id):** non-owners see only public, non-hidden lists. `contains` is computed from `memberIds` at 0 reads.
  - **ListListMembers:** a page of `memberIds` → `identity.Directory` GetMany (cache-first) → drop non-ACTIVE users and the D6 / F4 drops → `Relationship` from the caller graph. Sealed cursor (position plus `updatedAt`), 24 h.
  - **`lists.Reader.Members(ctx, viewer, listID)`** for the timeline: visibility applied, members minus the F4 drops, cached 60 s.
- **Acceptance criteria.**
  - Given a private list, then the owner sees it and others get NOT_FOUND, byte-identical to a missing id.
  - Given a member who blocks the viewer, then they are absent from that viewer's page.
  - Given a member who blocks the owner, then absent for everyone.
  - Given a tampered token, then VALIDATION with 0 reads.
- **Test notes.** `budgettest` per the table; visibility and block matrices; cursor binding.
- **Observability.** `list_op=get|user_lists|members`, `rows_dropped` by cause, `cache_hit`, `fs_reads`.
- **Budget.** GetList 3 / 0–1; ListUserLists ≤ 22; ListListMembers 24 / 54 cold. **As built, ADR-0030 numbers (these supersede the line above; they include the owner-profile read that D3 needs and the interceptor):** GetList 5 non-owner / 2 owner; ListUserLists 24 another owner / 21 own; ListListMembers 25 / 55 (page 20 / 50) non-owner, 23 / 53 owner. The emulator tests assert them exactly, minus the interceptor.
- **Flag.** `FEATURE_LISTS`.
- **Seam.** `lists.Reader` is the only way timeline reads a list.
- **Parallel with W3 Part A / W4:** yes.

### W5-8 — `GetListTimeline`  [owner: backend-developer] [size: M] [depends: W5-7]  Status: Open
- **Description.** In a new `backend/internal/timeline/service_list.go`:
  - `lists.Reader.Members` → authors minus `allowedAuthor` drops;
  - `removedIDs(ctx, tok, authors)` (scoped to the members, ≤ 180 authors so the window query applies);
  - `homeSources(ctx, authors, tok, limit, start)`;
  - `Merge` with Home's `keep` (`isPublic`, `allowedAuthor`, `embedAllowed`) plus the ADR-0025 hook point;
  - `toViews`;
  - `tokens(listFeed(uid, listID), ...)`.

  The list header (`List`) is in the response at 0 extra reads. `tokens.go` gets `listFeed` (`list|<uid>|<listId>`). A NOT_FOUND list → NOT_FOUND. An empty list → empty page with tokens. Rate limit `RATE_LIMIT_LIST_TIMELINE_PER_MIN`. **No new merge, cursor or cache.**
- **Acceptance criteria.**
  - Given a list of 45 members, then 2 chunks and the Home order.
  - Given a `since` refresh with 0 new, then 3 + C reads (owner, cold).
  - Given a member muted by the viewer, then their posts are dropped.
  - Given a Home token sent to the list, then VALIDATION with 0 reads.
  - Given a moderator takedown of a member's post after the token, then it is in `removed_ids` (with `removed_ids` on).
  - Given 150 members at page 50, then reads ≤ 110 (≤ 217 with the window query).
- **Test notes.** Emulator `budgettest` at the table's worst and planning values; the author-recent cache shared with Home (a warm Home makes the list refresh cheaper); token binding and kind; gap tokens; a list made private between pages → NOT_FOUND.
- **Observability.** `timeline_op=list`, `list_members`, `timeline_chunks`, `authors_from_cache`, `items_returned`, `items_filtered`, `gap`, `fs_reads`.
- **Budget.** As the Non-functional table; writes 0.
- **Flag.** `FEATURE_LISTS` + `posts`; `removed_ids` as for Home.
- **Seam.** The merge stays behind the `timeline` interface; the opaque, versioned token. The Stage 2 fan-out replaces `homeSources` with no client change.
- **Parallel with W3 Part A / W4:** new file; the `server.go` Deps and `tokens.go` bindings serialise with W3-9.

### W5-9 — Home tabs  [owner: backend-developer] [size: M] [depends: W5-3, W5-7]  Status: Open
- **Description.**
  - **SetHomeTabs(tabs)**, in timeline:
    - at most `HOME_TABS_MAX_PINNED`, no duplicates;
    - each LIST must be readable by the caller (`lists.Reader`, cached), and each COMMUNITY is validated once W5-27 wires `communities.Reader` (VALIDATION `field=tabs` until then);
    - kinds whose flag is off for the caller → FEATURE_DISABLED;
    - titles are trimmed snapshots.
  - It writes `users/{uid}.homeTabs` field-level through `timeline.HomeTabsStore`, implemented by identity in a new identity file (no change to `UpdateProfile`), then evicts the caller's profile cache. An identical write is skipped (0 writes).
  - `GetMe` returns `home_tabs`, dropping entries whose flag is off for the caller (0 reads; it is the same doc). Dangling ids stay until the next SetHomeTabs; the client shows them as unavailable.
  - The export profile section includes `home_tabs`; deletion needs no new step.
- **Acceptance criteria.**
  - Given 6 pinned tabs, then LIMIT_REACHED `limit=home_tabs`.
  - Given another user's private list, then VALIDATION `field=tabs`, the same as a missing list.
  - Given the same order again, then 0 writes.
  - Given `lists` off for the caller, then GetMe omits LIST tabs.
  - Given GetMe, then +0 reads.
- **Test notes.** `budgettest` 7 / 1; the flag matrix; the export golden file; identity's existing GetMe tests are unchanged.
- **Observability.** `timeline_op=set_home_tabs`, `tabs`, `fs_reads`, `fs_writes`.
- **Budget.** ≤ 7 reads, 1 write.
- **Flag.** `FEATURE_LISTS` or `FEATURE_COMMUNITIES` per entry.
- **Seam.** `timeline.HomeTabsStore` (consumer-side), so storage can move (A4) without touching timeline callers.
- **Parallel with W3 Part A / W4:** identity files after W3-6 (profile write) and W4-4 (`identity/api.go`).

### W5-10 — Client data layer A  [owner: frontend-developer] [size: S] [depends: W5-3]  Status: Done (#517)
- **Description.**
  - `ListsRepository` over the generated client, with friendly mapping of FEATURE_DISABLED, LIMIT_REACHED, QUOTA_EXCEEDED, RATE_LIMITED and NOT_FOUND.
  - `HomeTabsRepository`: reads `GetMe.home_tabs`, writes SetHomeTabs optimistically with rollback, and keeps a local title override from the latest list header.
  - `FeedKey.list(id)` (drift key `list:<id>`; the server token is bound to the same feed).
  - `kFeatureLists` from `enabled_features`.
- **Acceptance criteria.**
  - Given FeedKey `list:1`, then a separate cached feed from Home.
  - Given SetHomeTabs fails, then the old order is restored.
  - Given sign-out, then session state clears (`SessionEpoch`).
- **Test notes.** Unit tests; drift migration if the key format needs one (schema bump noted in `ui-catalog.md`).
- **Observability.** —
- **Budget.** 0 RPCs by itself.
- **Flag.** `lists` (client gate).
- **Seam.** The repositories are the only RPC callers; `TimelineCubit` stays generic over `FeedKey`.
- **Parallel with W3 Part A / W4:** `feed_key.dart` serialises with W3-16.

### W5-11 — Lists screen and create/edit  [owner: frontend-developer] [size: M] [depends: W5-10]  Status: Done (PR pending)
- **Description.** `/lists` (`AppBackHeader` "Lists" with a "Create a new List" icon button):
  - the "Your Lists" section (`AppSectionHeader`);
  - rows with a 48 dp rounded default tile, a bold name, "· N members" in muted text, and a lock icon when private (`lists.md` §3, MEASURED);
  - the empty sentence centred in muted text (`lists.md` §4; our own copy).

  A create/edit sheet (full-screen below 600 dp, dialog above) with name (25) and description (100) counters, a Private switch (default on, F3), Save, and Delete with a confirm. Friendly text for caps and quota.

  Navigation: a "Lists" row in `AppDrawer` and a desktop rail destination, needing `lists` + `ui_shell`.

  Not built (F10): the search pill and "Discover new Lists".
- **Capture.** The index is MEASURED (desktop and 500 dp). The create flow is **UNKNOWN**; X-like defaults.
- **Acceptance criteria.**
  - Given `lists` off, then no row and the route redirects Home.
  - Given 20 lists, then Create is disabled with the reason.
  - Given a private list, then the lock icon shows.
- **Test notes.** Widget tests at 360 / 600 / 1200, light and dark, text scale 1.0 / 1.3 / 2.0; flag-off routing.
- **Observability.** —
- **Budget.** 1 ListUserLists per open.
- **Flag.** `lists` + `ui_shell` (nav entry); `lists` (route).
- **Seam.** `ListsCubit` over `ListsRepository`; a shared `AppTileIcon` (default tile) goes in `app/lib/shared/widgets` and is reused by W5-31.
- **Parallel with W3 Part A / W4:** shell nav files serialise with W4-17.

### W5-12 — List detail  [owner: frontend-developer] [size: M] [depends: W5-10]  Status: Open
- **Description.** `/lists/:id`:
  - a header with the name, description, owner row, "N members" (→ `/lists/:id/members`), Pin / Unpin to Home and, for the owner, Edit;
  - the list timeline as `TimelineFeedView` over a `TimelineCubit(FeedKey.list(id))` (pill, gaps, prefetch, `removed_ids`);
  - the members page: `PagedUserList` with `FollowButton`, plus Remove for the owner;
  - NOT_FOUND → "This List is unavailable" with Unpin when pinned.
- **Capture.** The list detail is **UNKNOWN**; the header follows the profile header's type scale.
- **Acceptance criteria.**
  - Given a refresh, then `since_token` is sent.
  - Given Pin, then SetHomeTabs and the tab appears.
  - Given 5 pinned, then Pin is disabled with a hint.
  - Given a non-owner, then no Edit or Remove.
- **Test notes.** Widget tests at 3 widths, light and dark, 3 text scales; the unavailable state.
- **Observability.** —
- **Budget.** Per the cost table (list timeline calls, member pages).
- **Flag.** `lists`.
- **Seam.** It reuses `TimelineFeedView` / `TimelineCubit` unchanged except for `FeedKey`.
- **Parallel with W3 Part A / W4:** yes.

### W5-13 — "Add to Lists" and a user's lists  [owner: frontend-developer] [size: S] [depends: W5-11, W3-14]  Status: Open
- **Description.**
  - On another user's profile overflow menu, "Add/remove from Lists" opens a sheet of your lists with checkboxes, from `ListUserLists(self, contains_user_id)`. Toggles call Add or Remove one at a time with rollback.
  - "View Lists" opens `/u/:id/lists` (their public lists).
  - Hidden for your own profile.
- **Acceptance criteria.**
  - Given a list that contains the user, then it is checked.
  - Given LIMIT_REACHED, then the toggle rolls back with the reason.
  - Given `lists` off, then no menu rows.
- **Test notes.** Widget tests at 3 widths.
- **Observability.** —
- **Budget.** 1 ListUserLists per sheet open; Add or Remove per toggle.
- **Flag.** `lists`.
- **Seam.** Through `ListsRepository` only.
- **Parallel with W3 Part A / W4:** **after W3-13 / W3-14** (`profile_header.dart`).

### W5-14 — Home tab bar and Manage pinned  [owner: frontend-developer] [size: M] [depends: W5-10, W5-12]  Status: Open
- **Description.**
  - The Home header's `AppTabBar` becomes content-sized and scrollable: Following first and fixed, then pinned tabs in order, then a trailing "+" (`home.md` §3: tabs content-sized, 4 dp accent bar).
  - Each tab is a lazily created, kept-alive `TimelineFeedView` + `TimelineCubit` (Following = `FeedKey.home`, a list = `FeedKey.list`, a community = `FeedKey.community` once W5-30 lands).
  - "+" opens `/home/pinned` (Manage pinned): reorderable rows, Unpin, and "Add" from your lists (and, with `communities`, your communities); saved through `HomeTabsRepository`.
  - The legacy chrome (`ui_shell` off) keeps the single Following header.
- **Capture.** Tabs MEASURED; the "Manage timelines" dialog is **UNKNOWN** (our own screen).
- **Acceptance criteria.**
  - Given 2 pinned lists, then 3 tabs, and each keeps its scroll and cache across switches.
  - Given a reorder, then one SetHomeTabs.
  - Given `lists` off, then only Following.
  - Given an unavailable pinned list, then the tab shows the unavailable state with Unpin.
- **Test notes.** Widget tests at 360 / 600 / 1200, light and dark, 3 text scales; keyboard arrows across tabs; reorder semantics.
- **Observability.** —
- **Budget.** 0 extra calls at startup (GetMe); 1 list-timeline call per first visit to a tab per session, then refreshes ≥ 60 s apart.
- **Flag.** `lists` / `communities` per tab, plus `ui_shell`.
- **Seam.** Tabs are data (a list of `HomeTab` descriptors fed to one scaffold), so a new kind adds no scaffold code.
- **Parallel with W3 Part A / W4:** `home_screen.dart` serialises with W3-19.

### W5-15 — Part A backend tests  [owner: tester] [size: M] [depends: W5-6 to W5-9]  Status: Open
- **Description.** Emulator integration:
  - flag modes for `lists`;
  - the authz matrix (owner / other / private / hidden / blocked both ways / overflow);
  - caps and quotas;
  - replays at 0 writes;
  - `budgettest` per the W5-1 table, including GetListTimeline at 150 members page 50 and the window-query path;
  - token binding (Home vs list vs user, foreign uid);
  - the D6 drop matrix on list timelines;
  - SetHomeTabs validation and GetMe at +0 reads;
  - eraser, export and residue sweep.

  Coverage on `internal/` stays at 70 % or more.
- **Acceptance criteria.** Every acceptance criterion in W5-4 to W5-9 has a named test; `make test-int` is green.
- **Test notes.** Load shapes: a 150-member list with all members posting, and a viewer switching 6 tabs a minute (with W5-18).
- **Observability.** —
- **Budget.** 0 (emulators).
- **Flag.** Under test: `lists` in every mode.
- **Seam.** —
- **Parallel with W3 Part A / W4:** yes.

### W5-16 — Part A client tests  [owner: tester] [size: S] [depends: W5-11 to W5-14]  Status: Open
- **Description.** The responsive matrix and flows: Lists → create → detail → pin → Home tab → reorder → unpin; flag combinations (`lists` × `ui_shell`); sign-out clears state; text scale 2.0 overflow checks.
- **Acceptance criteria.** Every new widget is covered at 360 / 600 / 1200, light and dark; no overflow at 2.0.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Under test: `lists` × `ui_shell`.
- **Seam.** —
- **Parallel with W3 Part A / W4:** yes.

### W5-17 — Part A security review  [owner: security-auditor] [size: S] [depends: W5-6 to W5-9, W5-13]  Status: Open
- **Description.** A threat model for:
  - private-list confidentiality (NOT_FOUND identity, caches keyed safely, the export);
  - id guessing;
  - member-page scraping (page ≤ 50, rate × 3 instances, read budget);
  - the block oracle in Add and in member pages;
  - harassment via public lists (F3, F4 defaults);
  - pinned tabs as a stored-reference leak (a private list's title in another user's tabs: only the owner can pin it);
  - log hygiene.

  Findings are fixed or ticketed before any dev allowlist.
- **Acceptance criteria.** A report in `docs/reviews/` with no open Critical or High findings.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Reviews the `lists` gate.
- **Seam.** Checks the rate-limit multiplication and the `stage-ladder` author-`in` scraping vector.
- **Parallel with W3 Part A / W4:** yes.

### W5-18 — Part A cost and performance budget  [owner: sre-performance] [size: S] [depends: W5-8, W5-9]  Status: Open
- **Description.**
  - Add the Part A rows (+22.1 reads, +0.51 writes, +2.3 requests per DAU) to `docs/reviews/cost-model.md` §2-§5 as a W5 block, additive like W2's.
  - Run an emulator load smoke, `make loadtest SCENARIO=list_timeline`: a cold page, a refresh with 0 and with 5 new, 150 members at page 50, and the author-recent cache shared with Home.
  - Measure the p95 against 400 ms (emulator, indicative only).
  - Name the trigger: list timeline reads > 15 % of daily reads for 7 days.
- **Acceptance criteria.** The model is updated with measured reads per call (± 25 % of this plan, or the plan's table corrected), and a k6 script is added under `loadtest/`.
- **Test notes.** —
- **Observability.** A Logs Explorer query for `timeline_op=list` and `fs_reads` in `cost-model.md` §9 (no new log-based metric or alert policy).
- **Budget.** 0 (emulators, no cloud load test).
- **Flag.** n/a.
- **Seam.** —
- **Parallel with W3 Part A / W4:** yes.

### W5-19 — Part A dev rollout  [owner: production-deployer] [size: S] [depends: W5-15, W5-17, W5-18, ADR-0030 merged]  Status: Open
- **Description.**
  - Show the founder a **targeted** dev Terraform plan for `feature_lists*` and the list config env vars (`docs/plans/roadmap.md` section 9, item 3.10: a full dev apply is unsafe).
  - Apply only on OK, with an allowlist of 3 test uids.
  - Smoke: create a list, add 3 members, open the timeline, pin it, reorder, unpin, delete, turn the flag off.
  - Prod: no change.
- **Acceptance criteria.** The dev smoke passes; the flag is back to its planned state.
- **Test notes.** —
- **Observability.** Check the `timeline_op=list` and `list_op` lines in dev logs.
- **Budget.** A handful of reads inside dev's free quota.
- **Flag.** Dev: `feature_lists` set to allowlist (3 uids); prod stays `off`.
- **Seam.** —
- **Parallel with W3 Part A / W4:** serialise dev applies with W3-24 / W4-24.

### W5-20 — ADR "Communities and their moderation scope at Stage 0"  [owner: architect] [size: M] [depends: —]  Status: Open
- **Description.** `docs/adr/0028-communities-and-moderation-scope.md` (Proposed), or the next free number. It decides:
  - F1 and F6 to F13;
  - the collections (`communities/{cid}`, `communities/{cid}/communityMembers/{uid}`, `communityMemberships/{uid}`) and doc shapes;
  - the feed query (A1, **with the dev Firestore check recorded**; an emulator run does not count);
  - the posting gate (A2), removals (A3), memberships (A6), the reply rule (A7) and owner deletion (A8);
  - the moderation scope and what platform moderation overrides;
  - caches (A9), the per-RPC cost table above, the flag and creation allowlist, the eraser and export;
  - the `stage-ladder` rows (A11).

  In the same PR: the `stage-ladder` "Community feed" and "Community moderation" rows, `firestore-data-model` rows, and the `quotas` fields `communityJoins` / `communityPosts`.
- **Acceptance criteria.**
  - Given the ADR, then F1 and F6 to F13 each have options, a default and an INR line at 300 / 1,000 / 3,000 DAU citing `cost-model.md`.
  - Given A1, then the ADR records the result of the query run against the dev Firestore (who ran it, when, each of the three forms) and, if any form failed, names the exact composite index as a founder-gated change in W5-21. An emulator result alone fails this criterion.
  - Given the moderation scope, then it lists every moderator power, every limit, and what platform moderation overrides.
- **Test notes.** None (docs).
- **Observability.** The ADR lists the log fields: `community_op`, `timeline_op=community`, `mod_action`, `rows_dropped` by cause, `fs_reads`.
- **Budget.** The ADR's table is the source for W5-23 to W5-29.
- **Flag.** None (docs); it names `FEATURE_COMMUNITIES`, its ceiling and `COMMUNITY_CREATORS`.
- **Seam.** It defines `communities.Service`, `communities.Reader`, `communities.Moderation`, `posts.CommunityGate`, `posts.Reader.ByCommunity` and `posts.CommunityModerator` (the `communityHidden` writer).
- **Parallel with W3 Part A / W4:** yes.

### W5-21 — Part B protos  [owner: architect] [size: S] [depends: W5-20 drafted]  Status: Open
- **Description.** All additive.
  - New `proto/dzeroth/communities/v1/communities.proto`, `CommunityService`:
    - CreateCommunity(idempotency_key, name, description, rules);
    - UpdateCommunity;
    - GetCommunity → `Community {id, name, description, rules, member_count, status, viewer_role, moderators (≤ 10 UserListItem)}`;
    - ListCommunities (directory, ≤ 50);
    - ListMyCommunities (→ communities + `can_create`);
    - JoinCommunity / LeaveCommunity;
    - ListCommunityMembers(page, `role_filter`);
    - HideCommunityPost / RestoreCommunityPost;
    - SetMemberRole(BAN, UNBAN, MAKE_MODERATOR, REMOVE_MODERATOR);
    - ListModerationLog.
  - `posts.proto`: `CreatePostRequest.community_id`, `Post.community` (`CommunityRef {id, name}`); a `SchedulePost` comment says `community_id` is not accepted.
  - `moderation.proto`: `REPORT_TARGET_TYPE_COMMUNITY`, `REPORT_TARGET_TYPE_LIST`.
  - `timeline.proto`: `GetCommunityTimeline(community_id, page_size, page_token, since_token)` → the Home response shape + `Community` header; `HomeTab` kind COMMUNITY (it exists from W5-2).
  - If A7 decides so, the `ReplyPermission` value.
  - If A1 failed: the composite index `posts (communityId ASC, createdAt DESC)` in `firebase/firestore.indexes.json` (**founder-gated**). It is a composite entry only, and `scripts/promotion/check-field-overrides.sh` hashes `fieldOverrides` alone, so `firebase/field-overrides.ack` needs **no** re-hash; if the ADR adds any fieldOverride, it does.
- **Acceptance criteria.**
  - `buf breaking` is clean.
  - Every RPC comment carries its W5-20 budget and errors: FORBIDDEN `reason=banned|not_member|not_moderator`, NOT_FOUND byte-identical, LIMIT_REACHED, FEATURE_DISABLED `feature=communities`.
- **Test notes.** `buf breaking`.
- **Observability.** —
- **Budget.** Copied from W5-20.
- **Flag.** None (contract).
- **Seam.** Role and action enums are additive; cursors are opaque; the community `visibility` enum holds PUBLIC only.
- **Parallel with W3 Part A / W4:** `timeline.proto` after W5-2 and W3-2; the index file only if needed, one index PR at a time.

### W5-22 — Generate, `FEATURE_COMMUNITIES`, config, module skeleton  [owner: backend-developer] [size: M] [depends: W5-21]  Status: Open
- **Description.** As W5-3, for:
  - `FEATURE_COMMUNITIES` (wire `communities`);
  - `COMMUNITY_CREATORS` (≤ 10 uids, validated with `ids.ValidUID`);
  - the community caps and rate limits from the abuse section, `CACHE_COMMUNITIES_ENTRIES` 2,000, `CACHE_COMMUNITY_FEED_ENTRIES` 500;
  - `quota.Record` `communityJoins` / `communityPosts` with tiers;
  - `flag-ceiling.json` `COMMUNITIES` dev allowlist 6 (every flag since #463) (**founder-gated**);
  - Terraform `feature_communities*` and `community_creators`, default `off` / empty;
  - the `internal/communities` skeleton (no collection constant);
  - the timeline handler stub;
  - `CreatePost.community_id` → FEATURE_DISABLED while off.
- **Acceptance criteria.**
  - Given the flag unset, then every community RPC and `community_id` → FEATURE_DISABLED `feature=communities` with 0 reads.
  - Given an invalid uid in `COMMUNITY_CREATORS`, then startup fails.
  - `check-flag-registry.sh` passes.
- **Test notes.** The flag matrix; config bounds; the quota `Record` round trip.
- **Observability.** The startup flag line lists `communities`; the creators count (not the uids) is logged.
- **Budget.** 0 on the rejection paths.
- **Flag.** Adds `FEATURE_COMMUNITIES`.
- **Seam.** `communities.Service`.
- **Parallel with W3 Part A / W4:** shared plumbing files one PR at a time (after W5-3).

### W5-23 — Communities write path  [owner: backend-developer] [size: M] [depends: W5-22]  Status: Open  (**ships in one PR with W5-24**)
- **Description.** `communities.FirestoreRepo` owns:
  - `communities/{cid}` (Snowflake): `name`, `description`, `rules[]`, `ownerId`, `moderatorIds[]`, `memberCount`, `status` (ACTIVE / ARCHIVED / SUSPENDED), `visibility` (PUBLIC), `recentRemovals[]`, `modlog[]`, `createdAt`, `updatedAt`;
  - `communities/{cid}/communityMembers/{uid}`: `uid`, `role`, `joinedAt`;
  - `communityMemberships/{uid}`: `joined[]`, `banned[]`, `owned[]`, `modlogged[]` (A6; written from W5-28 on).

  RPCs:
  - **CreateCommunity:** `COMMUNITY_CREATORS` check first (FORBIDDEN, 0 reads); then idempotency, the owned and joined caps, quotas; it writes the community, the owner's member doc and the memberships doc in one transaction.
  - **UpdateCommunity:** owner only, with a modlog entry.
  - **GetCommunity:** `viewer_role` from the member doc, cached; SUSPENDED → NOT_FOUND for non-owners; ARCHIVED readable.

  Text rules as the bio.
- **Acceptance criteria.**
  - Given a caller not in `COMMUNITY_CREATORS`, then FORBIDDEN with 0 reads.
  - Given 2 owned, then LIMIT_REACHED `limit=communities_owned`.
  - Given a replay, then 0 writes.
  - Given 11 rules, then VALIDATION `field=rules`.
- **Test notes.** Emulator `budgettest`; replay; the text tables.
- **Observability.** `community_op`, outcome, `fs_reads`, `fs_writes`; never names or ids.
- **Budget.** Create 5 / 3 reads, 5 writes; Update 3 / 1; Get 3 / 0–1.
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** `communities.Service`; only `communities` touches its collections.
- **Parallel with W3 Part A / W4:** yes (new package).

### W5-24 — Communities lifecycle  [owner: backend-developer] [size: M] [depends: W5-22]  Status: Open  (**ships in one PR with W5-23**)
- **Description.**
  - **Eraser step `communities`** (BeforeIdentity, resumable, never flag-gated). For each community in the user's memberships doc (`joined`, `banned`, `owned`, `modlogged`, de-duplicated):
    - delete the member doc and decrement `memberCount` (only for a `joined` entry);
    - remove the uid from `moderatorIds`;
    - scrub modlog entries that name the uid as actor or target (the actor field is replaced by a "deleted account" marker, so the owner still sees that an action happened);
    - for an owned community, hand over to the longest-serving moderator, or archive it and clear `ownerId` (F12, A8).

    Then delete `communityMemberships/{uid}`. The user's community posts go with the posts eraser as today.
  - **Export section `communities`:** memberships, roles, owned communities (name, description, rules).
  - **T11** rows `communities`, `communityMembers` (a subcollection of `communities`; the residue sweep's scan uses the `uid` field on the emulator) and `communityMemberships`; residue fields `ownerId`, `moderatorIds`, `modlog` (actor and target), `uid`.
  - **Runbook `docs/runbooks/communities.md`:** kill switch, creators list, caps, a stuck eraser, hand-over, suspension (W5-29), hidden posts and `recentRemovals` overflow.
- **Acceptance criteria.**
  - Given an owner with one moderator, then the moderator becomes owner and the counts are right.
  - Given an owner without moderators, then the community is ARCHIVED with an empty `ownerId`.
  - Given a rerun, then 0 writes.
  - Given a moderator who hid a post, left the community, then deleted the account, then that community's modlog no longer names the uid.
  - Given the residue sweep, then no field names the uid.
- **Test notes.** The emulator lifecycle and residue sweep; resume mid-community; a banned member's deletion; a former moderator's deletion (the `modlogged` path).
- **Observability.** `account_job` with `step=communities`, `memberships`, `handovers`, `archived`.
- **Budget.** Per membership: 2 reads (member doc, community) and 2–3 writes or deletes; the memberships doc 1 read + 1 delete.
- **Flag.** None (never flag-gated).
- **Seam.** `communities.Eraser` / `Exporter` through identity's adapters.
- **Parallel with W3 Part A / W4:** lifecycle wiring files serialise (after W5-5).

### W5-25 — Join, leave and My Communities  [owner: backend-developer] [size: M] [depends: W5-23]  Status: Open
- **Description.**
  - **JoinCommunity:** one transaction. ACTIVE community, not BANNED, joined cap 50, `quotas.communityJoins`; it writes the member doc, memberships, `memberCount` Increment and quotas. Already a member → 0 writes.
  - **LeaveCommunity:** not the owner; it deletes the member doc, removes the community from `joined` (it stays in `modlogged` if present), decrements `memberCount` and, **when the leaver is a moderator, removes the uid from `moderatorIds`** in the same transaction, with a modlog entry.
  - **ListMyCommunities:** the memberships doc + `GetMany` of the community docs (cache-first), plus `can_create` from config.
  - Member-doc instance cache (60 s) with eviction on this instance's writes.
- **Acceptance criteria.**
  - Given a banned user, when they Join, then FORBIDDEN `reason=banned`.
  - Given the owner, when they Leave, then FAILED_PRECONDITION `reason=owner`.
  - Given a moderator who leaves, then they are no longer in `moderatorIds` and GetCommunity no longer lists them.
  - Given 51 joins, then LIMIT_REACHED.
  - Given `memberCount` under a 10-join burst, then it is exact.
- **Test notes.** `budgettest`; join and leave races; a counter `ABORTED` metric check (stage-ladder counters).
- **Observability.** `community_op=join|leave|my`, `cache_hit`, `fs_reads`.
- **Budget.** As the per-RPC table (Join 5 / 4, Leave 3 / 2, ListMyCommunities ≤ 52).
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** Counters through the one helper; the member cache sits behind `communities.Reader`.
- **Parallel with W3 Part A / W4:** yes.

### W5-25b — Directory and member list  [owner: backend-developer] [size: S] [depends: W5-25]  Status: Open
- **Description.**
  - **ListCommunities:** `orderBy memberCount desc Limit(50)` (automatic index), non-ACTIVE filtered in memory (a short list is allowed), a shared instance entry (5 min).
  - **ListCommunityMembers:** a `communityMembers orderBy joinedAt desc` page, `identity.Directory` hydration (cache-first), D6 drops for the viewer, `Relationship` from the caller graph. BANNED rows only for moderators (`role_filter`, a `role == BANNED` equality query on the automatic index). Sealed cursor bound to `community_members|<uid>|<cid>`, 24 h.
- **Acceptance criteria.**
  - Given a SUSPENDED or ARCHIVED community, then it is absent from the directory.
  - Given a warm directory entry, then 0–1 reads.
  - Given a member who blocks the viewer, then absent from that viewer's page.
  - Given a member asking for BANNED rows, then FORBIDDEN `reason=not_moderator`.
  - Given a tampered token, then VALIDATION with 0 reads.
- **Test notes.** `budgettest` (directory 51 cold / 0–1 warm; members 24 / 54 cold); cursor binding.
- **Observability.** `community_op=directory|members`, `rows_dropped` by cause, `cache_hit`, `fs_reads`.
- **Budget.** As the per-RPC table.
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** `communities.Directory` behind an interface (the W4 engine replaces it later).
- **Parallel with W3 Part A / W4:** yes.

### W5-26 — Posting into a community  [owner: backend-developer] [size: M] [depends: W5-23, W5-25]  Status: Open
- **Description.**
  - **`posts.CommunityGate`** (consumer-side, implemented by communities) inside CreatePost's transaction for a root post or quote with `community_id`:
    - the community is ACTIVE;
    - the caller is a member and not BANNED (member doc read **fresh** in the transaction);
    - `quotas.communityPosts` is reserved in the existing quota write;
    - the per-`(uid, cid)` `DailyCap`.
  - The post doc gets `communityId` and `community {id, name}`.
  - `community_id` on a reply → VALIDATION (replies follow the root). SchedulePost with `community_id` → VALIDATION.
  - `posts.Reader.ByCommunity(ctx, cid, window, limit)`: A1's query, root posts only, Limit 1..50.
- **Acceptance criteria.**
  - Given a non-member, then FORBIDDEN `reason=not_member` and 0 writes.
  - Given a ban on another instance a second ago, then the next post is refused (fresh read).
  - Given 51 community posts in a day, then QUOTA_EXCEEDED `limit_name=community_posts`.
  - Given SchedulePost with `community_id`, then VALIDATION.
  - Given `ByCommunity` on 25 posts, then pages of 20 + 5, newest first (functional on the emulator; the index question is settled only by A1's dev check or the W5-21 index).
- **Test notes.** Emulator `budgettest` (+2 / +1 reads over CreatePost, +0 writes); the A1 query shapes (since, page); the existing CreatePost tests unchanged.
- **Observability.** The CreatePost log line gains `community_post` (bool) and `community_gate` outcome.
- **Budget.** +2 cold / +1 warm reads, +0 writes.
- **Flag.** `FEATURE_COMMUNITIES` (with `posts`).
- **Seam.** `posts.CommunityGate` and `posts.Reader.ByCommunity`; posts never imports communities.
- **Parallel with W3 Part A / W4:** **after W3-7** (`hasMedia` on every create path).

### W5-26b — Members-only replies and the label kill switch  [owner: backend-developer] [size: S] [depends: W5-26]  Status: Open
- **Description.**
  - **Members-only replies (F8):** in the reply path, when the root has `communityId` (the root is already read), `CommunityGate.CanReply` reads the member doc (cached 60 s); a non-member or BANNED caller gets FORBIDDEN `reason=not_member`. `viewer_reply_permission` reports it per A7 (an additive enum value if the ADR decides so; UNKNOWN on timelines where it would need a read, as ADR-0021 D2 does).
  - `ToView` omits `community` when `communityHidden` is set or `communities` is globally off (`Registry.GloballyOff`, 0 reads).
- **Acceptance criteria.**
  - Given a reply by a non-member to a community post, then FORBIDDEN and 0 writes.
  - Given a reply by a member, then accepted with +1 cold / +0 warm reads.
  - Given a reply to a non-community post, then +0 reads (the existing reply tests unchanged).
  - Given `communities` globally off, then no `PostView` carries `community`.
- **Test notes.** `budgettest` on the reply path; a hidden post's `PostView` on every builder (GetPost, GetThread, both timelines, ListBookmarks).
- **Observability.** The reply log line gains `community_reply_gate` outcome.
- **Budget.** Replies into a community conversation +1 cold / +0 warm reads; 0 writes.
- **Flag.** `FEATURE_COMMUNITIES` + `replies`.
- **Seam.** `posts.CommunityGate.CanReply`; the label decision lives only in `ToView`.
- **Parallel with W3 Part A / W4:** the reply path after W3-7; `ToView` is shared with W3 builders, so rebase.

### W5-27 — `GetCommunityTimeline` and community tabs  [owner: backend-developer] [size: M] [depends: W5-26, W5-9]  Status: Open
- **Description.** A new `backend/internal/timeline/service_community.go`:
  - `communities.Reader.Get(cid)` (status, header, `recentRemovals`);
  - a shared **community entry** (newest 30 posts per community, `cache.LRU`, 60 s, shared across viewers) for cold and page 1;
  - `ByCommunity` for older pages and `since`;
  - `keep` = `isPublic`, not `communityHidden`, `allowedAuthor` for the viewer, `embedAllowed` (overflow fails closed), plus the ADR-0025 hook;
  - `next_page_token` follows the query, not the filtered count;
  - `removed_ids` = `recentRemovals` newer than the token. A token older than the oldest entry while the array is full is rejected like an expired token (A3).

  `tokens.go` gets `communityFeed` (`community|<uid>|<cid>`). A SUSPENDED community → NOT_FOUND. Also wire `communities.Reader` into SetHomeTabs for the COMMUNITY kind (W5-9).
- **Acceptance criteria.**
  - Given 25 community posts, then pages of 20 + 5.
  - Given a hidden post, then it is dropped and listed in `removed_ids` on the next refresh.
  - Given a post by a user the viewer blocks, then it is dropped.
  - Given a warm entry, then 0–3 reads.
  - Given a List token on a community, then VALIDATION.
  - Given SetHomeTabs with a joined community, then it is accepted.
- **Test notes.** `budgettest` 24 / 54 cold, 3 empty refresh, 0–3 warm; `recentRemovals` overflow; token binding.
- **Observability.** `timeline_op=community`, `cache_hit`, `items_filtered`, `removed`, `fs_reads`.
- **Budget.** As the per-RPC table; writes 0.
- **Flag.** `FEATURE_COMMUNITIES` + `posts`.
- **Seam.** Behind the `timeline` interface; `posts.Reader.ByCommunity`; the Stage 2 feed store replaces the query with no client change.
- **Parallel with W3 Part A / W4:** timeline files after W5-8.

### W5-28 — Community moderation  [owner: backend-developer] [size: M] [depends: W5-26]  Status: Open
- **Description.** `communities.Moderation`:
  - **HideCommunityPost / RestoreCommunityPost** (moderator or owner; the post's `communityId` must match). `communityHidden` is set through `posts.CommunityModerator`. On the community doc, `recentRemovals` (≤ 50, newest) and a `modlog` entry (≤ 100, newest; the post id, never the author's uid) are written in one transaction.
  - **Every modlog write** (hide, restore, role change, rules edit, a moderator leaving) adds the community id to the **actor's** `communityMemberships.modlogged[]` in the same transaction (A6), only when the id is not already there. The actor's memberships doc is read in the transaction anyway for the role check, so the first action per community costs +1 write and later ones +0.
  - **SetMemberRole:**
    - BAN / UNBAN by moderators (never the owner or a moderator);
    - MAKE / REMOVE_MODERATOR by the owner only (≤ 10).

    A ban writes the member doc role BANNED, removes the community from `joined`, adds it to `banned`, and decrements `memberCount`.
  - **ListModerationLog:** owner and moderators.
  - `COMMUNITY_MOD_ACTIONS_PER_DAY`.

  Moderators never delete posts and never see reports.
- **Acceptance criteria.**
  - Given a member, when they hide, then FORBIDDEN `reason=not_moderator`.
  - Given a moderator banning the owner or another moderator, then FORBIDDEN.
  - Given a hide, then the post stays on the author's profile and Home without its label.
  - Given 201 actions, then RATE_LIMITED `limit_name=community_mod_actions`.
  - Given 101 modlog entries, then the oldest is dropped.
  - Given a moderator's first hide in a community, then that community id is in their `modlogged[]`; a second hide adds no write for it.
- **Test notes.** The role matrix (owner, moderator, member, banned, outsider × each action); `budgettest`; idempotent replays (state-setting).
- **Observability.** `mod_action` enum, outcome, `fs_reads`, `fs_writes`; no ids in logs.
- **Budget.** Hide 4 / 2 reads, 2 writes (+1 on the actor's first action in that community); SetMemberRole ≤ 4 reads, ≤ 4 writes (+1 likewise).
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** `communities.Moderation` and `posts.CommunityModerator`; the capped arrays sit behind the interface, so a later `modlog` collection changes no caller.
- **Parallel with W3 Part A / W4:** yes.

### W5-29 — Platform levers  [owner: backend-developer] [size: M] [depends: W5-23, W5-4, W5-28]  Status: Open
- **Description.**
  - `ReportContent` accepts COMMUNITY and LIST targets. The target owner is the community or list owner. The evidence snapshot holds the name, description and rules text. Private lists are reportable only by their owner; others get NOT_FOUND. Quota `reports` as today.
  - Opsctl:
    - `community suspend|restore` (status; SUSPENDED hides the community from reads and directory and blocks posting);
    - `list hide|restore` (`hidden`);
    - `takedown-post` of a community post also appends the id to that community's `recentRemovals` (it already reads the post).
  - Runbook entries in `docs/runbooks/communities.md`, `lists.md` and the moderation runbook.
- **Acceptance criteria.**
  - Given a COMMUNITY report, then a report doc with the evidence and 2 writes.
  - Given a suspended community, then GetCommunity and the feed answer NOT_FOUND, and CreatePost into it is refused.
  - Given a hidden list, then non-owners get NOT_FOUND.
  - Given a takedown of a community post, then the next community refresh lists it in `removed_ids`.
- **Test notes.** Emulator; opsctl dry runs.
- **Observability.** The existing `report_filed` line with `target_type`; opsctl prints counts.
- **Budget.** ReportContent as ADR-0016 (+1 read for the community or list doc); opsctl is an ops path.
- **Flag.** `reports` for the new targets (plus `communities` / `lists`).
- **Seam.** `moderation` reaches communities and lists only through their `Reader` interfaces.
- **Parallel with W3 Part A / W4:** moderation module only.

### W5-30 — Client data layer B  [owner: frontend-developer] [size: S] [depends: W5-22]  Status: Open
- **Description.**
  - `CommunitiesRepository` with friendly mapping (FORBIDDEN reasons, caps, quota, FEATURE_DISABLED).
  - `FeedKey.community(id)`.
  - `kFeatureCommunities`.
  - `HomeTabsRepository` accepts COMMUNITY.
- **Acceptance criteria.** As W5-10, for communities.
- **Test notes.** Unit tests.
- **Observability.** —
- **Budget.** 0 RPCs by itself.
- **Flag.** `communities`.
- **Seam.** The repository is the only RPC caller.
- **Parallel with W3 Part A / W4:** after W5-10 (`feed_key.dart`).

### W5-31 — Communities screen and Create  [owner: frontend-developer] [size: M] [depends: W5-30]  Status: Open
- **Description.** `/communities`:
  - an `AppBackHeader` "Communities";
  - "My Communities" rows (default tile, name, "N members", role badge);
  - an "Explore Communities" section (the directory, top 50) with Join pills.

  "Create a Community" (only with `can_create`) opens `/communities/new`: name, description and rules editor (≤ 10, title + text), Create.

  Navigation: a drawer row and a desktop rail destination (`communities` + `ui_shell`). No chips or search (F10).
- **Capture.** Communities explore is MEASURED (`communities.md`); My Communities and Create are **UNKNOWN**.
- **Acceptance criteria.**
  - Given `can_create` false, then no Create entry.
  - Given Join, then an optimistic Joined with rollback.
  - Given `communities` off, then no row and the route redirects.
- **Test notes.** Widget tests at 3 widths, light and dark, 3 text scales.
- **Observability.** —
- **Budget.** ListMyCommunities + ListCommunities per open.
- **Flag.** `communities` (+ `ui_shell` for nav).
- **Seam.** It reuses W5-11's `AppTileIcon`, `AppSectionHeader` and `UserListRow` patterns.
- **Parallel with W3 Part A / W4:** shell nav files after W5-11 and W4-17.

### W5-32 — Community page  [owner: frontend-developer] [size: M] [depends: W5-30]  Status: Open
- **Description.** `/communities/:id`:
  - a header (name, "N members" → members page, Join / Joined / Banned, Pin to Home);
  - `AppTabBar` Posts · About;
  - Posts is `TimelineFeedView` over `TimelineCubit(FeedKey.community(id))`;
  - About shows the description, the numbered rules and moderators (`UserListRow`);
  - a members page;
  - NOT_FOUND → "This Community is unavailable".
- **Capture.** The community page is **UNKNOWN**; X-like defaults.
- **Acceptance criteria.**
  - Given a non-member, then a Join pill and no compose-to-community.
  - Given a banned user, then "You can't join this Community".
  - Given Pin, then SetHomeTabs.
- **Test notes.** Widget tests at 3 widths, light and dark, 3 text scales.
- **Observability.** —
- **Budget.** GetCommunity + community timeline calls per the cost table.
- **Flag.** `communities`.
- **Seam.** Feed reuse unchanged except `FeedKey`.
- **Parallel with W3 Part A / W4:** yes.

### W5-33 — Context label row on `PostCard`  [owner: frontend-developer] [size: S] [depends: W5-30]  Status: Open
- **Description.** Generalise the private `_RepostedBy` into one context-label row: an icon over the avatar column plus muted text (`communities.md` §3, MEASURED). Its variants are "<name> reposted" (existing behaviour, unchanged) and "<community name>" (people icon; tap → `/communities/:id`, only with `communities`). There is one row; when both apply, the repost label wins. Semantics: the article label starts with the community name (`communities.md` §4).
- **Acceptance criteria.**
  - Given a community post, then the label shows.
  - Given a repost of a community post, then "reposted" shows.
  - Given `communities` off, then the label is not tappable (the server omits it when globally off).
  - The existing repost tests stay green.
- **Test notes.** Widget tests on `PostCard`, light and dark, 3 widths.
- **Observability.** —
- **Budget.** 0.
- **Flag.** `communities` (tap).
- **Seam.** One `PostContextLabel` widget in `app/lib/shared/widgets` (catalogued), so later labels (pinned, W3-17) reuse it.
- **Parallel with W3 Part A / W4:** `post_card.dart` serialises with W3-17 and W4-16. If W3-17 lands first, its "Pinned" row moves onto this widget.

### W5-34 — Composer audience picker  [owner: frontend-developer] [size: M] [depends: W5-30]  Status: Open
- **Description.** Under the avatar in the composer, an audience pill "Everyone ▾" with an accent outline. It opens "Choose audience": `Everyone`, then "My Communities" rows (name, N members) (`composer.md` §3, OBSERVED + A11Y). Choosing a community sets `community_id` on CreatePost (root posts and quotes only). The pill is hidden in reply mode and in schedule mode (SchedulePost rejects it). Opening `/compose` from a community page preselects that community. Friendly errors for not-member, banned and quota.
- **Acceptance criteria.**
  - Given `communities` off or no memberships, then no pill.
  - Given a community chosen, then the post shows the label after posting.
  - Given schedule mode, then the pill is hidden.
- **Test notes.** Widget tests at 3 widths, light and dark, 3 text scales; keyboard and semantics (`menuitem`).
- **Observability.** —
- **Budget.** ListMyCommunities is cached for the session (0 extra calls when the Communities screen loaded it).
- **Flag.** `communities`.
- **Seam.** The audience is a value on the composer state (`ComposeAudience`), so a later audience kind adds no widget branch.
- **Parallel with W3 Part A / W4:** composer files serialise with W1.5 / W6 composer tickets.

### W5-35 — Moderation UI and reports  [owner: frontend-developer] [size: M] [depends: W5-32, W5-33]  Status: Open
- **Description.**
  - For moderators and the owner:
    - "Remove from Community" and "Restore" on a community post's overflow menu;
    - on the members page, Ban / Unban, plus (owner) Make / Remove moderator, with confirms;
    - a "Moderation log" page (action, target, time; muted).
  - For everyone: "Report Community" on the community header menu and "Report List" on a public list header, through the existing report sheet with the new target types.
- **Capture.** Moderator tools are **UNKNOWN**; our own copy.
- **Acceptance criteria.**
  - Given a member, then no moderator rows.
  - Given a hide, then the post leaves the community feed at once (local) and on other devices at the next refresh (`removed_ids`).
  - Given `reports` off, then no Report rows.
- **Test notes.** Widget tests at 3 widths, light and dark; the role matrix.
- **Observability.** —
- **Budget.** Per action; ListModerationLog per open.
- **Flag.** `communities` (+ `reports` for reporting; `lists` for Report List).
- **Seam.** Role checks come from `viewer_role` in GetCommunity only; the client never infers roles.
- **Parallel with W3 Part A / W4:** the post menu file after W3-17.

### W5-36 — Part B backend tests  [owner: tester] [size: M] [depends: W5-25 to W5-29]  Status: Open
- **Description.** Emulator integration:
  - flag modes for `communities`;
  - the creators allowlist;
  - the role × action matrix;
  - ban races (ban vs post on two instances: the fresh read wins);
  - members-only replies;
  - `budgettest` per the W5-20 table;
  - A1 query shapes;
  - `recentRemovals` overflow and token reset;
  - counters under a join burst (`ABORTED` metric);
  - the eraser hand-over and archive;
  - the export and residue sweep;
  - report targets and opsctl suspension.

  Coverage on `internal/` stays at 70 % or more.
- **Acceptance criteria.** Every acceptance criterion in W5-23 to W5-29 has a named test; `make test-int` is green.
- **Test notes.** Load shapes from `stage-ladder`: one community at 50 posts a minute and a 20-join-per-second burst on one community doc (with W5-39).
- **Observability.** —
- **Budget.** 0.
- **Flag.** Under test: `communities` in every mode.
- **Seam.** —
- **Parallel with W3 Part A / W4:** yes.

### W5-37 — Part B client tests  [owner: tester] [size: S] [depends: W5-31 to W5-35]  Status: Open
- **Description.** The responsive matrix and flows: Communities → join → post from the composer → label in Home → community tab → moderator hide → report; flag combinations (`communities` × `lists` × `ui_shell` × `reports`); text scale 2.0.
- **Acceptance criteria.** Every new widget is covered at 360 / 600 / 1200, light and dark; no overflow at 2.0.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Under test: `communities` × `lists` × `ui_shell` × `reports`.
- **Seam.** —
- **Parallel with W3 Part A / W4:** yes.

### W5-38 — Part B security review, including moderator abuse  [owner: security-auditor] [size: M] [depends: W5-25 to W5-29, W5-34]  Status: Open
- **Description.** A threat model for:
  - the creators allowlist;
  - public user-generated text (names, rules) and its report path;
  - moderator abuse (scope, limits, log, the owner-is-rogue residual);
  - ban evasion (new accounts: `communityJoins` and new-account post tiers);
  - spam and raids (post quotas, per-community `DailyCap`, members-only replies);
  - the feed as a scraping vector;
  - the label as a false-attribution vector (cleared on hide);
  - owner-deletion hand-over;
  - the export;
  - logs.

  Findings are fixed or ticketed before any dev allowlist, and the review confirms F6 (no community-only content exists, so no read path leaks).
- **Acceptance criteria.** A report in `docs/reviews/` with no open Critical or High findings.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Reviews the `communities` gate and `COMMUNITY_CREATORS`.
- **Seam.** The rate-limit × 3 arithmetic; the `stage-ladder` vectors.
- **Parallel with W3 Part A / W4:** yes.

### W5-39 — Part B cost and performance budget  [owner: sre-performance] [size: S] [depends: W5-27, W5-28]  Status: Open
- **Description.**
  - Add the Part B rows (+16.0 reads, +0.11 writes, +2.0 requests per DAU) to `cost-model.md`.
  - Run `make loadtest SCENARIO=community_feed`: cold and warm shared entry, refresh with 0 and with 5 new, page 50, a hide during refreshes, a join burst.
  - Name the triggers: community feed reads > 15 % of daily reads; a community above 1 post/s; `ABORTED` on a community doc.
- **Acceptance criteria.** The model is updated with measured reads (± 25 % or the plan corrected), and a k6 script is added.
- **Test notes.** —
- **Observability.** A Logs Explorer query for `timeline_op=community` and `fs_reads` in §9.
- **Budget.** 0.
- **Flag.** n/a.
- **Seam.** —
- **Parallel with W3 Part A / W4:** yes.

### W5-40 — Part B dev rollout  [owner: production-deployer] [size: S] [depends: W5-36, W5-38, W5-39, ADR-0028 merged]  Status: Open
- **Description.**
  - Show the founder a targeted dev Terraform plan for `feature_communities*`, `community_creators` (the founder's dev uid) and the community config.
  - If W5-21 added the A1 fallback index: it deploys with the dev workflow's `firebase deploy --only firestore:indexes` after merge and must show READY before the flag leaves `off`.
  - Apply on OK, with an allowlist of 3 uids.
  - Smoke: create a community, join from a second account, post, see the label in Home, pin the tab, hide, ban, report, suspend through opsctl in dev, flag off.
  - Prod: no change.
- **Acceptance criteria.** The smoke passes; the flags are back to their planned state.
- **Test notes.** —
- **Observability.** `timeline_op=community`, `community_op` and `mod_action` lines in dev logs.
- **Budget.** A handful of reads inside dev's free quota.
- **Flag.** Dev: `feature_communities` set to allowlist (3 uids); prod `off`.
- **Seam.** —
- **Parallel with W3 Part A / W4:** serialise dev applies.

## Rollout plan
- **Dev.** Allowlist (3 uids): `lists` first (W5-19), then `communities` (W5-40).
- **Prod.** The founder's MVP launch decision: allowlist → percent 5 → 25 → 100 → `on`, each step a Terraform change plus a tagged revision (ADR-0019). Before each step, check the `cost-model.md` headroom and the error rate. `communities` never ramps ahead of `lists`, and `COMMUNITY_CREATORS` holds the founders' uids at launch.
- **Rollback triggers:**
  - error rate on any W5 RPC above 2 % for 15 min;
  - list or community feed reads per DAU above twice the W5-18 / W5-39 model for a day;
  - a moderator-abuse or raid incident in a community (first suspend that community, else `FEATURE_COMMUNITIES=off`);
  - an abusive public list (`opsctl list hide`).
- **Kill switches:**
  - `FEATURE_LISTS=off`: the list RPCs reject, and the client hides Lists, list tabs and Add to Lists.
  - `FEATURE_COMMUNITIES=off`: the community RPCs and posting reject; the labels go when the flag is globally off; community tabs hide.

  Both need a deploy. No data migration is needed: the data stays, and the pins return with the flag. Opsctl suspension and list hide are per-object levers with no deploy.
- **Client-only pieces** roll back with their flags or by revert.

## Risks
| Risk | Mitigation |
|---|---|
| Lists and communities add +38 reads per DAU and move the free-read crossover from about 201 to about 174 DAU (about 138 with W3 and W4) | the 150-member cap, shared and author-recent caches, ≥ 60 s refreshes, the two 15 % triggers, the kill switches; cents per 100k reads, no fixed fee |
| A1's id-ordered query does not run on the automatic index (the emulator cannot tell: it never requires indexes) | the dev Firestore check in W5-20 before the ADR is final; the named fallback index in W5-21 (one gate-file change); the W5-40 dev smoke runs every feed form again before the flag leaves `off` |
| Rogue moderator or owner, raids, spam communities | F9 scope, caps, modlog, `DailyCap`, members-only replies, creators allowlist, opsctl suspension, W5-38 |
| Public lists as harassment lists | private by default (F3), no add notification, blocks prevent adds and hide members (F4), report and hide |
| A community post can be misattributed after a hide | the label is omitted when `communityHidden`; the post itself is untouched |
| Hot community doc (`memberCount`) during a viral join burst | rule 3 holds at Stage 0; the `ABORTED` metric and the counters-row trigger |
| `recentRemovals` overflow (> 50 hides between refreshes) resets cached feeds | the documented ADR-0016 D10 contract (cold open); the moderation-log trigger |
| Private accounts (W3 Part B) leak through the new feeds | the `keep` hook point named in W5-8 / W5-27; ADR-0025's matrix includes both feeds |
| Merge conflicts with W3 and W4 in shared files | the shared-files table; one PR at a time; new logic in new files |
| ADR number clash | Part A took ADR-0030 (W5-1); Part B: "ADR-0028 or the next free number" |
| Uncaptured visuals (list detail, community page, create flows, Manage timelines, moderator tools) | X-like defaults stated per ticket; a founder capture adjusts them in a follow-up PR |
| Home tab titles go stale after a rename | the timeline response carries the current header and the device updates its label; storage is refreshed on the next SetHomeTabs |
