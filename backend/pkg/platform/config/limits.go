package config

import "time"

// RateLimitConfig holds the in-memory token-bucket limits. Approximate per instance
// (effective ceiling is ~limit x max-instances).
type RateLimitConfig struct {
	PerUserPerMinute            int
	TimelinePerUserPerMinute    int
	CheckHandlePerUserPerMinute int
	LikesPerUserPerMinute       int
	PerIPPerMinute              int

	// Posts/timeline per-procedure buckets. GetHomeTimeline uses TimelinePerUserPerMinute (6) and
	// GetPost uses PerUserPerMinute (the 60/min default).
	UserTimelinePerMinute int // GetUserTimeline, env RATE_LIMIT_USER_TIMELINE_PER_MIN, default 30
	PostCreatePerMinute   int // CreatePost, env RATE_LIMIT_POST_CREATE_PER_MIN, default 10
	PostDeletePerMinute   int // DeletePost, env RATE_LIMIT_POST_DELETE_PER_MIN, default 20
	// MediaFinalizePerMinute is the FinalizeUpload bucket, env RATE_LIMIT_MEDIA_FINALIZE_PER_MIN, default 10, per
	// instance (30 with 3). CreateUpload stays on PostCreatePerMinute, so retries cannot starve new uploads and the reverse.
	MediaFinalizePerMinute int
	// ReportPerMinute is the ReportContent bucket, env RATE_LIMIT_REPORT_PER_MIN, default 5.
	ReportPerMinute int

	// BookmarksPerUserPerMinute is the AddBookmark + RemoveBookmark bucket, env RATE_LIMIT_BOOKMARKS_PER_MIN,
	// default 30; BookmarksListPerUserPerMinute is ListBookmarks, env RATE_LIMIT_BOOKMARKS_LIST_PER_MIN, default 10. Both
	// are per instance (effective ceiling x max-instances).
	BookmarksPerUserPerMinute     int
	BookmarksListPerUserPerMinute int

	// BookmarkMutationsPerDay is the in-memory daily cap on AddBookmark + RemoveBookmark calls combined (one counter per
	// uid per instance, ratelimit.DailyCap), env BOOKMARK_MUTATIONS_PER_DAY, logged as limit_name "bookmark_mutation_daily"
	// (security review M-1). An already bookmarked Add and a Remove of a missing bookmark reserve no quota but each
	// store an idempotency doc, so the 30/min bucket alone left them unbounded.
	//
	// Default 1,500: a full clear-out of the BOOKMARKS_MAX_PER_USER 1,000 cap plus room for adds, retries and undo churn. The cap is per instance, so with 3 instances an account can make at most 4,500 calls a day.
	BookmarkMutationsPerDay int64

	// MessagesSendPerUserPerMinute is the SendMessage bucket, env RATE_LIMIT_MESSAGES_SEND_PER_MIN, default 20;
	// MessagesReadPerUserPerMinute is the bucket shared by ListConversations, ListMessages and MarkConversationRead, env
	// RATE_LIMIT_MESSAGES_READ_PER_MIN, default 30. Both are per instance (60/min and 90/min with 3 instances).
	MessagesSendPerUserPerMinute int
	MessagesReadPerUserPerMinute int

	// MessagesSendsPerDay is the in-memory daily cap on SendMessage calls (one counter per uid per instance,
	// ratelimit.DailyCap), env MESSAGES_SENDS_PER_DAY, default 300, logged as limit_name "messages_daily".
	// Worst case per account: 300 x 3 instances = 900 messages a day. The new-account value is Messaging.NewAccountSendsPerDay.
	MessagesSendsPerDay int64

	// MessagesMarkReadPerDay is the in-memory daily cap on MarkConversationRead calls (one counter per uid per instance,
	// ratelimit.DailyCap), env MESSAGES_MARK_READ_PER_DAY, default 500, logged as limit_name "messages_mark_read_daily"
	// (security review M-1). Every call on an existing entry writes, a repeat included, and the call sat on the 60/min
	// default bucket (180/min at 3 instances). Default 500: a few dozen thread opens and
	// foreground pushes a day for an active user, with a wide margin. The cap is per instance, so with 3 instances
	// an account can make at most 1,500 calls a day.
	MessagesMarkReadPerDay int64

	// MessagesMutationsPerDay is the in-memory daily cap shared by AcceptMessageRequest and DeleteConversation (one counter per
	// uid per instance, ratelimit.DailyCap), env MESSAGES_MUTATIONS_PER_DAY, default 500, logged as limit_name
	// "messages_mutation_daily" (M-1). Sized like GraphMutationsPerDay (500): both are state changes on a social edge,
	// idempotent by state, and a person answers a handful of requests a day. A repeat writes nothing; the cap is per instance, so with 3 instances
	// an account can make at most 1,500 calls a day, and real work is bounded
	// further by the requests there are to answer (3 unanswered per sender, 20 new conversations per sender per day).
	MessagesMutationsPerDay int64

	// ListsWritePerUserPerMinute is the bucket shared by the six list mutations (CreateList, UpdateList, DeleteList, AddListMember,
	// RemoveListMember and SetHomeTabs), env RATE_LIMIT_LISTS_WRITE_PER_MIN, default 30; ListsReadPerUserPerMinute is GetList,
	// ListUserLists and ListListMembers, env RATE_LIMIT_LISTS_READ_PER_MIN, default 30; ListTimelinePerUserPerMinute is
	// GetListTimeline, env RATE_LIMIT_LIST_TIMELINE_PER_MIN, default 12 (tabs switch quickly; Home stays 6). All per instance, so
	// 90, 90 and 36 per minute with 3 instances.
	ListsWritePerUserPerMinute   int
	ListsReadPerUserPerMinute    int
	ListTimelinePerUserPerMinute int

	// ListMutationsPerDay is the in-memory daily cap shared by the six list mutations (one counter per uid per instance,
	// ratelimit.DailyCap), env LIST_MUTATIONS_PER_DAY, default 500, logged as limit_name "list_mutation_daily".
	// Without it 30/min x 3 instances x 1,440 min of UpdateList calls a day would be about 130k list mutations. The cap is per instance, so with 3 instances an
	// account can make at most 1,500 calls a day, and real work is bounded further by the caps (20 lists, 150 members, 10 creates, 300 adds).
	ListMutationsPerDay int64

	// CommunitiesWritePerUserPerMinute is the bucket shared by the seven community mutations (CreateCommunity, UpdateCommunity,
	// JoinCommunity, LeaveCommunity, HideCommunityPost, RestoreCommunityPost, SetMemberRole), env RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN,
	// default 20; CommunitiesReadPerUserPerMinute is GetCommunity, ListCommunities, ListMyCommunities, ListCommunityMembers and
	// ListModerationLog, env RATE_LIMIT_COMMUNITIES_READ_PER_MIN, default 30; CommunityTimelinePerUserPerMinute is GetCommunityTimeline, env
	// RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN, default 12. All per instance, so 60, 90 and 36 per minute with 3 instances.
	CommunitiesWritePerUserPerMinute  int
	CommunitiesReadPerUserPerMinute   int
	CommunityTimelinePerUserPerMinute int

	// CommunityMutationsPerDay is the in-memory daily cap shared by CreateCommunity, UpdateCommunity, JoinCommunity and LeaveCommunity (one
	// counter per uid per instance), env COMMUNITY_MUTATIONS_PER_DAY, default 200, logged as limit_name "community_mutation_daily".
	// CommunityModActionsPerDay is the cap per actor over HideCommunityPost, RestoreCommunityPost and SetMemberRole, env
	// COMMUNITY_MOD_ACTIONS_PER_DAY, default 200, "community_mod_actions_daily". CommunityPostsPerCommunityPerDay is the cap on CreatePost into
	// one community per uid and community (key uid|cid, built by the posts gate), env COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY, default 20,
	// "community_posts_per_community_daily". Effective x3 instances. Without the first, 20/min x 3 x 1,440 UpdateCommunity
	// calls would be about 86k writes a day.
	CommunityMutationsPerDay         int64
	CommunityModActionsPerDay        int64
	CommunityPostsPerCommunityPerDay int64

	// SuggestionsPerUserPerMinute is the ListSuggestedUsers bucket, env RATE_LIMIT_SUGGESTIONS_PER_MIN, default 10;
	// LikesListPerUserPerMinute is ListLikedPosts, env RATE_LIMIT_LIKES_LIST_PER_MIN, default 10; ProfileRelationshipPerUserPerMinute
	// is GetProfileRelationship, env RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN, default 60. All are per instance, so the
	// effective ceiling is x max-instances (30, 30 and 180 per minute with 3).
	SuggestionsPerUserPerMinute         int
	LikesListPerUserPerMinute           int
	ProfileRelationshipPerUserPerMinute int

	// SearchPeoplePerUserPerMinute is SearchPeople, env RATE_LIMIT_SEARCH_PEOPLE_PER_MIN, default 30;
	// SearchPostsPerUserPerMinute is SearchPosts, env RATE_LIMIT_SEARCH_POSTS_PER_MIN, default 20. Both per instance, so the
	// effective ceiling is x max-instances (90 and 60 per minute with 3). GetTrends uses the PerUserPerMinute default bucket.
	SearchPeoplePerUserPerMinute int
	SearchPostsPerUserPerMinute  int

	// PollVotePerUserPerMinute is the VotePoll bucket, env RATE_LIMIT_POLL_VOTE_PER_MIN, default 30, per
	// instance (90 per minute with 3).
	PollVotePerUserPerMinute int

	// PollVotesPerDay is the in-memory daily cap on VotePoll calls (one counter per uid per instance, ratelimit.DailyCap), env
	// POLL_VOTES_PER_DAY, default 300, logged as limit_name "poll_votes_daily" (option D). PollVotesPerDayNewAccount
	// (env POLL_VOTES_PER_DAY_NEW_ACCOUNT, default 50) is the value for an account inside the new-account window: the
	// ratelimit interceptor cannot tell account age, so the VotePoll service applies it; the interceptor cap uses
	// PollVotesPerDay. A cap in memory is sound here because the natural key admits ONE vote per account per poll: writes are
	// bounded by 3 x the open polls the account can see whatever the cap does after a restart. At most 300 x 3 instances = 900
	// calls per account per day.
	PollVotesPerDay           int64
	PollVotesPerDayNewAccount int64

	// SearchCallsPerDay is the in-memory daily cap on SearchPeople + SearchPosts calls together (one counter per uid per
	// instance, ratelimit.DailyCap), env SEARCH_CALLS_PER_DAY, logged as limit_name "search_daily".
	//
	// Default 300. At most 300 x 3 instances = 900 calls per account per day.
	// Worst people rows 900 x 20 = 18,000 handles a day, already public on profiles.
	SearchCallsPerDay int64

	// TrendsCallsPerDay is the in-memory daily cap on GetTrends calls (one counter per uid per instance, ratelimit.DailyCap),
	// env TRENDS_CALLS_PER_DAY, logged as limit_name "trends_daily" (part 4, review L-4). Its own cap,
	// not search_daily.
	//
	// Default 400 = 300 typeahead bursts (the search_daily level) + 100 TrendsCubit loads (a 5 min client TTL over 8 active
	// hours is 96). At most 400 x 3 instances = 1,200 calls per account per day, about 36,500 a month: INR 3 to 10 per account
	// month in requests, vCPU and memory, against INR 680 to 2,190 with only the 60/min bucket.
	TrendsCallsPerDay int64

	// FollowRequestsRespondPerUserPerMinute is RespondToFollowRequest, env
	// RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN, default 60, per instance (180 with 3). ListFollowRequests shares the graph
	// list bucket (GraphListPerMinute) and its graph_list_daily cap.
	FollowRequestsRespondPerUserPerMinute int

	// SuggestionsCallsPerDay is the in-memory daily cap on ListSuggestedUsers calls (one counter per uid per instance,
	// ratelimit.DailyCap), env SUGGESTIONS_CALLS_PER_DAY, logged as limit_name "suggestions_daily".
	//
	// Default 50. At most 50 calls x 3 instances (the cap is per instance) per account per day. Results are cached per viewer (SUGGESTIONS_CACHE_TTL).
	SuggestionsCallsPerDay int64

	// ProfileUpdatesPerDay is the in-memory daily cap on UpdateProfile calls (one counter per uid per instance,
	// ratelimit.DailyCap), env PROFILE_UPDATES_PER_DAY, logged as limit_name "profile_update_daily" (L-4).
	// Before it, UpdateProfile had only the 60/min default bucket, and rewrote the whole users
	// document on every call even when nothing changed, so a save loop could rewrite it thousands of times a day
	// per account.
	//
	// Default 100. A real user changes their profile a handful of times a day (name, bio, avatar, banner, location,
	// website, pin, plus retries), so 100 is generous. The cap is per instance, so with 3 instances an account
	// can make at most 300 calls a day, each writing at most once (not at all when nothing changes).
	ProfileUpdatesPerDay int64

	// PreAuthIPPerMinute is the coarse, pre-auth per-IP token bucket (M1):
	// plain net/http middleware in front of the whole Connect handler chain, so an unauthenticated flood
	// is rejected before it costs any App Check / ID token JWT-verify CPU. Deliberately generous — this is
	// a flood backstop, not the fine-grained per-uid/IP limiting PerIPPerMinute already does once a request
	// is inside the Connect chain (a separate bucket; see ratelimit.PreAuthIPMiddleware).
	PreAuthIPPerMinute int

	// Graph per-procedure buckets. GetRelationships uses PerUserPerMinute (the 60/min default).
	GraphFollowPerMinute int // Follow, Unfollow
	GraphBlockPerMinute  int // Block, Unblock, Mute, Unmute
	GraphListPerMinute   int // ListFollowers, ListFollowing, ListBlockedUsers, ListMutedUsers

	// GraphListCallsPerDay is the in-memory daily cap on list RPCs per uid per instance (an extension of the existing limiter, ratelimit.DailyCap),
	// logged as limit_name "graph_list_daily".
	GraphListCallsPerDay int64

	// GraphMutationsPerDay is the in-memory daily cap on ALL graph mutations (Follow, Unfollow, Block,
	// Unblock, Mute, Unmute share one counter) per uid per instance, ratelimit.DailyCap, logged as
	// limit_name "graph_mutation_daily" (security review M2). It bounds replays and no-ops,
	// which reserve no Firestore quota but still read documents.
	//
	// Default 500. The cap is per instance, so with 3 instances an account can make at most 1,500 calls a day,
	// far below what replay loops at the per-minute buckets allowed before the cap. Legitimate use fits with room: 200 follows +
	// 200 blocks/mutes (the Firestore quotas) plus their undos is under 500.
	GraphMutationsPerDay int64

	// CheckHandleCallsPerDay is the per-uid daily call cap on CheckHandleAvailability (a ratelimit.DailyCap,
	// limit_name "check_handle_daily"), env CHECK_HANDLE_CALLS_PER_DAY, default 100.
	CheckHandleCallsPerDay int64
	// AccountOpsCallsPerDay is the per-uid daily call cap shared by DeleteAccount, RequestAccountExport and
	// GetAccountExport (a ratelimit.DailyCap, limit_name "account_ops_daily"), env
	// ACCOUNT_OPS_CALLS_PER_DAY, default 20. This is their daily bound.
	AccountOpsCallsPerDay int64
	// NotificationDevicesCallsPerDay is the per-uid daily call cap shared by RegisterDevice and UnregisterDevice
	// (a ratelimit.DailyCap, limit_name "notification_devices_daily"), env
	// NOTIFICATION_DEVICES_CALLS_PER_DAY, default 10 (security audit N-5: a handful of launches and token refreshes per
	// day).
	NotificationDevicesCallsPerDay int64
	// NotificationSeenCallsPerDay is the per-uid daily call cap of MarkNotificationsSeen (a ratelimit.DailyCap,
	// limit_name "notification_seen_daily"), env NOTIFICATION_SEEN_CALLS_PER_DAY, default 200. A call inside the
	// 10 s no-op window writes nothing; otherwise it writes once (the per-minute bucket bounds the rest).
	NotificationSeenCallsPerDay int64
	// NotificationRecipientsPerActorPerDay is the per-actor daily cap on notification recipients, charged at the
	// producer before anything is published (security audit N-1; a notifications.RecipientCap), env
	// NOTIFICATION_RECIPIENTS_PER_ACTOR_PER_DAY, default 200. Each recipient costs the fan-out handler a few reads and a write, which bounds the work one actor can cause in a day. NotificationRecipientsPerNewActorPerDay is the tier for accounts younger than
	// Quota.NewAccountWindow (NOTIFICATION_RECIPIENTS_PER_NEW_ACTOR_PER_DAY, default 50).
	NotificationRecipientsPerActorPerDay    int64
	NotificationRecipientsPerNewActorPerDay int64
	// NotificationPushesPerRecipientPerHour is the inbound push limit per recipient (security audit N-2; a
	// ratelimit.Limiter, burst = the value), env NOTIFICATION_PUSHES_PER_RECIPIENT_PER_HOUR, default 10. Rows are
	// still written; only the FCM send is skipped.
	NotificationPushesPerRecipientPerHour int64
}

// QuotaConfig holds the daily per-user quotas kept against spam (persisted in quotas/{uid}) and the bookmarks cap.
type QuotaConfig struct {
	// NewAccountWindow is how long an account counts as new: the lower tiers below, and the new-account tiers of
	// other modules, apply inside it.
	NewAccountWindow time.Duration

	// ReportsPerDay/NewAccountReportsPerDay cap ReportContent writes (quota.Reports).
	ReportsPerDay           int
	NewAccountReportsPerDay int

	// BookmarksMaxPerUser is the hard cap of bookmarks a user can hold (LIMIT_REACHED).
	BookmarksMaxPerUser int

	// DMNewConversationsPerDay/NewAccountDMNewConversationsPerDay cap the new conversations a user opens per IST day
	// (quota.DMNew), env QUOTA_DM_NEW_CONVERSATIONS_PER_DAY (20) and QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY
	// (5, accounts younger than NewAccountWindow). Messages in an existing conversation are not charged.
	DMNewConversationsPerDay           int
	NewAccountDMNewConversationsPerDay int
}
