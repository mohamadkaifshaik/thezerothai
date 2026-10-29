package apiserver

import (
	"time"

	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	mediav1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	messagingv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	moderationv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1/moderationv1connect"
	notificationsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	postsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	timelinev1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// idleBucketTTL is how long an idle per-key token bucket is kept before eviction.
const idleBucketTTL = 10 * time.Minute

// RateLimitConfig builds the post-auth rate-limit interceptor's config: per-minute buckets, the per-uid daily
// call caps and the ADR-0010 D5 read budget (uid, plus IP on profileExempt procedures). It is a function of
// cfg alone so the guard test (guard_test.go) can inspect exactly what Build wires.
func RateLimitConfig(cfg config.Config) ratelimit.Config {
	rlDefault := ratelimit.NewLimiter(cfg.RateLimit.PerUserPerMinute, idleBucketTTL)
	rlCheckHandle := ratelimit.NewLimiter(cfg.RateLimit.CheckHandlePerUserPerMinute, idleBucketTTL)
	rlIP := ratelimit.NewLimiter(cfg.RateLimit.PerIPPerMinute, idleBucketTTL)

	// ADR-0008 D7: Follow/Unfollow 30/min, Block/Unblock/Mute/Unmute 20/min, lists 20/min; GetRelationships
	// uses rlDefault (the 60/min default). A shared DailyCap (not a second limiter) backs the per-uid daily
	// list cap (T4), logged as limit_name "graph_list_daily".
	rlGraphFollow := ratelimit.NewLimiter(cfg.RateLimit.GraphFollowPerMinute, idleBucketTTL)
	rlGraphBlock := ratelimit.NewLimiter(cfg.RateLimit.GraphBlockPerMinute, idleBucketTTL)
	rlGraphList := ratelimit.NewLimiter(cfg.RateLimit.GraphListPerMinute, idleBucketTTL)
	graphListDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.GraphListCallsPerDay)
	// M2: ONE shared cap across every graph mutation (same DailyCap type, one counter per uid): replays and
	// no-ops reserve no Firestore quota but still read 1-3 docs. See config.RateLimitConfig.GraphMutationsPerDay
	// for the default's math. Logged as limit_name "graph_mutation_daily".
	graphMutationDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.GraphMutationsPerDay)
	// ADR-0010 D5 / T3: CheckHandleAvailability call cap, limit_name "check_handle_daily".
	checkHandleDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.CheckHandleCallsPerDay)
	// ADR-0010 D5 A6: limit_name "account_ops_daily", shared by DeleteAccount, RequestAccountExport, GetAccountExport.
	accountOpsDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.AccountOpsCallsPerDay)

	// ADR-0017 D9: RegisterDevice and UnregisterDevice share one per-uid daily call cap, limit_name
	// "notification_devices_daily" (each call is a transaction of up to 8 reads and 5 writes). The other three
	// notification RPCs use the 60/min default bucket and the read budget.
	notificationDevicesDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.NotificationDevicesCallsPerDay)
	// MarkNotificationsSeen has its own cap, limit_name "notification_seen_daily": it is called on every tab focus,
	// so sharing the 50/day devices cap would lock device registration out. 200 writes/uid/day worst case.
	notificationSeenDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.NotificationSeenCallsPerDay)

	// ADR-0010 T4: home 6/min (the existing RATE_LIMIT_TIMELINE_PER_MIN), user timeline 30/min, CreatePost 10/min,
	// DeletePost 20/min; GetPost uses rlDefault (60/min). Posts are bounded per day by quota.Posts (100, 20 for
	// new accounts) and every read by the ADR-0010 D5 read budget, so there is no extra daily call cap.
	rlHomeTimeline := ratelimit.NewLimiter(cfg.RateLimit.TimelinePerUserPerMinute, idleBucketTTL)
	rlUserTimeline := ratelimit.NewLimiter(cfg.RateLimit.UserTimelinePerMinute, idleBucketTTL)
	rlPostCreate := ratelimit.NewLimiter(cfg.RateLimit.PostCreatePerMinute, idleBucketTTL)
	rlPostDelete := ratelimit.NewLimiter(cfg.RateLimit.PostDeletePerMinute, idleBucketTTL)
	// ADR-0021 D4: SchedulePost and CancelScheduledPost share the CreatePost bucket (the SAME limiter, so one user's
	// creates, schedules and cancels draw on one 10/min budget; that bound is what limits schedule/cancel churn
	// across the instance-local limiter). ListScheduledPosts is a read: the 60/min default bucket and the read budget.
	// Schedules are bounded per day by quota.Schedules (50, 10 for new accounts).
	// ADR-0016: ReportContent 5/min per user; the daily bound is the reports quota (20, 5 for new accounts).
	rlReport := ratelimit.NewLimiter(cfg.RateLimit.ReportPerMinute, idleBucketTTL)

	// ADR-0018 D9: LikePost, UnlikePost, RepostPost and UndoRepost share one per-user bucket
	// (RATE_LIMIT_LIKES_PER_MIN, 30/min). Likes are bounded per day by quota.Likes (500, 100 for new accounts),
	// reposts by quota.Posts, and every read by the ADR-0010 D5 read budget.
	rlEngagement := ratelimit.NewLimiter(cfg.RateLimit.LikesPerUserPerMinute, idleBucketTTL)

	// ADR-0023 D4: AddBookmark and RemoveBookmark share one per-user bucket (RATE_LIMIT_BOOKMARKS_PER_MIN, 30/min); ListBookmarks
	// has its own (RATE_LIMIT_BOOKMARKS_LIST_PER_MIN, 10/min). Adds are bounded per day by quota.Bookmarks (200, 50 for new
	// accounts) and the cap, every call by the ADR-0010 D5 read budget. DEGRADED_MODE=readonly rejects Add and Remove through
	// their idempotency level, with no list here.
	rlBookmarks := ratelimit.NewLimiter(cfg.RateLimit.BookmarksPerUserPerMinute, idleBucketTTL)
	rlBookmarksList := ratelimit.NewLimiter(cfg.RateLimit.BookmarksListPerUserPerMinute, idleBucketTTL)

	// ADR-0024 D10: ListSuggestedUsers (RATE_LIMIT_SUGGESTIONS_PER_MIN, 10/min), ListLikedPosts (RATE_LIMIT_LIKES_LIST_PER_MIN,
	// 10/min) and GetProfileRelationship (RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN, 60/min) each have their own per-user bucket;
	// the last is not rlDefault so the header call cannot be starved by, or starve, the shared default. Suggestions also have a
	// per-uid daily call cap (SUGGESTIONS_CALLS_PER_DAY, limit_name "suggestions_daily"); the likes list and the relationship
	// are reads, covered by the ADR-0010 D5 read budget. Tabs share the existing GetUserTimeline bucket.
	rlSuggestions := ratelimit.NewLimiter(cfg.RateLimit.SuggestionsPerUserPerMinute, idleBucketTTL)
	rlLikesList := ratelimit.NewLimiter(cfg.RateLimit.LikesListPerUserPerMinute, idleBucketTTL)
	rlProfileRelationship := ratelimit.NewLimiter(cfg.RateLimit.ProfileRelationshipPerUserPerMinute, idleBucketTTL)
	suggestionsDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.SuggestionsCallsPerDay)
	// ADR-0025 D13: RespondToFollowRequest has its own per-user bucket (RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN, 60/min per
	// instance). ListFollowRequests shares the graph list bucket (20/min) and the graph_list_daily cap. Both are covered by the
	// ADR-0010 D5 read budget; responses need no quota (the pending requests bound them).
	rlFollowRequestsRespond := ratelimit.NewLimiter(cfg.RateLimit.FollowRequestsRespondPerUserPerMinute, idleBucketTTL)
	// W3-22 L-4: UpdateProfile had only the 60/min default bucket and rewrote the whole users document on every call, so a
	// save loop was bounded by the read budget alone (about 6,000 writes a day per account at 3 instances). Its own per-uid
	// daily call cap, limit_name "profile_update_daily" (PROFILE_UPDATES_PER_DAY, default 100; see
	// config.RateLimitConfig.ProfileUpdatesPerDay for the math). It counts every call, including a no-op one (0 writes).
	profileUpdateDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.ProfileUpdatesPerDay)
	// W2-14 M-1: ONE shared daily call cap over AddBookmark + RemoveBookmark (same DailyCap type, one counter per uid): an
	// already bookmarked Add and a Remove of a missing bookmark reserve no quota but still store an idempotency doc (1 write +
	// 1 TTL delete), so the per-minute bucket alone left them unbounded. See config.RateLimitConfig.BookmarkMutationsPerDay for
	// the default's math. Logged as limit_name "bookmark_mutation_daily". ListBookmarks is a read: the read budget covers it.
	bookmarkMutationDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.BookmarkMutationsPerDay)

	// ADR-0027 D13: SendMessage has its own per-user bucket (RATE_LIMIT_MESSAGES_SEND_PER_MIN, 20/min per instance) and a per-uid
	// daily call cap (MESSAGES_SENDS_PER_DAY, limit_name "messages_daily"); ListConversations and ListMessages share one read
	// bucket (RATE_LIMIT_MESSAGES_READ_PER_MIN, 30/min per instance). MarkConversationRead, AcceptMessageRequest and
	// DeleteConversation use the default bucket (the read budget covers every RPC) and, since W7-29 (security review W7-22 M-1),
	// a daily call cap each: MarkConversationRead alone (MESSAGES_MARK_READ_PER_DAY, "messages_mark_read_daily": it writes the
	// caller's entry on every call, repeats included) and ONE shared cap over Accept + Delete (MESSAGES_MUTATIONS_PER_DAY,
	// "messages_mutation_daily", the graph_mutation_daily shape). The new-account tier of the send cap
	// (Messaging.NewAccountSendsPerDay) is applied by the send service, because a DailyCap holds one number per procedure.
	rlMessagesSend := ratelimit.NewLimiter(cfg.RateLimit.MessagesSendPerUserPerMinute, idleBucketTTL)
	rlMessagesRead := ratelimit.NewLimiter(cfg.RateLimit.MessagesReadPerUserPerMinute, idleBucketTTL)
	messagesDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.MessagesSendsPerDay)
	messagesMarkReadDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.MessagesMarkReadPerDay)
	messagesMutationDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.MessagesMutationsPerDay)

	// P4: CreateUpload and FinalizeUpload share one per-user bucket at the CreatePost rate (a post with images is
	// two media calls plus one CreatePost). Images are bounded per day by quota.Uploads (20, 5 for new accounts)
	// and Vision spend by VISION_MONTHLY_CAP.
	rlMedia := ratelimit.NewLimiter(cfg.RateLimit.PostCreatePerMinute, idleBucketTTL)

	return ratelimit.Config{
		Default: rlDefault,
		PerProcedure: map[string]*ratelimit.Limiter{
			timelinev1connect.TimelineServiceGetHomeTimelineProcedure:         rlHomeTimeline,
			timelinev1connect.TimelineServiceGetUserTimelineProcedure:         rlUserTimeline,
			postsv1connect.PostServiceCreatePostProcedure:                     rlPostCreate,
			postsv1connect.PostServiceDeletePostProcedure:                     rlPostDelete,
			postsv1connect.PostServiceSchedulePostProcedure:                   rlPostCreate,
			postsv1connect.PostServiceCancelScheduledPostProcedure:            rlPostCreate,
			moderationv1connect.ModerationServiceReportContentProcedure:       rlReport,
			engagementv1connect.EngagementServiceLikePostProcedure:            rlEngagement,
			engagementv1connect.EngagementServiceUnlikePostProcedure:          rlEngagement,
			engagementv1connect.EngagementServiceRepostPostProcedure:          rlEngagement,
			engagementv1connect.EngagementServiceUndoRepostProcedure:          rlEngagement,
			engagementv1connect.EngagementServiceAddBookmarkProcedure:         rlBookmarks,
			engagementv1connect.EngagementServiceRemoveBookmarkProcedure:      rlBookmarks,
			engagementv1connect.EngagementServiceListBookmarksProcedure:       rlBookmarksList,
			engagementv1connect.EngagementServiceListLikedPostsProcedure:      rlLikesList,
			mediav1connect.MediaServiceCreateUploadProcedure:                  rlMedia,
			mediav1connect.MediaServiceFinalizeUploadProcedure:                rlMedia,
			identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: rlCheckHandle,
			graphv1connect.GraphServiceFollowProcedure:                        rlGraphFollow,
			graphv1connect.GraphServiceUnfollowProcedure:                      rlGraphFollow,
			graphv1connect.GraphServiceBlockProcedure:                         rlGraphBlock,
			graphv1connect.GraphServiceUnblockProcedure:                       rlGraphBlock,
			graphv1connect.GraphServiceMuteProcedure:                          rlGraphBlock,
			graphv1connect.GraphServiceUnmuteProcedure:                        rlGraphBlock,
			graphv1connect.GraphServiceListFollowersProcedure:                 rlGraphList,
			graphv1connect.GraphServiceListFollowingProcedure:                 rlGraphList,
			graphv1connect.GraphServiceListBlockedUsersProcedure:              rlGraphList,
			graphv1connect.GraphServiceListMutedUsersProcedure:                rlGraphList,
			graphv1connect.GraphServiceListFollowRequestsProcedure:            rlGraphList,
			graphv1connect.GraphServiceRespondToFollowRequestProcedure:        rlFollowRequestsRespond,
			graphv1connect.GraphServiceGetProfileRelationshipProcedure:        rlProfileRelationship,
			graphv1connect.GraphServiceListSuggestedUsersProcedure:            rlSuggestions,
			messagingv1connect.MessagingServiceSendMessageProcedure:           rlMessagesSend,
			messagingv1connect.MessagingServiceListConversationsProcedure:     rlMessagesRead,
			messagingv1connect.MessagingServiceListMessagesProcedure:          rlMessagesRead,
		},
		DailyCaps: map[string]ratelimit.NamedDailyCap{
			graphv1connect.GraphServiceListFollowersProcedure:      {Name: "graph_list_daily", Cap: graphListDailyCap},
			graphv1connect.GraphServiceListFollowingProcedure:      {Name: "graph_list_daily", Cap: graphListDailyCap},
			graphv1connect.GraphServiceListBlockedUsersProcedure:   {Name: "graph_list_daily", Cap: graphListDailyCap},
			graphv1connect.GraphServiceListMutedUsersProcedure:     {Name: "graph_list_daily", Cap: graphListDailyCap},
			graphv1connect.GraphServiceListFollowRequestsProcedure: {Name: "graph_list_daily", Cap: graphListDailyCap},

			graphv1connect.GraphServiceFollowProcedure:   {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceUnfollowProcedure: {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceBlockProcedure:    {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceUnblockProcedure:  {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceMuteProcedure:     {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceUnmuteProcedure:   {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},

			engagementv1connect.EngagementServiceAddBookmarkProcedure:    {Name: "bookmark_mutation_daily", Cap: bookmarkMutationDailyCap},
			engagementv1connect.EngagementServiceRemoveBookmarkProcedure: {Name: "bookmark_mutation_daily", Cap: bookmarkMutationDailyCap},

			graphv1connect.GraphServiceListSuggestedUsersProcedure: {Name: "suggestions_daily", Cap: suggestionsDailyCap},

			messagingv1connect.MessagingServiceSendMessageProcedure:          {Name: "messages_daily", Cap: messagesDailyCap},
			messagingv1connect.MessagingServiceMarkConversationReadProcedure: {Name: "messages_mark_read_daily", Cap: messagesMarkReadDailyCap},
			messagingv1connect.MessagingServiceAcceptMessageRequestProcedure: {Name: "messages_mutation_daily", Cap: messagesMutationDailyCap},
			messagingv1connect.MessagingServiceDeleteConversationProcedure:   {Name: "messages_mutation_daily", Cap: messagesMutationDailyCap},

			identityv1connect.IdentityServiceUpdateProfileProcedure: {Name: "profile_update_daily", Cap: profileUpdateDailyCap},

			identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: {Name: "check_handle_daily", Cap: checkHandleDailyCap},

			notificationsv1connect.NotificationServiceRegisterDeviceProcedure:        {Name: "notification_devices_daily", Cap: notificationDevicesDailyCap},
			notificationsv1connect.NotificationServiceUnregisterDeviceProcedure:      {Name: "notification_devices_daily", Cap: notificationDevicesDailyCap},
			notificationsv1connect.NotificationServiceMarkNotificationsSeenProcedure: {Name: "notification_seen_daily", Cap: notificationSeenDailyCap},

			// A6: ONE shared call cap for the three charge-only account operations (their only bound).
			identityv1connect.IdentityServiceDeleteAccountProcedure:        {Name: "account_ops_daily", Cap: accountOpsDailyCap},
			identityv1connect.IdentityServiceRequestAccountExportProcedure: {Name: "account_ops_daily", Cap: accountOpsDailyCap},
			identityv1connect.IdentityServiceGetAccountExportProcedure:     {Name: "account_ops_daily", Cap: accountOpsDailyCap},
		},
		// ADR-0010 D5: covers every procedure; ReadBudgetExempt stays empty (guard_test.go). WithMaxCallReads
		// arms the single-flight guard near the cap (review M1).
		ReadBudget:   ratelimit.NewDailyCap(cfg.RateLimit.ReadBudgetPerUIDPerDay).WithMaxCallReads(config.ReadBudgetMaxCallReads),
		ReadBudgetIP: ratelimit.NewDailyCap(cfg.RateLimit.ReadBudgetPerIPNoProfilePerDay).WithMaxCallReads(config.IPReadBudgetMaxCallReads),
		// ADR-0010 D5 A8: the IP key never rejects. ReadBudgetIPEnforce is empty (the guard test keeps it so; a
		// procedure added needs an ADR amendment); both exempt procedures are charge-only, so one account behind a
		// shared IPv4 address cannot block sign-ups for everyone behind it. Together they must equal
		// profileExemptProcedures (guard test, security L6).
		ReadBudgetIPEnforce: map[string]struct{}{},
		ReadBudgetIPChargeOnly: map[string]struct{}{
			identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: {},
			identityv1connect.IdentityServiceCreateProfileProcedure:           {},
		},
		// ADR-0010 D5 A6 (review M2, CLAUDE.md rule 10): charged, never rejected. Each entry needs a reason in
		// guard_test.go allowedReadBudgetChargeOnly and a DailyCaps entry below (account_ops_daily).
		ReadBudgetChargeOnly: map[string]struct{}{
			// Right to delete: must work for a user who has spent today's budget (App Store / Play / DPDP).
			identityv1connect.IdentityServiceDeleteAccountProcedure: {},
			// Right to export: same reason; a small read count, and the per-minute bucket still applies.
			identityv1connect.IdentityServiceRequestAccountExportProcedure: {},
			// Polls the export produced by RequestAccountExport; must not be blocked while that job is pending.
			identityv1connect.IdentityServiceGetAccountExportProcedure: {},
		},
		IP:               rlIP,
		TrustedProxyHops: cfg.TrustedProxyHops,
	}
}

// RestrictedAllowedProcedures is the exact set of procedures a SUSPENDED or DELETING caller may still reach
// (ADR-0011 Q2/Q3): DeleteAccount only. A suspended user keeps the right to erase their own account, and a client
// that retries DeleteAccount after a lost response must get a replay, not ACCOUNT_RESTRICTED. Build wires it into
// authn.AccountStatusInterceptor and guard_test.go asserts it is exactly one procedure.
func RestrictedAllowedProcedures() []string {
	return []string{identityv1connect.IdentityServiceDeleteAccountProcedure}
}

// profileExemptProcedures is the set of procedures allowed before a profile exists (ADR-0006 §2). Build and the
// guard test share it, so the ratelimit IP sets cannot drift from it.
func profileExemptProcedures() map[string]struct{} {
	return authn.ProfileExemptProcedures(
		identityv1connect.IdentityServiceCreateProfileProcedure,
		// CheckHandleAvailability is read-only and must work before a profile exists (sign-up form);
		// see the ADR-0006 deviation note in pkg/platform/authn.ProfileExemptProcedures.
		identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure,
	)
}
