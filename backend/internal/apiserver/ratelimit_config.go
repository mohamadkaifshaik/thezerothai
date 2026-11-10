package apiserver

import (
	"time"

	articlesv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1/articlesv1connect"
	beaconsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	communitiesv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	listsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	mediav1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	messagingv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	moderationv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1/moderationv1connect"
	postsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	searchv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1/searchv1connect"
	timelinev1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// idleBucketTTL is how long an idle per-key token bucket is kept before eviction.
const idleBucketTTL = 10 * time.Minute

// RateLimitConfig builds the post-auth rate-limit interceptor's config: per-minute buckets, the per-uid daily
// call caps. It is a function of
// cfg alone so the guard test (guard_test.go) can inspect exactly what Build wires.
func RateLimitConfig(cfg config.Config) ratelimit.Config {
	rlDefault := ratelimit.NewLimiter(cfg.RateLimit.PerUserPerMinute, idleBucketTTL)
	rlCheckHandle := ratelimit.NewLimiter(cfg.RateLimit.CheckHandlePerUserPerMinute, idleBucketTTL)
	rlIP := ratelimit.NewLimiter(cfg.RateLimit.PerIPPerMinute, idleBucketTTL)

	// Follow/Unfollow 30/min, Block/Unblock/Mute/Unmute 20/min, lists 20/min; GetRelationships
	// uses rlDefault (the 60/min default).
	rlGraphFollow := ratelimit.NewLimiter(cfg.RateLimit.GraphFollowPerMinute, idleBucketTTL)
	rlGraphBlock := ratelimit.NewLimiter(cfg.RateLimit.GraphBlockPerMinute, idleBucketTTL)
	rlGraphList := ratelimit.NewLimiter(cfg.RateLimit.GraphListPerMinute, idleBucketTTL)
	// M2: ONE shared cap across every graph mutation (same DailyCap type, one counter per uid): replays and
	// no-ops reserve no Firestore quota but still read 1-3 docs. See config.RateLimitConfig.GraphMutationsPerDay
	// for the default's math. Logged as limit_name "graph_mutation_daily".
	graphMutationDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.GraphMutationsPerDay)

	// Home 6/min (the existing RATE_LIMIT_TIMELINE_PER_MIN), user timeline 30/min, CreatePost 10/min,
	// DeletePost 20/min; GetPost uses rlDefault (60/min). Posts have no daily
	// bound (the daily posts quota was removed): only these per-minute buckets limit them.
	rlHomeTimeline := ratelimit.NewLimiter(cfg.RateLimit.TimelinePerUserPerMinute, idleBucketTTL)
	rlUserTimeline := ratelimit.NewLimiter(cfg.RateLimit.UserTimelinePerMinute, idleBucketTTL)
	rlPostCreate := ratelimit.NewLimiter(cfg.RateLimit.PostCreatePerMinute, idleBucketTTL)
	rlPostDelete := ratelimit.NewLimiter(cfg.RateLimit.PostDeletePerMinute, idleBucketTTL)
	// SchedulePost and CancelScheduledPost share the CreatePost bucket (the SAME limiter, so one user's
	// creates, schedules and cancels draw on one 10/min budget; that bound is what limits schedule/cancel churn
	// across the instance-local limiter). ListScheduledPosts is a read: the 60/min default bucket.
	// PublishArticle creates a post, so it shares the CreatePost bucket too: an article post and a normal post draw on one
	// budget. SaveArticle is NOT mapped: the editor autosaves after every pause in typing, and on the 10/min bucket
	// that would block posting; it stays on the default bucket with the other article calls.
	// ReportContent 5/min per user; the daily bound is the reports quota (20, 5 for new accounts).
	rlReport := ratelimit.NewLimiter(cfg.RateLimit.ReportPerMinute, idleBucketTTL)

	// LikePost, UnlikePost, RepostPost and UndoRepost share one per-user bucket
	// (RATE_LIMIT_LIKES_PER_MIN, 30/min). Likes and reposts have no daily bound (those quotas were
	// removed): only this per-minute bucket limits them.
	rlEngagement := ratelimit.NewLimiter(cfg.RateLimit.LikesPerUserPerMinute, idleBucketTTL)

	// VotePoll has its own per-user bucket (RATE_LIMIT_POLL_VOTE_PER_MIN, 30/min per instance). The natural key admits one
	// vote per account per poll plus POLL_VOTE_CHANGES_MAX changes, so writes are bounded per poll, across the open polls
	// the account can see.
	rlPollVote := ratelimit.NewLimiter(cfg.RateLimit.PollVotePerUserPerMinute, idleBucketTTL)

	// AddBookmark and RemoveBookmark share one per-user bucket (RATE_LIMIT_BOOKMARKS_PER_MIN, 30/min); ListBookmarks
	// has its own (RATE_LIMIT_BOOKMARKS_LIST_PER_MIN, 10/min). Adds are bounded by the
	// 1,000 cap and the shared bookmark_mutation_daily cap. DEGRADED_MODE=readonly rejects Add and Remove through
	// their idempotency level, with no list here.
	rlBookmarks := ratelimit.NewLimiter(cfg.RateLimit.BookmarksPerUserPerMinute, idleBucketTTL)
	rlBookmarksList := ratelimit.NewLimiter(cfg.RateLimit.BookmarksListPerUserPerMinute, idleBucketTTL)

	// ListSuggestedUsers (RATE_LIMIT_SUGGESTIONS_PER_MIN, 10/min), ListLikedPosts (RATE_LIMIT_LIKES_LIST_PER_MIN,
	// 10/min) and GetProfileRelationship (RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN, 60/min) each have their own per-user bucket;
	// the last is not rlDefault so the header call cannot be starved by, or starve, the shared default. Tabs share the existing
	// GetUserTimeline bucket.
	rlSuggestions := ratelimit.NewLimiter(cfg.RateLimit.SuggestionsPerUserPerMinute, idleBucketTTL)
	rlLikesList := ratelimit.NewLimiter(cfg.RateLimit.LikesListPerUserPerMinute, idleBucketTTL)
	rlProfileRelationship := ratelimit.NewLimiter(cfg.RateLimit.ProfileRelationshipPerUserPerMinute, idleBucketTTL)
	// SearchPeople (30/min) and SearchPosts (20/min) have their own per-user buckets; GetTrends uses the 60/min
	// default. SearchPeople alone also has a daily cap (limit_name "search_people_daily", SEARCH_PEOPLE_CALLS_PER_DAY).
	rlSearchPeople := ratelimit.NewLimiter(cfg.RateLimit.SearchPeoplePerUserPerMinute, idleBucketTTL)
	rlSearchPosts := ratelimit.NewLimiter(cfg.RateLimit.SearchPostsPerUserPerMinute, idleBucketTTL)
	searchPeopleDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.SearchPeopleCallsPerDay)
	// ListFollowers and ListFollowing share ONE daily cap (limit_name "follow_list_daily", FOLLOW_LIST_CALLS_PER_DAY); the
	// blocked, muted and follow-request lists are only held by the graph list bucket.
	followListDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.FollowListCallsPerDay)
	// RespondToFollowRequest has its own per-user bucket (RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN, 60/min per
	// instance). ListFollowRequests shares the graph list bucket (20/min).
	// Responses need no quota (the pending requests bound them).
	rlFollowRequestsRespond := ratelimit.NewLimiter(cfg.RateLimit.FollowRequestsRespondPerUserPerMinute, idleBucketTTL)
	// L-4: UpdateProfile had only the 60/min default bucket and rewrote the whole users document on every call, so a
	// save loop was unbounded. Its own per-uid
	// daily call cap, limit_name "profile_update_daily" (PROFILE_UPDATES_PER_DAY, default 100; see
	// config.RateLimitConfig.ProfileUpdatesPerDay for the math). It counts every call, including a no-op one.
	profileUpdateDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.ProfileUpdatesPerDay)
	// M-1: ONE shared daily call cap over AddBookmark + RemoveBookmark (same DailyCap type, one counter per uid): an
	// already bookmarked Add and a Remove of a missing bookmark reserve no quota but still store an idempotency doc, so the per-minute
	// bucket alone left them unbounded. See config.RateLimitConfig.BookmarkMutationsPerDay for the default's math. Logged as limit_name "bookmark_mutation_daily". ListBookmarks is a read and has no daily cap.
	bookmarkMutationDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.BookmarkMutationsPerDay)

	// SendMessage has its own per-user bucket (RATE_LIMIT_MESSAGES_SEND_PER_MIN, 20/min per instance) and a per-uid
	// daily call cap (MESSAGES_SENDS_PER_DAY, limit_name "messages_daily"); ListConversations and ListMessages share one read
	// bucket (RATE_LIMIT_MESSAGES_READ_PER_MIN, 30/min per instance). MarkConversationRead, AcceptMessageRequest and
	// DeleteConversation use the default bucket and, since then (security review M-1),
	// a daily call cap each: MarkConversationRead alone (MESSAGES_MARK_READ_PER_DAY, "messages_mark_read_daily": it writes the
	// caller's entry on every call, repeats included) and ONE shared cap over Accept + Delete (MESSAGES_MUTATIONS_PER_DAY,
	// "messages_mutation_daily", the graph_mutation_daily shape). The new-account tier of the send cap
	// (Messaging.NewAccountSendsPerDay) is applied by the send service, because a DailyCap holds one number per procedure.
	rlMessagesSend := ratelimit.NewLimiter(cfg.RateLimit.MessagesSendPerUserPerMinute, idleBucketTTL)
	rlMessagesRead := ratelimit.NewLimiter(cfg.RateLimit.MessagesReadPerUserPerMinute, idleBucketTTL)
	messagesDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.MessagesSendsPerDay)
	messagesMarkReadDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.MessagesMarkReadPerDay)
	messagesMutationDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.MessagesMutationsPerDay)

	// The six list mutations (CreateList, UpdateList, DeleteList, AddListMember, RemoveListMember and the timeline module's
	// SetHomeTabs) share one per-user bucket (RATE_LIMIT_LISTS_WRITE_PER_MIN, 30/min per instance). GetList,
	// ListUserLists and ListListMembers share a read bucket (RATE_LIMIT_LISTS_READ_PER_MIN, 30/min); GetListTimeline has its own
	// (RATE_LIMIT_LIST_TIMELINE_PER_MIN, 12/min), because tabs switch quickly while Home stays at 6.
	rlListsWrite := ratelimit.NewLimiter(cfg.RateLimit.ListsWritePerUserPerMinute, idleBucketTTL)
	rlListsRead := ratelimit.NewLimiter(cfg.RateLimit.ListsReadPerUserPerMinute, idleBucketTTL)
	rlListTimeline := ratelimit.NewLimiter(cfg.RateLimit.ListTimelinePerUserPerMinute, idleBucketTTL)

	// Beacons: CreateBeacon, UpdateBeacon and CancelBeacon share one per-user bucket (RATE_LIMIT_BEACONS_WRITE_PER_MIN,
	// 10/min per instance); the five participation RPCs share another (RATE_LIMIT_BEACONS_ACTION_PER_MIN, 20/min); the
	// five reads (Get, ListBeacons, ListMyBeacons, ListParticipants, ListSharedBeacons) a third (RATE_LIMIT_BEACONS_READ_PER_MIN, 30/min). CreateBeacon alone carries the in-memory daily cap
	// BEACONS_CREATED_PER_DAY (limit_name "beacons_created_daily"). All twelve are mapped now so PR 3 touches no rate limits.
	rlBeaconsWrite := ratelimit.NewLimiter(cfg.RateLimit.BeaconsWritePerUserPerMinute, idleBucketTTL)
	rlBeaconsAction := ratelimit.NewLimiter(cfg.RateLimit.BeaconsActionPerUserPerMinute, idleBucketTTL)
	rlBeaconsRead := ratelimit.NewLimiter(cfg.RateLimit.BeaconsReadPerUserPerMinute, idleBucketTTL)
	beaconsCreatedDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.BeaconsCreatedPerDay)

	// The seven community mutations (CreateCommunity, UpdateCommunity, JoinCommunity, LeaveCommunity,
	// HideCommunityPost, RestoreCommunityPost, SetMemberRole) share one per-user bucket (RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN, 20/min per
	// instance). HideCommunityPost and SetMemberRole (bans go through it) also share one per-uid daily cap, limit_name
	// "community_mod_actions_daily" (COMMUNITY_MOD_ACTIONS_PER_DAY, 200 per actor); RestoreCommunityPost is left uncapped so an
	// owner can always undo hidden posts. GetCommunity, ListCommunities, ListMyCommunities,
	// ListCommunityMembers and ListModerationLog share a read bucket (RATE_LIMIT_COMMUNITIES_READ_PER_MIN, 30/min);
	// GetCommunityTimeline has its own (RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN, 12/min).
	// The uid|cid cap "community_posts_per_community_daily" is drawn on by the posts gate, not here.
	rlCommunitiesWrite := ratelimit.NewLimiter(cfg.RateLimit.CommunitiesWritePerUserPerMinute, idleBucketTTL)
	rlCommunitiesRead := ratelimit.NewLimiter(cfg.RateLimit.CommunitiesReadPerUserPerMinute, idleBucketTTL)
	rlCommunityTimeline := ratelimit.NewLimiter(cfg.RateLimit.CommunityTimelinePerUserPerMinute, idleBucketTTL)
	communityModActionsDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.CommunityModActionsPerDay)

	// CreateUpload keeps the CreatePost rate (a post with images is two media calls plus one CreatePost). Vision spend is
	// bounded by the per-uid units cap and the Vision project's request quota.
	rlMedia := ratelimit.NewLimiter(cfg.RateLimit.PostCreatePerMinute, idleBucketTTL)
	// FinalizeUpload has its own bucket, RATE_LIMIT_MEDIA_FINALIZE_PER_MIN, so client retries cannot starve new
	// uploads and the reverse. The per-uid Vision-units daily cap (media_vision_units_daily) lives in the media service, counted before the claim.
	rlMediaFinalize := ratelimit.NewLimiter(cfg.RateLimit.MediaFinalizePerMinute, idleBucketTTL)

	return ratelimit.Config{
		Default: rlDefault,
		PerProcedure: map[string]*ratelimit.Limiter{
			timelinev1connect.TimelineServiceGetHomeTimelineProcedure:            rlHomeTimeline,
			timelinev1connect.TimelineServiceGetUserTimelineProcedure:            rlUserTimeline,
			postsv1connect.PostServiceCreatePostProcedure:                        rlPostCreate,
			postsv1connect.PostServiceDeletePostProcedure:                        rlPostDelete,
			postsv1connect.PostServiceSchedulePostProcedure:                      rlPostCreate,
			postsv1connect.PostServiceCancelScheduledPostProcedure:               rlPostCreate,
			postsv1connect.PostServicePublishScheduledPostNowProcedure:           rlPostCreate,
			postsv1connect.PostServiceUpdateScheduledPostProcedure:               rlPostCreate,
			articlesv1connect.ArticleServicePublishArticleProcedure:              rlPostCreate,
			moderationv1connect.ModerationServiceReportContentProcedure:          rlReport,
			engagementv1connect.EngagementServiceLikePostProcedure:               rlEngagement,
			engagementv1connect.EngagementServiceUnlikePostProcedure:             rlEngagement,
			engagementv1connect.EngagementServiceRepostPostProcedure:             rlEngagement,
			engagementv1connect.EngagementServiceUndoRepostProcedure:             rlEngagement,
			engagementv1connect.EngagementServiceVotePollProcedure:               rlPollVote,
			engagementv1connect.EngagementServiceAddBookmarkProcedure:            rlBookmarks,
			engagementv1connect.EngagementServiceRemoveBookmarkProcedure:         rlBookmarks,
			engagementv1connect.EngagementServiceListBookmarksProcedure:          rlBookmarksList,
			engagementv1connect.EngagementServiceListLikedPostsProcedure:         rlLikesList,
			mediav1connect.MediaServiceCreateUploadProcedure:                     rlMedia,
			mediav1connect.MediaServiceFinalizeUploadProcedure:                   rlMediaFinalize,
			identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure:    rlCheckHandle,
			graphv1connect.GraphServiceFollowProcedure:                           rlGraphFollow,
			graphv1connect.GraphServiceUnfollowProcedure:                         rlGraphFollow,
			graphv1connect.GraphServiceBlockProcedure:                            rlGraphBlock,
			graphv1connect.GraphServiceUnblockProcedure:                          rlGraphBlock,
			graphv1connect.GraphServiceMuteProcedure:                             rlGraphBlock,
			graphv1connect.GraphServiceUnmuteProcedure:                           rlGraphBlock,
			graphv1connect.GraphServiceListFollowersProcedure:                    rlGraphList,
			graphv1connect.GraphServiceListFollowingProcedure:                    rlGraphList,
			graphv1connect.GraphServiceListBlockedUsersProcedure:                 rlGraphList,
			graphv1connect.GraphServiceListMutedUsersProcedure:                   rlGraphList,
			graphv1connect.GraphServiceListFollowRequestsProcedure:               rlGraphList,
			graphv1connect.GraphServiceRespondToFollowRequestProcedure:           rlFollowRequestsRespond,
			graphv1connect.GraphServiceGetProfileRelationshipProcedure:           rlProfileRelationship,
			graphv1connect.GraphServiceListSuggestedUsersProcedure:               rlSuggestions,
			searchv1connect.SearchServiceSearchPeopleProcedure:                   rlSearchPeople,
			searchv1connect.SearchServiceSearchPostsProcedure:                    rlSearchPosts,
			messagingv1connect.MessagingServiceSendMessageProcedure:              rlMessagesSend,
			messagingv1connect.MessagingServiceListConversationsProcedure:        rlMessagesRead,
			messagingv1connect.MessagingServiceListMessagesProcedure:             rlMessagesRead,
			listsv1connect.ListServiceCreateListProcedure:                        rlListsWrite,
			listsv1connect.ListServiceUpdateListProcedure:                        rlListsWrite,
			listsv1connect.ListServiceDeleteListProcedure:                        rlListsWrite,
			listsv1connect.ListServiceAddListMemberProcedure:                     rlListsWrite,
			listsv1connect.ListServiceRemoveListMemberProcedure:                  rlListsWrite,
			timelinev1connect.TimelineServiceSetHomeTabsProcedure:                rlListsWrite,
			listsv1connect.ListServiceGetListProcedure:                           rlListsRead,
			listsv1connect.ListServiceListUserListsProcedure:                     rlListsRead,
			listsv1connect.ListServiceListListMembersProcedure:                   rlListsRead,
			timelinev1connect.TimelineServiceGetListTimelineProcedure:            rlListTimeline,
			communitiesv1connect.CommunityServiceCreateCommunityProcedure:        rlCommunitiesWrite,
			communitiesv1connect.CommunityServiceUpdateCommunityProcedure:        rlCommunitiesWrite,
			communitiesv1connect.CommunityServiceJoinCommunityProcedure:          rlCommunitiesWrite,
			communitiesv1connect.CommunityServiceLeaveCommunityProcedure:         rlCommunitiesWrite,
			communitiesv1connect.CommunityServiceHideCommunityPostProcedure:      rlCommunitiesWrite,
			communitiesv1connect.CommunityServiceRestoreCommunityPostProcedure:   rlCommunitiesWrite,
			communitiesv1connect.CommunityServiceSetMemberRoleProcedure:          rlCommunitiesWrite,
			communitiesv1connect.CommunityServiceGetCommunityProcedure:           rlCommunitiesRead,
			communitiesv1connect.CommunityServiceListCommunitiesProcedure:        rlCommunitiesRead,
			communitiesv1connect.CommunityServiceListMyCommunitiesProcedure:      rlCommunitiesRead,
			communitiesv1connect.CommunityServiceListCommunityMembersProcedure:   rlCommunitiesRead,
			communitiesv1connect.CommunityServiceSearchCommunityMembersProcedure: rlCommunitiesRead,
			communitiesv1connect.CommunityServiceListModerationLogProcedure:      rlCommunitiesRead,
			timelinev1connect.TimelineServiceGetCommunityTimelineProcedure:       rlCommunityTimeline,
			beaconsv1connect.BeaconServiceCreateBeaconProcedure:                  rlBeaconsWrite,
			beaconsv1connect.BeaconServiceUpdateBeaconProcedure:                  rlBeaconsWrite,
			beaconsv1connect.BeaconServiceCancelBeaconProcedure:                  rlBeaconsWrite,
			beaconsv1connect.BeaconServiceRequestToJoinProcedure:                 rlBeaconsAction,
			beaconsv1connect.BeaconServiceWithdrawJoinRequestProcedure:           rlBeaconsAction,
			beaconsv1connect.BeaconServiceRespondToJoinRequestProcedure:          rlBeaconsAction,
			beaconsv1connect.BeaconServiceLeaveBeaconProcedure:                   rlBeaconsAction,
			beaconsv1connect.BeaconServiceRemoveParticipantProcedure:             rlBeaconsAction,
			beaconsv1connect.BeaconServiceGetBeaconProcedure:                     rlBeaconsRead,
			beaconsv1connect.BeaconServiceListBeaconsProcedure:                   rlBeaconsRead,
			beaconsv1connect.BeaconServiceListMyBeaconsProcedure:                 rlBeaconsRead,
			beaconsv1connect.BeaconServiceListParticipantsProcedure:              rlBeaconsRead,
			beaconsv1connect.BeaconServiceListSharedBeaconsProcedure:             rlBeaconsRead,
		},
		DailyCaps: map[string]ratelimit.NamedDailyCap{
			graphv1connect.GraphServiceFollowProcedure:   {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceUnfollowProcedure: {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceBlockProcedure:    {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceUnblockProcedure:  {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceMuteProcedure:     {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceUnmuteProcedure:   {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},

			engagementv1connect.EngagementServiceAddBookmarkProcedure:    {Name: "bookmark_mutation_daily", Cap: bookmarkMutationDailyCap},
			engagementv1connect.EngagementServiceRemoveBookmarkProcedure: {Name: "bookmark_mutation_daily", Cap: bookmarkMutationDailyCap},

			messagingv1connect.MessagingServiceSendMessageProcedure:          {Name: "messages_daily", Cap: messagesDailyCap},
			messagingv1connect.MessagingServiceMarkConversationReadProcedure: {Name: "messages_mark_read_daily", Cap: messagesMarkReadDailyCap},
			messagingv1connect.MessagingServiceAcceptMessageRequestProcedure: {Name: "messages_mutation_daily", Cap: messagesMutationDailyCap},
			messagingv1connect.MessagingServiceDeleteConversationProcedure:   {Name: "messages_mutation_daily", Cap: messagesMutationDailyCap},

			identityv1connect.IdentityServiceUpdateProfileProcedure: {Name: "profile_update_daily", Cap: profileUpdateDailyCap},

			communitiesv1connect.CommunityServiceHideCommunityPostProcedure: {Name: communities.LimitModActionsDaily, Cap: communityModActionsDailyCap},
			communitiesv1connect.CommunityServiceSetMemberRoleProcedure:     {Name: communities.LimitModActionsDaily, Cap: communityModActionsDailyCap},

			searchv1connect.SearchServiceSearchPeopleProcedure: {Name: "search_people_daily", Cap: searchPeopleDailyCap},

			graphv1connect.GraphServiceListFollowersProcedure: {Name: "follow_list_daily", Cap: followListDailyCap},
			graphv1connect.GraphServiceListFollowingProcedure: {Name: "follow_list_daily", Cap: followListDailyCap},

			beaconsv1connect.BeaconServiceCreateBeaconProcedure: {Name: "beacons_created_daily", Cap: beaconsCreatedDailyCap},
		},
		IP:               rlIP,
		TrustedProxyHops: cfg.TrustedProxyHops,
	}
}

// RestrictedAllowedProcedures is the exact set of procedures a SUSPENDED or DELETING caller may still reach:
// DeleteAccount only. A suspended user keeps the right to erase their own account, and a client
// that retries DeleteAccount after a lost response must get a replay, not ACCOUNT_RESTRICTED. Build wires it into
// authn.AccountStatusInterceptor and guard_test.go asserts it is exactly one procedure.
func RestrictedAllowedProcedures() []string {
	return []string{identityv1connect.IdentityServiceDeleteAccountProcedure}
}

// profileExemptProcedures is the set of procedures allowed before a profile exists. Build and the
// guard test share it, so the ratelimit IP sets cannot drift from it.
func profileExemptProcedures() map[string]struct{} {
	return authn.ProfileExemptProcedures(
		identityv1connect.IdentityServiceCreateProfileProcedure,
		// CheckHandleAvailability is read-only and must work before a profile exists (sign-up form);
		// see the deviation note in pkg/platform/authn.ProfileExemptProcedures.
		identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure,
	)
}
