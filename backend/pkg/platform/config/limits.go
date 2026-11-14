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
	// DMSuggestionsPerUserPerMinute is the ListMessageSuggestions bucket (F30), env RATE_LIMIT_DM_SUGGESTIONS_PER_MIN, default
	// 10, per instance (30 per minute with 3). No daily cap: one call reads at most about 27 source documents plus
	// cache-first profiles and follow edges.
	DMSuggestionsPerUserPerMinute int

	// NotificationsListPerUserPerMinute is the ListNotifications bucket, env RATE_LIMIT_NOTIFICATIONS_LIST_PER_MIN,
	// default 30 per instance (90 with 3), the read-bucket norm (messages, lists, communities and beacons reads are 30).
	// Normal use is far below it: the client refreshes every 60 s, and a scroll fetches one 20-row page at a time.
	// It bounds the read cost per call: up to 50 rows, plus, for a caller whose blockedBy overflowed, one
	// graph.BlockLookup of up to 100 graph docs (cache first). Before, the RPC fell back to the 60/min default.
	NotificationsListPerUserPerMinute int

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

	// CommunitiesWritePerUserPerMinute is the bucket shared by the seven community mutations (CreateCommunity, UpdateCommunity,
	// JoinCommunity, LeaveCommunity, HideCommunityPost, RestoreCommunityPost, SetMemberRole), env RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN,
	// default 20; CommunitiesReadPerUserPerMinute is GetCommunity, ListCommunities, ListMyCommunities, ListCommunityMembers and
	// ListModerationLog, env RATE_LIMIT_COMMUNITIES_READ_PER_MIN, default 30; CommunityTimelinePerUserPerMinute is GetCommunityTimeline, env
	// RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN, default 12. All per instance, so 60, 90 and 36 per minute with 3 instances.
	CommunitiesWritePerUserPerMinute  int
	CommunitiesReadPerUserPerMinute   int
	CommunityTimelinePerUserPerMinute int

	// BeaconsWritePerUserPerMinute is the bucket shared by CreateBeacon, UpdateBeacon and CancelBeacon, env
	// RATE_LIMIT_BEACONS_WRITE_PER_MIN, default 10; BeaconsActionPerUserPerMinute is shared by RequestToJoin,
	// WithdrawJoinRequest, RespondToJoinRequest, LeaveBeacon and RemoveParticipant, env RATE_LIMIT_BEACONS_ACTION_PER_MIN,
	// default 20; BeaconsReadPerUserPerMinute is shared by GetBeacon, ListBeacons, ListMyBeacons and ListParticipants, env
	// RATE_LIMIT_BEACONS_READ_PER_MIN, default 30. All per instance (x3 with 3 instances); docs/beacons-plan.md section 5.
	BeaconsWritePerUserPerMinute  int
	BeaconsActionPerUserPerMinute int
	BeaconsReadPerUserPerMinute   int

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
	// SearchDirectoryPerUserPerMinute is the one bucket SearchLists and SearchCommunities share (F20, F21), env
	// RATE_LIMIT_SEARCH_DIRECTORY_PER_MIN, default 20, per instance (60 per minute with 3). No daily cap: each call is one
	// query of at most 20 documents.
	SearchDirectoryPerUserPerMinute int

	// PollVotePerUserPerMinute is the VotePoll bucket, env RATE_LIMIT_POLL_VOTE_PER_MIN, default 30, per
	// instance (90 per minute with 3).
	PollVotePerUserPerMinute int

	// SharesPerUserPerMinute is the RecordPostShare bucket, env RATE_LIMIT_SHARES_PER_MIN, default 20, per instance (60 per
	// minute with 3). SharesRecordedPerDay is its in-memory daily call cap (one counter per uid per instance,
	// ratelimit.DailyCap), env SHARES_RECORDED_PER_DAY, default 300, logged as limit_name "shares_daily"; it counts every
	// call, a repeat share included. The once-per-account marker already bounds counter writes per account to the number of
	// distinct posts it can see (shares design §4.7).
	SharesPerUserPerMinute int
	SharesRecordedPerDay   int64

	// ImpressionsPerUserPerMinute is the RecordImpressions bucket, env RATE_LIMIT_IMPRESSIONS_PER_MIN, default 6, per
	// instance (18 per minute with 3; the client flushes every 30 s and on pause). ImpressionsRecordedPerDay is its
	// in-memory daily call cap (one counter per uid per instance, ratelimit.DailyCap), env IMPRESSIONS_RECORDED_PER_DAY,
	// default 500, logged as limit_name "impressions_daily"; it counts every call. With at most 50 ids per call it bounds
	// one account to 25,000 impression checks (50 reads and 100 writes per call at worst) per instance and IST day; the
	// (viewer, post, day) impression doc bounds the counted views to the distinct posts the account can see.
	ImpressionsPerUserPerMinute int
	ImpressionsRecordedPerDay   int64

	// CommunityModActionsPerDay is the in-memory daily cap per actor over HideCommunityPost and SetMemberRole (bans go through
	// it), env COMMUNITY_MOD_ACTIONS_PER_DAY, default 200, logged as limit_name "community_mod_actions_daily". RestoreCommunityPost
	// is not capped. CommunityPostsPerCommunityPerDay is the cap on CreatePost into one community per uid and community (key
	// uid|cid, built by the posts gate), env COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY, default 20,
	// "community_posts_per_community_daily". Both are per instance, so the effective limit is x max-instances.
	CommunityModActionsPerDay        int64
	CommunityPostsPerCommunityPerDay int64

	// SearchPeopleCallsPerDay is the in-memory daily cap on SearchPeople alone (one counter per uid per instance,
	// ratelimit.DailyCap), env SEARCH_PEOPLE_CALLS_PER_DAY, default 1000, logged as limit_name "search_people_daily".
	// SearchPosts and GetTrends are not capped. FollowListCallsPerDay is one counter shared by ListFollowers and
	// ListFollowing only, env FOLLOW_LIST_CALLS_PER_DAY, default 1000, "follow_list_daily"; the blocked, muted and follow
	// request lists are not capped. The older SEARCH_CALLS_PER_DAY and LIST_CALLS_PER_DAY keys are ignored, so a deployment that
	// still sets them keeps the new defaults.
	SearchPeopleCallsPerDay int64
	FollowListCallsPerDay   int64

	// BeaconsCreatedPerDay is the in-memory daily cap on CreateBeacon per uid (ratelimit.DailyCap), env
	// BEACONS_CREATED_PER_DAY, default 10, logged as limit_name "beacons_created_daily". Per instance, so the effective
	// limit is x max-instances.
	BeaconsCreatedPerDay int64

	// FollowRequestsRespondPerUserPerMinute is RespondToFollowRequest, env
	// RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN, default 60, per instance (180 with 3). ListFollowRequests shares the graph
	// list bucket (GraphListPerMinute).
	FollowRequestsRespondPerUserPerMinute int

	// ProfileUpdatesPerDay is the in-memory daily cap on UpdateProfile calls (one counter per uid per instance,
	// ratelimit.DailyCap), env PROFILE_UPDATES_PER_DAY, logged as limit_name "profile_update_daily" (L-4).
	// Before it, UpdateProfile had only the 60/min default bucket, and rewrote the whole users
	// document on every call even when nothing changed, so a save loop could rewrite it thousands of times a day
	// per account.
	//
	// Default 100. A real user changes their profile a handful of times a day (name, bio, avatar, location, website,
	// pin, plus retries), so 100 is generous. The cap is per instance, so with 3 instances an account
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

	// GraphMutationsPerDay is the in-memory daily cap on ALL graph mutations (Follow, Unfollow, Block,
	// Unblock, Mute, Unmute share one counter) per uid per instance, ratelimit.DailyCap, logged as
	// limit_name "graph_mutation_daily" (security review M2). It bounds replays and no-ops,
	// which reserve no Firestore quota but still read documents.
	//
	// Default 500. The cap is per instance, so with 3 instances an account can make at most 1,500 calls a day,
	// far below what replay loops at the per-minute buckets allowed before the cap. Legitimate use fits with room: 200 follows +
	// 200 blocks/mutes (the Firestore quotas) plus their undos is under 500.
	GraphMutationsPerDay int64

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
