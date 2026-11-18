package apiserver

// The uid scan's procedure table (public id PR 7). Untagged on purpose: the guard at the bottom runs in `make test`,
// so a new RPC cannot be added without either a request builder here or a commented exclusion. The seeding and the
// scan itself are in public_ids_uid_scan_integration_test.go (integration tag).
//
// Every registered procedure of every dzeroth service has an entry in uidScanCases (a builder that produces a
// meaningful request in the seeded world, with the outcome the world is expected to give) or in uidScanExcluded (a
// reason). A builder is a pure function of the world and of the view (the caller's id form), so it compiles and is
// checked without emulators: the guard asserts that every builder produces the request message the procedure takes.

import (
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/known/timestamppb"

	articlesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1/articlesv1connect"
	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	billingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/billing/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/billing/v1/billingv1connect"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	locationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1/locationv1connect"
	mediav1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1/moderationv1connect"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1/searchv1connect"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/publicid"
)

// uidScanUser is one seeded account: its role relative to the scanner F, its uid, public id and handle.
type uidScanUser struct{ Role, UID, Pub, Handle string }

// uidScanWorld is every id the builders need. Plain strings, filled by the integration seeding; a fixture whose
// seeding step failed stays empty and only the builders that use it fail (the step is named in the failure).
type uidScanWorld struct {
	// F is the scanner (the flagged caller); the others are defined by their relationship to F.
	F  *uidScanUser // the caller; private account at the end of the seeding
	A  *uidScanUser // F follows A, A follows F; author of replies, quotes, mentions, a poll; owner of community K and of beacon ABeacon
	B  *uidScanUser // quoted by A; requested to follow F; DMs F; member of F's list and of a list F follows; requester in F's beacon; moderator of F's community
	C  *uidScanUser // blocked by F
	D  *uidScanUser // muted by F
	Y  *uidScanUser // blocks F
	P  *uidScanUser // private; F requested to follow it and it accepted (FOLLOW_ACCEPTED to F)
	E  *uidScanUser // banned from F's community
	S1 *uidScanUser // spare: Follow / Mute targets
	S2 *uidScanUser // spare: Block target
	G1 *uidScanUser // F follows it (with A and G2, so F follows three accounts and the suggester runs)
	G2 *uidScanUser // F follows it

	FPost, APost, AReply, AQuote, AMention, APoll, BPost, KFPost, SparePost string
	FList, BList, BList2, SpareList                                         string
	FBeacon, ABeacon, BBeaconPending, BBeaconJoin, SpareBeacon              string
	K, KF, KJoin                                                            string
	ConvA, ConvB                                                            string
	Article, ArticleNew, ArticleSpare                                       string
	SchedCancel, SchedPublish, SchedUpdate                                  string
	ExportID, AreaID, Tag                                                   string
}

func newUidScanWorld() *uidScanWorld {
	w := &uidScanWorld{AreaID: "in.blr.indiranagar", Tag: fmt.Sprintf("uidscan%d", rand.Int63n(1_000_000_000))}
	mk := func(role string) *uidScanUser { return &uidScanUser{Role: role} }
	w.F, w.A, w.B, w.C, w.D, w.Y, w.P, w.E, w.S1, w.S2, w.G1, w.G2 = mk("F (the scanner)"), mk("A (mutual follow)"), mk("B (requester, DM peer, list and beacon member)"),
		mk("C (blocked by F)"), mk("D (muted by F)"), mk("Y (blocks F)"), mk("P (private, accepted F)"), mk("E (banned from F's community)"), mk("S1 (spare)"), mk("S2 (spare)"), mk("G1 (followed by F)"), mk("G2 (followed by F)")
	w.ArticleNew = fmt.Sprintf("uidscan-article-new-%d", rand.Int63())
	return w
}

// Users is every seeded account, F first.
func (w *uidScanWorld) Users() []*uidScanUser {
	return []*uidScanUser{w.F, w.A, w.B, w.C, w.D, w.Y, w.P, w.E, w.S1, w.S2, w.G1, w.G2}
}

// uidScanView is the caller's id form: the flagged scanner names people by public id, the control by uid.
type uidScanView struct{ Flagged bool }

func (v uidScanView) id(u *uidScanUser) string {
	if v.Flagged {
		return u.Pub
	}
	return u.UID
}

// uidScanKey is a fresh idempotency key (16-64 chars of [A-Za-z0-9_-]).
func uidScanKey(op string) string { return fmt.Sprintf("uidscan-%s-%d", op, rand.Int63()) }

func uidScanPtr[T any](v T) *T { return &v }

type uidScanPhase int

const (
	// uidScanRead: no state change; every read runs before any write.
	uidScanRead uidScanPhase = iota
	// uidScanWrite: changes state but can be repeated (the control sweep runs it too).
	uidScanWrite
	// uidScanDestroy: removes a fixture, so it runs last and only for the flagged scanner.
	uidScanDestroy
)

func (p uidScanPhase) String() string { return [...]string{"read", "write", "destroy"}[p] }

// uidScanBuild produces one request.
type uidScanBuild func(w *uidScanWorld, v uidScanView) proto.Message

// uidScanCase is the scan's entry for one procedure.
type uidScanCase struct {
	Phase uidScanPhase
	// Want is the outcome the seeded world gives the flagged scanner: "ok" (a success), "error" (a refusal that is
	// itself the point, Why says why) or "any" (either; Why says why). A mismatch is a builder or seeding failure
	// named as such, separate from a leak.
	Want, Why string
	// MustHaveID: the response must carry at least one seeded public id (flagged) or uid (control), so a pass is not
	// vacuous.
	MustHaveID bool
	Build      uidScanBuild
	// Also are further requests of the same procedure, scanned the same way (another folder, another filter).
	Also []uidScanBuild
}

// uidScanExcluded are procedures the scan does not call, each with the reason.
var uidScanExcluded = map[string]string{
	identityv1connect.IdentityServiceDeleteAccountProcedure: "destructive: it deletes the scanner and everything seeded; the deletion chain has its own " +
		"lifecycle tests, and the response carries no user id",
	billingv1connect.BillingServiceEnsureBillingIdentityProcedure: "creates a customer at the external billing provider (RevenueCat), which the emulator " +
		"chain does not have; the other two billing RPCs are called",
	// TEMPORARY (E2EE plan 3): the contract exists (Task 1) but no handler does yet, so the embedded
	// UnimplementedMessagingServiceHandler answers them. Task 6 wires the handlers and replaces these five exclusions
	// with scan cases. None of their requests or responses carries a user id.
	messagingv1connect.MessagingServiceCommitConversationProcedure:      "no handler until E2EE plan 3 Task 6 (then scanned)",
	messagingv1connect.MessagingServiceListConversationCommitsProcedure: "no handler until E2EE plan 3 Task 6 (then scanned)",
	messagingv1connect.MessagingServiceListEpochMessagesProcedure:       "no handler until E2EE plan 3 Task 6 (then scanned)",
	messagingv1connect.MessagingServiceListWelcomesProcedure:            "no handler until E2EE plan 3 Task 6 (then scanned)",
	messagingv1connect.MessagingServiceAckWelcomesProcedure:             "no handler until E2EE plan 3 Task 6 (then scanned)",
}

func uidScanCaseTable() map[string]uidScanCase {
	return map[string]uidScanCase{
		// ---- articles (publishing needs a premium subscription: no billing on the emulators; drafts are real) ----
		articlesv1connect.ArticleServiceGetArticleProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &articlesv1.GetArticleRequest{ArticleId: w.Article}
		}},
		articlesv1connect.ArticleServiceListArticlesProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &articlesv1.ListArticlesRequest{PageSize: 20}
		}},
		articlesv1connect.ArticleServiceSaveArticleProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &articlesv1.SaveArticleRequest{Article: &articlesv1.Article{ArticleId: w.ArticleNew, Title: "Scan draft", BodyJson: uidScanArticleBody}}
		}},
		articlesv1connect.ArticleServiceDeleteArticleProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &articlesv1.DeleteArticleRequest{ArticleId: w.ArticleSpare, ExpectedRevision: 1}
		}},
		articlesv1connect.ArticleServicePublishArticleProcedure: {Phase: uidScanWrite, Want: "error",
			Why: "publishing needs a premium subscription and the emulator chain has no billing, so the answer is a refusal; the error is scanned",
			Build: func(w *uidScanWorld, v uidScanView) proto.Message {
				return &articlesv1.PublishArticleRequest{ArticleId: w.Article, ExpectedRevision: 1, IdempotencyKey: uidScanKey("publish"), Caption: "scan"}
			}},

		// ---- beacons ----
		beaconsv1connect.BeaconServiceCreateBeaconProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return uidScanCreateBeacon("Scan beacon")
		}},
		beaconsv1connect.BeaconServiceUpdateBeaconProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.UpdateBeaconRequest{IdempotencyKey: uidScanKey("bupd"), BeaconId: w.FBeacon, Title: uidScanPtr("Scan beacon, edited")}
		}},
		beaconsv1connect.BeaconServiceCancelBeaconProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.CancelBeaconRequest{IdempotencyKey: uidScanKey("bcancel"), BeaconId: w.SpareBeacon}
		}},
		beaconsv1connect.BeaconServiceGetBeaconProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.GetBeaconRequest{BeaconId: w.FBeacon}
		}, Also: []uidScanBuild{func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.GetBeaconRequest{BeaconId: w.ABeacon}
		}}},
		beaconsv1connect.BeaconServiceListBeaconsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.ListBeaconsRequest{Audience: &beaconsv1.ListBeaconsRequest_Public{Public: true}, Limit: 20}
		}},
		beaconsv1connect.BeaconServiceListMyBeaconsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.ListMyBeaconsRequest{Role: beaconsv1.MyBeaconsRole_MY_BEACONS_ROLE_ALL, Window: beaconsv1.MyBeaconsWindow_MY_BEACONS_WINDOW_UPCOMING, Limit: 20}
		}},
		beaconsv1connect.BeaconServiceRequestToJoinProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.RequestToJoinRequest{IdempotencyKey: uidScanKey("bjoin"), BeaconId: w.BBeaconJoin, Note: "scan"}
		}},
		beaconsv1connect.BeaconServiceWithdrawJoinRequestProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.WithdrawJoinRequestRequest{IdempotencyKey: uidScanKey("bwd"), BeaconId: w.BBeaconPending}
		}},
		beaconsv1connect.BeaconServiceRespondToJoinRequestProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.RespondToJoinRequestRequest{IdempotencyKey: uidScanKey("bresp"), BeaconId: w.FBeacon, UserId: v.id(w.B), Response: beaconsv1.JoinResponse_JOIN_RESPONSE_ACCEPT}
		}},
		beaconsv1connect.BeaconServiceLeaveBeaconProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.LeaveBeaconRequest{IdempotencyKey: uidScanKey("bleave"), BeaconId: w.ABeacon}
		}},
		beaconsv1connect.BeaconServiceRemoveParticipantProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.RemoveParticipantRequest{IdempotencyKey: uidScanKey("brm"), BeaconId: w.FBeacon, UserId: v.id(w.A)}
		}},
		beaconsv1connect.BeaconServiceListParticipantsProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.ListParticipantsRequest{BeaconId: w.FBeacon, Limit: 20}
		}, Also: []uidScanBuild{func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.ListParticipantsRequest{BeaconId: w.FBeacon, Filter: beaconsv1.ParticipantFilter_PARTICIPANT_FILTER_REQUESTED, Limit: 20}
		}}},
		beaconsv1connect.BeaconServiceListSharedBeaconsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &beaconsv1.ListSharedBeaconsRequest{PeerUserId: v.id(w.A), Limit: 20}
		}},
		beaconsv1connect.BeaconServiceListNearbyBeaconsProcedure: {Phase: uidScanRead, Want: "any", Why: "needs the caller's chosen area; either answer is scanned",
			Build: func(w *uidScanWorld, v uidScanView) proto.Message {
				return &beaconsv1.ListNearbyBeaconsRequest{AreaId: w.AreaID, Scope: beaconsv1.NearbyScope_NEARBY_SCOPE_AREA, Limit: 20}
			}},

		// ---- billing ----
		billingv1connect.BillingServiceGetMySubscriptionProcedure: {Phase: uidScanRead, Want: "any", Why: "billing is not configured on the emulator chain; either answer is scanned",
			Build: func(w *uidScanWorld, v uidScanView) proto.Message { return &billingv1.GetMySubscriptionRequest{} }},
		billingv1connect.BillingServiceGetAvailablePlansProcedure: {Phase: uidScanRead, Want: "any", Why: "billing is not configured on the emulator chain; either answer is scanned",
			Build: func(w *uidScanWorld, v uidScanView) proto.Message { return &billingv1.GetAvailablePlansRequest{} }},

		// ---- communities ----
		communitiesv1connect.CommunityServiceCreateCommunityProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.CreateCommunityRequest{IdempotencyKey: uidScanKey("ccreate"), Name: fmt.Sprintf("Scan %d", rand.Int63n(1e12)), Description: "scan"}
		}},
		communitiesv1connect.CommunityServiceUpdateCommunityProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.UpdateCommunityRequest{IdempotencyKey: uidScanKey("cupd"), CommunityId: w.KF, Description: uidScanPtr("scan, edited")}
		}},
		communitiesv1connect.CommunityServiceGetCommunityProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.GetCommunityRequest{CommunityId: w.KF}
		}, Also: []uidScanBuild{func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.GetCommunityRequest{CommunityId: w.K}
		}}},
		communitiesv1connect.CommunityServiceListCommunitiesProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.ListCommunitiesRequest{PageSize: 20}
		}},
		communitiesv1connect.CommunityServiceListMyCommunitiesProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.ListMyCommunitiesRequest{PageSize: 20}
		}},
		communitiesv1connect.CommunityServiceJoinCommunityProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.JoinCommunityRequest{IdempotencyKey: uidScanKey("cjoin"), CommunityId: w.KJoin}
		}},
		communitiesv1connect.CommunityServiceLeaveCommunityProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.LeaveCommunityRequest{IdempotencyKey: uidScanKey("cleave"), CommunityId: w.K}
		}},
		communitiesv1connect.CommunityServiceListCommunityMembersProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.ListCommunityMembersRequest{CommunityId: w.KF, PageSize: 20}
		}, Also: []uidScanBuild{
			func(w *uidScanWorld, v uidScanView) proto.Message {
				return &communitiesv1.ListCommunityMembersRequest{CommunityId: w.KF, Filter: communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_BANNED, PageSize: 20}
			},
			func(w *uidScanWorld, v uidScanView) proto.Message {
				return &communitiesv1.ListCommunityMembersRequest{CommunityId: w.KF, Filter: communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_MODERATORS, PageSize: 20}
			},
		}},
		communitiesv1connect.CommunityServiceSearchCommunityMembersProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.SearchCommunityMembersRequest{CommunityId: w.KF, Prefix: uidScanPrefix(w.A.Handle), Limit: 10}
		}},
		communitiesv1connect.CommunityServiceHideCommunityPostProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.HideCommunityPostRequest{IdempotencyKey: uidScanKey("chide"), CommunityId: w.KF, PostId: w.KFPost}
		}},
		communitiesv1connect.CommunityServiceRestoreCommunityPostProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.RestoreCommunityPostRequest{IdempotencyKey: uidScanKey("crest"), CommunityId: w.KF, PostId: w.KFPost}
		}},
		communitiesv1connect.CommunityServiceSetMemberRoleProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.SetMemberRoleRequest{IdempotencyKey: uidScanKey("crole"), CommunityId: w.KF, UserId: v.id(w.A), Action: communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_MAKE_MODERATOR}
		}},
		communitiesv1connect.CommunityServiceListModerationLogProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &communitiesv1.ListModerationLogRequest{CommunityId: w.KF, PageSize: 20}
		}},

		// ---- engagement ----
		engagementv1connect.EngagementServiceLikePostProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.LikePostRequest{IdempotencyKey: uidScanKey("like"), PostId: w.AQuote}
		}},
		engagementv1connect.EngagementServiceUnlikePostProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.UnlikePostRequest{IdempotencyKey: uidScanKey("unlike"), PostId: w.APost}
		}},
		engagementv1connect.EngagementServiceRepostPostProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.RepostPostRequest{IdempotencyKey: uidScanKey("repost"), PostId: w.BPost}
		}},
		engagementv1connect.EngagementServiceUndoRepostProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.UndoRepostRequest{IdempotencyKey: uidScanKey("unrepost"), PostId: w.APost}
		}},
		engagementv1connect.EngagementServiceAddBookmarkProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.AddBookmarkRequest{IdempotencyKey: uidScanKey("bmadd"), PostId: w.AQuote}
		}},
		engagementv1connect.EngagementServiceRemoveBookmarkProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.RemoveBookmarkRequest{IdempotencyKey: uidScanKey("bmrm"), PostId: w.BPost}
		}},
		engagementv1connect.EngagementServiceListBookmarksProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.ListBookmarksRequest{PageSize: 20}
		}},
		engagementv1connect.EngagementServiceListLikedPostsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.ListLikedPostsRequest{PageSize: 20}
		}},
		engagementv1connect.EngagementServiceVotePollProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.VotePollRequest{IdempotencyKey: uidScanKey("vote"), PostId: w.APoll, ChoiceIndex: 0}
		}},
		engagementv1connect.EngagementServiceRecordPostShareProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.RecordPostShareRequest{IdempotencyKey: uidScanKey("share"), PostId: w.APost, Channel: engagementv1.ShareChannel_SHARE_CHANNEL_COPY_LINK}
		}},
		engagementv1connect.EngagementServiceRecordImpressionsProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &engagementv1.RecordImpressionsRequest{IdempotencyKey: uidScanKey("imp"), PostIds: []string{w.APost, w.BPost}}
		}},

		// ---- graph ----
		graphv1connect.GraphServiceFollowProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.FollowRequest{IdempotencyKey: uidScanKey("follow"), UserId: v.id(w.S1)}
		}},
		graphv1connect.GraphServiceUnfollowProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.UnfollowRequest{IdempotencyKey: uidScanKey("unfollow"), UserId: v.id(w.A)}
		}},
		graphv1connect.GraphServiceListFollowRequestsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.ListFollowRequestsRequest{PageSize: 20}
		}},
		graphv1connect.GraphServiceRespondToFollowRequestProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.RespondToFollowRequestRequest{IdempotencyKey: uidScanKey("fresp"), RequesterUserId: v.id(w.B), Accept: true}
		}},
		graphv1connect.GraphServiceBlockProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.BlockRequest{IdempotencyKey: uidScanKey("block"), UserId: v.id(w.S2)}
		}},
		graphv1connect.GraphServiceUnblockProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.UnblockRequest{IdempotencyKey: uidScanKey("unblock"), UserId: v.id(w.C)}
		}},
		graphv1connect.GraphServiceMuteProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.MuteRequest{IdempotencyKey: uidScanKey("mute"), UserId: v.id(w.S1)}
		}},
		graphv1connect.GraphServiceUnmuteProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.UnmuteRequest{IdempotencyKey: uidScanKey("unmute"), UserId: v.id(w.D)}
		}},
		graphv1connect.GraphServiceGetRelationshipsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.GetRelationshipsRequest{UserIds: []string{v.id(w.A), v.id(w.B), v.id(w.C), v.id(w.D), v.id(w.P), v.id(w.Y), v.id(w.E)}}
		}},
		graphv1connect.GraphServiceGetProfileRelationshipProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.GetProfileRelationshipRequest{UserId: v.id(w.A)}
		}},
		graphv1connect.GraphServiceListSuggestedUsersProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.ListSuggestedUsersRequest{MaxResults: 10}
		}},
		graphv1connect.GraphServiceListFollowersProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.ListFollowersRequest{UserId: v.id(w.F), PageSize: 20}
		}},
		graphv1connect.GraphServiceListFollowingProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.ListFollowingRequest{UserId: v.id(w.F), PageSize: 20}
		}},
		graphv1connect.GraphServiceListBlockedUsersProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.ListBlockedUsersRequest{PageSize: 20}
		}},
		graphv1connect.GraphServiceListMutedUsersProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &graphv1.ListMutedUsersRequest{PageSize: 20}
		}},

		// ---- identity ----
		identityv1connect.IdentityServiceCreateProfileProcedure: {Phase: uidScanWrite, Want: "ok", // replaying CreateProfile for an existing profile is an idempotent success; the Profile in the response is scanned

			Build: func(w *uidScanWorld, v uidScanView) proto.Message {
				return &identityv1.CreateProfileRequest{IdempotencyKey: uidScanKey("cprof"), Handle: uidScanHandle("sc"), DisplayName: "Scan"}
			}},
		identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &identityv1.CheckHandleAvailabilityRequest{Handle: w.A.Handle}
		}},
		identityv1connect.IdentityServiceSuggestHandlesProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &identityv1.SuggestHandlesRequest{Handle: w.A.Handle}
		}},
		identityv1connect.IdentityServiceGetMeProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &identityv1.GetMeRequest{}
		}},
		identityv1connect.IdentityServiceGetProfileProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: v.id(w.A)}}
		}, Also: []uidScanBuild{
			func(w *uidScanWorld, v uidScanView) proto.Message {
				return &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_Handle{Handle: w.B.Handle}}
			},
			func(w *uidScanWorld, v uidScanView) proto.Message {
				return &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: v.id(w.F)}}
			},
		}},
		identityv1connect.IdentityServiceUpdateProfileProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &identityv1.UpdateProfileRequest{IdempotencyKey: uidScanKey("uprof"), DisplayName: uidScanPtr("Scan caller")}
		}},
		identityv1connect.IdentityServiceChangeHandleProcedure: {Phase: uidScanWrite, Want: "any", Why: "a handle change may be refused by its cooldown on a repeat; either answer is scanned",
			Build: func(w *uidScanWorld, v uidScanView) proto.Message {
				return &identityv1.ChangeHandleRequest{IdempotencyKey: uidScanKey("chandle"), NewHandle: uidScanHandle("sh")}
			}},
		identityv1connect.IdentityServiceRequestAccountExportProcedure: {Phase: uidScanWrite, Want: "any", Why: "the export step already used the daily export quota; either answer is scanned",
			Build: func(w *uidScanWorld, v uidScanView) proto.Message {
				return &identityv1.RequestAccountExportRequest{IdempotencyKey: uidScanKey("export"), Format: identityv1.ExportFormat_EXPORT_FORMAT_JSON}
			}},
		identityv1connect.IdentityServiceGetAccountExportProcedure: {Phase: uidScanRead, Want: "any", Why: "the emulators cannot sign the download URL; either answer is scanned",
			Build: func(w *uidScanWorld, v uidScanView) proto.Message {
				return &identityv1.GetAccountExportRequest{ExportId: w.ExportID}
			}},
		identityv1connect.IdentityServiceGetCreatorInsightsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &identityv1.GetCreatorInsightsRequest{WindowDays: 7}
		}},

		// ---- lists ----
		listsv1connect.ListServiceCreateListProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.CreateListRequest{IdempotencyKey: uidScanKey("lcreate"), Name: "Scan list"}
		}},
		listsv1connect.ListServiceUpdateListProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.UpdateListRequest{IdempotencyKey: uidScanKey("lupd"), ListId: w.FList, Description: uidScanPtr("scan, edited")}
		}},
		listsv1connect.ListServiceDeleteListProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.DeleteListRequest{IdempotencyKey: uidScanKey("ldel"), ListId: w.SpareList}
		}},
		listsv1connect.ListServiceGetListProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.GetListRequest{ListId: w.FList}
		}, Also: []uidScanBuild{func(w *uidScanWorld, v uidScanView) proto.Message { return &listsv1.GetListRequest{ListId: w.BList} }}},
		listsv1connect.ListServiceListUserListsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.ListUserListsRequest{OwnerId: v.id(w.F), PageSize: 20}
		}, Also: []uidScanBuild{
			func(w *uidScanWorld, v uidScanView) proto.Message {
				return &listsv1.ListUserListsRequest{OwnerId: v.id(w.F), ContainsUserId: v.id(w.A), PageSize: 20} // contains_user_id is accepted only with the caller's own lists
			},
		}},
		listsv1connect.ListServiceAddListMemberProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.AddListMemberRequest{IdempotencyKey: uidScanKey("ladd"), ListId: w.FList, UserId: v.id(w.E)}
		}},
		listsv1connect.ListServiceRemoveListMemberProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.RemoveListMemberRequest{IdempotencyKey: uidScanKey("lrm"), ListId: w.FList, UserId: v.id(w.E)}
		}},
		listsv1connect.ListServiceListListMembersProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.ListListMembersRequest{ListId: w.FList, PageSize: 20}
		}, Also: []uidScanBuild{func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.ListListMembersRequest{ListId: w.BList, PageSize: 20}
		}}},
		listsv1connect.ListServiceFollowListProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.FollowListRequest{IdempotencyKey: uidScanKey("lfollow"), ListId: w.BList2}
		}},
		listsv1connect.ListServiceUnfollowListProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.UnfollowListRequest{IdempotencyKey: uidScanKey("lunfollow"), ListId: w.BList}
		}},
		listsv1connect.ListServiceListFollowedListsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.ListFollowedListsRequest{PageSize: 20}
		}},
		listsv1connect.ListServiceDiscoverListsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.DiscoverListsRequest{PageSize: 20}
		}},
		listsv1connect.ListServiceListSuggestedMembersProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &listsv1.ListSuggestedMembersRequest{ListId: w.FList, MaxResults: 10}
		}},

		// ---- keys (sorted within a phase: RegisterKeyDevice runs before UploadKeyPackages; RemoveKeyDevice destroys) ----
		keysv1connect.KeyServiceRegisterKeyDeviceProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: uidScanKey("keyreg"), DeviceId: uidScanKeyDevice, SignaturePublicKey: uidScanSigKey}
		}},
		keysv1connect.KeyServiceListMyKeyDevicesProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &keysv1.ListMyKeyDevicesRequest{}
		}},
		keysv1connect.KeyServiceUploadKeyPackagesProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &keysv1.UploadKeyPackagesRequest{IdempotencyKey: uidScanKey("keyup"), DeviceId: uidScanKeyDevice, KeyPackages: [][]byte{[]byte("uidscan key package")}}
		}},
		keysv1connect.KeyServiceGetKeyDevicesProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &keysv1.GetKeyDevicesRequest{UserIds: []string{v.id(w.A), v.id(w.F)}}
		}},
		keysv1connect.KeyServiceClaimKeyPackagesProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &keysv1.ClaimKeyPackagesRequest{IdempotencyKey: uidScanKey("keyclaim"), UserId: v.id(w.A)}
		}},
		keysv1connect.KeyServiceRemoveKeyDeviceProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: uidScanKey("keyrm"), DeviceId: uidScanKeyDevice}
		}},

		// ---- location ----
		locationv1connect.LocationServiceGetLocationSettingsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &locationv1.GetLocationSettingsRequest{}
		}},
		locationv1connect.LocationServiceSetAreaProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &locationv1.SetAreaRequest{IdempotencyKey: uidScanKey("area"), AreaId: w.AreaID, Consent: &locationv1.ConsentGrant{CopyVersion: 2, AdultConfirmed: true}}
		}},
		locationv1connect.LocationServiceClearAreaProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &locationv1.ClearAreaRequest{IdempotencyKey: uidScanKey("clrarea")}
		}},
		locationv1connect.LocationServiceListAreasProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &locationv1.ListAreasRequest{Limit: 10}
		}},

		// ---- media (the emulators cannot sign upload URLs) ----
		mediav1connect.MediaServiceCreateUploadProcedure: {Phase: uidScanWrite, Want: "any", Why: "the emulators have no signing credentials, so this is usually a refusal; when it succeeds, the " +
			"scanner's own uid may appear in SignedUpload.url (object path u/<uid>/...) and nowhere else",
			Build: func(w *uidScanWorld, v uidScanView) proto.Message {
				return &mediav1.CreateUploadRequest{IdempotencyKey: uidScanKey("upload"), Purpose: mediav1.MediaPurpose_MEDIA_PURPOSE_POST, Items: []*mediav1.UploadItem{{
					ContentType: "image/webp", FullSizeBytes: 100_000, ThumbSizeBytes: 10_000, Width: 1200, Height: 800,
					FullMd5: "AAAAAAAAAAAAAAAAAAAAAA==", ThumbMd5: "AAAAAAAAAAAAAAAAAAAAAA==",
				}}}
			}},
		mediav1connect.MediaServiceFinalizeUploadProcedure: {Phase: uidScanWrite, Want: "error", Why: "nothing was uploaded under this media id; the refusal is scanned",
			Build: func(w *uidScanWorld, v uidScanView) proto.Message {
				return &mediav1.FinalizeUploadRequest{IdempotencyKey: uidScanKey("finalize"), Items: []*mediav1.FinalizeItem{{MediaId: "1234567890123456789"}}}
			}},

		// ---- messaging ----
		messagingv1connect.MessagingServiceSendMessageProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &messagingv1.SendMessageRequest{IdempotencyKey: uidScanKey("dm"), Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: v.id(w.A)}, Text: "scan hello"}
		}},
		messagingv1connect.MessagingServiceListConversationsProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, PageSize: 20}
		}, Also: []uidScanBuild{func(w *uidScanWorld, v uidScanView) proto.Message {
			return &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_REQUESTS, PageSize: 20}
		}}},
		messagingv1connect.MessagingServiceListMessagesProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &messagingv1.ListMessagesRequest{ConversationId: w.ConvA, PageSize: 20}
		}, Also: []uidScanBuild{func(w *uidScanWorld, v uidScanView) proto.Message {
			return &messagingv1.ListMessagesRequest{ConversationId: w.ConvB, PageSize: 20}
		}}},
		messagingv1connect.MessagingServiceMarkConversationReadProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &messagingv1.MarkConversationReadRequest{IdempotencyKey: uidScanKey("dmread"), ConversationId: w.ConvA}
		}},
		messagingv1connect.MessagingServiceAcceptMessageRequestProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &messagingv1.AcceptMessageRequestRequest{IdempotencyKey: uidScanKey("dmaccept"), ConversationId: w.ConvB}
		}},
		messagingv1connect.MessagingServiceDeleteConversationProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &messagingv1.DeleteConversationRequest{IdempotencyKey: uidScanKey("dmdel"), ConversationId: w.ConvA}
		}},
		messagingv1connect.MessagingServiceListMessageSuggestionsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &messagingv1.ListMessageSuggestionsRequest{Limit: 10}
		}},

		// ---- moderation ----
		moderationv1connect.ModerationServiceReportContentProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &moderationv1.ReportContentRequest{IdempotencyKey: uidScanKey("report"), TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_ACCOUNT,
				TargetId: v.id(w.C), Reason: moderationv1.ReportReason_REPORT_REASON_SPAM, Note: "scan"}
		}},

		// ---- notifications ----
		notificationsv1connect.NotificationServiceListNotificationsProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &notificationsv1.ListNotificationsRequest{PageSize: 50}
		}},
		notificationsv1connect.NotificationServiceMarkNotificationsSeenProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &notificationsv1.MarkNotificationsSeenRequest{IdempotencyKey: uidScanKey("seen")}
		}},
		notificationsv1connect.NotificationServiceRegisterDeviceProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &notificationsv1.RegisterDeviceRequest{IdempotencyKey: uidScanKey("regdev"), DeviceId: "uidscan-device-0001", FcmToken: "uidscan-fcm-token-0001-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Platform: notificationsv1.DevicePlatform_DEVICE_PLATFORM_ANDROID}
		}},
		notificationsv1connect.NotificationServiceUnregisterDeviceProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &notificationsv1.UnregisterDeviceRequest{IdempotencyKey: uidScanKey("unregdev"), DeviceId: "uidscan-device-0001"}
		}},
		notificationsv1connect.NotificationServiceGetNotificationPrefsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &notificationsv1.GetNotificationPrefsRequest{}
		}},
		notificationsv1connect.NotificationServiceUpdateNotificationPrefsProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &notificationsv1.UpdateNotificationPrefsRequest{IdempotencyKey: uidScanKey("prefs"), Prefs: &notificationsv1.NotificationPrefs{
				PlansPush: true, MentionsRepliesPush: true, LikesRepostsPush: true, FollowersPush: true, MessagesPush: true}}
		}},

		// ---- posts ----
		postsv1connect.PostServiceCreatePostProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &postsv1.CreatePostRequest{IdempotencyKey: uidScanKey("post"), Text: "scan post quoting a post", QuoteOfPostId: w.APost}
		}},
		postsv1connect.PostServiceDeletePostProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &postsv1.DeletePostRequest{IdempotencyKey: uidScanKey("pdel"), PostId: w.SparePost}
		}},
		postsv1connect.PostServiceGetPostProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &postsv1.GetPostRequest{PostId: w.AQuote}
		}, Also: []uidScanBuild{
			func(w *uidScanWorld, v uidScanView) proto.Message { return &postsv1.GetPostRequest{PostId: w.AReply} },
			func(w *uidScanWorld, v uidScanView) proto.Message { return &postsv1.GetPostRequest{PostId: w.AMention} },
			func(w *uidScanWorld, v uidScanView) proto.Message { return &postsv1.GetPostRequest{PostId: w.APoll} },
		}},
		postsv1connect.PostServiceGetThreadProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &postsv1.GetThreadRequest{PostId: w.FPost, PageSize: 20}
		}},
		postsv1connect.PostServiceSchedulePostProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &postsv1.SchedulePostRequest{IdempotencyKey: uidScanKey("sched"), Text: "scheduled scan", PublishAt: timestamppb.New(time.Now().Add(3 * time.Hour))}
		}},
		postsv1connect.PostServiceListScheduledPostsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &postsv1.ListScheduledPostsRequest{PageSize: 20}
		}},
		postsv1connect.PostServiceCancelScheduledPostProcedure: {Phase: uidScanDestroy, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &postsv1.CancelScheduledPostRequest{IdempotencyKey: uidScanKey("schedx"), ScheduledId: w.SchedCancel}
		}},
		postsv1connect.PostServicePublishScheduledPostNowProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &postsv1.PublishScheduledPostNowRequest{IdempotencyKey: uidScanKey("schedp"), ScheduledId: w.SchedPublish}
		}},
		postsv1connect.PostServiceUpdateScheduledPostProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &postsv1.UpdateScheduledPostRequest{IdempotencyKey: uidScanKey("schedu"), ScheduledId: w.SchedUpdate, Text: uidScanPtr("scheduled scan, edited")}
		}},

		// ---- search ----
		searchv1connect.SearchServiceSearchPeopleProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &searchv1.SearchPeopleRequest{Query: uidScanPrefix(w.A.Handle), Limit: 20}
		}},
		searchv1connect.SearchServiceSearchPostsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &searchv1.SearchPostsRequest{Query: "#" + w.Tag, Tab: searchv1.SearchTab_SEARCH_TAB_LATEST, PageSize: 20}
		}, Also: []uidScanBuild{func(w *uidScanWorld, v uidScanView) proto.Message {
			return &searchv1.SearchPostsRequest{Query: "#" + w.Tag, Tab: searchv1.SearchTab_SEARCH_TAB_TOP, PageSize: 20}
		}}},
		searchv1connect.SearchServiceGetTrendsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &searchv1.GetTrendsRequest{Limit: 10}
		}},
		searchv1connect.SearchServiceSearchListsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &searchv1.SearchListsRequest{Query: "Scan", PageSize: 20}
		}},
		searchv1connect.SearchServiceSearchCommunitiesProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &searchv1.SearchCommunitiesRequest{Query: "Scan", PageSize: 20}
		}},
		searchv1connect.SearchServiceExploreMediaProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &searchv1.ExploreMediaRequest{PageSize: 20}
		}},
		searchv1connect.SearchServiceExplorePostsProcedure: {Phase: uidScanRead, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &searchv1.ExplorePostsRequest{PageSize: 20}
		}},

		// ---- timeline ----
		timelinev1connect.TimelineServiceGetHomeTimelineProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &timelinev1.GetHomeTimelineRequest{PageSize: 50}
		}},
		timelinev1connect.TimelineServiceGetUserTimelineProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &timelinev1.GetUserTimelineRequest{UserId: v.id(w.A), PageSize: 50}
		}, Also: []uidScanBuild{
			func(w *uidScanWorld, v uidScanView) proto.Message {
				return &timelinev1.GetUserTimelineRequest{UserId: v.id(w.A), IncludeReplies: true, Tab: timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPLIES, PageSize: 50}
			},
			func(w *uidScanWorld, v uidScanView) proto.Message {
				return &timelinev1.GetUserTimelineRequest{UserId: v.id(w.F), Tab: timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPOSTS, PageSize: 50}
			},
		}},
		timelinev1connect.TimelineServiceGetListTimelineProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &timelinev1.GetListTimelineRequest{ListId: w.FList, PageSize: 50}
		}},
		timelinev1connect.TimelineServiceGetCommunityTimelineProcedure: {Phase: uidScanRead, Want: "ok", MustHaveID: true, Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &timelinev1.GetCommunityTimelineRequest{CommunityId: w.KF, PageSize: 50}
		}},
		timelinev1connect.TimelineServiceSetHomeTabsProcedure: {Phase: uidScanWrite, Want: "ok", Build: func(w *uidScanWorld, v uidScanView) proto.Message {
			return &timelinev1.SetHomeTabsRequest{IdempotencyKey: uidScanKey("tabs"), Tabs: []*commonv1.HomeTab{{Kind: commonv1.HomeTabKind_HOME_TAB_KIND_LIST, Id: w.FList}}}
		}},
	}
}

// uidScanKeyDevice is the scanner's encryption device id and uidScanSigKey its 32-byte signature key (the key directory).
const uidScanKeyDevice = "uidscan-keydevice-0001"

var uidScanSigKey = []byte("uidscan-signature-key-32-bytes!!")

// uidScanArticleBody is a valid article body (the shape the articles package tests use).
const uidScanArticleBody = `[{"kind":"paragraph","runs":[{"text":"Hello world"}]}]`

func uidScanCreateBeacon(title string) *beaconsv1.CreateBeaconRequest {
	return &beaconsv1.CreateBeaconRequest{
		IdempotencyKey: uidScanKey("bcreate"), Audience: &beaconsv1.CreateBeaconRequest_Public{Public: true},
		Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Title: title, Venue: "Hall",
		StartAt: timestamppb.New(time.Now().Add(time.Hour)), DurationMinutes: 30, OpenSpots: 3,
		Cost: beaconsv1.BeaconCost_BEACON_COST_FREE, ChatPreference: beaconsv1.ChatPreference_CHAT_PREFERENCE_QUIET,
	}
}

// uidScanPrefix is the first characters of a handle (empty stays empty).
func uidScanPrefix(handle string) string {
	if len(handle) > 8 {
		return handle[:8]
	}
	return handle
}

// uidScanProcedures is every registered procedure ("/pkg.Service/Method") with its descriptor, sorted.
func uidScanProcedures() ([]string, map[string]protoreflect.MethodDescriptor) {
	byName := map[string]protoreflect.MethodDescriptor{}
	for _, sd := range publicid.DzerothServices(protoregistry.GlobalFiles) {
		ms := sd.Methods()
		for i := range ms.Len() {
			byName["/"+string(sd.FullName())+"/"+string(ms.Get(i).Name())] = ms.Get(i)
		}
	}
	names := make([]string, 0, len(byName))
	for n := range byName {
		names = append(names, n)
	}
	sort.Strings(names)
	return names, byName
}

// TestUIDScan_TableCoversEveryRegisteredProcedure: a new RPC cannot join the API without joining the uid scan. Runs
// without emulators.
func TestUIDScan_TableCoversEveryRegisteredProcedure(t *testing.T) {
	procs, methods := uidScanProcedures()
	if len(procs) == 0 {
		t.Fatal("no registered procedure")
	}
	cases := uidScanCaseTable()
	w := newUidScanWorld()
	for _, p := range procs {
		c, hasCase := cases[p]
		reason, excluded := uidScanExcluded[p]
		switch {
		case hasCase && excluded:
			t.Errorf("%s is both scanned and excluded", p)
		case !hasCase && !excluded:
			t.Errorf("%s has neither a request builder in uidScanCaseTable nor a reasoned exclusion in uidScanExcluded: add it to the uid scan "+
				"(backend/internal/apiserver/public_ids_uid_scan_table_test.go)", p)
		case excluded && strings.TrimSpace(reason) == "":
			t.Errorf("the exclusion of %s has no reason", p)
		}
		if !hasCase {
			continue
		}
		if c.Build == nil || (c.Want != "ok" && c.Want != "error" && c.Want != "any") || (c.Want != "ok" && c.Why == "") {
			t.Errorf("%s: a case needs a builder, Want ok|error|any, and a Why when Want is not ok", p)
			continue
		}
		for i, b := range append([]uidScanBuild{c.Build}, c.Also...) {
			for _, v := range []uidScanView{{Flagged: true}, {Flagged: false}} {
				m := b(w, v)
				if got, want := m.ProtoReflect().Descriptor().FullName(), methods[p].Input().FullName(); got != want {
					t.Errorf("%s builder #%d produces %s, the procedure takes %s", p, i, got, want)
				}
			}
		}
	}
	for p := range cases {
		if _, ok := methods[p]; !ok {
			t.Errorf("uidScanCaseTable has %s, which is not a registered procedure", p)
		}
	}
	for p := range uidScanExcluded {
		if _, ok := methods[p]; !ok {
			t.Errorf("uidScanExcluded has %s, which is not a registered procedure", p)
		}
	}
	t.Logf("%d registered procedures: %d scanned, %d excluded", len(procs), len(cases), len(uidScanExcluded))
}

// uidScanHandle is a unique handle of at most 15 characters starting with prefix.
func uidScanHandle(prefix string) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	suffix := make([]byte, 15-len(prefix))
	for i := range suffix {
		suffix[i] = alphabet[rand.Intn(len(alphabet))]
	}
	return prefix + string(suffix)
}
