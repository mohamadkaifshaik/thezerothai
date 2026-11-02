# UI W5: Lists, Communities and custom Home tabs
Plan owner: planner · Date: 2026-10-26 · Stage 0 (free tier, per use past it; about INR 441/month at 300 DAU with W2, `docs/reviews/cost-model.md` §5, ADR-0022) · **Two parts.** Part A is Lists and custom Home tabs: a new `lists` module, a new `dzeroth.lists.v1.ListService`, one new collection (`lists`), a list timeline and the Home tab order in `timeline`, and one `users/{uid}` field written through identity's interface. Part B is Communities: a new `communities` module, a new `dzeroth.communities.v1.CommunityService`, two new collections and a subcollection, community posting in `posts`, a community feed in `timeline`, and report targets in `moderation`. Each part has its own ADR, flag and rollout, so Part B can be held or dropped without touching Part A. **No new GCP service, no fixed cost, and no index-file change in the default design** · Flags: new `FEATURE_LISTS` (Part A) and `FEATURE_COMMUNITIES` (Part B); existing `posts`, `engagement`, `bookmarks`, `reports`, `removed_ids`, `ui_shell`
Source: `docs/plans/roadmap.md` (W5 row "Lists and Communities, custom Home tabs | lists + communities modules | moderation scope for communities", section 3 row P2 Lists and Communities, section 5 W5 capture row, "W5 to W8 follow in order of dependency and risk"), `docs/x_research/screens/lists.md`, `communities.md`, `home.md` §3, `composer.md` §3, `mobile/screens.md` §5-§6, `14_mvp_structured_plan.md` (W5 row, cost row 68) (all local and git-ignored), ADR-0004, ADR-0008, ADR-0010 (D5 read budget, D6 filtering, D13/D14 tokens), ADR-0011, ADR-0016 (D10 removal log), ADR-0018, ADR-0021, ADR-0023, the W3 and W4 plans (file boundaries, ADR numbers), the protos and modules on `main` d2ff011.
Branches: `feat/ui-w5-N-<slug>` off `main` (not stacked); one ticket per PR except where a ticket says "same PR as" (the T11 lifecycle guard); merge `origin/main` into the branch.

## Questions for the founder (proposed default in bold; nothing blocks the ADR or proto tickets)
Answered: F2 to F5, and F10 and F13 for lists, with ADR-0030 (Accepted 2026-10-30); F1 and F6 to F14 for communities at the defaults with ADR-0031 (Accepted 2026-11-01, #583); F15 to F17 on 2026-11-02 (the W5-38 security review, #647; the W5-51 amendment records F15 to F17 in ADR-0031, Amendment 1).
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
- **F15. Can community moderators remove replies in their community's conversations? (W5-38 M-1)** **Answered 2026-11-02: yes**, by an amendment to ADR-0031 D4 (W5-51). The owner and moderators can hide and restore a reply whose `conversationCommunityId` is their community. GetThread then drops the reply for everyone but its author, at 0 extra reads, and each action writes a modlog entry. Tickets: W5-51 (amendment), W5-51b (backend), W5-51c (reply menu); all before `percent`.
- **F16. Does F9's "cannot act on the owner, and moderators cannot act on other moderators" cover hiding their posts? (W5-38 L-1)** **Answered 2026-11-02: yes, F9 is literal.** A moderator cannot hide or restore a post (or, with F15, a reply) by the owner or by another moderator: FORBIDDEN `not_owner`. `SetCommunityListing` returns the post's `authorId`, so the check costs 0 extra reads. The owner can act on every post, and a moderator on their own. Ticket W5-53, with the L-2 fix; before `percent`.
- **F17. Should a protected account's community memberships be hidden from viewers it has not approved? (W5-38 L-5)** **Answered 2026-11-02: hide.** On the member pages, a protected account's row is shown only to the community's owner and moderators, to its approved followers and to the account itself. `memberCount` is unchanged. **Answered 2026-11-02:** a protected account that holds a role (owner or moderator) stays visible to everyone, as ADR-0031 D7 already shows every role holder in GetCommunity. The residual: its member row also shows its join date (`Since`), which GetCommunity's moderators list does not. The Privacy Policy lines of the W5-38 report §7 stay, without "protected accounts included"; their wording is drafted with legal review (`docs/plans/roadmap.md` section 9, item 3.26). Tickets W5-56 and W5-56b; before prod `on`.

## What exists already (verified on `main` d2ff011)
| Piece | State | W5 delta |
|---|---|---|
| Lists, Communities | **nothing:** no module, proto, collection or flag (roadmap section 3: MISSING) | two modules, two protos |
| Home timeline | `timeline.homeSources(authors, tok, limit, start)` reads author-recent entries first, then chunks of 30 (`posts.MaxByAuthors`) at `k = ceil(2p/C')` with ≤ 4 in flight; `Merge`, `Compare`, `PositionOf`; `allowedAuthor`, `embedAllowed`; `removedIDs(ctx, tok, authors)`; tokens bound by `homeFeed` / `userFeed` in `tokens.go` (`backend/internal/timeline/service.go`, `merge.go`, `tokens.go`, `removed.go`) | **reuse all of it** for the list timeline; a new `listFeed` binding |
| Post query for a community | `posts.Reader.ByAuthors` (root posts, `isReply == false`), `ByAuthor`, `GetMany`; no community field on posts | `communityId` on root community posts; `Reader.ByCommunity` |
| Home tabs | `HomeScreen` has a one-tab "Following" `AppTabBar` (W1-5); `AppTabBar` already scrolls content-sized tabs and takes a trailing widget (`docs/ui-catalog.md`) | Following + pinned tabs, "+" → Manage pinned |
| Post context label | `PostCard` has a private `_RepostedBy` row (`app/lib/shared/widgets/post/post_card.dart:463`) | generalise it into one context-label row (repost, community) |
| Navigation | `AppDrawer` rows Profile / History / Settings / Sign out ("add Lists here in a later wave"); `MainShell` bar and rail Home, Notifications, Profile (W4-17 adds Explore) | Lists and Communities rows (drawer, desktop rail) |
| Reports, takedowns | `ReportContent` with `ReportTargetType` POST and ACCOUNT (`moderation.proto`); opsctl `takedown-post`, `suspend-user`; `postRemovals` log for `removed_ids` (ADR-0016) | targets COMMUNITY and LIST (LIST shipped in W5-44); opsctl community suspend and list hide (shipped in W5-44) |
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
- scheduled posts into a community (SchedulePost has no `community_id` field, W5-21);
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

- **W5-18 correction (2026-10-31, measured in `docs/reviews/cost-model.md` §17).** Part A measures **24.35 reads, 0.79 writes, 0.29 deletes and 2.29 requests per DAU** (this table: 22.1 / 0.51), because the table predates ADR-0030 D7: AddListMember writes 3 (not 2), RemoveListMember 2 (not 1), GetList non-owner worst 5 (not 3), SetHomeTabs worst 19 (not 7; measured 14), and the cold open is 38 (not 30; 46 all-cold, 30 warm). Worst measured: GetListTimeline 106 at 150 members page 50 (hold 269). Against the whole product with W6 the free reads cross at 130 DAU and the free writes at 484.
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
- **Ramp.** Dev allowlist (3 uids) → the founder's MVP launch decision for prod: allowlist → percent 5 → 25 → 100 → `on`, each a Terraform change plus a tagged revision (ADR-0019). `communities` ramps after `lists` and only once W5-38's moderator-abuse findings are closed: `percent` needs W5-51 to W5-53 (with W5-51b, W5-51c and W5-52b), and prod `on` also needs W5-54 to W5-56 (with W5-55b and W5-56b). See the Rollout plan.

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
  - Every action is in the modlog (actor, action, target, time), readable by the owner and moderators, and in a structured log line. The log line carries counts and enums only; the ids live in the modlog. W5-52 adds keyed hashes (`community_hash`, `target_hash`, `post_hash`) so an operator can rebuild one community's history from the logs (W5-38 M-2).
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
- **The founder's answers to F1 to F13** (and F14 to F17, recorded above).
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
- **ADR-0031 (Part B, W5-20; answered there, see the ADR for each item; A1 was proven on the dev Firestore, ADR-0031 D3):**
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
- **ADR-0031 amendment (W5-51, from the W5-38 review; proposed defaults, the architect decides, the founder OKs the merge):** answered in ADR-0031 Amendment 1, "Answers to R1 to R6". Every default holds. R4 adds the parent-slot rule (a hidden reply is an unavailable parent) and "replying to it stays allowed"; R6 uses the marker `_platform`, not `_deleted`, with `--since` applied in memory. Where W5-51b, W5-51c, W5-52, W5-52b, W5-54 or W5-56 differ from the amendment, the amendment's "What changed against the tickets" wins.
  - **R1. A reply hide and `recentRemovals`.** Default: **no entry.** Replies are not in the community feed. Cleaning up hundreds of raid replies would roll the 50-entry log and make every member device cold-open the feed.
  - **R2. Where a moderator restores a hidden reply.** GetThread drops it for moderators too. Default: **from the HIDE row of the moderation log**, which already restores a hidden post by id (W5-35's log screen).
  - **R3. How the client knows it may moderate a reply.** Default: **the conversation root's `community` label plus the caller's role from ListMyCommunities** (each row carries `viewer_role`; the list is cached for the session). No proto change. A hidden root has no label, so its replies get no menu; the platform playbook (W5-52b) covers that case. If the architect prefers a role field on GetThread, W5-51 adds it as an additive proto change.
  - **R4. What else a hidden reply does.** Default:
    - replies under it stay, shown as GetThread shows replies under an unavailable parent;
    - opened as the focal post, it is served as GetPost serves it;
    - GetPost, the author's Replies tab and search are unchanged (a hide is never `Hidden()`);
    - the parent's `replyCount` is unchanged.
  - **R5. A hidden reply while `communities` is globally off.** Default: **GetThread still drops it.** The kill switch must not undo a moderation decision. The label rule is unchanged.
  - **R6. `restore-hidden --since T` needs the hide time, and the run must not flush the modlog.** Default: the hide also writes `communityHiddenAt` in the same field-level update (+0 writes), and the restore deletes it. Each `restore-hidden` run writes **one** modlog entry with a platform actor marker (as `_deleted`), not one per post.

## Milestones
1. **M5.1 Contracts:** W5-1, W5-2 (Part A) and W5-20, W5-21 (Part B). The ADRs are accepted by the founder's merge.
2. **M5.2 Lists backend:** W5-3 to W5-9. Flags off; dev check by allowlist.
3. **M5.3 Lists client:** W5-10 to W5-14.
4. **M5.4 Lists verify and roll:** W5-15 to W5-19, with W5-17 and W5-18 done before `lists` leaves `off` in dev.
5. **M5.5 Communities backend:** W5-22 to W5-29.
6. **M5.6 Communities client:** W5-30 to W5-35.
7. **M5.7 Communities verify and roll:** W5-36 to W5-40, with W5-38 and W5-39 done before `communities` leaves `off` in dev.
8. **M5.8 W5-38 follow-ups:** W5-51 to W5-56 (W5-51, W5-51b, W5-51c, W5-52, W5-52b and W5-53 before `percent`; W5-54, W5-55, W5-55b, W5-56 and W5-56b before prod `on`), then W5-57 to W5-59 (no gate).

Prod for both parts waits for the held prod apply (`docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.2) and the founder's MVP launch decision.

| ID | Ticket | Owner | Size | Depends | Parallel with W3 Part A / W4? | Status |
| --- | --- | --- | --- | --- | --- | --- |
| W5-1 | ADR-0030 "Lists and custom Home tabs at Stage 0" | architect | M | — | **yes, start now** (new file) | Done (#485) |
| W5-2 | Part A protos: new `lists.proto`; `common.proto` `HomeTab`; `timeline.proto` GetListTimeline + SetHomeTabs; `identity.proto` `GetMeResponse.home_tabs` | architect | S | W5-1 drafted | `timeline.proto` and `identity.proto` serialise with W3-2 | Done (#485) |
| W5-3 | `make proto`; `FEATURE_LISTS`, list config, quota fields, rate limits, ceiling, Terraform vars; `internal/lists` skeleton (no collection constant yet) | backend-developer | M | W5-2 | shared plumbing files: merge one at a time with W3-4 / W4-3 | Done (#495) |
| W5-4 | Lists write path: CreateList / UpdateList / DeleteList (**same PR as W5-5**) | backend-developer | M | W5-3 | yes (new module) | Done (#506) |
| W5-5 | Lists lifecycle: `lists` eraser step, export section, T11 rows, runbook (**same PR as W5-4**) | backend-developer | M | W5-3 | lifecycle wiring files serialise with W3-32 / W4-9 | Done (#506) |
| W5-6 | AddListMember / RemoveListMember | backend-developer | S | W5-4 | yes | Done (#512) |
| W5-7 | GetList, ListUserLists, ListListMembers + `lists.Reader` | backend-developer | M | W5-4 | yes | Done (#518) |
| W5-8 | `GetListTimeline` (reuse `homeSources`, `Merge`, `removedIDs`; `listFeed` token) | backend-developer | M | W5-7 | timeline `server.go` / `tokens.go` serialise with W3-9 | Done (#524) |
| W5-9 | SetHomeTabs + `users.homeTabs` through identity + `GetMe.home_tabs` | backend-developer | M | W5-3, W5-7 | identity files: after W3-6 | Done (#526) |
| W5-10 | Client data layer A: `ListsRepository`, `HomeTabsRepository`, `FeedKey.list`, `kFeatureLists` | frontend-developer | S | W5-3 | `feed_key.dart` serialises with W3-16 | Done (#517) |
| W5-11 | Lists screen `/lists`, create/edit sheet, drawer row and rail destination | frontend-developer | M | W5-10 | shell nav files serialise with W4-17 | Done |
| W5-13 | "Add to Lists" from a profile; "Lists" of another user | frontend-developer | S | W5-11, W3-14 | **after W3-13 / W3-14** (`profile_header.dart`) | Done (#531) |
| W5-12 | List detail `/lists/:id`: header, list timeline, members page, Pin | frontend-developer | M | W5-10 | yes | Done (#527) |
| W5-14 | Home tab bar (Following + pinned) and Manage pinned | frontend-developer | M | W5-10, W5-12 | `home_screen.dart` serialises with W3-19 | Done (#537) |
| W5-15 | Part A backend tests | tester | M | W5-6 to W5-9 | yes | Done (#539) |
| W5-16 | Part A client tests | tester | S | W5-11 to W5-14 | yes | Done (#551) |
| W5-17 | Part A security review | security-auditor | S | W5-6 to W5-9, W5-13 | yes | Done (#540; report `docs/reviews/security/security-w5-lists.md`) |
| W5-18 | Part A cost and performance budget: list timeline hot path, load smoke | sre-performance | S | W5-8, W5-9 | yes | Done (#538) |
| W5-19 | Part A dev rollout | production-deployer | S | W5-15, W5-17, W5-18, ADR-0030 merged | serialise dev applies with W3-24 / W4-24 | Done in dev 2026-10-31 (allowlist 3 uids applied earlier that day; targeted plan 0 changes for lists; API smoke passed incl. the real-Firestore `ownerId ==` count; the eraser and export `memberIds array-contains` query was not exercised, owed; see "Dev rollout result" in the ticket) |
| W5-20 | ADR-0031 "Communities and their moderation scope at Stage 0" | architect | M | — | **yes, start now** (new file) | Done (#583; ADR-0031 Accepted 2026-11-01, F1 and F6 to F14 at the defaults) |
| W5-21 | Part B protos: new `communities.proto`; `posts.proto` `community_id` / `community`; `moderation.proto` targets; `timeline.proto` GetCommunityTimeline (+ the A1 fallback index if needed) | architect | S | W5-20 drafted | `timeline.proto` after W5-2 and W3-2; the index file (only if needed) serialises with W3-2 / W4-9 | Done (#590) |
| W5-22 | `make proto`; `FEATURE_COMMUNITIES`, `COMMUNITY_CREATORS`, community config, quota fields, rate limits, ceiling, Terraform vars; `internal/communities` skeleton | backend-developer | M | W5-21 | shared plumbing files: one at a time (after W5-3) | Done (#596) |
| W5-23 | Communities write path: CreateCommunity / UpdateCommunity / GetCommunity (**same PR as W5-24**) | backend-developer | M | W5-22 | yes (new module) | Done (#601) |
| W5-24 | Communities lifecycle: eraser step (memberships, member docs, counts, owner hand-over, modlog scrub), export, T11 rows, runbook (**same PR as W5-23**) | backend-developer | M | W5-22 | lifecycle wiring files serialise | Done (#601) |
| W5-25 | Join / Leave (a leaving moderator leaves `moderatorIds`) / ListMyCommunities | backend-developer | M | W5-23 | yes | Done (#613) |
| W5-25b | ListCommunities (directory) / ListCommunityMembers | backend-developer | S | W5-25 | yes | Done (#626) |
| W5-26 | Posting into a community: `posts.CommunityGate`, `communityId`, label snapshot, `Reader.ByCommunity` | backend-developer | M | W5-23, W5-25 | **after W3-7** (every create path) | Done (#629) |
| W5-26b | Members-only replies (F8) and the `ToView` label rules | backend-developer | S | W5-26 | reply path after W3-7 | Done (#633) |
| W5-27 | `GetCommunityTimeline` + COMMUNITY kind in Home tabs | backend-developer | M | W5-26, W5-9 | timeline files after W5-8 | Done (#634) |
| W5-28 | Community moderation: Hide / Restore post, SetMemberRole, ListModerationLog | backend-developer | M | W5-26 | yes | Done (#636) |
| W5-29 | Platform levers: report target COMMUNITY; opsctl community suspend / restore; takedown appends `recentRemovals` (the LIST report target and `list hide|restore` moved to W5-44) | backend-developer | M | W5-23, W5-4, W5-28 | moderation module only | Done (#639) |
| W5-30 | Client data layer B: `CommunitiesRepository`, `FeedKey.community`, `kFeatureCommunities` | frontend-developer | S | W5-22 | after W5-10 (`feed_key.dart`) | Done (#599) |
| W5-31 | Communities screen `/communities` (My Communities + directory) and Create community | frontend-developer | M | W5-30 | shell nav files after W5-11 | Done (#616) |
| W5-32 | Community page `/communities/:id`: header, Join / Joined, Posts, About | frontend-developer | M | W5-30 | yes | Done (#616) |
| W5-33 | One context-label row on `PostCard` (repost, community) | frontend-developer | S | W5-30 | `post_card.dart` serialises with W3-17 / W4-16 | Done (#614) |
| W5-34 | Composer audience picker (Everyone / a joined community) | frontend-developer | M | W5-30 | composer files serialise with W1.5 / W6 tickets | Done (#630) |
| W5-35 | Moderation UI (hide, restore, members, roles, modlog) + report list (already done by W5-48); report community moved to W5-35b | frontend-developer | M | W5-32, W5-33 | post menu file after W3-17 | Done (#637) |
| W5-35b | *(W5-35 follow-up)* "Report Community" on the community header menu: `ReportTargetType.community` through the existing report sheet, hidden for the owner, friendly NOT_FOUND `community not found` and `FEATURE_DISABLED feature=communities`. | frontend-developer | S | W5-29, W5-35 | yes | Done (#641) |
| W5-36 | Part B backend tests | tester | M | W5-25 to W5-29 | yes | Done (#650) |
| W5-37 | Part B client tests | tester | S | W5-31 to W5-35 | yes | Done (#649) |
| W5-38 | Part B security review incl. moderator abuse | security-auditor | M | W5-25 to W5-29, W5-34 | yes | Done (#647; report `docs/reviews/security/security-w5-communities.md`, CLEAR WITH CONDITIONS; findings ticketed as W5-51 to W5-56) |
| W5-39 | Part B cost and performance budget: community feed hot path, load smoke | sre-performance | S | W5-27, W5-28 | yes | Done (#644) |
| W5-40 | Part B dev rollout | production-deployer | S | W5-36, W5-38, W5-39, ADR-0031 merged | serialise dev applies | Done |
| W5-41 | *(W5-17 M-1)* ListUserLists for another owner returns all public lists in one page, token "" (filter before paging); fix the `lists.proto:114-115` comment; test private-first with page_size 1 | backend-developer | XS | W5-7 | yes | Done (#542) |
| W5-42 | *(W5-17 M-2, founder question)* Protected owner rule in `resolve` and `otherOwner` (NOT_FOUND / PROTECTED_ACCOUNT for unapproved viewers, 0 reads); hide "View Lists" on protected profiles not followed; ADR-0030 D3 note | architect + backend-developer + frontend-developer | S | founder answer (yes, 2026-10-31) | yes | Done (#556; gate: before percent) |
| W5-43 | *(W5-17 M-3)* SetHomeTabs with the kind's flag off for the caller answers an empty request at 0 reads and 0 writes; test it | backend-developer | XS | W5-9 | `timeline/home_tabs.go` | Done (#542) |
| W5-44 | *(W5-17 M-4)* opsctl `lists hide` / `restore` (field-level Update, never Set) and the LIST report target with a name/description snapshot, split from W5-29 to depend on W5-4 only; correct runbook `lists.md` §7 | backend-developer | S | W5-4 | moderation module + opsctl | Done (#543) |
| W5-45 | *(W5-17 L-1..L-4)* Negative cache for missing list ids; visible-rune rule in the shared single-line text helper (also display names); id-only idempotency result or T11 note; fresh target status on AddListMember | backend-developer | S | W5-6, W5-7 | yes | Done (#549) |
| W5-46 | *(W5-17 L-7, founder question)* Export section `lists_member_of` (public rows: list id, owner handle, name; private, hidden and unreadable lists only as a `redactedCount`; no other member) | backend-developer | S | founder answer (yes, redacted, 2026-10-31) | lifecycle export files serialise | Done (#556; gate: before prod on) |
| W5-47 | *(W5-18 cost L-1)* Startup bound `LIST_MAX_MEMBERS <= 500` (`pkg/platform/config/lists.go:26`; above 500 breaks the ADR-0030 trigger, above about 4,890 the 269-read hold) | backend-developer | XS | — | yes | Done (#549) |
| W5-48 | *(W5-44 follow-up)* "Report list" in the list overflow menu: `ReportTargetType.list`, the reason sheet, friendly mapping of NOT_FOUND `list not found` and `FEATURE_DISABLED feature=lists`; the sheet shows only for lists the viewer does not own | frontend-developer | S | W5-44, W5-11 | yes | Done (#557) |
| W5-49 | *(W5-45 L-2 follow-up)* Dart port of the visible-rune and format-character rules of `testdata/profile_text/single_line_text.json` into `profile_extras_rules.dart` (display name, location) and the list name field, with the fixture runner; Dart has no Unicode category data, so it needs an explicit Cf table | frontend-developer | S | W5-45 | no | Done (#557) |
| W5-50 | *(W5-16 D2, D3)* ListsRepository session epoch and reset on account switch: `ListsRepository` takes the shared `SessionEpoch` (a `GetList` / `ListUserLists` / mutation answer and a `GetListTimeline` header that land after sign-out or a switch are dropped); one `AccountSessionReset` run by `AppWidget` for sign-out and for a direct A to B switch; inventory of every per-account cache | frontend-developer | S | W5-16 | yes | Done (#553) |
| W5-51 | *(W5-38 M-1, F15)* ADR-0031 amendment (founder OK before merge): D4 reply moderation (hide and restore a reply whose `conversationCommunityId` is the community; GetThread drops it for everyone but its author; modlog entry; 0 extra reads), plus the F16, F17, L-2, L-3(c) and M-2 lines W5-52 to W5-54 and W5-56 build; comment-only proto updates | architect | S | F15, F16, F17 | yes | Done (#654; founder OK 2026-11-02) |
| W5-51b | *(W5-38 M-1, F15)* Reply moderation backend: `SetCommunityListing` accepts a reply of the community's conversation; GetThread drops a hidden reply for everyone but its author (0 reads); modlog entry, no `recentRemovals` entry; runbook `communities.md` §7 | backend-developer | M | W5-51 merged, W5-53 | `SetCommunityListing` after W5-53 | Done (#658) |
| W5-51c | *(W5-38 M-1, F15)* Reply menu: "Remove from Community" on a reply in a community conversation for the owner and moderators; Restore from the moderation-log row; the platform marker in the log | frontend-developer | S | W5-51b | post menu file serialises | Done (gate: before percent) |
| W5-52 | *(W5-38 M-2)* Keyed `community_hash`, `target_hash` and `post_hash` on the moderation request lines (HMAC with `CURSOR_HMAC_KEY`, the W7-34 precedent) and an `opsctl` loghash counterpart | backend-developer | S | W5-51 merged, W5-28 | communities moderation files: one at a time with W5-53 | Done (gate: before percent) |
| W5-52b | *(W5-38 M-2)* `opsctl community hidden CID` and `restore-hidden CID [--since T]` (Limit ≤ 50, paged, field-level, one platform modlog entry per run), the query proven on dev Firestore; runbook section "Rogue moderator or community raid" | backend-developer + sre-performance (runbook) | M | W5-51b, W5-29 | opsctl and communities moderation files | Done (PR pending; gate: before percent) |
| W5-53 | *(W5-38 L-1 / F16, L-2)* `SetCommunityListing` returns `authorId`: a moderator's hide or restore of the owner's or another moderator's post or reply is FORBIDDEN `not_owner` (0 extra reads); a post with `moderation` set is NOT_FOUND, so a hide and restore cannot erase a platform removal | backend-developer | S | W5-51 merged, W5-28 | `SetCommunityListing` before W5-51b | Done (gate: before percent) |
| W5-54 | *(W5-38 L-3)* While creation is allowlisted, UpdateCommunity by an owner outside `COMMUNITY_CREATORS` is FORBIDDEN `not_creator` (0 reads); runbook lines on cached labels (the posts-cache label lag folds in here); the suspended-community label seam stays on the open-creation list | backend-developer | XS | W5-51 merged, W5-23 | yes | Open (gate: before prod on) |
| W5-55 | *(W5-38 L-4)* The Cf and filler rule in `identity.BioText` (keeping `\n`, and ZWJ, ZWNJ and emoji tags inside sequences), vectors in `testdata/profile_text/bio.json`; covers bios, list descriptions and community description and rule text | backend-developer | S | W5-45 | `identity` text files | Done (gate: before prod on) |
| W5-55b | *(W5-38 L-4)* Dart port of the W5-55 rule (bio, list description, community description and rules) with the fixture runner | frontend-developer | S | W5-55, W5-49 | no | Done (gate: before prod on) |
| W5-56 | *(W5-38 L-5, F17)* ListCommunityMembers drops a protected member's row for a viewer who is not the owner, a moderator, an approved follower or the member (0 reads); role holders stay listed; `memberCount` unchanged | backend-developer | XS | W5-51 merged, W5-25b | yes | Open (gate: before prod on) |
| W5-56b | *(W5-38 §7, F17)* Privacy Policy lines for communities (report §7, without "protected accounts included"), worded with legal review (roadmap section 9, item 3.26) | architect (draft) + founder (approval) | S | W5-56 | yes | Open (gate: before prod on) |
| W5-57 | *(W5-28 D-1, W5-38 I-3)* Call `timeline.Server.ForgetCommunityFeed(cid)` after a committed restore, through an apiserver callback; un-skip W5-36's repro; runbook `communities.md` §4e and `docs/code-map.md` | backend-developer | XS | W5-28, W5-36 | apiserver wiring | Done (#652) |
| W5-58 | *(W5-27 follow-up)* Comment-only fix of the stale SetHomeTabs comment in `timeline.proto` (COMMUNITY tabs are accepted since W5-27); `make proto`, `buf breaking` clean | architect | XS | — | `timeline.proto`: one proto PR at a time | Done (#654, with W5-51) |
| W5-59 | *(ADR-0031 D6, W5-27 follow-up)* A community post created on an instance reaches that instance's shared community entry at once (the entry is marked stale and refills incrementally, 1 + new reads); the author's device already inserts it (W5-34) | backend-developer | XS | W5-57 | apiserver wiring, after W5-57 | Open (no gate) |

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
5. **W5-38 follow-ups (Part B):**
   - W5-51 first (the ADR-0031 amendment; the founder's OK before merge). Then W5-53 → W5-51b → W5-51c, and W5-52 ‖ W5-54 ‖ W5-56 → W5-56b; W5-52b after W5-51b.
   - Independent of the amendment: W5-55 → W5-55b.
   - No gate: W5-57 (after W5-36 merges) → W5-59; W5-58 any time (it may ride in W5-51's PR).

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
| `app/lib/shared/widgets/post/post_card.dart` (context label, post menu) | W5-33, W5-35 | W3-17 (pinned label, pin menu), W4-16 (hashtag tap) | one at a time |
| `app/lib/features/profile/presentation/widgets/profile_header.dart` (overflow menu) | W5-13 | W3-13, W3-14 | after W3-14 |
| composer files (`app/lib/features/compose/...`) | W5-34 | W1.5 composer conformance, W6 | one at a time |
| `backend/internal/posts/community_moderator.go` (`SetCommunityListing`, `listingDoc`), its mirror `communities.PostModerator`, `backend/internal/communities/repo_moderation.go` and `service_moderation.go` | W5-53, W5-51b, W5-52, W5-52b | — | one at a time: W5-53, then W5-51b, then W5-52b; W5-52 rebases on whichever lands first |
| `backend/internal/apiserver` wiring of callbacks into `timeline.Server` (communities and posts never import timeline) | W5-57, W5-59 | — | W5-57, then W5-59 |
| `docs/code-map.md`, `docs/ui-catalog.md` | every ticket | every wave | trivial merges |

**Definition of done per ticket:**
- Backend: Go unit tests plus emulator integration (`make test-int`, `budgettest.Assert` on every RPC).
- Client: widget tests in light and dark at 360 / 600 / 1200 via `test/support/theme_harness.dart` for every new screen or widget, at text scale 1.0 / 1.3 / 2.0. Pixel goldens are deferred (B-01).
- `make ci` green.
- `docs/code-map.md` / `docs/ui-catalog.md` updated; this table's Status updated in the PR.

## Tickets

### W5-1 — ADR "Lists and custom Home tabs at Stage 0"  [owner: architect] [size: M] [depends: —]  Status: In review (PR #485)
- **Description.** `docs/adr/0030-lists-and-custom-home-tabs.md` (Accepted 2026-10-30). 0024 and 0025 went to W3, 0026 to W8, 0027 to W7, 0028 to W4 and 0029 to W6, so Part A is 0030. It decides:
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
- **Description.** `lists.FirestoreRepo` owns `lists/{listId}` (Snowflake id): `ownerId`, `name`, `description`, `private`, `memberIds[]`, `memberCount`, `hidden` (platform, written by `opsctl lists hide|restore`, W5-44), `createdAt`, `updatedAt`.
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
  - **Runbook `docs/runbooks/lists.md`:** the kill switch, caps, a stuck eraser page, the F4 rule, and how to hide an abusive public list (W5-44).
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
- **Budget change (W5-45, L-3 and L-4).** Service reads (interceptor excluded): a real add 6 cold (7 on overflow; +1 fresh `users/{target}` in the transaction), add replay 4, create replay 2, update replay 2, remove replay 2 (+1 list read each; a first call is unchanged). The idempotency record holds the list id only. Details: ADR-0030 implementation note 2026-10-31.
- **Budget.** Add 5 cold / 2 warm, 2 writes; Remove 2 / 1, 1 write.
- **Flag.** `FEATURE_LISTS`.
- **Seam.** Block checks only through `graph.Reader.Snapshot`; the users check only through `identity.Directory`.
- **Parallel with W3 Part A / W4:** yes.

### W5-7 — List reads  [owner: backend-developer] [size: M] [depends: W5-4]  Status: In review (PR #518)
- **Description.**
  - **GetList:** private → NOT_FOUND for non-owners. A non-owner viewer also reads the owner graph for F4. `hidden` (W5-44) → NOT_FOUND for non-owners. `pinned_by_viewer` comes from the caller's `homeTabs` (0 reads).
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

### W5-8 — `GetListTimeline`  [owner: backend-developer] [size: M] [depends: W5-7]  Status: In review (PR #524)
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

### W5-9 — Home tabs  [owner: backend-developer] [size: M] [depends: W5-3, W5-7]  Status: In review
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
- **Budget.** Superseded by ADR-0030 D7 (idempotency on every mutation): worst 19 reads, typical 4, writes 2 (users field-level, idempotency); the same tabs under a new key 1 write; a replay 2 reads, 0 writes. The "same order again, 0 writes" criterion holds only for a replay of the same key. GetMe +0 reads.
- **Implementation note (W5-9).** GetMe does not drop dangling tabs (proto and ADR D6: +0 reads; the client shows them unavailable and offers Unpin); it drops only tabs whose kind is off for the caller. `homeTabs` is a `userDoc` field so whole-document rewrites keep it; `Profile` carries it as the comparable string `HomeTabsEnc`. `pinned_by_viewer` (GetList and the GetListTimeline header) reads the viewer's tabs through `identity.Directory`.
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

### W5-12 — List detail  [owner: frontend-developer] [size: M] [depends: W5-10]  Status: Done (PR pending)
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

### W5-13 — "Add to Lists" and a user's lists  [owner: frontend-developer] [size: S] [depends: W5-11, W3-14]  Status: Done (#531)
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
- **As built.** The profile overflow menu (graph on and off variants) gets "Add or remove from Lists" and "View Lists" for another user when `lists` is on (`ProfileHeader.listsEnabled`); the Add row is hidden while the viewer blocks the profile. The sheet is `showAddToListsSheet` over `AddToListsCubit`: 1 `ListUserLists(contains_user_id)` per open, then 1 Add or Remove per toggle, optimistic with rollback and the `listsErrorMessage` reason inline; the idempotency key is reused when the same toggle is retried after a failure and dropped after a success. `/u/:userId/lists` is `UserListsScreen` over `ListsCubit(ownerId:)`, behind the `lists` redirect; the handle travels as `extra` for the header only. Not built: pagination beyond 3 pages of 50 (the owner cap is 20).
- **Parallel with W3 Part A / W4:** **after W3-13 / W3-14** (`profile_header.dart`).

### W5-14 — Home tab bar and Manage pinned  [owner: frontend-developer] [size: M] [depends: W5-10, W5-12]  Status: In review (#537)
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
- **As built (W5-14).**
  - Gate: `lists` and `ui_shell` both on. With either off, `HomeScreen` renders the one-tab Following header and makes no Lists call; `/home/pinned` redirects Home.
  - Worst case per Home open with the flag on:

    | Moment | RPCs |
    |---|---|
    | Startup | `GetMe` carries `home_tabs`: 0 extra |
    | Following | unchanged (cached read, one throttled `GetHomeTimeline`) |
    | A pinned list with no known name (another user's list, new device) | 1 `GetList` each, once per session; at most 5 |
    | First visit to a list tab | 1 `GetListTimeline` (none when refreshed < 60 s ago) |
    | Switching back to a visited tab | 0, or 1 throttled refresh when it is 60 s or more stale; hidden tabs never tick |
    | Manage pinned open | 1 `ListUserLists` |
    | Pin, Unpin, one reorder | 1 `SetHomeTabs` each (a burst while one is in flight sends one follow-up) |

  - Not built: the communities rows (arrive with W5-30).
- **Parallel with W3 Part A / W4:** `home_screen.dart` serialises with W3-19.

### W5-15 — Part A backend tests  [owner: tester] [size: M] [depends: W5-6 to W5-9]  Status: In review (PR #539; report `docs/reviews/tests/test-report-w5-lists.md`)
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

### W5-16 — Part A client tests  [owner: tester] [size: S] [depends: W5-11 to W5-14]  Status: In review (PR #551)
- **Description.** The responsive matrix and flows: Lists → create → detail → pin → Home tab → reorder → unpin; flag combinations (`lists` × `ui_shell`); sign-out clears state; text scale 2.0 overflow checks.
- **Acceptance criteria.** Every new widget is covered at 360 / 600 / 1200, light and dark; no overflow at 2.0.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Under test: `lists` × `ui_shell`.
- **Seam.** —
- **Parallel with W3 Part A / W4:** yes.

### W5-17 — Part A security review  [owner: security-auditor] [size: S] [depends: W5-6 to W5-9, W5-13]  Status: In review (report `docs/reviews/security/security-w5-lists.md`)
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

### W5-18 — Part A cost and performance budget  [owner: sre-performance] [size: S] [depends: W5-8, W5-9]  Status: In review (#538)
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

### W5-19 — Part A dev rollout  [owner: production-deployer] [size: S] [depends: W5-15, W5-17, W5-18, ADR-0030 merged]  Status: Done in dev 2026-10-31 (see "Dev rollout result" below)
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
- **Dev rollout result (2026-10-31).**
  - **State.** `feature_lists = allowlist` with 3 uids (the founder's account and two dev test accounts; dev ceiling 3, #546) was applied earlier on 2026-10-31, so this ticket needed no apply. Serving revision `api-00953-giw` (100%, fallback `api-00950-kuh`); all 15 list env vars (`FEATURE_LISTS*`, `LISTS_MAX_PER_USER` 20, `LIST_MAX_MEMBERS` 150, `HOME_TABS_MAX_PINNED` 5, the quotas, rate limits and `CACHE_LISTS_ENTRIES`) are live with the values in `envs/dev/main.tf`. Prod: untouched.
  - **Targeted plan** (from the main checkout's `envs/dev`, `-target` the `api` service and the `billing_alerts` topic, no plan file): 0 to add, 1 to change, 0 to destroy. **0 changes for lists.** The one change is a non-lists env add pending from #554, `RATE_LIMIT_MEDIA_FINALIZE_PER_MIN=10` (equal to the code default, so no behaviour change; accepted in `docs/reviews/security/security-w6-40-attempt-cap.md`), plus the known `template.revision -> null` line. Not applied. The 3.10 drift items stay outside the plan.
  - **Smoke as dev test accounts (API only), 18:00 to 18:02 UTC:**
    - Owner (allowlisted) created a public and a private list; the cap count (`ownerId ==` with `Limit(21)`, a transaction aggregation inside CreateList) ran twice on real Firestore with no "requires an index" error. `ListUserLists` by `owner_id`, by `owner_id` plus `contains_user_id`, and by `contains_user_id` alone (the Lists screen and "Add to Lists" queries) all answered 200.
    - Added 3 members (the two other test accounts and the owner itself: the lists module sends no notification, and a self-add is always allowed, so no founder account was touched); the member page showed 3 and `GetList` `member_count` 3; a member removal gave 2; a rename worked.
    - List timeline: cold open 3 posts (the members' existing posts, `since_token` set, no older page), refresh 0 new, a second allowlisted account read the same 3.
    - Home tabs: pin list A (title set, `pinned_by_viewer` true), pin A and B, reorder to B, A (read back through `GetMe` `home_tabs` each time), then unpin all. The owner's `home_tabs` was empty before, so the saved snapshot `[]` was restored exactly.
    - Negatives: a private list is `NOT_FOUND` for another allowlisted user on both `GetList` and `GetListTimeline`; the non-allowlisted account got `FAILED_PRECONDITION` + `FEATURE_DISABLED` (`feature=lists`) on `CreateList`, `GetList`, `GetListTimeline` and `SetHomeTabs`.
    - Cleanup: both lists deleted; `GetList` and `GetListTimeline` of each answer `NOT_FOUND`; `ListUserLists` for the owner and for the member each show 0; `home_tabs` equals the saved snapshot; the flag was left at `allowlist` (3 uids), not turned off (that would need an apply).
  - **Logs** (`dzeroth-dev`, service `api`, the smoke window). `list_op` lines: `create` done x2 (3 and 4 reads, 3 writes), `add` done x4 (3 to 5 reads, 3 writes), `remove` done x1 (2 reads, 2 writes), `update` done x1 (3 reads, 2 writes), `delete` done x2 (3 reads, 1 write), `members` ok x1 (0), `user_lists` ok x6 (1 read), `get` ok x3 and `rejected:not_found` x3. `timeline_op=list`: ok x4 (owner cold open 4 reads = 3 + C with C = 1, refresh 0, a second account's cold open 1, a re-open 0) and `not_found` x2 (0 reads). The only WARNING lines were the 9 probes above (5 x 404 for the private or deleted list, 4 x 400 `FEATURE_DISABLED` for the non-allowlisted account). No ERROR line and no 5xx in the window. The lines carry `uid_hash` (a prefix of a hash), not the uid.
  - **Deviations from the ticket.**
    - The step "turn the flag off" was replaced by keeping the allowlist, as the Flag line plans (turning it off needs an apply).
    - Order of the dependencies against the allowlist apply (the Terraform revision `api-00429-lcx`, 12:42 UTC): W5-18 (#538, 12:14 UTC) and W5-17 (#540, 12:27 UTC) were merged before it; W5-15 (#539) merged at 13:03 UTC, 21 minutes after it and well before the smoke (18:00 UTC). The smoke ran on `api-00953-giw`, which also carries the W5-41 to W5-44 fixes merged after the apply. The status cells of W5-15, W5-17 and W5-18 in the table above are stale (owned by those tickets).
    - The first smoke was API-only: the Lists screen, the Home tab bar and Manage pinned (W5-11 to W5-14) were not driven in the app, and no Android or web client check was made.
  - **Proven 2026-11-01** (was owed): the `memberIds array-contains uid` query, used by the eraser `RemoveMemberPage` and the `lists_member_of` export page, works on dev Firestore with the automatic array index (no override in `firestore.indexes.json`).
    - w7smoke1 created a private list and added w7smoke2.
    - w7smoke2's export was READY on the first poll, with `lists_member_of` `{public: [], redactedCount: 1}`.
    - The export's exact query, ordered by document id, also ran by REST with no index error.
    - The proof list was deleted afterwards.
  - **Still owed:** the latency questions in `docs/reviews/cost-model.md` section 17 (warm p95, cold start on Cloud Run) need real traffic from the allowlist and were not measured here.
  - Prod: no change (held release).

### W5-20 — ADR "Communities and their moderation scope at Stage 0"  [owner: architect] [size: M] [depends: —]  Status: In review (PR #583)
- **Description.** `docs/adr/0031-communities-and-moderation-scope.md` (Accepted 2026-11-01, #583). 0028 went to W4, 0029 to W6 and 0030 to Part A, so Part B is 0031. It decides:
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
- **A1 dev check (recorded in ADR-0031 D3).**
  - Run by the architect agent with the local `gcloud` user credential on 2026-11-01, 04:34:00 to 04:34:09 UTC.
  - Method: Firestore REST `runQuery` on `dzeroth-dev` (not the emulator), read-only, `limit` 5, about 13 billed reads.
  - Results, all on `posts where communityId == <probe> ORDER BY __name__ DESC`:
    - page 1: HTTP 200;
    - `since` (`__name__ >`, and the `EndBefore` cursor): HTTP 200;
    - older page (`__name__ <`, and the `StartAfter` cursor): HTTP 200.
  - The gap window, the member and banned pages and the directory also pass.
  - The controls fail as they must, with HTTP 400 FAILED_PRECONDITION "The query requires an index":
    - `ORDER BY createdAt DESC, __name__ DESC`;
    - `state == BANNED ORDER BY joinedAt`.
  - **No composite index is needed, so W5-21 does not touch `firebase/firestore.indexes.json`.**
  - W5-40 re-runs the forms on real data before the flag leaves `off`.

### W5-21 — Part B protos  [owner: architect] [size: S] [depends: W5-20 drafted]  Status: Done (#590)
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
- **ADR-0031 changes.**
  - A1 passed on the dev Firestore (D3). **No index-file change and no fieldOverride.**
  - A7: **no new `ReplyPermission` value.** Add a comment on `NOT_ALLOWED`: on a post carrying `community` it means members only.
  - `REPORT_TARGET_TYPE_LIST` shipped in W5-44, so only COMMUNITY is added.
  - `idempotency_key` goes on all seven mutations (D8).
  - `viewer_role` is OWNER / MODERATOR / MEMBER / BANNED / NONE (D4).
  - ListModerationLog is paged, at most 25 entries, with a `seq` token.
  - Errors gain FORBIDDEN `reason=not_owner`, FAILED_PRECONDITION `reason=owner|moderator|community_archived` and `PROTECTED_ACCOUNT` (change item 20).
  - `CreatePost.community_id` with a `reply_policy` other than EVERYONE is VALIDATION (F8).

### W5-22 — Generate, `FEATURE_COMMUNITIES`, config, module skeleton  [owner: backend-developer] [size: M] [depends: W5-21]  Status: Done (#596)
- **Description.** As W5-3, for:
  - `FEATURE_COMMUNITIES` (wire `communities`);
  - `COMMUNITY_CREATORS` (≤ 10 uids, validated with `ids.ValidUID`);
  - the community caps and rate limits from the abuse section, `CACHE_COMMUNITIES_ENTRIES` 2,000, `CACHE_COMMUNITY_FEED_ENTRIES` 500;
  - `quota.Record` `communityJoins` / `communityPosts` with tiers;
  - `flag-ceiling.json` `COMMUNITIES` dev `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}` (ADR-0031 D10, A14; not the 6 of earlier flags) (**founder-gated**);
  - the names #590 fixed (ADR-0031 N1, N6): `ERROR_REASON_FORBIDDEN` and `ERROR_REASON_COMMUNITY_STATE` with `metadata["reason"]`, and the RATE_LIMITED, QUOTA_EXCEEDED and LIMIT_REACHED names;
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
- **ADR-0031 changes (D10, D11, D12).**
  - The dev ceiling `COMMUNITIES` is **allowlist 3**, not 6: the Flags table and the LISTS precedent (#546).
  - Cache sizes: `CACHE_COMMUNITIES_ENTRIES` **200** and `CACHE_COMMUNITY_FEED_ENTRIES` **100**. Also `CACHE_COMMUNITY_MEMBERS_ENTRIES` 5,000.
  - Add the `community_mutation_daily` (`COMMUNITY_MUTATIONS_PER_DAY` 200) and `COMMUNITY_MOD_ACTIONS_PER_DAY` (200) `DailyCap`s.
  - Add the `uid|cid` `COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY` (20) `DailyCap`.
  - Rate-limit buckets: write 20, read 30 and timeline 12 per minute.

### W5-23 — Communities write path  [owner: backend-developer] [size: M] [depends: W5-22]  Status: Done (#601)  (**ships in one PR with W5-24**)
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
  - Given a caller not in `COMMUNITY_CREATORS`, then FORBIDDEN `reason=not_creator` with 0 reads.
  - Given 2 owned, then LIMIT_REACHED `limit=communities_owned`.
  - Given a replay, then 0 writes.
  - Given 11 rules, then VALIDATION `field=rules`.
- **Test notes.** Emulator `budgettest`; replay; the text tables.
- **Observability.** `community_op`, outcome, `fs_reads`, `fs_writes`; never names or ids.
- **Budget.** Create 5 / 3 reads, 5 writes; Update 3 / 1; Get 3 / 0–1.
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** `communities.Service`; only `communities` touches its collections.
- **Parallel with W3 Part A / W4:** yes (new package).
- **ADR-0031 changes (D2, D8, Cost impact).**
  - The member doc stores `state` (JOINED / BANNED) with `joinedAt` or `bannedAt`, **never a role**. OWNER and MODERATOR come from the community doc.
  - The community doc also has `removalsTruncatedAt` and `modlogSeq`.
  - CreateCommunity has **no daily quota**: the owned cap of 2 is exact and lifetime.
  - Budgets:
    - Create: 3 / 2 reads, 4 writes.
    - Update: 4 / 3 reads, 2 writes (1 when unchanged); it stores the idempotency doc too.
    - Get: 15 cold (owner + ≤ 10 moderator profiles), 0 warm, planning 4.
- **As built (#601).**
  - Measured by the emulator `budgettest`, without the interceptor's 1: Create 2 reads and 4 writes (replay 2 reads, 0 writes); Update 3 reads and 3 writes for an owner's first edit, 2 writes after that, 2 reads and 1 write when nothing changes, replay 0 writes; Get 14 cold with an owner and 10 moderators, 0 repository reads warm.
  - Check order: the creators check first (0 reads, before the key and the text), then the key, then the text. Update: NOT_FOUND (missing or SUSPENDED, the owner included, N3), then `not_owner`, then `community_archived`; an ownerless ARCHIVED community therefore answers `not_owner` to everyone.
  - A replay of Create or Update on a community that is SUSPENDED since answers the one NOT_FOUND. The idempotency record holds the community id only; a replay re-reads the community.
  - Caches: the community doc and the member doc 60 s (absence cached, so an outsider's repeat Get reads nothing); a missing community id is remembered 60 s too (the lists precedent; not in D12). A write fills the writing instance from the written data.
  - `GetCommunity` skips the member-doc read for the owner and moderators (the community doc decides their role). SUSPENDED answers right after the community read, before the member doc, the graph or any profile, so its cost and bytes match a missing id.
  - `identity.BioText(s, maxRunes)` is the exported bio rule (`bioIssue` is BioText at 160).

### W5-24 — Communities lifecycle  [owner: backend-developer] [size: M] [depends: W5-22]  Status: Done (#601)  (**ships in one PR with W5-23**)
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
- **ADR-0031 changes (D9, F12).**
  - `modlogged` holds every community whose modlog names the uid as actor **or target** (I-L). That covers a member who was banned, unbanned, then deleted.
  - The hand-over goes to the first ACTIVE uid in `moderatorIds` (appointment order).
  - An archive keeps the name, description and rules.
  - The export is `{joined, owned, banned, moderationActions, redactedCount}`, with no other user's uid.
  - Budget: 1 read + 2 per community (+ ≤ 10 profiles per owned community).
- **As built (#601).**
  - Step placement: appended **after `poll_votes`** (the ADR said "after `lists`", but `poll_votes` was registered since); step names are persisted, so it is never inserted earlier. Wired in `apiserver/lifecycle_communities.go`.
  - The checkpoint is `{after: <last finished community id>, communities, handovers, archived}`, not an index into the sorted list, so a late change to the list cannot shift the resume point. One invocation handles up to 10 communities (each in its own transaction) and deletes the memberships doc in the same call when it finishes; a rerun is 1 read and 0 writes. Reference account (2 joined): 5 reads, 2 writes, 3 deletes, measured.
  - A hand-over candidate must be ACTIVE (`identity.Directory`, cache-first) and still have a memberships doc, read inside the transaction (+1 read per ACTIVE candidate tried, at most 10). The new owner's memberships get an `Update` with `ArrayUnion` on `owned` and `modlogged`, never a `Set`, so a moderator who is mid-deletion is skipped and never recreated as residue.
  - Archive on the owner's deletion writes **no** modlog entry (D9). A SUSPENDED community whose owner leaves with no successor stays SUSPENDED with `ownerId ""` (the eraser must not un-suspend it).
  - Export reads **1 + 2 per community** (the community doc and the user's own member doc, which alone carries `joinedAt` and `bannedAt`), not the ADR's 1 + 1: the reference account's section is 5 reads, not 3. A SUSPENDED community the user does not own, and a community whose doc is gone, count once in `redactedCount` and emit no row (`moderationActions` included). Reference-account lifecycle budgets: +1 read for the step and +1 for the section on an account with no memberships.
  - `.claude/skills/firestore-data-model/SKILL.md` (code-owner gated) still says "after `lists`" and "1 + the communities" for the export, and omits the extra memberships read per hand-over candidate; stored field names match.

### W5-25 — Join, leave and My Communities  [owner: backend-developer] [size: M] [depends: W5-23]  Status: Done (#613)
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
- **ADR-0031 changes (D2, D8).**
  - The Join transaction **never reads the community doc**: `memberCount` is a blind `Increment`, and the status comes from the 60 s cache.
  - "Already a member" writes **1** (the idempotency doc), not 0. So does Leave by a non-member.
  - Budgets:
    - Join: 6 / 4 reads, 5 writes.
    - Leave: 5 (6 for a moderator) / 3 reads, 3 writes + 1 delete.

### W5-25b — Directory and member list  [owner: backend-developer] [size: S] [depends: W5-25]  Status: Done (#626)
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
- **ADR-0031 changes (D3, D7, F14).**
  - The banned page orders by `bannedAt`: **field presence is the filter**, not a `role == BANNED` equality. That shape needs a composite index (dev control C2 failed).
  - Budgets:
    - directory: 52 cold (≤ 22 at Stage 0) / 0–2 warm;
    - members: 43 / 103 cold at page 20 / 50, counting the profile hydration and the caller graph.
  - An owner or moderator also sees the members who block them (F14).

### W5-26 — Posting into a community  [owner: backend-developer] [size: M] [depends: W5-23, W5-25]  Status: Done (#629)
- **Description.**
  - **`posts.CommunityGate`** (consumer-side, implemented by communities) inside CreatePost's transaction for a root post or quote with `community_id`:
    - the community is ACTIVE;
    - the caller is a member and not BANNED (member doc read **fresh** in the transaction);
    - `quotas.communityPosts` is reserved in the existing quota write;
    - the per-`(uid, cid)` `DailyCap`.
  - The post doc gets `communityId` and `community {id, name}`.
  - `community_id` on a reply → VALIDATION (replies follow the root). SchedulePost has no `community_id` field (#590, ADR-0031 N7), so a scheduled post is always an ordinary post.
  - `posts.Reader.ByCommunity(ctx, cid, window, limit)`: A1's query, root posts only, Limit 1..50.
- **Acceptance criteria.**
  - Given a non-member, then FORBIDDEN `reason=not_member` and 0 writes.
  - Given a ban on another instance a second ago, then the next post is refused (fresh read).
  - Given 51 community posts in a day, then QUOTA_EXCEEDED `quota=community_posts`.
  - Given `ByCommunity` on 25 posts, then pages of 20 + 5, newest first (functional on the emulator; the index question is settled only by A1's dev check or the W5-21 index).
- **Test notes.** Emulator `budgettest` (+2 / +1 reads over CreatePost, +0 writes); the A1 query shapes (since, page); the existing CreatePost tests unchanged.
- **Observability.** The CreatePost log line gains `community_post` (bool) and `community_gate` outcome.
- **Budget.** +2 cold / +1 warm reads, +0 writes.
- **Flag.** `FEATURE_COMMUNITIES` (with `posts`).
- **Seam.** `posts.CommunityGate` and `posts.Reader.ByCommunity`; posts never imports communities.
- **Parallel with W3 Part A / W4:** **after W3-7** (`hasMedia` on every create path).
- **ADR-0031 changes (D3, D5, F6).**
  - `ByCommunity` is its own query, `communityId == C ORDER BY __name__ DESC` with id-bound windows. **Never `FirestoreRepo.run()`**: its `createdAt DESC` order needs a composite index (dev control C1).
  - Unit-test the settle sentinel: `EndAt` of the smallest Snowflake of millisecond W.
  - Refusals:
    - a protected caller: FAILED_PRECONDITION `PROTECTED_ACCOUNT`;
    - an ARCHIVED community: `community_archived`;
    - a `reply_policy` other than EVERYONE with `community_id`: VALIDATION.
  - The post also gets `conversationCommunityId`.

### W5-26b — Members-only replies and the label kill switch  [owner: backend-developer] [size: S] [depends: W5-26]  Status: Done (#633)
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
- **ADR-0031 changes (D5, A7).**
  - The rule keys on the parent's **`conversationCommunityId`**, which every reply inherits, not on the root's `communityId`. A reply to a reply never reads the root, and a hidden root has no `communityId`.
  - **No new enum value:** `NOT_ALLOWED` on a post carrying `community`.
    - GetCommunityTimeline: +0.
    - GetPost and GetThread: +1 cold, +0 warm.
    - Home, profile, list and search timelines: UNKNOWN.
  - Reply budget: +2 cold (community status and member doc, both cached) / +0 warm.

### W5-27 — `GetCommunityTimeline` and community tabs  [owner: backend-developer] [size: M] [depends: W5-26, W5-9]  Status: Done (#634)
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
- **ADR-0031 changes (D6, A3, A12, F14).**
  - `keep` does not test `communityHidden`: a hidden post has already left the query. It drops ids in `recentRemovals` instead.
  - F14: an owner or moderator keeps the rows of members who block them.
  - Cold budget: **25 / 55**, which adds the viewer's member doc for `viewer_role`.
  - Every shared-entry fill reads at most `page_size`.
  - Truncation is detected with `removalsTruncatedAt`, not with "the array is full".
  - SetHomeTabs accepts any ACTIVE or ARCHIVED community. Membership is not required.

### W5-28 — Community moderation  [owner: backend-developer] [size: M] [depends: W5-26]  Status: Done (#636)
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
  - Given 201 actions, then RATE_LIMITED `limit=community_mod_actions_daily`.
  - Given 101 modlog entries, then the oldest is dropped.
  - Given a moderator's first hide in a community, then that community id is in their `modlogged[]`; a second hide adds no write for it.
- **Test notes.** The role matrix (owner, moderator, member, banned, outsider × each action); `budgettest`; idempotent replays (state-setting).
- **Observability.** `mod_action` enum, outcome, `fs_reads`, `fs_writes`; no ids in logs.
- **Budget.** Hide 4 / 2 reads, 2 writes (+1 on the actor's first action in that community); SetMemberRole ≤ 4 reads, ≤ 4 writes (+1 likewise).
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** `communities.Moderation` and `posts.CommunityModerator`; the capped arrays sit behind the interface, so a later `modlog` collection changes no caller.
- **Parallel with W3 Part A / W4:** yes.
- **ADR-0031 changes (D2, D4, D5, D8).**
  - A hide **deletes `communityId`** and sets `communityHidden`; a restore reverses both (A12, through `SetCommunityListing`).
  - Every mutation stores the **standard idempotency doc**, not a "state-setting" replay. Otherwise a late retry of a hide after a restore would re-hide the post.
  - `modlogged` also gets the target (I-L).
  - BAN accepts a non-member.
  - The owner bans a moderator only after removing the role: FAILED_PRECONDITION `moderator`.
  - ListModerationLog is paged at ≤ 25.
  - Budgets:
    - Hide / Restore: 5 / 4 reads, 3 writes (+1 on the actor's first entry);
    - SetMemberRole: 7 / 6 reads, ≤ 5 writes.

### W5-29 — Platform levers  [owner: backend-developer] [size: M] [depends: W5-23, W5-4, W5-28]  Status: Done (#639)
- **Description.**
  - `ReportContent` accepts the COMMUNITY target (the LIST target shipped in W5-44). The target owner is the community owner. The evidence snapshot holds the name, description and rules text. Quota `reports` as today.
  - Opsctl:
    - `community suspend|restore` (status; SUSPENDED hides the community from reads and directory and blocks posting);
    - `takedown-post` of a community post also appends the id to that community's `recentRemovals` (it already reads the post).
  - Runbook entries in `docs/runbooks/communities.md`, `lists.md` and the moderation runbook.
- **Acceptance criteria.**
  - Given a COMMUNITY report, then a report doc with the evidence and 2 writes.
  - Given a suspended community, then GetCommunity and the feed answer NOT_FOUND, and CreatePost into it is refused.
  - Given a takedown of a community post, then the next community refresh lists it in `removed_ids`.
- **Test notes.** Emulator; opsctl dry runs.
- **Observability.** The existing `report_filed` line with `target_type`; opsctl prints counts.
- **Budget.** ReportContent as ADR-0016 (+1 read for the community doc); opsctl is an ops path.
- **Flag.** `reports` for the new target (plus `communities`).
- **Seam.** `moderation` reaches communities and lists only through their `Reader` interfaces.
- **Parallel with W3 Part A / W4:** moderation module only.
- **ADR-0031 changes (D14).**
  - The COMMUNITY evidence is `authorHandle` (the owner's), `communityName`, `communityDescription`, `communityRules` and `postCreatedAt`.
  - ReportContent COMMUNITY: 5 / 2 reads, 2 writes.
  - New lever: `opsctl community archive` (an owner's support request).
  - `suspend-user`'s hide loop also appends to `recentRemovals`, once per community per page, through `communities.PlatformRemovals`.

- **As built (W5-29).**
  - `ReportContent` COMMUNITY: `moderation.CommunityLookup` (apiserver `lateCommunityLookup` over `communities.CommunityReporter`); flags `reports` for the caller and `communities` not globally off; 5 reads cold / 2 warm, 2 writes.
  - `opsctl community suspend|restore|archive` over `communities.Platform` (field-level `Update`, never `Set`); `--report` on suspend only. Archive refuses a SUSPENDED community and has no undo (N10).
  - `takedown-post` and `suspend-user` append through `communities.PlatformRemovals.Append(cid, postIDs, at, limit)` (batch form, N10); `posts.ModerationResult.CommunityID` and `ModerationCheckpoint.PageCommunityPosts` carry the ids at no extra read.
  - Runbooks: `communities.md` section 6 and `moderation.md`. `lists.md` needed no change (W5-44).
  - Moved to W5-36: the end-to-end test of acceptance 3 (a takedown, then `removed_ids` on the next `GetCommunityTimeline` refresh). Tests cover each half: the takedown append here (`TestTakedownAndSuspend_Integration_CommunityRemovals`) and `removed_ids` in W5-27 (`community_feed_test.go`).

### W5-30 — Client data layer B  [owner: frontend-developer] [size: S] [depends: W5-22]  Status: Done (#599)
- **Description.**
  - `CommunitiesRepository` with friendly mapping (FORBIDDEN reasons, caps, quota, FEATURE_DISABLED). FORBIDDEN and COMMUNITY_STATE are their own `ErrorReason` values, mapped by `metadata["reason"]` (#590, ADR-0031 N1); roles come only from `viewer_role` and `CommunityMember.role`.
  - `FeedKey.community(id)`.
  - `kFeatureCommunities`.
  - `HomeTabsRepository` accepts COMMUNITY.
- **Order.** In every served or distributed build before `communities` leaves `off` anywhere (ADR-0031 N8): the reply gate runs whenever the flag is not globally off, and a build without this ticket shows FORBIDDEN as the generic "restricted" message and COMMUNITY_STATE as the profile-required flow.
- **Acceptance criteria.** As W5-10, for communities.
- **Test notes.** Unit tests.
- **Observability.** —
- **Budget.** 0 RPCs by itself.
- **Flag.** `communities`.
- **Seam.** The repository is the only RPC caller.
- **Parallel with W3 Part A / W4:** after W5-10 (`feed_key.dart`).
- **As built (W5-30).**
  - FORBIDDEN and COMMUNITY_STATE map to `CommunityForbiddenException` and `CommunityStateException` (one fixed text per `metadata["reason"]`; an unknown reason is a generic text, never AccountRestricted or ProfileRequired). The other refusals ride the existing mapper cases; `communitiesErrorMessage` gives their text.
  - `CommunitiesRepository` has no session state (no headers cached yet), so it takes no `SessionEpoch`. `FeedKey.community` is wired in `TimelineRepository` as "not available" until W5-32 adds `GetCommunityTimeline`.
  - `HomeTabsRepository` shows and writes COMMUNITY tabs only while `communities` is on; a VALIDATION `tabs` refusal of a write that holds a community tab (the server before W5-27) rolls back and reads as FEATURE_DISABLED `communities`.

### W5-31 — Communities screen and Create  [owner: frontend-developer] [size: M] [depends: W5-30]  Status: Done (#616)
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
- **As built (W5-31).**
  - Routes `/communities`, `/communities/new`, `/communities/:id`, `/communities/:id/members` share one `communities` flag redirect (Home when off). `/communities/new` is flag-gated only: the Create entry needs `can_create`, and a non-creator who opens the URL gets the server's FORBIDDEN `not_creator` text.
  - Drawer row and rail destination (rail only, like Lists) need `communities` and `ui_shell`.
  - My Communities and the directory load, fail and retry independently (an RPC not served yet reads as a calm note inside its section).

### W5-32 — Community page  [owner: frontend-developer] [size: M] [depends: W5-30]  Status: Done (#616)
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
- **As built (W5-32).**
  - `TimelineRepository` fetches `FeedKey.community` through a `communitiesGate` (`GetCommunityTimeline`, like the list path); `onCommunitySeen` is an optional hook, not wired in `bootstrap.dart` (the page reads its header from its one `GetCommunity`).
  - No compose-to-community from the page: W5-34 owns posting, including preselect from `/communities/:id`. (W5-34, #630: the header got a "Post" button for a joined, not archived community; it opens `/compose?community=<id>`.)
  - The members page has no moderation actions (ban, roles): W5-35.
  - Pin / Unpin reuses the new shared `PinToHomeButton` (extracted from the List header).

### W5-33 — Context label row on `PostCard`  [owner: frontend-developer] [size: S] [depends: W5-30]  Status: Done (#614)
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

### W5-34 — Composer audience picker  [owner: frontend-developer] [size: M] [depends: W5-30]  Status: Done (#630)
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
- **ADR-0031 changes (D5, F6, F8).**
  - When a community is chosen, hide the reply-audience control: a community post takes no `reply_policy`.
  - A protected account gets `PROTECTED_ACCOUNT` from the server, so no pill is shown while `is_private`.
  - A draft keeps the community id (ADR-0029 F8). Reset it to Everyone if the user is no longer a member.
  - Show "Only members of <name> can reply" for `NOT_ALLOWED` on a labelled post.

### W5-35 — Moderation UI and reports  [owner: frontend-developer] [size: M] [depends: W5-32, W5-33]  Status: Done (#637); "Report Community" shipped by W5-35b (#641); "Report List" was already shipped by W5-48 (#557)
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

### W5-36 — Part B backend tests  [owner: tester] [size: M] [depends: W5-25 to W5-29]  Status: Done (#650)
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
  - report targets and opsctl suspension, including W5-29 acceptance 3 end to end (`takedown-post` of a community post, then the next `GetCommunityTimeline` refresh lists it in `removed_ids`) and a suspension mid-pagination.

  Coverage on `internal/` stays at 70 % or more.
- **Acceptance criteria.** Every acceptance criterion in W5-23 to W5-29 has a named test; `make test-int` is green.
- **Test notes.** Load shapes from `stage-ladder`: one community at 50 posts a minute and a 20-join-per-second burst on one community doc (with W5-39).
- **Observability.** —
- **Budget.** 0.
- **Flag.** Under test: `communities` in every mode.
- **Seam.** —
- **Parallel with W3 Part A / W4:** yes.

### W5-37 — Part B client tests  [owner: tester] [size: S] [depends: W5-31 to W5-35]  Status: Done (#649)
- **Description.** The responsive matrix and flows: Communities → join → post from the composer → label in Home → community tab → moderator hide → report; flag combinations (`communities` × `lists` × `ui_shell` × `reports`); text scale 2.0.
- **Acceptance criteria.** Every new widget is covered at 360 / 600 / 1200, light and dark; no overflow at 2.0.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Under test: `communities` × `lists` × `ui_shell` × `reports`.
- **Seam.** —
- **Parallel with W3 Part A / W4:** yes.

### W5-38 — Part B security review, including moderator abuse  [owner: security-auditor] [size: M] [depends: W5-25 to W5-29, W5-34]  Status: Done (#647; report `docs/reviews/security/security-w5-communities.md`)
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
- **Result (2026-11-02, #647).** CLEAR WITH CONDITIONS: no Critical or High finding. F6 is confirmed (report §4).
  - Findings: M-1 (moderators cannot remove replies), M-2 (moderation cannot be audited or undone past the capped arrays), and L-1 to L-5.
  - The founder answered the report's three questions on 2026-11-02 (F15 to F17).
  - Every finding is ticketed: W5-51 to W5-56, with W5-51b, W5-51c, W5-52b, W5-55b and W5-56b. That meets this ticket's rule, "fixed or ticketed before any dev allowlist".
  - Gates (report §6): W5-51 to W5-53 before `percent`; W5-54 to W5-56 before prod `on`.
  - Informational items: I-3 is W5-57 (D-1). I-5 and I-7 are covered by W5-51b and W5-52b's runbook section. I-1, I-2, I-4, I-6, I-8 and I-9 need no ticket (accepted, or watched through existing signals).

### W5-39 — Part B cost and performance budget  [owner: sre-performance] [size: S] [depends: W5-27, W5-28]  Status: Done (#644)
- **Description.**
  - Add the Part B rows (+20.3 reads, +0.15 writes, +0.05 deletes, +2.0 requests per DAU; ADR-0031 supersedes the earlier +16.0 / +0.11) to `cost-model.md`.
  - Run `make loadtest SCENARIO=community_feed`: cold and warm shared entry, refresh with 0 and with 5 new, page 50, a hide during refreshes, a join burst.
  - Name the triggers: community feed reads > 15 % of daily reads; a community above 1 post/s; `ABORTED` on a community doc.
- **Acceptance criteria.** The model is updated with measured reads (± 25 % or the plan corrected), and a k6 script is added.
- **Test notes.** —
- **Observability.** A Logs Explorer query for `timeline_op=community` and `fs_reads` in §9.
- **Budget.** 0.
- **Flag.** n/a.
- **Seam.** —
- **Parallel with W3 Part A / W4:** yes.
- **ADR-0031 changes (Cost impact).**
  - The Part B rows are **+20.3 reads, +0.15 writes, +0.05 deletes and +2.0 requests per DAU**, not +16.0 / +0.11.
  - That is about INR 6 / 36 / 114 at 300 / 1,000 / 3,000 DAU.
  - Free reads now run out at about 123 DAU.
  - Measure the cold open both all-cold and with a warm entry.
  - Watch `community_txn_attempts`.

### W5-40 — Part B dev rollout  [owner: production-deployer] [size: S] [depends: W5-36, W5-38, W5-39, ADR-0031 merged]  Status: Done (2026-11-02, dev only; results below)
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
- **ADR-0031 changes (D3, D10).**
  - A1 passed on dev, so there is **no fallback index** to deploy.
  - The smoke **first re-runs ADR-0031 D3's F1, F2b, F3b and M1 on real data**. A "requires an index" error means stop and ask the founder.
  - `COMMUNITY_CREATORS` holds the founder's dev uid.
- **W5-38 condition (2026-11-02).**
  - The review (#647) is CLEAR WITH CONDITIONS. Its dev-allowlist condition is met once #647 merges, because W5-51 to W5-56 are then in this plan. None of them blocks this ticket.
  - `percent` is not this ticket (it needs a founder-gated ceiling raise). It additionally needs W5-51, W5-51b, W5-51c, W5-52, W5-52b and W5-53 merged. It also needs W5-36's role × action matrix green, including the new W5-53 cells (a moderator against the owner's and another moderator's posts; takedown, hide, restore) and the W5-51b reply cells.
  - Prod `on` also needs W5-54, W5-55, W5-55b, W5-56 and W5-56b, and the held release (ADR-0019).
- **Result (2026-11-02, dev `dzeroth-dev` only; prod untouched).**
  - **Apply.** Targeted plan `-target=module.cloud_run_api`: 0 add, 1 change, 0 destroy, only the `api` service template env (no image change). Added env vars: `FEATURE_COMMUNITIES` (`allowlist`), `FEATURE_COMMUNITIES_ALLOWLIST` (3 uids), `FEATURE_COMMUNITIES_PERCENT` (0), `COMMUNITY_CREATORS` (2 uids), `COMMUNITY_MAX_MODERATORS`, `COMMUNITY_MAX_RULES`, `COMMUNITY_MODLOG_MAX`, `COMMUNITY_MOD_ACTIONS_PER_DAY`, `COMMUNITY_MUTATIONS_PER_DAY`, `COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY`, `COMMUNITY_RECENT_REMOVALS_MAX`, `COMMUNITIES_MAX_JOINED`, `COMMUNITIES_MAX_OWNED`, `CACHE_COMMUNITIES_ENTRIES`, `CACHE_COMMUNITY_FEED_ENTRIES`, `CACHE_COMMUNITY_MEMBERS_ENTRIES`, `QUOTA_COMMUNITY_JOINS_PER_DAY`, `QUOTA_COMMUNITY_POSTS_PER_DAY`, `QUOTA_NEW_ACCOUNT_COMMUNITY_JOINS_PER_DAY`, `QUOTA_NEW_ACCOUNT_COMMUNITY_POSTS_PER_DAY`, `RATE_LIMIT_COMMUNITIES_READ_PER_MIN`, `RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN`, `RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN`, plus the inert `FEATURE_ANALYTICS` and `FEATURE_CRASH_REPORTING` (value `off`, allowlist empty, percent 0).
  - **Routing.** The apply created revision `api-00491-7wg` at 0% (same image digest as `api-01100-nuc`); dev traffic is pinned, so it was routed with `update-traffic --to-revisions=api-00491-7wg=100`. `GET /health` answered `ok` (200). Previous serving revision for rollback: `api-01100-nuc` (`--to-revisions=api-01100-nuc=100`; it has no community env, so the flag is off by the code default).
  - **Flag state after the smoke.** `allowlist` (3 uids); prod `off` and unchanged.
- **Smoke results (dev accounts: smoke 1 = owner and creator, smoke 2 = member, smoke 3 = not allowlisted).**

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | ADR-0031 D3 F1: community feed page 1 on real data | Pass | HTTP 200, 2 posts, `next_page_token` set; no "requires an index" |
| 2 | F3b: older page (`page_token`) | Pass | HTTP 200, 2 posts |
| 3 | F2b: `since_token` refresh after a new post (65 s later, past `CACHE_TTL`) | Pass | HTTP 200, exactly the 1 new post |
| 4 | M1: `ListCommunityMembers` | Pass | HTTP 200, 2 members; directory `ListCommunities` HTTP 200, 1 row |
| 5 | Create community (creator) | Pass | HTTP 200, viewer role OWNER, status ACTIVE |
| 6 | `CreateCommunity` by an allowlisted non-creator | Pass | HTTP 403 FORBIDDEN |
| 7 | Join (member) | Pass | HTTP 200, role MEMBER, member count 2 |
| 8 | Post in the community (owner and member) | Pass | HTTP 200, `post.community` set on every view |
| 9 | Community label in Home (follower of the author) | Pass | `GetHomeTimeline` posts carry `community.name` |
| 10 | Pin the community as a Home tab, header refresh, unpin | Pass | `SetHomeTabs` returns kind COMMUNITY; `GetCommunityTimeline` header has name and viewer role; unpin returns 0 tabs |
| 11 | Moderator hide | Pass | HTTP 200; the post is gone from the member's feed on the next call |
| 12 | Restore reappears at once (W5-57) | Pass | the next `GetCommunityTimeline` shows the post again, no 60 s wait; modlog lists HIDE and RESTORE |
| 13 | Ban: post refused, rejoin refused | Pass | both HTTP 403 FORBIDDEN |
| 14 | Unban, rejoin, post | Pass | role NONE after unban, then MEMBER; post HTTP 200 |
| 15 | Report COMMUNITY | Pass | HTTP 200, report id returned, `already_reported` false |
| 16 | `opsctl community suspend` (dry run, then real) | Pass | dry run `reads=1 writes=0`; real `reads=1 writes=1`; after 62 s the member gets NOT_FOUND on read and on post, the owner still sees SUSPENDED |
| 17 | `opsctl community restore` | Pass | after 62 s ACTIVE for the member, post HTTP 200 |
| 18 | Cloud Logging | Pass | `timeline_op=community` x16; `community_op` create, directory, get, hide, join, log, members, my, restore, role; `mod_action` hide, restore, role x2, log; no ERROR-severity lines since the apply |
| 19 | Not-allowlisted account (flag off for it) | Pass | `GetCommunity`, `JoinCommunity`, `GetCommunityTimeline`, `CreatePost` with `community_id`, `ListMyCommunities`: HTTP 400 FAILED_PRECONDITION `FEATURE_DISABLED` (feature `communities`) |

  - **Observations (not failures).** (a) The community feed is served from the shared instance entry for up to `CACHE_TTL` (60 s): a post by the owner showed in Home at once but in the community feed only after the next refill, and a `since` call made inside that window returned the entry's items rather than only the new post. After the window it returned exactly the new post (check 3). Clients treat `since` as a merge, so no change is proposed. (b) `opsctl community suspend` rejects `--note` without `--report`; flags go after the community id.
  - **Test data.** One dev community ("W540 smoke") with about 10 posts, left in place in dev.

### W5-51 — ADR-0031 amendment: reply moderation and the W5-38 rules  [owner: architect] [size: S] [depends: F15, F16, F17]  Status: Done (#654; ADR-0031 Amendment 1 Accepted, founder OK 2026-11-02)
- **Description.** A dated amendment to ADR-0031. The ADR is Accepted, so **the founder's OK is needed before merge**; the decision text stays and the amendment adds to it. One amendment carries every ADR change the W5-38 tickets need, so the founder reviews once:
  - **D4, replies (F15, M-1).**
    - The owner and moderators can hide and restore a reply whose `conversationCommunityId` is the community, at any depth.
    - A hide sets `communityHidden` on the reply (a reply has no `communityId` to delete); a restore deletes it.
    - GetThread drops a hidden reply for every viewer but its author, from rows it already read (0 extra reads).
    - Each action writes one modlog entry (HIDE or RESTORE with the reply's id), as for a post.
    - The D4 table's hide row names replies, and the `stage-ladder` "Community moderation" row says "posts and replies".
  - **D4, targets (F16, L-1).** A moderator cannot hide or restore a post or reply by the owner or by another moderator: FORBIDDEN `not_owner`. The author's role is the current one, from the community doc already read in the transaction. The owner can act on every post; a moderator on their own posts and on members'.
  - **D5, platform removals (L-2).** `SetCommunityListing` answers NOT_FOUND for a post whose `moderation` is set, so a community hide and restore can never erase a platform removal entry.
  - **D4 and D10, editing (L-3(c)).** While creation is allowlisted, UpdateCommunity by an owner outside `COMMUNITY_CREATORS` (an F12 hand-over owner) is FORBIDDEN `not_creator`.
  - **D7, protected members (F17, L-5).** ListCommunityMembers shows a protected member's row only to the owner and moderators, to approved followers and to the member; `memberCount` is unchanged. Role holders stay visible to everyone (D7's GetCommunity rule; F17, answered 2026-11-02, with the join-date residual accepted).
  - **D13, keyed hashes (M-2).** The moderation request lines carry `community_hash`, `post_hash` for hides and restores, and `target_hash` for role actions. Each is an HMAC keyed with `CURSOR_HMAC_KEY`, as W7-34's `conversation_hash`, and an `opsctl` loghash command reproduces it. They are not ids in the D13 sense.
  - **D14, platform recovery (M-2).** `opsctl community hidden` and `restore-hidden` (W5-52b), `communityHiddenAt` and the modlog's platform actor marker (R6).
  - **FU-5 note.** `posts.conversationCommunityId`, `posts.community` and the new `communityHidden` / `communityHiddenAt` stay indexed: W5-52b queries them. The `firestore-data-model` skill's `posts` row gains `communityHiddenAt`.
  - The answers to R1 to R6 in "Questions for @architect".
  - **Comment-only proto updates** (`buf breaking` clean):
    - `communities.proto` HideCommunityPost and RestoreCommunityPost: replies accepted, `not_owner`, NOT_FOUND for a platform-removed post;
    - UpdateCommunity: `not_creator`;
    - `posts.proto` GetThread: hidden replies dropped.

    W5-58's SetHomeTabs comment may ride in the same PR.
- **Acceptance criteria.**
  - Given the amendment, then each item above has its decision, its cost line and the ticket that builds it. The cost line for a reply hide or restore is 5 / 4 reads and 3 writes (+1 on the actor's first entry); GetThread is +0.
  - Given the D4 table, then the hide row covers replies and the F16 refusals, and no row contradicts F9 as answered in F16.
  - Given `buf breaking` against `main`, then it is clean, and the proto change is comments only.
  - Given the PR, then it is not merged before the founder's OK.
- **Test notes.** None (docs). `code-reviewer` checks the seams and that every item maps to a ticket.
- **Observability.** The amendment names:
  - the outcome `rejected:not_owner` on hide and restore;
  - a `mod_target` enum (`post`, `reply`);
  - GetThread's `rows_dropped` cause `community_hidden`;
  - the three hash fields.
- **Budget.** 0 (docs). The amendment's numbers are the source for W5-51b to W5-54 and W5-56.
- **Flag.** None (docs). Every change sits behind `FEATURE_COMMUNITIES`.
- **Seam.** `communities.Moderation` and `posts.CommunityModerator` stay the only writers of `communityHidden`. The reply drop lives in GetThread only.
- **Gate.** Before `percent`.
- **Parallel with W3 Part A / W4:** yes (ADR and proto comments only).

### W5-51b — Reply moderation backend  [owner: backend-developer] [size: M] [depends: W5-51 merged, W5-53]  Status: Done (#658)
- **Description.**
  - `SetCommunityListing` also accepts a reply whose `conversationCommunityId == cid` (a reply never carries `community`). A hide sets `communityHidden` and `communityHiddenAt`; a restore deletes both. A root keeps its rule (`community.id == cid`), and gains `communityHiddenAt` too. W5-53's `authorId` and `moderation` rules apply unchanged.
  - `communities.Moderation` Hide and Restore of a reply:
    - write the modlog entry and the `modlogged` updates as for a post;
    - write **no** `recentRemovals` entry (R1);
    - apply F16.
  - GetThread drops a reply carrying `communityHidden` for every viewer but its author (rows already read), with `rows_dropped` cause `community_hidden`. Replies under it and a hidden focal reply follow R4; the flag rule follows R5.
  - Runbook `communities.md` §7: rewrite the NOT_FOUND row that calls replies out of scope ("replies and REPOSTs carry none"), and add a reply-hide row.
- **Acceptance criteria.**
  - Given a moderator and a member's reply in the community's conversation, when the moderator hides it, then GetThread omits it for other viewers, its author still sees it, and the modlog has a HIDE entry with its id.
  - Given that reply restored, then GetThread shows it to everyone again.
  - Given a reply in another community's conversation, or in a conversation with no community, then NOT_FOUND "post not found" and 0 writes.
  - Given a reply by the owner or another moderator, when a moderator hides it, then FORBIDDEN `not_owner` and no write (F16).
  - Given a reply hide, then the community's `recentRemovals` is unchanged and existing feed tokens stay valid.
  - Given GetThread on a thread with a hidden reply, then the same reads as on that thread without one (+0).
  - Given a replay of the hide's key after a restore, then 0 writes (A13).
- **Test notes.**
  - Emulator integration and `budgettest` on Hide, Restore and GetThread.
  - Add the reply cells to W5-36's role × action matrix: owner, moderator, member, banned and outsider × hide and restore a reply; a moderator against the owner's and another moderator's reply. If W5-36 merged first, this ticket extends its matrix test.
  - Flag off: FEATURE_DISABLED with 0 reads.
  - A hidden reply by a protected author: `posts.Audience` still applies first.
  - Replay with the same key; a new key after a restore.
- **Observability.** `mod_target=reply`; the same outcomes as for posts; GetThread `rows_dropped` cause `community_hidden`. No ids in logs.
- **Budget.**
  - Hide or restore of a reply: 5 reads cold / 4 warm, 3 writes (+1 on the actor's first modlog entry in the community). A no-op writes the idempotency doc only.
  - GetThread: +0 reads.
  - At 0.003 moderation actions per DAU this stays below 0.02 reads per DAU.
- **Flag.** `FEATURE_COMMUNITIES` for Hide and Restore. GetThread's drop applies whenever `communityHidden` is set (R5).
- **Seam.** `posts.CommunityModerator` and its mirror `communities.PostModerator` change together. The drop sits in GetThread only; communities never imports posts.
- **Gate.** Before `percent`.
- **Parallel with W3 Part A / W4:** `posts/community_moderator.go` and its mirror after W5-53 (shared-files table).

### W5-51c — Reply moderation menu  [owner: frontend-developer] [size: S] [depends: W5-51b]  Status: Done
- **Description.**
  - In a thread whose root carries `community`, a reply's overflow menu gets "Remove from Community" (with a confirm) when the caller's role in that community is OWNER or MODERATOR. The role comes from ListMyCommunities, cached for the session (R3). The thread does not carry the reply author's role, so the entry shows on every reply; the server refuses a moderator's hide of the owner's or another moderator's reply (F16), and the client shows the friendly `not_owner` text.
  - After a hide, the reply leaves the open thread at once (local).
  - Restore: the moderation log's HIDE row already restores by post id (W5-35). Check it works for a reply id.
  - The log renders the platform actor marker W5-51 picks (W5-52b's `restore-hidden`), as it renders `_deleted`.
  - A hidden root has no label, so its replies get no menu (R3).
- **Acceptance criteria.**
  - Given a member, then no "Remove from Community" on any reply.
  - Given a moderator in a community thread, then the entry shows on a member's reply, and a hide removes it from the thread.
  - Given a moderator who removes the owner's reply, then the friendly `not_owner` text and the reply stays.
  - Given the log's HIDE row of a reply, then Restore calls RestoreCommunityPost with the reply's id.
  - Given `communities` off, then no entry.
- **Test notes.** Widget tests at 360 / 600 / 1200, light and dark, text scale 1.0 / 1.3 / 2.0; the role matrix; W5-37's flows gain "moderator hides a reply".
- **Observability.** —
- **Budget.** 0 extra RPCs on a thread open (ListMyCommunities is session-cached; a cold session pays one, ≤ 52 reads, once). 1 Hide or Restore per action.
- **Flag.** `communities`.
- **Seam.** The role still comes from the server (`viewer_role` in ListMyCommunities); the client never infers it.
- **Gate.** Before `percent`.
- **Parallel with W3 Part A / W4:** the post menu file serialises with any other post-menu change.

### W5-52 — Keyed hashes on moderation request lines  [owner: backend-developer] [size: S] [depends: W5-51 merged, W5-28]  Status: Done
- **Description.**
  - Every request that writes a modlog entry (hide, restore, set_role, update, a moderator's leave) adds `community_hash` to its request line. Hides and restores add `post_hash`, and role actions add `target_hash`.
  - Each is an HMAC keyed with `CURSOR_HMAC_KEY`. Reuse the W7-34 `conversation_hash` helper and the keyed `HashPost` (search `docs/code-map.md` first).
  - An `opsctl` loghash counterpart prints the hashes for a given community id, post id or uid, so an operator can rebuild one community's history in Logs Explorer.
  - The request line still carries no raw id, name or text (D13 as amended).
- **Acceptance criteria.**
  - Given a hide, then its request line carries `community_hash` and `post_hash` and no raw id.
  - Given a BAN, then the line carries `community_hash` and `target_hash`.
  - Given `opsctl` loghash with the same community id, then it prints the same `community_hash`.
  - Given another key, then the hash differs (keyed, not a plain digest).
- **Test notes.** Unit tests on the fields per action; a log-hygiene test that no raw id appears; the `opsctl` round trip.
- **Observability.** This ticket is the observability change. W5-52b's runbook section holds the Logs Explorer query.
- **Budget.** 0 reads, 0 writes: one HMAC in memory per moderation request.
- **Flag.** `FEATURE_COMMUNITIES` (the paths it logs).
- **Seam.** The shared hash helper in `pkg/platform/logger`; no module-local hashing.
- **Gate.** Before `percent`.
- **Parallel with W3 Part A / W4:** communities moderation files, one at a time with W5-53 (shared-files table).

### W5-52b — Platform recovery of hidden posts and the raid runbook  [owner: backend-developer + sre-performance (runbook)] [size: M] [depends: W5-51b, W5-29]  Status: Done
- **Description.**
  - **`opsctl community hidden CID [--page-token T]`** lists the posts and replies hidden in a community: `posts where conversationCommunityId == C AND communityHidden == true`, Limit ≤ 50, paged by id. Roots keep `conversationCommunityId` after a hide (ADR-0031 D5) and replies always carry it, so one query covers both. It prints ids, kind (root or reply) and hide time, never text. The community id appears only as `community_hash`.
  - **Prove that query on the dev Firestore** before merge. It relies on two automatic single-field indexes, and the emulator never requires an index (the A1 precedent). A "requires an index" error means stop and ask the founder: the index file is founder-gated.
  - **`opsctl community restore-hidden CID [--since T] [--dry-run]`** restores through `posts.CommunityModerator.SetCommunityListing` (field-level, never `Set`):
    - one transaction per page with the community doc;
    - it deletes the matching `recentRemovals` entries;
    - `--since T` uses `communityHiddenAt` (R6);
    - a post with `moderation` set stays hidden and is counted as `skipped_platform` (L-2);
    - each run writes **one** modlog entry with the platform marker (R6).

    opsctl cannot evict an instance's shared feed entry, so a restored root comes back within the 5-minute entry bound (`communityEntryMaxAge`).
  - **Runbook** `docs/runbooks/communities.md`, a new section "Rogue moderator or community raid" (sre-performance):
    - identify: the modlog and the request lines by `community_hash` (W5-52), with the Logs Explorer query;
    - contain: the owner removes the moderator; for a rogue owner, `community suspend`, and `suspend-user` where needed;
    - list: `community hidden`;
    - undo: `restore-hidden --since T`;
    - clean a raid: bans, hides of posts and replies (W5-51b), and `takedown-post` and `suspend-user` for sock accounts;
    - the I-7 residual: there is no lever to replace a rogue owner except the console edit of section 5.
- **Acceptance criteria.**
  - Given 3 hidden posts and 2 hidden replies in a community, then `community hidden` lists all 5 and nothing from another community.
  - Given the dev query, then the ticket records who ran it, when and the result (an emulator run does not count).
  - Given `restore-hidden --since T`, then only posts hidden after T come back, and the modlog gains exactly one platform entry.
  - Given a platform-removed post among them, then it stays hidden and is counted as skipped.
  - Given a post hidden before W5-51b added `communityHiddenAt` (no backfill), then `hidden` lists it with the time "unknown", `restore-hidden --since T` skips it with a `skipped_no_time` count, and a run without `--since` restores it.
  - Given a re-run, then 0 post writes.
  - Given `--dry-run`, then 0 writes.
- **Test notes.** Emulator integration for both commands; the paging; the `--since` cut; the L-2 skip; `opsctl` prints `cost: reads=... writes=...` last, as the other community commands do.
- **Observability.** A fixed-shape `audit:` line with `community_hash` and counts (`listed`, `restored`, `skipped_platform`).
- **Budget.** An ops path, 0 per DAU.
  - `community hidden`: 1 (community doc) + ≤ 50 reads per page; 1 when empty.
  - `restore-hidden`: per page ≤ 50 post reads + 1 community read, and ≤ 50 post writes + 1 community write. A re-run with nothing hidden: 2 reads, 0 writes.
  - Dev query proof: under 20 reads.
- **Flag.** None (opsctl runs whatever the flag; it touches documents only).
- **Seam.** `posts.CommunityModerator` stays the only writer of `communityHidden`; opsctl reaches communities through `communities.Platform`.
- **Gate.** Before `percent`.
- **Parallel with W3 Part A / W4:** opsctl and communities moderation files, after W5-51b (shared-files table).
- **Implementation notes (as built, 2026-11-02, backend-developer).**
  - **Dev proof of the query (AC).** Run by the backend-developer agent on behalf of the lead, 2026-11-02 14:10 UTC, against project `dzeroth-dev` with ADC, read-only:
    - `opsctl community hidden 0110691057677942784 --project dzeroth-dev` (an existing dev community): answered, `rows=0`, `cost: reads=2 writes=0`; `restore-hidden --dry-run` the same, 2 reads. No "requires an index" error.
    - Control (REST `runQuery`, same two equalities with `ORDER BY createdAt DESC, __name__ DESC`): `400 The query requires an index`, as the ADR expects, so the proof discriminates.
    - Reads: 1 (finding the community id) + 2 + 2 = 5, under the 20 allowed. `firestore.indexes.json` untouched. The emulator run does not count and is not claimed as proof.
  - **Seam shape.** `SetCommunityListing` reads then writes per post, and a Firestore transaction refuses a read after a write, so one transaction per page cannot call it once per post. `posts.CommunityModerator` gains `ListHidden` (the listing, outside a transaction) and `RestoreHiddenPage` (reads the page fresh in the transaction, then stages one field-level Update per wanted row, sharing `listingUpdates` with `SetCommunityListing`, so posts stays the only writer of `communityHidden` / `communityHiddenAt`). `communities` declares the identical `HiddenPosts` interface and reaches it through `communities.HiddenRecovery` (`ListHidden`, `RestoreHidden`), implemented by `FirestoreRepo`. A `moderation` post and a REPOST are refused inside posts whatever the caller asks.
  - **Platform marker.** `communities.PlatformMarker` (`_platform`); `ListModerationLog` leaves it out of the profile lookup and returns an unset actor with `actor_deleted` false.
  - **Run shape.** `--since` is applied in memory (`hiddenVerdict`, shared by the real run and `--dry-run`); the modlog entry is requested until a page reports it written; a run stops after 100 pages and prints `--page-token` to resume. `--page-token` is `h1.<post id>`.
  - **community_hash.** `hiddenCommunityHash` in `community_hidden.go` is the one call and returns `communityHashForAudit` (W5-52: the keyed hash with `CURSOR_HMAC_KEY` set, else `unavailable(set-CURSOR_HMAC_KEY)`).

### W5-53 — F16 targets and platform removals in `SetCommunityListing`  [owner: backend-developer] [size: S] [depends: W5-51 merged, W5-28]  Status: Done
- **Description.**
  - `SetCommunityListing` (and its mirror `communities.PostModerator`) also returns the post's `authorId`.
  - It answers found=false for a post whose `moderation` is set, so the caller answers the one NOT_FOUND "post not found" (L-2).
  - The post is already read, so both cost 0 extra reads. The refusal must come before any write: split the read from the write, or pass the check in.
  - In `communities.Moderation` Hide and Restore, a moderator who is not the owner gets FORBIDDEN `not_owner` with no write when the author is the owner or in `moderatorIds` (F16). The community doc is already read in the transaction. A moderator acting on their own post is allowed.
  - Runbook `communities.md` §7: a `not_owner` row for hides, and a NOT_FOUND row for a platform-removed post.
- **Acceptance criteria.**
  - Given a moderator and the owner's post, when they hide or restore it, then FORBIDDEN `not_owner` and no write.
  - Given a moderator and another moderator's post, then the same.
  - Given the owner and a moderator's post, then the hide succeeds.
  - Given a moderator and their own post, then the hide succeeds.
  - Given a post by a former moderator whose role was removed, then a moderator can hide it (the current role decides).
  - Given a platform takedown of community post P, listed in `recentRemovals` at T1, when a moderator hides and then restores P, then both answer NOT_FOUND and the entry from T1 is still listed.
  - Given `budgettest`, then Hide and Restore reads are unchanged (+0).
- **Test notes.** Add the cells to W5-36's role × action matrix: a moderator × an author who is the owner, another moderator, themselves or a member, for hide and restore. Also the takedown, hide, restore sequence; a replay; flag off. If W5-36 merged first, this ticket extends its matrix test.
- **Observability.** `outcome=rejected:not_owner` on `mod_action=hide|restore`; NOT_FOUND keeps `rejected:post_not_found`.
- **Budget.** +0 reads; a refusal writes nothing. Hide and Restore stay 5 / 4 reads, 3 writes.
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** `posts.CommunityModerator` (primitives and the transaction only); posts and communities still never import each other.
- **Gate.** Before `percent`.
- **Parallel with W3 Part A / W4:** `SetCommunityListing` before W5-51b (shared-files table).

### W5-54 — Hand-over owners and cached labels  [owner: backend-developer] [size: XS] [depends: W5-51 merged, W5-23]  Status: Open
- **Description.**
  - **L-3(c).** While creation is allowlisted (always at Stage 0), UpdateCommunity by an owner outside `COMMUNITY_CREATORS` gets FORBIDDEN `not_creator`. The check uses CreateCommunity's creators function, at 0 reads, before the key and the text checks. A hand-over owner keeps every other owner power (hide, ban, appoint moderators).
  - **L-3(a) and the posts-cache label lag (the W5-28 follow-up folds in here; no separate ticket).** Add runbook lines to `communities.md` §7:
    - a hidden post's label stays on devices that cached the card until the card is fetched again (a `since` refresh never re-renders an old row);
    - the label stays in other instances' posts caches for up to `CACHE_TTL` (60 s).

    Both are intended. There is no code change: another instance's cache cannot be evicted, so the 60 s server bound stays.
  - **L-3(b).** There is no work at Stage 0. The suspended-community label lookup stays on the `stage-ladder` "Creation" row as a prerequisite for open creation. Confirm the row still says so.
- **Acceptance criteria.**
  - Given a hand-over owner outside `COMMUNITY_CREATORS`, when they call UpdateCommunity, then FORBIDDEN `not_creator`, 0 reads beyond the interceptor and 0 writes.
  - Given an owner in `COMMUNITY_CREATORS`, then the edit works as before.
  - Given the hand-over owner, then hide, ban and MAKE_MODERATOR still work.
  - Given the runbook, then §7 states both label bounds.
- **Test notes.** Unit and emulator: the F12 hand-over (W5-24's test), then an edit by the new owner. Check the client's `not_creator` text (W5-30) reads right on the edit screen; if it reads as a creation refusal, a one-line text change rides in this PR.
- **Observability.** `community_op=update`, `outcome=rejected:not_creator`.
- **Budget.** The refusal costs 0 reads beyond the interceptor; edits are unchanged.
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** The one creation check function (the `stage-ladder` "Creation" row), now used by both CreateCommunity and UpdateCommunity.
- **Gate.** Before prod `on`.
- **Parallel with W3 Part A / W4:** yes.

### W5-55 — Invisible characters in bio-rule text  [owner: backend-developer] [size: S] [depends: W5-45]  Status: Done
- **Description.**
  - Apply W5-45's Cf and filler rule (from `SingleLineText`) inside `identity.BioText`. Keep `\n`, and keep ZWJ (U+200D), ZWNJ (U+200C), variation selectors and emoji tag characters (U+E0020 to U+E007F) inside sequences, as W5-45 does for names. Reuse its helper.
  - The VALIDATION message stays: it becomes true.
  - **This is an unflagged behaviour change at merge.** `BioText` is the rule for profile bios, list descriptions, and community descriptions and rule text.
  - It applies on write only. Stored text is not rewritten.
- **Acceptance criteria.**
  - Given a community description with U+200B, then VALIDATION `field=description`.
  - Given a rule text with U+3164, then VALIDATION `field=rules`.
  - Given a bio with U+2060 or an interior U+FEFF, then VALIDATION `field=bio`.
  - Given a bio with a ZWJ family emoji, a subdivision flag (a tag sequence), or Hindi or Malayalam text with ZWJ or ZWNJ, then accepted.
  - Given multi-line text, then accepted.
  - Given a stored bio that the new rule would refuse, then reads return it unchanged.
- **Test notes.** Vectors in `testdata/profile_text/bio.json` (shared with the Dart port); the Go fixture runner; the existing bio, list and community text tests stay green.
- **Observability.** —
- **Budget.** 0 (validation only).
- **Flag.** None: a validation rule, applied wherever `BioText` is used.
- **Seam.** `identity.BioText` stays the one bio rule; lists and communities call it.
- **Gate.** Before prod `on`.
- **Parallel with W3 Part A / W4:** `identity` text files, one at a time.

### W5-55b — Dart port of the bio-rule change  [owner: frontend-developer] [size: S] [depends: W5-55, W5-49]  Status: Done
- **Description.** Port W5-55's rule to the client checks for the bio, the list description (`list_text_rules.dart`) and the community description and rules, with the fixture runner over `testdata/profile_text/bio.json`. Dart has no Unicode category data, so reuse W5-49's explicit Cf table.
- **Acceptance criteria.**
  - Given each `bio.json` vector, then the Dart verdict equals the Go verdict.
  - Given a refused character in a field, then the field shows the error before any RPC.
- **Test notes.** The fixture runner; widget tests of the three forms at 360 / 600 / 1200.
- **Observability.** —
- **Budget.** 0 RPCs.
- **Flag.** None (validation).
- **Seam.** One shared Dart helper, catalogued in `docs/ui-catalog.md`.
- **Gate.** Before prod `on`.
- **Done.** `multiLineTextIssue` in `shared/format/single_line_text.dart` (one scanner with `singleLineIssue`, LF kept, no visible-rune rule) backs `bioIssue` (new `BioIssue.invisibleCharacter`) and the community description and rule text (new `CommunityTextIssue.notPlainText`); the list description already used the single-line rule. `profile_text_fixture_test.dart` runs every `bio.json` row; `community_text_rules_test.dart` and the Create Community screen test cover the rest.
- **Parallel with W3 Part A / W4:** no (follows W5-55).

### W5-56 — Protected members on member pages  [owner: backend-developer] [size: XS] [depends: W5-51 merged, W5-25b]  Status: Open
- **Description.**
  - ListCommunityMembers drops the row of a member whose profile is protected (`IsPrivate`), unless the viewer is:
    - the owner or a moderator;
    - that member;
    - an approved follower of that member.

    The profile and the caller's graph are already read, so this costs 0 reads.
  - Role holders' rows stay for every viewer: D7 shows every role holder in GetCommunity, because who moderates is part of the rules, and GetCommunity is unchanged. The founder decided this on 2026-11-02 (F17), with the join-date residual accepted (ADR-0031 Amendment 1, D7a).
  - `memberCount` is unchanged. The BANNED page (owner and moderators only) is unchanged.
  - `next_page_token` follows the query; a short page is allowed, as for the other drops.
  - A runbook line in `communities.md`.
- **Acceptance criteria.**
  - Given protected member P and viewer V who does not follow P, then P's row is absent from V's page.
  - Given V an approved follower of P, then P's row is present.
  - Given V the owner or a moderator, then present.
  - Given P viewing, then present.
  - Given P a moderator, then present for everyone, and GetCommunity lists P.
  - Given `memberCount`, then unchanged.
  - Given a page where every row is dropped, then a short or empty page with a valid next token.
- **Test notes.** Emulator `budgettest` (+0); the viewer matrix above; P's protection turned on after joining (the profile cache bound, 60 s).
- **Observability.** `rows_dropped` cause `protected` on `community_op=members`.
- **Budget.** +0 reads: 43 / 103 cold at page 20 / 50, unchanged.
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** The drop sits behind `communities.Directory`'s member page.
- **Gate.** Before prod `on`.
- **Parallel with W3 Part A / W4:** yes.

### W5-56b — Privacy Policy lines for communities  [owner: architect (draft) + founder (approval)] [size: S] [depends: W5-56]  Status: Open
- **Description.** Add the W5-38 report §7 lines to the Privacy Policy (as refreshed by W6-55, #584), without "protected accounts included" (F17):
  - communities and their members are public;
  - community posts are public posts that also appear on the author's profile and in Home;
  - moderators can remove a post or a reply from the community, not from the platform;
  - the owner and moderators see a moderation log that names them;
  - account deletion removes you from communities and replaces your name in the log with "deleted account".

  The wording is drafted with legal review (`docs/plans/roadmap.md` section 9, item 3.26). That review also decides whether to say how a protected account's membership shows (F17). Not legal advice.
- **Acceptance criteria.**
  - Given the PR, then the founder approves the text by merging it (the W6-55 precedent).
  - Given prod `on` for `communities`, then prod Hosting already serves the text.
- **Test notes.** None (text).
- **Observability.** —
- **Budget.** 0.
- **Flag.** None.
- **Seam.** —
- **Gate.** Before prod `on`.
- **Parallel with W3 Part A / W4:** yes.

### W5-57 — Wire `ForgetCommunityFeed` on restore (D-1)  [owner: backend-developer] [size: XS] [depends: W5-28, W5-36]  Status: Done (#652)
- **Description.**
  - `timeline.Server.ForgetCommunityFeed` is never called in production (W5-38 I-3). So a restore on the same instance does not bring back, for up to 5 minutes, a post that was hidden before the shared entry filled. Hides are fine: `recentRemovals` drops them at once on the writing instance.
  - Fix: after a committed RestoreCommunityPost that changed the post, an apiserver callback calls `ForgetCommunityFeed(cid)`. The next read on that instance cold-fills and returns the restored post. communities never imports timeline: apiserver hands communities a function, like the late lookups.
  - A hide needs no call.
  - Un-skip W5-36's D-1 repro test.
  - Update runbook `communities.md` §4e ("should call ... W5-28 owns the hook" becomes the as-built line) and the `docs/code-map.md` entry.
  - The alternative is docs only: say in the runbook and code map that the method is unused and the restore bound is 5 minutes. Default: wire it.
- **Acceptance criteria.**
  - Given a post hidden before this instance's entry filled, when it is restored on the same instance, then the next GetCommunityTimeline on that instance returns it (the un-skipped repro passes).
  - Given a hide, then the entry is not dropped.
  - Given a restore on another instance, then the 5-minute bound stays (runbook).
- **Test notes.** The un-skipped repro; a unit test that the callback fires only on a committed, changed restore (not on a replay, a no-op or a refusal).
- **Observability.** —
- **Budget.** 0 reads at the call. The next feed read on that instance cold-fills: 25 / 55 wire reads at page 20 / 50 instead of 3 warm, once per restore. Restores are a fraction of the 0.003 moderation actions per DAU, so this is below 0.1 reads per DAU.
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** A callback set by apiserver; communities never imports timeline; the entry stays behind `ForgetCommunityFeed`.
- **Gate.** None.
- **Parallel with W3 Part A / W4:** apiserver wiring, before W5-59.

### W5-58 — Stale SetHomeTabs proto comment  [owner: architect] [size: XS] [depends: —]  Status: Done (#654, with W5-51; `buf lint` and `buf breaking` against origin/main clean, generated Go and Dart regenerated)
- **Description.** The SetHomeTabs comment in `proto/dzeroth/timeline/v1/timeline.proto` (lines 206-207) still lists "kind COMMUNITY (until GetCommunityTimeline ships, plan W5-27)" among the VALIDATION causes. A COMMUNITY tab is accepted since W5-27, as the same comment says a few lines down (ADR-0031 D6, Home tabs). Remove the stale clause. This is a comment-only change: `make proto` regenerates Go and Dart, and `buf lint` and `buf breaking` stay clean. It may ride in W5-51's PR.
- **Acceptance criteria.**
  - Given `buf breaking` against `main`, then it is clean.
  - Given the comment, then it matches ADR-0031 D6 (any ACTIVE or ARCHIVED community; missing or SUSPENDED is VALIDATION `tabs`).
- **Test notes.** `buf breaking`.
- **Observability.** —
- **Budget.** 0.
- **Flag.** None (contract comment).
- **Seam.** —
- **Gate.** None.
- **Parallel with W3 Part A / W4:** `timeline.proto`, one proto PR at a time.

### W5-59 — A new community post reaches the writing instance's entry at once (D6)  [owner: backend-developer] [size: XS] [depends: W5-57]  Status: Open
- **Description.**
  - ADR-0031 D6 says a new post on this instance updates the shared entry at once. It does not: CreatePost into a community leaves timeline's entry alone. On the writing instance, the post appears in the community feed only after the entry's 60 s TTL.
  - The author's own device already shows it at once: `PostsRepository.createPost` inserts it into `FeedKey.community` (W5-34). The gap is the author's other devices and other members served by that instance, for up to 60 s.
  - Fix: after a committed CreatePost with `community_id`, an apiserver callback (posts never imports timeline) **marks that community's entry stale**. The next read then refills incrementally from the entry's newest row (1 + new reads).
  - Do not prepend the post into the entry. The entry must stay complete from its newest row down (`communityEntry` in `service_community.go`; refills run `After = newestId`), so a prepend would skip posts written on other instances in between.
  - The alternative is an as-built note correcting D6 (architect). Default: wire it.
- **Acceptance criteria.**
  - Given a warm entry on instance I, when a member posts into the community on I, then the next GetCommunityTimeline on I (within 60 s) returns the post, at 1 + new reads.
  - Given a post written on another instance, then the 60 s bound stays.
  - Given a post that is not a community post, then no entry changes.
  - Given posts on two instances in the same second, then no post is skipped after the refill.
- **Test notes.** Unit tests in timeline (stale mark, then an incremental refill); the callback fires only on a committed community CreatePost (not on a replay or a refusal); `budgettest` of the refill.
- **Observability.** The existing `timeline_cache_hit` and `fs_reads` show the refill.
- **Budget.** The next read on that instance pays 1 + new reads instead of 0 (warm). At 0.1 community posts per DAU this is at most +0.1 reads per DAU.
- **Flag.** `FEATURE_COMMUNITIES`.
- **Seam.** A callback set by apiserver; a new `timeline.Server` method next to `ForgetCommunityFeed` (code-map row); the entry stays behind the `timeline` interface.
- **Gate.** None.
- **Parallel with W3 Part A / W4:** apiserver wiring, after W5-57.

## Rollout plan
- **Dev.** Allowlist (3 uids): `lists` first (W5-19), then `communities` (W5-40).
- **Prod.** The founder's MVP launch decision: allowlist → percent 5 → 25 → 100 → `on`, each step a Terraform change plus a tagged revision (ADR-0019). Before each step, check the `cost-model.md` headroom and the error rate. `communities` never ramps ahead of `lists`, and `COMMUNITY_CREATORS` holds the founders' uids at launch.
- **`communities` gates from W5-38 (#647, report §6):**
  - **Dev allowlist (W5-40):** met once #647 merges (W5-51 to W5-56 are in this plan).
  - **`percent`** (a founder-gated ceiling raise): W5-51, W5-51b, W5-51c, W5-52, W5-52b and W5-53 merged, and W5-36's role × action matrix green, including the W5-51b and W5-53 cells.
  - **Prod `on`:** also W5-54, W5-55, W5-55b, W5-56 and W5-56b (the Privacy Policy lines served by prod Hosting), and the held release (ADR-0019).
- **Rollback triggers:**
  - error rate on any W5 RPC above 2 % for 15 min;
  - list or community feed reads per DAU above twice the W5-18 / W5-39 model for a day;
  - a moderator-abuse or raid incident in a community: first suspend that community, else `FEATURE_COMMUNITIES=off`. To undo a rogue moderator's hides, use `opsctl community hidden` and `restore-hidden` (W5-52b, runbook "Rogue moderator or community raid");
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
| Rogue moderator or owner, raids, spam communities | F9 scope (literal, F16: W5-53), caps, modlog, `DailyCap`, members-only replies, creators allowlist (also for edits by hand-over owners, W5-54), opsctl suspension, W5-38 |
| A reply raid in a community's threads outlives the ban (W5-38 M-1) | F15: moderators hide and restore replies (W5-51 to W5-51c), before `percent`; until then `takedown-post` and `suspend-user` |
| A rogue or hijacked moderator's actions cannot be audited or undone past the capped modlog (100) and `recentRemovals` (50) (W5-38 M-2) | keyed hashes on the moderation request lines (W5-52); `opsctl community hidden` and `restore-hidden` and the raid runbook section (W5-52b); all before `percent` |
| W5-55 tightens the bio rule for every surface (profile bios, list descriptions, community text) at merge, with no flag | it applies on write only (stored text is not rewritten); vectors keep ZWJ, ZWNJ and emoji tag sequences valid; the Dart port (W5-55b) shows the error before any RPC |
| Public lists as harassment lists | private by default (F3), no add notification, blocks prevent adds and hide members (F4), report and hide |
| A community post can be misattributed after a hide | the label is omitted when `communityHidden`; the post itself is untouched |
| Hot community doc (`memberCount`) during a viral join burst | rule 3 holds at Stage 0; the `ABORTED` metric and the counters-row trigger |
| `recentRemovals` overflow (> 50 hides between refreshes) resets cached feeds | the documented ADR-0016 D10 contract (cold open); the moderation-log trigger |
| Private accounts (W3 Part B) leak through the new feeds | the `keep` hook point named in W5-8 / W5-27; ADR-0025's matrix includes both feeds |
| Merge conflicts with W3 and W4 in shared files | the shared-files table; one PR at a time; new logic in new files |
| ADR number clash | Part A took ADR-0030 (W5-1); Part B took ADR-0031 (W5-20) |
| Uncaptured visuals (list detail, community page, create flows, Manage timelines, moderator tools) | X-like defaults stated per ticket; a founder capture adjusts them in a follow-up PR |
| Home tab titles go stale after a rename | the timeline response carries the current header and the device updates its label; storage is refreshed on the next SetHomeTabs |
