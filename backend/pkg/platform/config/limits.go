package config

import "time"

// RateLimitConfig holds the in-memory token-bucket limits from ADR-0006 §3. Approximate per instance
// (effective ceiling is ~limit x max-instances).
type RateLimitConfig struct {
	PerUserPerMinute            int
	TimelinePerUserPerMinute    int
	CheckHandlePerUserPerMinute int
	LikesPerUserPerMinute       int
	PerIPPerMinute              int

	// Posts/timeline per-procedure buckets (ADR-0010 T4). GetHomeTimeline uses TimelinePerUserPerMinute (6) and
	// GetPost uses PerUserPerMinute (the 60/min default).
	UserTimelinePerMinute int // GetUserTimeline, env RATE_LIMIT_USER_TIMELINE_PER_MIN, default 30
	PostCreatePerMinute   int // CreatePost, env RATE_LIMIT_POST_CREATE_PER_MIN, default 10
	PostDeletePerMinute   int // DeletePost, env RATE_LIMIT_POST_DELETE_PER_MIN, default 20
	// ReportPerMinute is the ReportContent bucket (ADR-0016), env RATE_LIMIT_REPORT_PER_MIN, default 5.
	ReportPerMinute int

	// BookmarksPerUserPerMinute is the AddBookmark + RemoveBookmark bucket (ADR-0023 D4), env RATE_LIMIT_BOOKMARKS_PER_MIN,
	// default 30; BookmarksListPerUserPerMinute is ListBookmarks, env RATE_LIMIT_BOOKMARKS_LIST_PER_MIN, default 10. Both
	// are per instance (effective ceiling x max-instances).
	BookmarksPerUserPerMinute     int
	BookmarksListPerUserPerMinute int

	// BookmarkMutationsPerDay is the in-memory daily cap on AddBookmark + RemoveBookmark calls combined (one counter per
	// uid per instance, ratelimit.DailyCap), env BOOKMARK_MUTATIONS_PER_DAY, logged as limit_name "bookmark_mutation_daily"
	// (W2-14 security review M-1). An already bookmarked Add and a Remove of a missing bookmark reserve no quota but each
	// store an idempotency doc (1 write + 1 TTL delete), so the 30/min bucket alone left them unbounded.
	//
	// Default 1,500: QUOTA_BOOKMARKS_PER_DAY 200 adds + a full clear-out of the BOOKMARKS_MAX_PER_USER 1,000 cap = 1,200
	// legitimate calls, plus 300 for retries and undo churn. Worst case per account per day: 1,500 calls x 3 instances
	// (max-instances 3, the cap is per instance) = 4,500 idempotency writes + 4,500 TTL deletes, against the 20k writes
	// and 20k deletes a day free quotas.
	BookmarkMutationsPerDay int64

	// MessagesSendPerUserPerMinute is the SendMessage bucket (ADR-0027 D13), env RATE_LIMIT_MESSAGES_SEND_PER_MIN, default 20;
	// MessagesReadPerUserPerMinute is the bucket shared by ListConversations, ListMessages and MarkConversationRead, env
	// RATE_LIMIT_MESSAGES_READ_PER_MIN, default 30. Both are per instance (60/min and 90/min with 3 instances).
	MessagesSendPerUserPerMinute int
	MessagesReadPerUserPerMinute int

	// MessagesSendsPerDay is the in-memory daily cap on SendMessage calls (one counter per uid per instance,
	// ratelimit.DailyCap), env MESSAGES_SENDS_PER_DAY, default 300, logged as limit_name "messages_daily" (ADR-0027 D13).
	// Worst case per account: 300 x 3 instances = 900 messages a day. The new-account value is Messaging.NewAccountSendsPerDay.
	MessagesSendsPerDay int64

	// MessagesMarkReadPerDay is the in-memory daily cap on MarkConversationRead calls (one counter per uid per instance,
	// ratelimit.DailyCap), env MESSAGES_MARK_READ_PER_DAY, default 500, logged as limit_name "messages_mark_read_daily"
	// (security review W7-22 M-1). Every call on an existing entry is 1 write, a repeat included, and the call sat on the 60/min
	// default bucket (180/min at 3 instances = 259,200 writes a day for one account). Default 500: a few dozen thread opens and
	// foreground pushes a day for an active user, with a wide margin. Worst case per account: 500 x 3 instances = 1,500 writes
	// a day, against the 20k a day free quota.
	MessagesMarkReadPerDay int64

	// MessagesMutationsPerDay is the in-memory daily cap shared by AcceptMessageRequest and DeleteConversation (one counter per
	// uid per instance, ratelimit.DailyCap), env MESSAGES_MUTATIONS_PER_DAY, default 500, logged as limit_name
	// "messages_mutation_daily" (W7-22 M-1). Sized like GraphMutationsPerDay (500): both are state changes on a social edge,
	// idempotent by state, and a person answers a handful of requests a day. A repeat writes nothing; a first Accept is 4 writes
	// and 1 delete, so the bound is 500 x 3 instances x 5 = 7,500 operations per account per day, and real work is bounded
	// further by the requests there are to answer (3 unanswered per sender, 20 new conversations per sender per day).
	MessagesMutationsPerDay int64

	// SuggestionsPerUserPerMinute is the ListSuggestedUsers bucket (ADR-0024 D10), env RATE_LIMIT_SUGGESTIONS_PER_MIN, default 10;
	// LikesListPerUserPerMinute is ListLikedPosts, env RATE_LIMIT_LIKES_LIST_PER_MIN, default 10; ProfileRelationshipPerUserPerMinute
	// is GetProfileRelationship, env RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN, default 60 (0 reads warm). All are per instance, so the
	// effective ceiling is x max-instances (30, 30 and 180 per minute with 3).
	SuggestionsPerUserPerMinute         int
	LikesListPerUserPerMinute           int
	ProfileRelationshipPerUserPerMinute int

	// SearchPeoplePerUserPerMinute is SearchPeople (ADR-0028 D9), env RATE_LIMIT_SEARCH_PEOPLE_PER_MIN, default 30;
	// SearchPostsPerUserPerMinute is SearchPosts, env RATE_LIMIT_SEARCH_POSTS_PER_MIN, default 20. Both per instance, so the
	// effective ceiling is x max-instances (90 and 60 per minute with 3). GetTrends uses the PerUserPerMinute default bucket.
	SearchPeoplePerUserPerMinute int
	SearchPostsPerUserPerMinute  int

	// PollVotePerUserPerMinute is the VotePoll bucket (ADR-0029 D6), env RATE_LIMIT_POLL_VOTE_PER_MIN, default 30, per
	// instance (90 per minute with 3).
	PollVotePerUserPerMinute int

	// PollVotesPerDay is the in-memory daily cap on VotePoll calls (one counter per uid per instance, ratelimit.DailyCap), env
	// POLL_VOTES_PER_DAY, default 300, logged as limit_name "poll_votes_daily" (ADR-0029 D6, option D). PollVotesPerDayNewAccount
	// (env POLL_VOTES_PER_DAY_NEW_ACCOUNT, default 50) is the value for an account inside the new-account window: the
	// ratelimit interceptor cannot tell account age, so the VotePoll service applies it (W6-7); the interceptor cap uses
	// PollVotesPerDay. A cap in memory is sound here because the natural key admits ONE vote per account per poll: writes are
	// bounded by 3 x the open polls the account can see whatever the cap does after a restart. At most 300 x 3 instances = 900
	// calls (2,700 writes) per account per day.
	PollVotesPerDay           int64
	PollVotesPerDayNewAccount int64

	// SearchCallsPerDay is the in-memory daily cap on SearchPeople + SearchPosts calls together (one counter per uid per
	// instance, ratelimit.DailyCap), env SEARCH_CALLS_PER_DAY, logged as limit_name "search_daily" (ADR-0028 D9).
	//
	// Default 300. At most 300 x 3 instances = 900 calls per account per day; the per-uid daily read budget
	// (READ_BUDGET_PER_UID_PER_DAY 2,000 per instance, ADR-0010 D5) binds first for post searches (33 cold reads each).
	// Worst people rows 900 x 20 = 18,000 handles a day, already public on profiles.
	SearchCallsPerDay int64

	// FollowRequestsRespondPerUserPerMinute is RespondToFollowRequest (ADR-0025 D13), env
	// RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN, default 60, per instance (180 with 3). ListFollowRequests shares the graph
	// list bucket (GraphListPerMinute) and its graph_list_daily cap.
	FollowRequestsRespondPerUserPerMinute int

	// SuggestionsCallsPerDay is the in-memory daily cap on ListSuggestedUsers calls (one counter per uid per instance,
	// ratelimit.DailyCap), env SUGGESTIONS_CALLS_PER_DAY, logged as limit_name "suggestions_daily" (ADR-0024 D10).
	//
	// Default 50. Worst case per account per day: 50 calls x 32 cold reads (SUGGESTIONS_EDGE_LIMIT 20, ADR-0024 Amendment 2
	// B1(b); it was 42 at 30) x 3 instances (the cap is per instance) = 4,800 reads, under the 6,000 per-uid daily read
	// budget (READ_BUDGET_PER_UID_PER_DAY 2,000 x 3 instances, ADR-0010 D5), so this call cap binds first. A warm call
	// costs 1 read (the per-viewer cache, SUGGESTIONS_CACHE_TTL).
	SuggestionsCallsPerDay int64

	// ProfileUpdatesPerDay is the in-memory daily cap on UpdateProfile calls (one counter per uid per instance,
	// ratelimit.DailyCap), env PROFILE_UPDATES_PER_DAY, logged as limit_name "profile_update_daily" (W3-22 L-4).
	// Before it, UpdateProfile had only the 60/min default bucket and the read budget, and rewrote the whole users
	// document on every call even when nothing changed, so a save loop cost about 6,000 writes and 6,000 reads a day
	// per account at 3 instances.
	//
	// Default 100. A real user changes their profile a handful of times a day (name, bio, avatar, banner, location,
	// website, pin, plus retries), so 100 is generous. Worst case per account per day: 100 calls x 3 instances (the cap
	// is per instance) = 300 calls, each at most 1 write (0 when the call changes nothing) and 4 reads (cold: the
	// interceptor profile, the users doc, a banner resolve, a pin check) = 300 writes and 1,200 reads.
	ProfileUpdatesPerDay int64

	// PreAuthIPPerMinute is the coarse, pre-auth per-IP token bucket (M1, docs/reviews/security-audit-v0.1.0.md):
	// plain net/http middleware in front of the whole Connect handler chain, so an unauthenticated flood
	// is rejected before it costs any App Check / ID token JWT-verify CPU. Deliberately generous — this is
	// a flood backstop, not the fine-grained per-uid/IP limiting PerIPPerMinute already does once a request
	// is inside the Connect chain (a separate bucket; see ratelimit.PreAuthIPMiddleware).
	PreAuthIPPerMinute int

	// Graph per-procedure buckets (ADR-0008 D7). GetRelationships uses PerUserPerMinute (the 60/min default).
	GraphFollowPerMinute int // Follow, Unfollow
	GraphBlockPerMinute  int // Block, Unblock, Mute, Unmute
	GraphListPerMinute   int // ListFollowers, ListFollowing, ListBlockedUsers, ListMutedUsers

	// GraphListCallsPerDay is the in-memory daily cap on list RPCs per uid per instance (ADR-0008 D7/T4:
	// "an extension of the existing limiter", ratelimit.DailyCap), logged as limit_name "graph_list_daily".
	GraphListCallsPerDay int64

	// GraphMutationsPerDay is the in-memory daily cap on ALL graph mutations (Follow, Unfollow, Block,
	// Unblock, Mute, Unmute share one counter) per uid per instance, ratelimit.DailyCap, logged as
	// limit_name "graph_mutation_daily" (security review M2). It bounds the read cost of replays and no-ops,
	// which reserve no Firestore quota (ADR-0008 D7) but still read 1-4 docs each.
	//
	// Default 500. Worst case per account per day: 500 calls x 4 reads (Follow replay is the most expensive
	// mutation, 4 cold: caller + target profiles, caller graph, quotas; ADR-0008 A2) x 3 instances (the cap is per
	// instance, max-instances 3) = 6,000 reads (500x4x3, ADR-0008 Amendment cost impact), versus 172.8k/day (Follow + Block replay loops at the per-minute buckets) before the cap,
	// and ADR-0008's accepted 30.6k/day list-scraping bound. Legitimate use fits with room: 200 follows +
	// 200 blocks/mutes (the Firestore quotas) plus their undos is under 500.
	GraphMutationsPerDay int64

	// ReadBudgetPerUIDPerDay is the per-uid daily Firestore read budget every RPC is charged against
	// (ADR-0010 D5, ratelimit.Config.ReadBudget), env READ_BUDGET_PER_UID_PER_DAY, default 2,000 (~9-11x a
	// typical day of ~183 reads). The counter is per instance LIFETIME (in memory, reset only at the IST day
	// boundary, lost when the instance dies): a uid spends at most 2,000 - 1 + ReadBudgetMaxCallReads = 2,368 reads
	// on the budget plus 40 on account_ops_daily = 2,408 per instance lifetime (ADR-0010 D5 A1, A6). The daily
	// total is that times the lifetimes the uid touches: 3 on a steady day, up to 6 on a rollout day, and up to
	// ~270 when an attacker idle-cycles instances (residual R2, accepted; abuse-spike.md has the churn check).
	ReadBudgetPerUIDPerDay int64
	// ReadBudgetPerIPNoProfilePerDay is the per-IP (IPv4 or IPv6 /64) daily read METER (ADR-0010 D5 A3, A8, A9),
	// env READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY, default 500. Since A8 it never rejects: it is charged on
	// CheckHandleAvailability, CreateProfile and the calls of a verified caller without a profile. The cap is the
	// level at which a farm behind one address shows up (alert: jsonPayload.read_budget_ip_spent >= 500).
	ReadBudgetPerIPNoProfilePerDay int64
	// CheckHandleCallsPerDay is the per-uid daily call cap on CheckHandleAvailability (a ratelimit.DailyCap,
	// limit_name "check_handle_daily"), env CHECK_HANDLE_CALLS_PER_DAY, default 100.
	CheckHandleCallsPerDay int64
	// AccountOpsCallsPerDay is the per-uid daily call cap shared by DeleteAccount, RequestAccountExport and
	// GetAccountExport (ADR-0010 D5 A6; a ratelimit.DailyCap, limit_name "account_ops_daily"), env
	// ACCOUNT_OPS_CALLS_PER_DAY, default 20. Those calls are charge-only on the read budget, so this is their bound.
	AccountOpsCallsPerDay int64
	// NotificationDevicesCallsPerDay is the per-uid daily call cap shared by RegisterDevice and UnregisterDevice
	// (ADR-0017 D9; a ratelimit.DailyCap, limit_name "notification_devices_daily"), env
	// NOTIFICATION_DEVICES_CALLS_PER_DAY, default 10 (security audit N-5: a handful of launches and token refreshes per
	// day; each call is at most 9 reads and 5 writes, so 10 bounds one uid to 90 reads and 50 writes).
	NotificationDevicesCallsPerDay int64
	// NotificationSeenCallsPerDay is the per-uid daily call cap of MarkNotificationsSeen (a ratelimit.DailyCap,
	// limit_name "notification_seen_daily"), env NOTIFICATION_SEEN_CALLS_PER_DAY, default 200. A call inside the
	// 10 s no-op window writes nothing; otherwise 1 write, so the worst case is 200 writes per uid per day (1% of
	// the 20k/day free quota for one uid; the per-minute bucket and the account read budget bound the rest).
	NotificationSeenCallsPerDay int64
	// NotificationRecipientsPerActorPerDay is the per-actor daily cap on notification recipients, charged at the
	// producer before anything is published (security audit N-1; a notifications.RecipientCap), env
	// NOTIFICATION_RECIPIENTS_PER_ACTOR_PER_DAY, default 200. Each recipient costs the fan-out handler 1 + R reads
	// (typically 2) and 1 write, so 200 bounds one actor to about 600 reads and 200 writes a day (1.2% and 1% of the
	// free quota). NotificationRecipientsPerNewActorPerDay is the tier for accounts younger than
	// Quota.NewAccountWindow (NOTIFICATION_RECIPIENTS_PER_NEW_ACTOR_PER_DAY, default 50).
	NotificationRecipientsPerActorPerDay    int64
	NotificationRecipientsPerNewActorPerDay int64
	// NotificationPushesPerRecipientPerHour is the inbound push limit per recipient (security audit N-2; a
	// ratelimit.Limiter, burst = the value), env NOTIFICATION_PUSHES_PER_RECIPIENT_PER_HOUR, default 10. Rows are
	// still written; only the FCM send is skipped.
	NotificationPushesPerRecipientPerHour int64
}

// QuotaConfig holds the daily per-user quotas from ADR-0006 §4, persisted in quotas/{uid}.
type QuotaConfig struct {
	PostsPerDay   int
	FollowsPerDay int
	MediaPerDay   int
	ExportsPerDay int
	// SnapshotEditsPerDay caps the profile edits that rewrite the author snapshot on posts (P2, ADR-0003: 5/day).
	SnapshotEditsPerDay int

	// Lower quotas for accounts younger than NewAccountWindow.
	NewAccountPostsPerDay   int
	NewAccountFollowsPerDay int
	NewAccountMediaPerDay   int
	NewAccountWindow        time.Duration

	// BlocksPerDay/NewAccountBlocksPerDay cover Block + Mute together (ADR-0008 D7, quota.Blocks).
	// Unblock/Unmute are never quota-gated.
	BlocksPerDay           int
	NewAccountBlocksPerDay int

	// ReportsPerDay/NewAccountReportsPerDay cap ReportContent writes (ADR-0016 D1, quota.Reports).
	ReportsPerDay           int
	NewAccountReportsPerDay int

	// LikesPerDay/NewAccountLikesPerDay cap LikePost writes (ADR-0018 D3, quota.Likes). Unlike and UndoRepost are
	// never quota-gated; reposts use the posts quota.
	LikesPerDay           int
	NewAccountLikesPerDay int

	// SchedulesPerDay/NewAccountSchedulesPerDay cap SchedulePost calls per IST day (ADR-0021 D4, quota.Schedules;
	// review L-4). CancelScheduledPost and ListScheduledPosts are never quota-gated. The new-account tier applies to
	// accounts younger than NewAccountWindow.
	SchedulesPerDay           int
	NewAccountSchedulesPerDay int

	// BookmarksPerDay/NewAccountBookmarksPerDay cap AddBookmark writes per IST day (ADR-0023 D4, quota.Bookmarks); Remove
	// and List are never quota-gated. BookmarksMaxPerUser is the hard cap of bookmarks a user can hold (LIMIT_REACHED).
	BookmarksPerDay           int
	NewAccountBookmarksPerDay int
	BookmarksMaxPerUser       int

	// PrivacyTogglesPerDay caps UpdateProfile is_private changes (both directions) per IST day (ADR-0025 D8,
	// quota.PrivacyToggles), env QUOTA_PRIVACY_TOGGLES_PER_DAY, default 4. An is_private equal to the stored value is not
	// charged. There is no new-account tier: the cap is already small.
	PrivacyTogglesPerDay int

	// DMNewConversationsPerDay/NewAccountDMNewConversationsPerDay cap the new conversations a user opens per IST day
	// (ADR-0027 D13, quota.DMNew), env QUOTA_DM_NEW_CONVERSATIONS_PER_DAY (20) and QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY
	// (5, accounts younger than NewAccountWindow). Messages in an existing conversation are not charged.
	DMNewConversationsPerDay           int
	NewAccountDMNewConversationsPerDay int
}
