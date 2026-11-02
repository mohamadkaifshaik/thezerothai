# Security review: W5 Part B, Communities, including moderator abuse (W5-38)

**Reviewer:** security-auditor · **Date:** 2026-11-02 · **Reviewed:** `origin/main` at `e133f4ad` (worktree `docs/communities-w5-38-security-review`), read only. Backend W5-21 to W5-29 (#590, #601, #613, #626, #629, #633, #634, #636, #639); client W5-30 to W5-35b (#599, #614, #616, #630, #637, #641).

**Verdict: CLEAR WITH CONDITIONS.** No Critical or High finding is open. There are two Medium and five Low findings. None of them has to be fixed before the dev allowlist (3 accounts, founders as creators).
- **Condition:** the lead adds tickets W5-51 to W5-56 (section 5) to the plan before W5-40 applies the dev allowlist. This is the W5-38 rule: "findings are fixed or ticketed before any dev allowlist".
- **Percent:** needs W5-51 to W5-53 merged (section 6).

**Design:** ADR-0031 (Accepted 2026-11-01) with as-built notes N1 to N10; ADR-0008 (blocks), ADR-0010 D5 (read budget), ADR-0016 (platform moderation), ADR-0025 (protected accounts), ADR-0030 (the lists patterns). Plan `docs/plans/ui-w5-lists-communities.md`: W5-23 to W5-29, W5-34, W5-35, W5-35b, W5-38 and founder decisions F1, F6 to F14.

**Code read:**
- `backend/internal/communities/` (every non-test file).
- `backend/internal/posts/{community_gate,community_moderator,repo_community,service_create,repo_create,convert,service_thread,service_engagement,moderate}.go`
- `backend/internal/timeline/{service_community,server_community,home_tabs}.go`
- `backend/internal/moderation/{community,server,service}.go`
- `backend/internal/identity/{single_line_text,validate}.go`, `backend/internal/graph/api.go`
- `backend/internal/apiserver/{apiserver,ratelimit_config}.go`, `lifecycle_collections_guard_test.go` (rows 149-151, 188)
- `backend/pkg/platform/config/{config,communities,limits}.go`, `backend/cmd/opsctl/community.go`
- `firebase/firestore.rules`, `scripts/promotion/flag-ceiling.json`, `infra/terraform/envs/{dev,prod}` (community variables)
- `docs/runbooks/communities.md`
- Client: `app/lib/features/communities/**`, `app/lib/shared/widgets/post/post_context_label.dart`, `app/lib/features/posts/presentation/composer_screen.dart` (the `community=` preselect)

**Run:** `go test ./internal/communities/ ./internal/timeline/` passes. It needs `GOWORK=off`, because the worktree sits outside the root `go.work`.

**Not run:** emulator integration tests, Flutter tests, `govulncheck` and `osv-scanner` (not installed here; Part B added no Go or pub dependency: `golang.org/x/sync` was already in `backend/go.mod:13`). No cloud calls.

**Test inputs:** W5-36 (backend tests, including the role × action matrix) and W5-37 are Open, so there were no tester authz results to read. The verdicts rest on code reading and the existing unit and integration test sources.

**Where it runs today:**
- `FEATURE_COMMUNITIES` is off everywhere (default off, `config.go:1054`).
- The dev ceiling is `{"mode":"allowlist","max_allowlist":3,"max_percent":0}` (`flag-ceiling.json:22`).
- `COMMUNITY_CREATORS` is empty by default (`envs/dev/variables.tf:474-481`).
- The prod release is held (ADR-0019).

## 1. Findings

| ID | Severity | Where | Issue | Fix | Before dev allowlist? |
|---|---|---|---|---|---|
| M-1 | Medium | `posts/community_moderator.go:69-71`; `posts/service_thread.go:514`; `runbooks/communities.md:297` | Moderators cannot remove replies in community conversations. A member's reply raid stays in the threads after the ban. | Architect, ADR-0031 amendment (F9 scope): hide and restore for replies whose `conversationCommunityId == cid`, dropped by GetThread, 0 extra reads. Or accept and document, with a platform playbook. | No (W5-51, before percent) |
| M-2 | Medium | `communities/repo_moderation.go:37-47, 180-198`; `repo_firestore.go:401-405`; `ratelimit_config.go:161, 276-278`; `runbooks/communities.md:301` | Modlog (100) and `recentRemovals` (50) are the only record. 600 actions a day per actor can push everything out, and nothing lists hidden posts. Request lines carry no community identifier. A rogue or hijacked moderator's work can be neither audited nor undone in the app. | Keyed `community_hash` / `target_hash` on moderation request lines (the W7-34 precedent); `opsctl community hidden` and `restore-hidden`; keep `posts.community` indexed (FU-5); a rogue-moderator and raid runbook section | No (W5-52, before percent) |
| L-1 | Low (founder question) | `communities/repo_moderation.go:128-133`; `posts/community_moderator.go:37-41` | F9 says moderators cannot act on the owner or on other moderators, but Hide and Restore accept their posts | The founder picks the reading. If literal: return `authorId` from `SetCommunityListing` (0 extra reads) and refuse with FORBIDDEN `not_owner`. Otherwise add a D4 note. | No (W5-53, before percent) |
| L-2 | Low | `communities/repo_moderation.go:184-188`; `posts/community_moderator.go:52-84` | A moderator's hide then restore of a post the platform took down deletes the platform's `recentRemovals` entry, so stale device feeds keep the card | `SetCommunityListing` answers found=false for a post with `moderation` set, 0 extra reads | No (W5-53, before percent) |
| L-3 | Low | `posts/convert.go:214-219`; `communities/purge.go:196-211`; `communities/repo_firestore.go:373` | The community label outlives a hide on devices and a suspension everywhere. The F12 hand-over lets a uid outside `COMMUNITY_CREATORS` rename the community. | While creation is allowlisted, edits by a non-creator owner get FORBIDDEN. Add a suspended-community seam in `communityRef` before open creation. Add a runbook note. | No (W5-54, before prod on) |
| L-4 | Low | `identity/single_line_text.go:33-48`; `communities/service.go:133-139, 153-156` | Description and rule text accept zero-width and other invisible format characters and fillers, although the VALIDATION message says they are refused | Apply the Cf and filler rule in `BioText` (keeping `\n` and ZWJ/ZWNJ inside sequences), with vectors and the Dart port, or correct the message | No (W5-55, before prod on) |
| L-5 | Low (founder question) | `communities/service_directory.go:216-236` | A protected account's community memberships and join dates are visible to every signed-in user on member pages | The founder decides. If hidden: drop the rows for viewers who are not role holders and not approved, 0 reads. If not: a Privacy Policy line. | No (W5-56, before prod on) |

### M-1 (Medium): community moderators cannot remove replies, so a member raid in the threads outlives the ban
**Where:**
- `SetCommunityListing` answers found=false unless the post carries `community.id == cid` (`posts/community_moderator.go:69-71`). A reply never does: `applyReply` copies only `conversationCommunityId` (`posts/service_thread.go:514`).
- So `HideCommunityPost` of a reply is NOT_FOUND "post not found" (`repo_moderation.go:142-144`), and the runbook calls that intended (`communities.md:297`).
- ADR-0031 D4 gives moderators "hide or restore a post in this community's view". Replies are not in the feed, but they are in every thread of a community post, where F8 makes them members-only.

**Scenario:**
1. A raider joins: 5 joins a day as a new account, 20 when established (`quota.CommunityJoins`).
2. The raider replies under the community's posts. Replies spend only `posts` (20 a day new, 100 established; `service_create.go:189-192`). `communityPosts` and the `uid|cid` cap apply only when `community_id` is set (`community_gate.go:151-160`).
3. A moderator bans the raider. Further replies stop within 60 s (member cache, `gate.go:90-102`).
4. The replies already posted stay in every thread. The levers left are POST reports and `opsctl takedown-post` per reply, or `suspend-user`.

100 new sock accounts post up to 1,000 replies a day after their 10 community posts each, or up to 2,000 if they post no roots. The community cannot remove any of them.
- **Cost:** about 5 writes a reply: 5,000 writes is about INR 0.5 a day.
- **Harm:** the content itself, plus founder time.

**Fix:** a design change, so it goes to the architect and the founder (F9 sets moderator powers). Either:
- (a) let Hide and Restore accept a reply whose `conversationCommunityId == cid`, set `communityHidden` on it, and have GetThread drop such replies for everyone but the author. That costs 0 extra reads, since GetThread reads every row already. The modlog entry works as for a hide.
- (b) record the residual in ADR-0031 D4, and add an "abusive replies in a community" playbook to the runbook (`takedown-post`, `suspend-user`).

### M-2 (Medium): moderation history and hidden posts cannot be recovered beyond the capped arrays
**Where:**
- **Caps.** The modlog keeps the newest 100 entries (`appendLog`, `repo_moderation.go:37-47`) and `recentRemovals` the newest 50 (`removalsAfter`, `:180-198`).
- **Action budget.** The cap is 200 actions per actor per instance, 600 effective (`ratelimit_config.go:161, 276-278`). EDIT entries are capped separately by `community_mutation_daily`, also 600 effective (`repo_firestore.go:401-405`).
- **No listing.** A hide deletes `communityId` (`community_moderator.go:76`), so the post leaves the only query the owner has. No RPC lists hidden posts.
- **Logs.** The request line has `mod_action`, `outcome` and `uid_hash`, but no community, post or target (D13; `service.go:26`; `pkg/platform/mw/mw.go:153`). The runbook's answer, "the request log keeps one line per action" (`communities.md:301`), cannot say which community, post or member an action touched.

**Scenario:**
1. A moderator account is taken over (ATO is a day-one threat), or an owner appoints the wrong person.
2. The actor bans members and hides up to 600 posts a day.
3. The actor then runs 50 hide-and-restore pairs on one post (100 actions), which pushes every earlier entry out of the modlog.

What the owner can and cannot recover:
- The owner sees 100 HIDE and RESTORE lines by that moderator and can remove them (D4), so the actor is not anonymous.
- Nobody can see what the actor did before. Bans remain on the banned page, without the actor. Hidden posts cannot be found once they leave `recentRemovals` (50).
- An owner can do the same with EDIT toggles.
- The platform cannot rebuild the history from Cloud Logging. Recovery needs an ad hoc Firestore query that no runbook describes: `community.id == C AND communityHidden == true`, served by merging two automatic single-field indexes.

**Cost:** at most INR 0.44 a day per role holder (section 2.4).

**Fix:**
- (a) Add a keyed `community_hash` to the moderation request lines, plus `target_hash` for role actions: an HMAC from `CURSOR_HMAC_KEY`, as `conversation_hash` (W7-34) does, with an `opsctl loghash` counterpart. An operator can then rebuild one community's history.
- (b) Add `opsctl community hidden CID` (list, Limit ≤ 50, paged) and `opsctl community restore-hidden CID [--since T]` (field-level updates through `posts.CommunityModerator`, with a modlog entry carrying a platform marker).
- (c) Keep `posts.community` indexed: leave it out of FU-5's optional exemption, because (b) depends on it.
- (d) Add a "rogue moderator or community raid" section to `communities.md`.
- Optional: a per-community daily hide cap no larger than the modlog.

### L-1 (Low, founder question): F9 and D4 disagree on hides of the owner's and moderators' posts
**Where:**
- `ModeratePost` checks the actor's role only (`repo_moderation.go:128-133`). `SetCommunityListing` reads the post but returns no author (`community_moderator.go:37-41`).
- D4 restricts only bans.
- F9 (plan, line 25) says: "They cannot: ... act on the owner, and moderators cannot act on other moderators."

**Scenario:** a moderator hides the owner's announcements or another moderator's posts. The posts leave the feed until the owner restores them. The action is logged with its actor and reversible, and the owner can remove the moderator.

**Fix:** the founder chooses the reading.
- If F9 is literal: return `authorId` from `SetCommunityListing` (the post is already read, so 0 extra reads), and refuse a moderator's hide or restore of the owner's or another moderator's post with FORBIDDEN `not_owner`. Add tests.
- Otherwise: add a note to ADR-0031 D4 that hides apply to every post.

### L-2 (Low): a moderator's hide then restore erases a platform removal from the community feed's removal log
**Where:**
- A hide first deletes every `recentRemovals` entry for the post (`repo_moderation.go:184`), and a restore deletes it (`:186-188`).
- `SetCommunityListing` never looks at `posts.moderation` (`community_moderator.go:52-84`).
- A platform takedown appends `{postId, at}` (`platform.go:157-194`) and leaves `communityId` in place.

**Scenario:**
1. The platform takes down community post P, which is listed in `recentRemovals` at T1.
2. A moderator who has P's id hides it, which replaces the entry at T2, then restores it, which deletes the entry.
3. A device whose cached community feed predates T1 never receives P in `removed_ids`, and keeps showing the taken-down card until its next cold open.

The server never serves P again: `keep` drops `!Visible()` (`service_community.go:161`). Home's own removal log (`postRemovals`) is unaffected. Cost: INR 0.

**Fix:** `SetCommunityListing` answers found=false (NOT_FOUND "post not found") for a post whose `moderation` is set. That costs 0 extra reads, since the document is already read. Test: takedown, hide, restore, then the entry is still listed.

### L-3 (Low): the community label outlives a hide on devices, a suspension everywhere, and the creators allowlist after a hand-over
**Where:**
- `communityRef` shows the label snapshot taken at post time unless the post carries `communityHidden` or the global kill switch is on. It does no status lookup (`posts/convert.go:214-219`).
- The F12 hand-over is at `purge.go:196-211`.
- UpdateCommunity checks the owner only, with no creators check (`repo_firestore.go:373`).

**Scenario:**
- **(a) Hide.** A post hidden by moderators keeps "<community>" on followers' cached Home and profile cards. A `since` refresh returns only newer rows and `removed_ids`, never a re-rendered old row. The server stops sending the label within 60 s (the instance post cache, `communities.md:285`).
- **(b) Rename or suspension.** An owner renames the community to a slur or an impersonating name ("dzeroth Official"). Every post created after that carries the name on Home, profiles, search and lists. `community suspend` does not clear it; only the global flag-off or per-post takedowns do. ADR-0031's Consequences accept this "while creators are allowlisted".
- **(c) Hand-over.** That premise fails after an F12 hand-over: the first ACTIVE moderator becomes the owner, edits the text and appoints moderators, without being in `COMMUNITY_CREATORS`.

**Fix:**
- (c) While creation is allowlisted, an UpdateCommunity edit by an owner outside `COMMUNITY_CREATORS` gets FORBIDDEN `not_creator` (0 reads, `service.go:316`). Alternatively, record the decision in ADR-0031.
- (b) Add a suspended-community set that `communityRef` consults through a seam: the protected-set pattern, 0 reads when warm. The Stage ladder already requires it before creation opens.
- (a) Add a runbook line.

### L-4 (Low): description and rule text accept invisible format characters, although the VALIDATION text says they are refused
**Where:**
- `identity.BioText` refuses only control characters other than `\n`, line separators and bidi controls (`single_line_text.go:33-48`). It accepts U+200B, U+2060, an interior U+FEFF, U+3164 and other Cf characters or fillers.
- `validateDescription` and `validateRules` say "without control, invisible or direction characters" (`communities/service.go:133-139, 153-156`).
- Names and rule titles use `SingleLineText`, which refuses these characters (W5-45).

**Scenario:** a description or rule split with zero-width characters slips past a keyword read in `opsctl reports show`, or renders as blank lines. The client renders this text with plain `Text`: there is no linkify, markdown or HTML under `app/lib/features/communities`, so there is no injection. The gap belongs to the existing bio rule and is not new.

**Fix:** apply the Cf and filler rule in `BioText`, keeping `\n` and ZWJ/ZWNJ inside sequences. Add vectors to `testdata/profile_text` and do the Dart port (the W5-49 pattern). Alternatively, correct the message.

### L-5 (Low, founder question): a protected account's community memberships are visible to everyone
**Where:** `ListCommunityMembers` drops only inactive accounts and block rows (`service_directory.go:216-236`), and each row carries the join date (`Since`).

**Scenario:** anyone can scan the member pages of the ≤ 20 communities (≤ 103 reads for a page of 50) and learn which communities protected account P joined, and when.
- **Consistent with ADR-0025:** the ADR-0025 matrix refuses only ListFollowers(P) and ListFollowing(P) (`docs/adr/0025-private-accounts-follow-requests.md:203`), so P may appear on a public account's follower list, which the graph lists render with the lock badge (`graph/lists_test.go:310-335`).
- **Unlike W5-17 M-2:** that decision hid P's own lists. A community membership also says more about P's interests than a single follow does.
- So this is Low, not Medium.

**Fix:** the founder decides.
- If hidden: for a viewer who is not an owner or moderator, drop rows where `IsPrivate` is set and the viewer does not follow P (0 reads; the profile and graph are already held). `memberCount` stays as it is.
- If not: add one Privacy Policy line ("community memberships are public, also for protected accounts").

### Informational
- **I-1 (the × 3 arithmetic):** `COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY` is 20 per instance, so 20 to 60 effective.
  - Spread over 3 instances it never binds above the exact `communityPosts` quota of 50 (10 for new accounts). The real per-community bound is that quota.
  - Replies are outside both. They spend `posts` (100, or 20 for new accounts).
  - If a per-community bound matters, make it an exact quota field or set 7 per instance.
- **I-2:** a COMMUNITY report needs `reports` on and `communities` not globally off, so a user outside the allowlist can file one (`moderation/server.go:59, 80-85`). This follows the LIST and MESSAGE precedent.
  - Such a user can probe community ids (NOT_FOUND versus success), but communities are public.
  - The probe is bounded by the reports quota (20, or 5 for new accounts) and the read budget.
- **I-3:** `ForgetCommunityFeed` is never called in production (`timeline/service_community.go:82`; the only caller is in tests). This is staleness, not exposure, and is already tracked as D-1:
  - a restore reaches a warm instance's shared entry within 5 minutes;
  - after more than 50 later hides, a hidden post can reappear for up to 5 minutes (`communityEntryMaxAge`, `:43`).
- **I-4:** a join burst on one community doc can make moderators' read-modify-write transactions retry during a raid (ADR-0031 D2, hot doc). The signal is `community_txn_attempts`; the fallback is the Stage ladder's sharded counter.
- **I-5:** a ban never hides earlier posts (F9, accepted). Cleaning up after a raid costs one hide per post, and with M-1 replies cannot be cleaned up at all.
- **I-6:** `removed_ids` tells every reader which post ids left the community (`service_community.go:316-340`). Those are ids of public posts, accepted by A3.
- **I-7 (owner-is-rogue residual):** the platform levers act on the whole community only.
  - `suspend` leaves the owner still able to see it, and `archive` keeps the text with no undo (`platform.go:78-154`).
  - There is no lever to clear abusive text while keeping the community, to replace an owner, or to bulk-restore.
  - This is accepted by D4 while creators are the founders.
  - COMMUNITY reports keep `targetOwnerId` until resolved + 90 days, by ADR-0016 D5 (`lifecycle_collections_guard_test.go:188`).
- **I-8:** a moderator removed on another instance keeps three things for up to 60 s, because each reads the cached community doc (D12): the F14 waiver (`service_community.go:149`), the banned page (`service_directory.go:188`) and the log (`service_moderation.go:184`).
- **I-9:** report evidence is the community text the server holds at report time (from the 60 s cache). EDIT log entries keep no old text, so an owner who flips the name back and forth leaves evidence only in reports filed while it was offensive.

## 2. Threat model (STRIDE) and the controls on every path

**Assets:**
- community text (name, description, rules);
- who moderates;
- the moderation log and banned list (role holders only);
- membership;
- the integrity of the community feed and of the label;
- the free Firestore quota and the credit (cost).

### 2.1 STRIDE
| STRIDE | Threat | Control as built | Result |
|---|---|---|---|
| Spoofing | Calling as another user, or as a role holder | Global chain: App Check, Firebase ID token, account-status interceptor (`routes.connect`, `apiserver.go:688-691`). The uid comes from `authn` only (`communities/server.go:36-55`). Every moderation transaction reads the role fresh from the community doc (`repo_moderation.go:124-133, 230-241`). | OK |
| Tampering / IDOR | Edit another user's community; hide posts of another community; ban across communities | Update re-checks the owner on a fresh doc (`repo_firestore.go:366-378`). Hide requires the post's `community.id == cid` (`community_moderator.go:69`). SetRole applies the D4 matrix on fresh reads (`repo_moderation.go:234-257`). | OK; L-1 |
| Tampering | Forged or replayed tokens; idempotency reuse | Sealed cursors are bound to the caller and the community: the member pages to label `community_members`, uid, cid and filter (`service_directory.go:151-153, 175-178`), the log to `community_modlog`, uid and cid (`service_moderation.go:149, 170-176`), and the feed to `communityFeed(uid, cid)` (`service_community.go:96-97`). All seven mutations hash uid, rpc and key and store a request hash, with an id-only result (`repo_firestore.go:202-224`). | OK |
| Repudiation | A role holder denies or erases what they did | Modlog (at most 100 entries, actor named); request line `mod_action` + `uid_hash` | **M-2** |
| Information disclosure | Community-only content; modlog and banned list; a SUSPENDED oracle; a block oracle | F6 (section 4). The modlog and banned page are role-gated. One NOT_FOUND, with missing ids cached negatively for 60 s, so timing does not separate missing from SUSPENDED (`cache.go:15-18`, `service.go:432-434`). `Relationship` has no blocked-by bit (`graph/api.go:33-38, 68-80`); F14's inference residual is accepted. | OK; L-5, I-6 |
| Denial of service / cost | Mutation floods, moderation floods, scraping, hot doc, refresh resets | Sections 2.3 and 2.4 | Bounded; I-1, I-4 |
| Elevation | Feature use while off or not allowlisted; creation by a non-creator; a moderator acting as owner; a banned user posting | The flag `Guard` runs first everywhere: `server.go:36-55`, `server_community.go:43-48`, `service_create.go:99-107`, `home_tabs.go:170-185`. The creators check runs before any read (`service.go:278-281`). Posting reads the member doc fresh inside CreatePost's transaction (`repo_create.go:183-187`). | OK; L-1, L-3(c) |

### 2.2 Authz on every communities RPC and opsctl path
| Path | Who may | Check (fresh or cached) | Evidence |
|---|---|---|---|
| CreateCommunity | flag + `COMMUNITY_CREATORS` | config, 0 reads; owned and joined caps exact in the transaction | `service.go:278-281`; `repo_firestore.go:299-308` |
| UpdateCommunity | owner | fresh in the transaction; SUSPENDED is NOT_FOUND, ARCHIVED refused | `repo_firestore.go:366-378` |
| GetCommunity | anyone with the flag; a SUSPENDED one only for its owner | 60 s cache | `service.go:428-434` |
| ListCommunities | anyone; ACTIVE only | 5 min shared entry | `service_directory.go:77-81` |
| ListMyCommunities | self | fresh memberships | `service_membership.go:189-233` |
| JoinCommunity | anyone not banned; ARCHIVED refused | ban, cap and quota fresh; status from the 60 s cache | `service_membership.go:107-143`; `repo_membership.go:80-109` |
| LeaveCommunity | members; the owner refused | fresh | `repo_membership.go:158-188` |
| ListCommunityMembers | anyone; the BANNED filter only for the owner and moderators | community doc cached 60 s (I-8) | `service_directory.go:181-192` |
| HideCommunityPost, RestoreCommunityPost | owner, moderators | fresh in the transaction | `repo_moderation.go:124-144` (M-1, L-1, L-2) |
| SetMemberRole | the D4 matrix | fresh in the transaction; the target's status through the 60 s directory cache | `service_moderation.go:122-129`; `repo_moderation.go:230-287` |
| ListModerationLog | owner, moderators | community doc cached 60 s (I-8) | `service_moderation.go:177-186` |
| GetCommunityTimeline | flag + `posts`; SUSPENDED is NOT_FOUND for everyone, owner included | 60 s cache | `server_community.go:37-55`; `service_community.go:107-113` |
| CreatePost with `community_id` | flag; not protected; Admit; JOINED; quota; per-community cap | member doc fresh in the transaction | `service_create.go:99-107, 156-160`; `repo_create.go:183-187, 234-247` |
| Reply in a community conversation | JOINED members | member doc cached 60 s | `community_gate.go:183-204`; `gate.go:90-102` |
| SetHomeTabs, COMMUNITY tab | flag; ACTIVE or ARCHIVED community | 60 s cache | `timeline/home_tabs.go:170-185, 236-246` |
| ReportContent, COMMUNITY target | `reports` + `communities` not globally off; the caller's own community is VALIDATION | 60 s cache | `moderation/server.go:59, 80-85`; `communities/report.go:43-68` |
| `opsctl community` suspend, restore, archive | operator (project credentials; a prod project asks for the id typed in) | field-level `Update` in a transaction, never `Set`; `--report` checked first | `cmd/opsctl/community.go:28-80`; `communities/platform.go:78-154` |
| `opsctl takedown-post` and `suspend-user` appends | operator | `PlatformRemovals.Append`, idempotent | `platform.go:157-194` (L-2) |
| Eraser and export | the lifecycle job (internal) | fresh, one transaction per community | `purge.go:134-240, 489-550` |

**Platform invariants:**
- **Firestore rules** stay deny-all (`firebase/firestore.rules:6-11`, unchanged).
- **Indexes:** no index file or fieldOverride change.
- **No new GCP resource:** no IAM, service account, Pub/Sub topic (`Events` is a no-op), Scheduler job or secret. The Terraform change is env vars only (`envs/dev/main.tf:316-341`).
- **Idempotency key** on every mutation: the seven CommunityService mutations (`idempotency.Key(uid, rpc, key)`, `service.go:298, 348`; `service_membership.go:121, 156`; `service_moderation.go:76, 132`) and CreatePost with `community_id` in its request hash (`service_create.go:199-201`).
- **Every query has a Limit:**
  - `ByCommunity`: `q.Limit(limit)` with `clampLimit` at most 50 (`posts/repo_community.go:29`; `posts/service.go:137-145`);
  - the directory: at most 50 (`repo_directory.go:21-22`);
  - member pages: at most 50 (`repo_directory.go:49`).
  - Everything else is a document get (memberships at most 50 joined; export `GetAll` batches of 100 references).

### 2.3 Effective limits (per instance × 3 max instances)
| Limit | Per instance | Effective | Store |
|---|---|---|---|
| `RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN` (the seven mutations) | 20/min | 60/min | memory |
| `RATE_LIMIT_COMMUNITIES_READ_PER_MIN` (GetCommunity, ListCommunities, ListMyCommunities, ListCommunityMembers, ListModerationLog) | 30/min | 90/min; no daily call cap | memory |
| `RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN` | 12/min | 36/min; no daily call cap | memory |
| `COMMUNITY_MUTATIONS_PER_DAY` (Create, Update, Join, Leave) | 200 | 600 | memory |
| `COMMUNITY_MOD_ACTIONS_PER_DAY` (Hide, Restore, SetMemberRole), per actor | 200 | 600 | memory |
| `COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY` (keyed uid and cid) | 20 | 60; never binds above the exact 50 (I-1) | memory |
| Read budget (ADR-0010 D5), per-call hold 269 | 2,000 reads/uid/day | 6,000 | memory |
| `QUOTA_COMMUNITY_JOINS_PER_DAY` | 20 (5 new) | exact | `quotas` |
| `QUOTA_COMMUNITY_POSTS_PER_DAY` (on top of `posts`) | 50 (10 new) | exact | `quotas` |
| `QUOTA_POSTS_PER_DAY` (replies count here) | 100 (20 new; new = first 24 h, `config.go:477`) | exact | `quotas` |
| `QUOTA_REPORTS_PER_DAY` | 20 (5 new) | exact | `quotas` |
| `COMMUNITIES_MAX_OWNED`, `COMMUNITIES_MAX_JOINED`, `COMMUNITY_MAX_MODERATORS`, `COMMUNITY_MAX_RULES` | 2, 50, 10, 10 | exact | the doc in the transaction |
| `COMMUNITY_RECENT_REMOVALS_MAX`, `COMMUNITY_MODLOG_MAX` | 50, 100 | exact | community doc |
| `COMMUNITY_CREATORS` | at most 10 uids, each `ids.ValidUID`; startup fails otherwise | exact | config |

Sources:
- `config/config.go:537-539, 609-611, 685, 755, 770, 787, 790, 863-866`;
- `config/communities.go:47-71`;
- `apiserver/ratelimit_config.go:157-161, 221-233, 272-278`.

All twelve CommunityService procedures and GetCommunityTimeline have a bucket, so none falls to the default bucket. Rule 11 holds: every value is config, mirrored in Terraform and validated > 0.

### 2.4 Cost amplification (`cost-model.md` §7 prices)
Prices: reads $0.035, writes $0.104 and deletes $0.012 per 100k; requests $0.40 per million; INR 95 per USD. That is INR 0.0000333 a read, 0.0000988 a write, 0.0000114 a delete and 0.000038 a request.

| Vector (one account, one day, worst) | Firestore | INR |
|---|---|---|
| Feed or member-page scraping | The read budget, 6,000 reads: about 109 older feed pages of 50 (about 5,400 posts) or 58 member pages | **0.20 a day, about 6 a month.** 1,000 sock accounts: about 6,000 a month (24 % of the INR 25,000 credit cap). This is the generic bound shared by every read path, as for lists. |
| Warm feed calls (0 post reads) | requests only: 36/min × 1,440 = 51,840 | about 2.0 a day |
| Ordinary account, `community_mutation_daily` | 20 real joins (100 writes) + 20 leaves (60 writes, 20 deletes) + about 560 no-op calls, each storing an idempotency doc (560 writes, 560 TTL deletes) + about 2,400 reads | **about 0.16 a day, about 5 a month.** About 27 such accounts use up the free 20k writes a day. |
| A rogue or hijacked role holder, `community_mod_actions_daily` | 600 × at most 5 writes = 3,000, 600 TTL deletes, about 4,200 reads | **about 0.44 a day, about 13 a month.** All 11 role holders of one community: about 145 a month. All 220 possible at Stage 0 (20 communities × 11): about 2,900 a month (12 % of the cap), and every one of them is an appointed account. |
| An owner's edit flood (creators or hand-over owners only) | 600 × 2 writes, 600 deletes, 2,400 reads | about 0.2 a day |
| Raid by 100 new sock accounts | each: 5 joins (25 writes), 10 community posts (40), 10 replies (50) = 11,500 writes | **about 1.1 a day.** The harm is content: 1,000 posts + 1,000 replies a day. Clean-up is 100 bans + 1,000 hides = 1,100 actions, which needs at least 2 role holders, and the replies cannot be removed (M-1). |
| Removal-log resets by a hide burst (more than 50 hides between refreshes) | each refreshing member device cold-opens: 25 reads instead of about 3.5 | 1,000 members × 3 refreshes: about 64,500 extra reads, about 2.1 a day |
| Join and leave loop | 20 exact joins: 160 writes + 20 deletes | about 0.02 a day |
| Reports | 20 × 2 writes; a repeat writes 0 | about 0.004 a day |
| Requests across all community procedures | 62/min × 3 × 1,440 = 267,840 | about 10 a day sustained. This is generic: refused calls are billed too, and the request-flood alert covers it (`abuse-spike.md`). |
| Vision, GCS, Pub/Sub | 0 (F13: no images; `Events` is a no-op) | 0 |

## 3. Threat model per vector

### 3.1 The creators allowlist and the flag gate
- **Flag first.** `Guard` runs before any read on every CommunityService method: `entry` calls `gate` (`server.go:36-55`). It also runs on GetCommunityTimeline (`server_community.go:43-48`), on CreatePost with `community_id` (`service_create.go:99-107`) and on COMMUNITY tabs (`home_tabs.go:170-185`). Refusal is FEATURE_DISABLED with 0 reads beyond the interceptor.
- **Lists M-3 does not recur.** SetHomeTabs with `lists` and `communities` both off answers an empty request at 0 reads (`home_tabs.go:181-182`).
- **Creation needs two things:** the flag, and the caller in `COMMUNITY_CREATORS`. The creators check comes before key and text validation, at 0 reads (`service.go:278-281`). The owned cap (2) is exact and lifetime (`repo_firestore.go:303-305`).
- **Config validation.** The list holds at most 10 uids, each `ids.ValidUID`. A bad list fails startup without echoing a uid (`config/communities.go:60-71`), and startup logs the count only (`apiserver.go:131-134`).
- **`can_create`** goes only to the caller, 0 reads (`service_membership.go:194`).
- **Residual:** the allowlist bounds who creates, not who owns. After a hand-over a non-creator owns the community and can edit its text (L-3(c)).
- **Outside the allowlist,** a user still sees community labels on Home, because the flag is not globally off. They can report a community (I-2), and they get FORBIDDEN `not_member` on a reply to a community post (N8). None of this exposes non-public data.

### 3.2 Public user text and the report path (including Report Community, W5-35b)
- **Input rules.**
  - Names: 1-30 code points after NFC.
  - Rule titles: 1-60 code points. Both single-line: no control, line or paragraph separator, bidi or Cf character, no filler, and at least one visible rune (`validate.go:65-90`).
  - Description: at most 160, and rule text at most 300, under the bio rules. Cf characters get through (L-4).
  - At most 10 rules (`service.go:125-160`).
- **Rendering.** The client renders this text with plain `Text`: no linkify, markdown or HTML (grep of `app/lib/features/communities`). The label is plain text (`post_context_label.dart`).
- **Report path.**
  - A missing or SUSPENDED community is the one NOT_FOUND. The owner's own community is VALIDATION `target_id` (`report.go:43-68`); the client hides the menu entry from the owner (`community_screen.dart:264-268`).
  - The evidence is a snapshot of the owner's handle, the name, the description, the rules and the creation time: no member id, no child document.
  - The report id is a hash of reporter, type and target, so a repeat writes 0. The `reports` quota applies.
- **What a report can do:** an operator can only suspend the community (`community suspend --report`) or archive it. There is no lever to clear the text while keeping the community (I-7), and the text stays in post labels (L-3(b)).

### 3.3 Moderator abuse: scope, limits, log, and the owner-is-rogue residual
- **Scope.** Moderators can only:
  - hide a post from the community feed and label. The post stays on the profile, in Home and in search, and is never `Hidden()`; the hide is a field-level `Update` (`community_moderator.go:76-81`);
  - ban, which acts on the member doc and the memberships only (`repo_moderation.go:302-332`).

  They cannot delete posts or see reports, and moderation has no path outside the community.
- **Who may act on whom.**
  - A moderator cannot ban the owner or another moderator (`repo_moderation.go:246-254`).
  - The owner must remove a moderator's role before banning them (`ErrModeratorTarget`).
  - A moderator can hide the owner's or another moderator's posts (L-1).
- **Limits.** 600 actions per actor per day effective; at most 10 moderators; arrays capped at 100 and 50.
- **The log.** It names the actor, never the post author (`repo_moderation.go:154, 333`).
  - It can be flooded and is the only record (M-2).
  - Every entry adds the community to the actor's and the target's `modlogged` (I-L, `stageModlogged`, `repo_moderation.go:62-83`), so erasure finds them.
- **Owner-is-rogue.** The owner holds every moderator power, plus removing moderators and editing the text, and can also wipe the log with EDIT toggles.
  - Platform levers: `community suspend` (offline; the owner still sees it), `community archive` (ownerless, no undo), `suspend-user` of the owner and `takedown-post`.
  - Nothing replaces a rogue owner short of an edit in the console (`communities.md` section 5).
  - Accepted at Stage 0 because the owners are founders (I-7). Hand-overs weaken that premise (L-3(c)).

### 3.4 Ban evasion
- **What a ban blocks:** Join (read fresh, `repo_membership.go:80-86`), posting (read fresh in CreatePost's transaction, `gate.go:58-70`) and replies (60 s cache, `gate.go:90-102`). A Leave by a banned user keeps the ban (`repo_membership.go:163-170`).
- **Pre-emptive bans:** BAN accepts a non-member (`repo_moderation.go:310-312`), so a moderator can pre-ban known sock accounts.
- **A new account:**
  - needs a verified email to post (`service_create.go:139`), but not to join;
  - gets 5 joins, 10 community posts and 20 posts a day for 24 h.
  - There is no SMS OTP, by design. App Check and the provider mix are the platform's signup friction.
- **Cost to moderators:** each evading account costs one BAN plus one hide per post (I-5). A role holder has 600 actions a day.
- **Residual:** account creation is the limit, not a community control. That is accepted for Stage 0. Replies posted before the ban stay (M-1).

### 3.5 Spam and raids
- **Exact quotas:** joins 20 (5 new), community posts 50 (10 new) on top of `posts` 100 (20 new). All are reserved in the same quota write (`repo_create.go:234-247`).
- **The per-community cap** is 20 to 60 effective and adds nothing above the exact quota across instances (I-1).
- **Members-only replies (F8)** limit replies to members, but joining is open. So the reply raid of M-1 is the residual.
- **A raid of hides** of more than 50 between refreshes resets device tokens. That is a cold open per refresh, about INR 2 a day per 1,000 members (section 2.4).
- **Join bursts** can make moderators' transactions retry (I-4).
- **Kill switches,** in order: `community suspend` (one community, no deploy), then `FEATURE_COMMUNITIES=off` (a deploy). These are ADR-0031 D10's rollback triggers.

### 3.6 The feed as a scraping vector
- **Who can read:** any signed-in user with the flag reads any community feed (public by F6). Each page is at most 50 rows, at 36 calls a minute effective.
- **The read budget binds:** about 5,400 posts a day per account, about INR 0.2 a day (section 2.4). Warm entry hits cost 0 reads but return only the newest 30 rows at most.
- **Members:** pages of at most 50, 58 pages a day per account under the budget.
- **Directory:** top 50 from a shared 5-minute entry.
- **Media:** none (F13).
- **Ids:** community ids are time-ordered Snowflakes and guessable.
  - The directory already lists every ACTIVE community.
  - An ARCHIVED one is readable by id, as designed.
  - A SUSPENDED one answers the same bytes, with the same read count and timing, as a missing id (negative cache, `cache.go:15-18`).

### 3.7 The label as a false-attribution vector
- **Only real members can create a label.** `community {id, name}` is written only by CreatePost into a community after a fresh JOINED check (`repo_create.go:183-187`, `community_gate.go:151-154`). A user cannot label a post with a community they are not in.
- **Labels never propagate:**
  - not to replies (`service_thread.go:514` copies only `conversationCommunityId`);
  - not to REPOSTs (`service_engagement.go:125-130`);
  - not to embeds (`snapshotOf`, `:112-119`);
  - not to scheduled posts (no `community_id` field, N7).
- **A hide clears the label on the wire.** `communityRef` returns nil when `communityHidden` is set, and every PostView goes through `ToView` (`convert.go:104`; the only other builder is CreatePost's own response, `posts/server.go:123-124`). The global kill switch clears every label (`posts/api.go:551, 609, 626`).
- **Residual:** device caches, the snapshot surviving a suspension, and hand-over renames (L-3).

### 3.8 Owner deletion and hand-over (F12)
- **One transaction per community** (`purge.go:134-240`):
  - the successor is the first ACTIVE moderator in appointment order, and their memberships doc must exist (read in the transaction, `:157-173`), so a moderator who is being deleted is skipped;
  - their memberships get an `ArrayUnion` `Update`, never a `Set`, so no residue is recreated (`:206-210`);
  - an `OWNER_HANDOVER` entry is written with actor `_deleted`;
  - with no successor, `ownerId` becomes `""` and the community ARCHIVED, keeping its text. A SUSPENDED community stays SUSPENDED (`:212-217`).
  - A rerun writes 0.
- **Threats:**
  - owner powers pass to a uid outside the allowlist (L-3(c));
  - the ACTIVE check uses the directory's 60 s cache, so a moderator suspended less than 60 s earlier could be chosen. That is low, and the platform still has `community archive`.
- **A live owner** cannot leave or transfer. Support runs `opsctl community archive` (`platform.go:113-154`), which writes an `OWNER_HANDOVER` entry naming the former owner and adds the community to their `modlogged` (I-L).

### 3.9 The export (and erasure)
- **The section** is `{joined, owned, banned, moderationActions, redactedCount}` (`purge.go:470-550`).
  - It names no other user: `moderationActions` holds only entries with `actor == uid`, without target or post (`:543-547`).
  - A SUSPENDED community the user does not own, or one that is gone, only raises `redactedCount` (`:510-512`).
- **Erasure:**
  - the modlog's actor and target are rewritten to `_deleted` (`:101-117`);
  - the uid leaves `moderatorIds`;
  - the member doc is deleted, then the memberships doc last.
  - T11 rows: `lifecycle_collections_guard_test.go:149-151`.
- **Idempotency records** hold the community id only (`repo_firestore.go:202-207`), so no community text survives in them. This applies the lessons of lists L-3.
- **Kept by policy:** COMMUNITY reports keep the owner as `targetOwnerId` (ADR-0016 D5; residue row 188). Posts keep `community {id, name}` in the posts section (D9).
- **PII:** none new. Community text is public user content, and email and phone are never read.

### 3.10 Logs
- **Request-line fields** are enums and counts only: `community_op`, `mod_action`, `outcome`, `cache_hit`, `community_txn_attempts`, `rows_dropped` (by cause), `viewer_role`, `removed`, `community_gate` and `community_reply_gate` (grep of every `SetRequestField` in the community files).
- **WARN lines** carry `uid_hash` only: `communities_contention` (`service.go:266`) and the eraser's `account_job` (`purge.go:325, 355`).
- **Internal errors** go through `logger.RedactErr` with the uid and community id (`service.go:270`, `gate.go:45, 110, 116`, `repo_membership.go:236`).
- **Startup** logs counts only (`apiserver.go:131-134`).
- **opsctl** prints `community_hash`, never a name or owner (`cmd/opsctl/community.go:80`).
- **Gap:** no name, description, rule text, post id or member id appears in any log. The same rule makes the moderation trail unrebuildable (M-2: a keyed hash solves both).

### 3.11 Stage-ladder vectors
- **Unchanged surfaces:** handle prefix search, hashtag `array-contains` and author `in` queries. Community posts are ordinary posts on those surfaces.
- **No public-read GCS objects:** there are no images (F13).
- **Guessable ids:** see section 3.6.
- **Per instance × max-instances:** section 2.3.
- **max-instances** is a cost circuit breaker, not a defence. The request-flood alert and the degraded-mode switch in the interceptor chain cover Part B as they cover everything else.
- **Triggers to watch:**
  - more than 50 removals per community a day (token resets);
  - more than 20 COMMUNITY or community-post reports a week;
  - `community_txn_attempts` above 3 on one community.
- **Opening creation** needs its own security review (the Stage ladder's "Creation" row). L-3(b) and (c) are prerequisites for it.

## 4. F6 confirmation: no community-only content exists, so no read path leaks
**Confirmed.**
- **Posts.** A community post is written with `visibility` PUBLIC (`service_create.go:216`). The community fields are additive (`community_gate.go:151-154`).
  - No read path consults membership for post visibility. `CommunityID` and `ConversationCommunityID` are read only by four things:
    - the label (`convert.go:214-219`);
    - the reply gate and hints (`community_gate.go:183-228`; `timeline/service_community.go:367-379`);
    - the feed query (`repo_community.go`);
    - moderation (`community_moderator.go`, `moderate.go:95, 191-197`).
  - So Home, profile, GetPost, GetThread, search, lists and bookmarks apply exactly the rules for any public post: `Visible()`, blocks and mutes, and `posts.Audience` for authors who became protected later (`service_community.go:156, 161` on the feed itself).
- **Communities.** `visibility` is only ever PUBLIC. It is written at create (`repo_firestore.go:312`), rendered as a constant (`server_rpcs.go:111`) and never read for gating.
- **Role-only data** is limited to two paths, both gated on the community doc's role check:
  - the modlog (`ListModerationLog`, `service_moderation.go:184`);
  - the banned page (`service_directory.go:188-192`).

  GetCommunity, the directory, My Communities and the timeline header render the light header, with no modlog and no `recentRemovals` (`server_rpcs.go:107-114`). `removed_ids` carries public post ids only (I-6).
- **What a suspension does not remove.** It takes the community surfaces offline (NOT_FOUND), but the posts stay public on Home, profiles and search, with their label snapshot (L-3(b)). Only the global flag-off or per-post takedowns clear those labels. This is consistent with F6 and F7, and it is the reason L-3 exists.

## 5. Proposed tickets (W5-50 is the highest existing id; the lead adds these to the plan)

| ID | Ticket row text | Owner | Size | Depends | Gate |
|---|---|---|---|---|---|
| W5-51 | M-1: moderation of replies in community conversations. Either an ADR-0031 D4 amendment (hide and restore a reply whose `conversationCommunityId == cid`, GetThread drops it for everyone but the author, modlog entry, 0 extra reads), or a recorded acceptance with an "abusive replies in a community" runbook playbook | architect + backend-developer (+ frontend-developer for the menu) | S/M | founder answer | before percent |
| W5-52 | M-2: keyed `community_hash` and `target_hash` on moderation request lines (the W7-34 HMAC precedent, `opsctl` loghash); `opsctl community hidden CID` and `restore-hidden CID [--since T]` (Limit at most 50, field-level, platform modlog marker); keep `posts.community` indexed (FU-5 note); a "rogue moderator or community raid" runbook section | backend-developer + sre-performance (runbook) | M | W5-28, W5-29 | before percent |
| W5-53 | L-1: founder answer on F9 versus D4; if literal, return `authorId` from `SetCommunityListing` and refuse hides of the owner's and other moderators' posts (FORBIDDEN `not_owner`), with tests. L-2: `SetCommunityListing` refuses a post with `moderation` set; test takedown, hide, restore, still listed | backend-developer | S | founder answer (L-1) | before percent |
| W5-54 | L-3: while creation is allowlisted, UpdateCommunity by an owner outside `COMMUNITY_CREATORS` gets FORBIDDEN `not_creator` (or an ADR-0031 note); a runbook line on cached labels; the suspended-community label seam stays on the Stage-ladder open-creation list | backend-developer (+ architect for the note) | XS | W5-23 | before prod on |
| W5-55 | L-4: the Cf and filler rule in `identity.BioText` (keeping `\n`, ZWJ and ZWNJ in sequences), vectors in `testdata/profile_text`, the Dart port; or correct the VALIDATION text | backend-developer + frontend-developer | S | W5-45, W5-49 | before prod on |
| W5-56 | L-5: founder decision on protected members in member pages. If hidden: drop the rows for viewers who are not role holders and not approved, 0 reads, with a test. Plus the Privacy Policy lines of section 7 | founder + backend-developer | XS | founder answer | before prod on |

## 6. Verdict per stage

| Stage | Verdict |
|---|---|
| **Dev allowlist** (W5-40: 3 accounts, the founders' dev uids in `COMMUNITY_CREATORS`) | **GO, CLEAR WITH CONDITIONS:** W5-51 to W5-56 are in the plan before W5-40 applies. W5-40's smoke must re-run D3's F1, F2b, F3b and M1 on real data first (ADR-0031). |
| **Percent** (needs a founder-gated ceiling raise) | GO once W5-51, W5-52 and W5-53 are merged (or W5-51 recorded as accepted by the founder), and W5-36's role × action matrix is green |
| **Prod on** | BLOCKED until everything for percent, plus W5-54 to W5-56, the Privacy Policy lines and the held release (ADR-0019). `communities` never ramps ahead of `lists` (D10). |
| **Open creation** (Stage ladder) | Needs its own security review: L-3(b), an account-age gate, a creation quota, a `banned[]` cap |

No Critical or High finding is open.

## 7. Founder actions
1. **M-1:** should community moderators be able to remove replies in their community's threads (proposed: yes, by an ADR-0031 amendment), or do you accept the residual with a platform playbook?
2. **L-1:** does F9's "cannot act on the owner, and moderators cannot act on other moderators" cover hiding their posts?
3. **L-5:** should a protected account's community memberships be hidden from viewers it has not approved?
4. **Privacy Policy lines:**
   - communities and their members are public, protected accounts included unless L-5 says otherwise;
   - community posts are public posts that also appear on the author's profile and in Home;
   - moderators can remove a post from the community, not from the platform;
   - the owner and moderators see a moderation log that names them;
   - account deletion removes you from communities and replaces your name in the log with "deleted account".

## 8. What I did not check
- **Tester results:** the W5-36 role × action matrix and the W5-37 client flows are Open.
- **Tests not run:** no emulator integration tests (`make test-int`) and no Flutter tests. Unit tests passed for `internal/communities` and `internal/timeline` only, with `GOWORK=off`.
- **Ban race and hot-doc behaviour:** the ban race (ban versus post on two instances) and the 20-joins-a-second burst were not exercised. Their correctness rests on code reading of the fresh in-transaction reads.
- **D3 shapes on real data:** not re-checked. W5-40's smoke owns that.
- **Scanners and timing:** `govulncheck` and `osv-scanner` were not run (no new dependency). The timing of NOT_FOUND paths was not measured; the parity claim rests on the negative cache.
- **Infrastructure and App Check:** the dev and prod Terraform plan was not run (W5-40). App Check enforcement for web is an open ADR and was not re-assessed here.
- **Client scope:** read only for rendering (plain `Text`), the Report Community entry and the composer's `community=` preselect. The drift cache behaviour behind L-3(a) is inferred from the `since` contract, not from a device test.

SECURITY: CLEAR
