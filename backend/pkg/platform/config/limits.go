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
}
