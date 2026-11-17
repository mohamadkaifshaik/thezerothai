//go:build integration

package apiserver

// The end-to-end uid scan (public id PR 7): the test that decides whether FEATURE_PUBLIC_IDS may be switched on.
//
// One seeded world on the allowlist chain: a flagged scanner F and nine other accounts in different roles relative to F
// (see uidScanWorld), every one minted, so no placeholder is expected anywhere. Then, as subtests of one test:
//
//	seed                 every fixture step succeeded (a failed step is named; the builders that need it fail on their own)
//	export               F's data export holds no other seeded user's uid, and names people by public id
//	sweep/<phase>/...    EVERY registered procedure (uidScanCaseTable, guarded by TestUIDScan_TableCoversEveryRegisteredProcedure)
//	                     is called as F, flagged, and every response, error (code, message, every detail, headers, trailers) is
//	                     scanned for every seeded uid (F's own included) and for the placeholder; then as the same F on a chain
//	                     where the flag is off (the control), where no seeded public id may appear
//	errors               every inbound user-id RPC gets unknown, raw-uid, malformed, own, blocker, blocked and muted ids; an
//	                     error never contains a uid the client did not send
//	known leaks          every entry of uidScanKnownLeaks still leaks (else it must be removed)
//
// Pushes are scanned in backend/internal/notifications (TestUIDScan_PushPayloadsPerRecipient): the chain wires LogSender
// unless delivery is pubsub, so a push cannot be captured here without a production seam (buildOpts.pushSender).
//
// The only allowlisted uid is the caller's own, inside media.v1.SignedUpload.url (object path u/<uid>/...).

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"reflect"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/known/timestamppb"

	articlesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	articlesv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1/articlesv1connect"
	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/publicid"
)

// uidScanAllFlagsOn turns every feature flag on for everyone except public_ids, which the chain config sets itself.
func uidScanAllFlagsOn(c *config.Config) {
	v := reflect.ValueOf(c).Elem()
	spec := reflect.TypeOf(flags.Spec{})
	for i := range v.NumField() {
		f := v.Field(i)
		// export_zip stays at its default: exportOf reads the JSON object.
		if name := v.Type().Field(i).Name; f.Type() != spec || name == "FeaturePublicIDs" || name == "FeatureExportZip" || !f.CanSet() {
			continue
		}
		s := f.Interface().(flags.Spec)
		s.Mode = flags.On
		f.Set(reflect.ValueOf(s))
	}
}

// uidScanCfg is the chain config of both chains: every module and flag on, limits lifted, delivery inline, creators
// allowed to create communities, public_ids as given.
func uidScanCfg(mode flags.Mode, allow, creators []string) func(*config.Config) {
	base := pubChainCfg(mode, allow, creators)
	return func(c *config.Config) {
		base(c)
		uidScanAllFlagsOn(c)
		c.NotificationsDelivery = "inline"
	}
}

// uidScanEmailToken mints a verified-email account (the export needs one) and returns a fresh token and its uid.
func uidScanEmailToken(t *testing.T, projectID string) (token, uid string) {
	t.Helper()
	email := fmt.Sprintf("uidscan-%d@example.test", rand.Int63())
	_, uid = mintToken(t, email)
	post := func(url string, body map[string]any, auth bool) []byte {
		raw, _ := json.Marshal(body)
		req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		if auth {
			req.Header.Set("Authorization", "Bearer owner")
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		out, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("%s: status %d: %s", url, resp.StatusCode, out)
		}
		return out
	}
	host := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	post(fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/projects/%s/accounts:update", host, projectID), map[string]any{"localId": uid, "emailVerified": true}, true)
	out := post(fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake-api-key", host),
		map[string]any{"email": email, "password": "correct horse battery staple", "returnSecureToken": true}, false)
	var signedIn struct {
		IDToken string `json:"idToken"`
	}
	if err := json.Unmarshal(out, &signedIn); err != nil || signedIn.IDToken == "" {
		t.Fatalf("sign in: %v: %s", err, out)
	}
	return signedIn.IDToken, uid
}

// uidScanRig is the seeded world on the flagged chain.
type uidScanRig struct {
	t      *testing.T
	e      *lifecycleEnv
	w      *uidScanWorld
	tok    map[*uidScanUser]string
	failed []string // "step: error", every seeding step that did not work

	lists   listsv1connect.ListServiceClient
	beacons beaconsv1connect.BeaconServiceClient
	comm    communitiesv1connect.CommunityServiceClient
	msg     messagingv1connect.MessagingServiceClient
	eng     engagementv1connect.EngagementServiceClient
	art     articlesv1connect.ArticleServiceClient
}

// as is how caller names target: F is flagged (public ids), everyone else is not (uids).
func (r *uidScanRig) as(caller, target *uidScanUser) string {
	if caller == r.w.F {
		return target.Pub
	}
	return target.UID
}

// ok records a failed seeding step (the test goes on; the builders that need the fixture fail by name).
func uidScanOK[T any](r *uidScanRig, step string, resp *connect.Response[T], err error) *T {
	r.t.Helper()
	if err != nil {
		r.failed = append(r.failed, fmt.Sprintf("%s: %v", step, uidScanMask(err.Error(), r.w.allNeedles())))
		return nil
	}
	return resp.Msg
}

func (w *uidScanWorld) uidNeedles() []uidScanNeedle {
	var out []uidScanNeedle
	for _, u := range w.Users() {
		out = append(out, uidScanNeedle{Label: u.Role, Value: u.UID})
	}
	return append(out, uidScanNeedle{Label: "placeholder", Value: publicid.Tombstone})
}

func (w *uidScanWorld) pubNeedles() []uidScanNeedle {
	var out []uidScanNeedle
	for _, u := range w.Users() {
		out = append(out, uidScanNeedle{Label: u.Role, Value: u.Pub})
	}
	return append(out, uidScanNeedle{Label: "placeholder", Value: publicid.Tombstone})
}

func (w *uidScanWorld) allNeedles() []uidScanNeedle { return append(w.uidNeedles(), w.pubNeedles()...) }

// uidScanMask replaces every needle in s by {label}, so text can be printed.
func uidScanMask(s string, needles []uidScanNeedle) string {
	for _, n := range needles {
		if n.Value != "" {
			s = strings.ReplaceAll(s, n.Value, "{"+n.Label+"}")
		}
	}
	return s
}

func (r *uidScanRig) newUser(w *uidScanUser, token, uid string) {
	r.t.Helper()
	w.UID = uid
	r.tok[w] = token
	r.e.createProfile(r.t, token)
	w.Pub = pubStoredID(r.t, r.e.chainEnv, uid)
	me, err := r.e.identity.GetMe(context.Background(), authed(token, &identityv1.GetMeRequest{}))
	if err != nil {
		r.t.Fatalf("GetMe for %s: %v", w.Role, err)
	}
	w.Handle = me.Msg.GetProfile().GetHandle()
}

// seed builds the world. Every step records its own failure.
func (r *uidScanRig) seed() {
	ctx := context.Background()
	w, e := r.w, r.e
	F, A, B, C, D, Y, P, E, S1 := w.F, w.A, w.B, w.C, w.D, w.Y, w.P, w.E, w.S1

	follow := func(who, target *uidScanUser) *graphv1.FollowResponse {
		resp, err := e.graph.Follow(ctx, authed(r.tok[who], &graphv1.FollowRequest{IdempotencyKey: uidScanKey("sfollow"), UserId: r.as(who, target)}))
		return uidScanOK(r, fmt.Sprintf("%s follows %s", who.Role, target.Role), resp, err)
	}
	post := func(who *uidScanUser, req *postsv1.CreatePostRequest, step string) string {
		req.IdempotencyKey = uidScanKey("spost")
		resp, err := e.posts.CreatePost(ctx, authed(r.tok[who], req))
		return uidScanOK(r, step, resp, err).GetPost().GetPost().GetPostId()
	}

	// Graph: F and A follow each other; A follows B (F's suggestions); Y blocks F; F blocks C and mutes D; P is private, F
	// asks to follow it and P accepts (FOLLOW_ACCEPTED to F).
	follow(F, A)
	follow(A, F)
	follow(A, B)
	follow(A, S1)
	resp, err := e.graph.Block(ctx, authed(r.tok[Y], &graphv1.BlockRequest{IdempotencyKey: uidScanKey("sblock"), UserId: F.UID}))
	uidScanOK(r, "Y blocks F", resp, err)
	resp2, err := e.graph.Block(ctx, authed(r.tok[F], &graphv1.BlockRequest{IdempotencyKey: uidScanKey("sblock"), UserId: C.Pub}))
	uidScanOK(r, "F blocks C", resp2, err)
	resp3, err := e.graph.Mute(ctx, authed(r.tok[F], &graphv1.MuteRequest{IdempotencyKey: uidScanKey("smute"), UserId: D.Pub}))
	uidScanOK(r, "F mutes D", resp3, err)
	pr, err := e.identity.UpdateProfile(ctx, authed(r.tok[P], &identityv1.UpdateProfileRequest{IdempotencyKey: uidScanKey("spriv"), IsPrivate: uidScanPtr(true)}))
	uidScanOK(r, "P becomes private", pr, err)
	follow(F, P)
	rr, err := e.graph.RespondToFollowRequest(ctx, authed(r.tok[P], &graphv1.RespondToFollowRequestRequest{IdempotencyKey: uidScanKey("sresp"), RequesterUserId: F.UID, Accept: true}))
	uidScanOK(r, "P accepts F's follow request", rr, err)

	// Posts.
	tag := " #" + w.Tag
	w.FPost = post(F, &postsv1.CreatePostRequest{Text: "F's post" + tag}, "F posts")
	w.SparePost = post(F, &postsv1.CreatePostRequest{Text: "F's spare post"}, "F posts a spare post")
	w.BPost = post(B, &postsv1.CreatePostRequest{Text: "B's post" + tag}, "B posts")
	w.APost = post(A, &postsv1.CreatePostRequest{Text: "A's post" + tag}, "A posts")
	w.AReply = post(A, &postsv1.CreatePostRequest{Text: "A replies to F", ReplyToPostId: w.FPost}, "A replies to F")
	w.AQuote = post(A, &postsv1.CreatePostRequest{Text: "A quotes B", QuoteOfPostId: w.BPost}, "A quotes B")
	post(A, &postsv1.CreatePostRequest{Text: "A quotes F", QuoteOfPostId: w.FPost}, "A quotes F")
	w.AMention = post(A, &postsv1.CreatePostRequest{Text: "hello @" + B.Handle + " and @" + F.Handle}, "A mentions B and F")
	w.APoll = post(A, &postsv1.CreatePostRequest{Text: "A asks", Poll: &postsv1.PollDraft{Choices: []string{"Yes", "No"}, DurationMinutes: 60}}, "A posts a poll")

	// Engagement: A likes and reposts F's post (LIKE, REPOST to F); F likes, reposts and bookmarks A's, bookmarks B's.
	for _, s := range []struct {
		who  *uidScanUser
		step string
		fn   func() error
	}{
		{A, "A likes F's post", func() error {
			_, err := r.eng.LikePost(ctx, authed(r.tok[A], &engagementv1.LikePostRequest{IdempotencyKey: uidScanKey("slike"), PostId: w.FPost}))
			return err
		}},
		{A, "A reposts F's post", func() error {
			_, err := r.eng.RepostPost(ctx, authed(r.tok[A], &engagementv1.RepostPostRequest{IdempotencyKey: uidScanKey("srepost"), PostId: w.FPost}))
			return err
		}},
		{F, "F likes A's post", func() error {
			_, err := r.eng.LikePost(ctx, authed(r.tok[F], &engagementv1.LikePostRequest{IdempotencyKey: uidScanKey("slike"), PostId: w.APost}))
			return err
		}},
		{F, "F reposts A's post", func() error {
			_, err := r.eng.RepostPost(ctx, authed(r.tok[F], &engagementv1.RepostPostRequest{IdempotencyKey: uidScanKey("srepost"), PostId: w.APost}))
			return err
		}},
		{F, "F bookmarks A's post", func() error {
			_, err := r.eng.AddBookmark(ctx, authed(r.tok[F], &engagementv1.AddBookmarkRequest{IdempotencyKey: uidScanKey("sbm"), PostId: w.APost}))
			return err
		}},
		{F, "F bookmarks B's post", func() error {
			_, err := r.eng.AddBookmark(ctx, authed(r.tok[F], &engagementv1.AddBookmarkRequest{IdempotencyKey: uidScanKey("sbm"), PostId: w.BPost}))
			return err
		}},
	} {
		if err := s.fn(); err != nil {
			r.failed = append(r.failed, s.step+": "+uidScanMask(err.Error(), w.allNeedles()))
		}
	}

	// Lists: F's list holds A and B; B's list (which F follows) holds A; a spare list and a second B list for the writes.
	mkList := func(who *uidScanUser, name, step string) string {
		resp, err := r.lists.CreateList(ctx, authed(r.tok[who], &listsv1.CreateListRequest{IdempotencyKey: uidScanKey("slist"), Name: name}))
		return uidScanOK(r, step, resp, err).GetList().GetListId()
	}
	addMember := func(owner *uidScanUser, list string, member *uidScanUser, step string) {
		resp, err := r.lists.AddListMember(ctx, authed(r.tok[owner], &listsv1.AddListMemberRequest{IdempotencyKey: uidScanKey("sladd"), ListId: list, UserId: r.as(owner, member)}))
		uidScanOK(r, step, resp, err)
	}
	w.FList = mkList(F, "Scan list", "F creates a list")
	w.SpareList = mkList(F, "Scan spare list", "F creates a spare list")
	w.BList = mkList(B, "Scan B list", "B creates a list")
	w.BList2 = mkList(B, "Scan B list two", "B creates a second list")
	addMember(F, w.FList, A, "F adds A to F's list")
	addMember(F, w.FList, B, "F adds B to F's list")
	addMember(B, w.BList, A, "B adds A to B's list")
	addMember(B, w.BList2, A, "B adds A to B's second list")
	addMember(B, w.BList2, F, "B adds F to B's second list (F's lists_member_of)")
	fl, err := r.lists.FollowList(ctx, authed(r.tok[F], &listsv1.FollowListRequest{IdempotencyKey: uidScanKey("slfollow"), ListId: w.BList}))
	uidScanOK(r, "F follows B's list", fl, err)

	// Beacons: F's (B and A request, A accepted), A's (F accepted), B's (F requested), a spare of F's.
	mkBeacon := func(who *uidScanUser, title, step string) string {
		resp, err := r.beacons.CreateBeacon(ctx, authed(r.tok[who], uidScanCreateBeacon(title)))
		return uidScanOK(r, step, resp, err).GetView().GetBeacon().GetBeaconId()
	}
	w.FBeacon = mkBeacon(F, "F's coffee", "F creates a beacon")
	w.SpareBeacon = mkBeacon(F, "F's spare coffee", "F creates a spare beacon")
	w.ABeacon = mkBeacon(A, "A's coffee", "A creates a beacon")
	w.BBeaconPending = mkBeacon(B, "B's coffee", "B creates a beacon")
	w.BBeaconJoin = mkBeacon(B, "B's other coffee", "B creates a second beacon")
	join := func(who *uidScanUser, beacon, step string) {
		resp, err := r.beacons.RequestToJoin(ctx, authed(r.tok[who], &beaconsv1.RequestToJoinRequest{IdempotencyKey: uidScanKey("sbjoin"), BeaconId: beacon, Note: "scan"}))
		uidScanOK(r, step, resp, err)
	}
	accept := func(org *uidScanUser, beacon string, who *uidScanUser, step string) {
		resp, err := r.beacons.RespondToJoinRequest(ctx, authed(r.tok[org], &beaconsv1.RespondToJoinRequestRequest{
			IdempotencyKey: uidScanKey("sbresp"), BeaconId: beacon, UserId: r.as(org, who), Response: beaconsv1.JoinResponse_JOIN_RESPONSE_ACCEPT}))
		uidScanOK(r, step, resp, err)
	}
	join(B, w.FBeacon, "B requests F's beacon")
	join(A, w.FBeacon, "A requests F's beacon")
	accept(F, w.FBeacon, A, "F accepts A into F's beacon")
	join(F, w.ABeacon, "F requests A's beacon")
	accept(A, w.ABeacon, F, "A accepts F into A's beacon")
	join(F, w.BBeaconPending, "F requests B's beacon")

	// Communities: A owns K and KJoin; F owns KF (A, B, E join; B moderator, E banned); F and B join K.
	mkCommunity := func(who *uidScanUser, name, step string) string {
		resp, err := r.comm.CreateCommunity(ctx, authed(r.tok[who], &communitiesv1.CreateCommunityRequest{IdempotencyKey: uidScanKey("scom"), Name: name + " " + w.Tag, Description: "scan"}))
		return uidScanOK(r, step, resp, err).GetCommunity().GetCommunityId()
	}
	cjoin := func(who *uidScanUser, community, step string) {
		resp, err := r.comm.JoinCommunity(ctx, authed(r.tok[who], &communitiesv1.JoinCommunityRequest{IdempotencyKey: uidScanKey("scjoin"), CommunityId: community}))
		uidScanOK(r, step, resp, err)
	}
	role := func(community string, target *uidScanUser, action communitiesv1.MemberRoleAction, step string) {
		resp, err := r.comm.SetMemberRole(ctx, authed(r.tok[F], &communitiesv1.SetMemberRoleRequest{IdempotencyKey: uidScanKey("scrole"), CommunityId: community, UserId: target.Pub, Action: action}))
		uidScanOK(r, step, resp, err)
	}
	w.KF = mkCommunity(F, "Scan F", "F creates a community")
	w.K = mkCommunity(A, "Scan A", "A creates a community")
	w.KJoin = mkCommunity(A, "Scan A joinable", "A creates a second community")
	cjoin(A, w.KF, "A joins F's community")
	cjoin(B, w.KF, "B joins F's community")
	cjoin(E, w.KF, "E joins F's community")
	cjoin(F, w.K, "F joins A's community")
	cjoin(B, w.K, "B joins A's community")
	role(w.KF, B, communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_MAKE_MODERATOR, "F makes B a moderator of F's community")
	role(w.KF, E, communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_BAN, "F bans E from F's community")
	w.KFPost = post(A, &postsv1.CreatePostRequest{Text: "A in F's community", CommunityId: w.KF}, "A posts in F's community")

	// Direct messages: B writes to F (a request: F does not follow B), F and A are mutual (an accepted conversation).
	w.ConvA, w.ConvB = messaging.ConversationID(F.UID, A.UID), messaging.ConversationID(F.UID, B.UID)
	sm, err := r.msg.SendMessage(ctx, authed(r.tok[B], &messagingv1.SendMessageRequest{IdempotencyKey: uidScanKey("sdm"),
		Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: F.UID}, Text: "B says hi"}))
	uidScanOK(r, "B messages F", sm, err)
	sm, err = r.msg.SendMessage(ctx, authed(r.tok[F], &messagingv1.SendMessageRequest{IdempotencyKey: uidScanKey("sdm"),
		Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: A.Pub}, Text: "F says hi"}))
	uidScanOK(r, "F messages A", sm, err)

	// Scheduled posts and article drafts (F's own).
	sched := func(step string) string {
		resp, err := e.posts.SchedulePost(ctx, authed(r.tok[F], &postsv1.SchedulePostRequest{IdempotencyKey: uidScanKey("ssched"), Text: "scheduled " + step, PublishAt: timestamppb.New(time.Now().Add(2 * time.Hour))}))
		return uidScanOK(r, step, resp, err).GetScheduledPost().GetScheduledId()
	}
	w.SchedCancel, w.SchedPublish, w.SchedUpdate = sched("F schedules one to cancel"), sched("F schedules one to publish"), sched("F schedules one to update")
	draft := func(id, step string) {
		resp, err := r.art.SaveArticle(ctx, authed(r.tok[F], &articlesv1.SaveArticleRequest{Article: &articlesv1.Article{ArticleId: id, Title: "Scan draft", BodyJson: uidScanArticleBody}}))
		uidScanOK(r, step, resp, err)
	}
	w.Article, w.ArticleSpare = fmt.Sprintf("uidscan-article-%d", rand.Int63()), fmt.Sprintf("uidscan-article-%d", rand.Int63())
	draft(w.Article, "F saves an article draft")
	draft(w.ArticleSpare, "F saves a spare article draft")

	// Last: F becomes private, so B's follow is a request (FOLLOW_REQUEST to F, a row in ListFollowRequests).
	pf, err := e.identity.UpdateProfile(ctx, authed(r.tok[F], &identityv1.UpdateProfileRequest{IdempotencyKey: uidScanKey("spriv"), IsPrivate: uidScanPtr(true)}))
	uidScanOK(r, "F becomes private", pf, err)
	follow(B, F)
}

func uidScanWithoutPlaceholder(ns []uidScanNeedle) []uidScanNeedle {
	var out []uidScanNeedle
	for _, n := range ns {
		if n.Label != "placeholder" {
			out = append(out, n)
		}
	}
	return out
}

// ---- the scan --------------------------------------------------------------------------------------------------

var uidScanSeq atomic.Int64

// uidScanPost POSTs a Connect JSON unary request and returns the status, every response header and trailer, and the body.
func uidScanPost(url, token, proc string, body []byte) (int, http.Header, []byte, error) {
	req, err := http.NewRequest(http.MethodPost, url+proc, bytes.NewReader(body))
	if err != nil {
		return 0, nil, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connect-Protocol-Version", "1")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, nil, err
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	h := resp.Header.Clone()
	for k, vs := range resp.Trailer {
		for _, v := range vs {
			h.Add("Trailer-"+k, v)
		}
	}
	uidScanSeq.Add(1)
	return resp.StatusCode, h, out, err
}

// uidScanCaller is F as seen on one chain: the flagged chain (where public ids are expected) or the control.
type uidScanCaller struct {
	name    string
	url     string
	token   string
	view    uidScanView
	needles []uidScanNeedle // what must not appear
	present []uidScanNeedle // what a "must contain" response must hold at least one of
}

// uidScanState is what the sweeps share: the known-leak bookkeeping.
type uidScanState struct {
	r         *uidScanRig
	knownSeen map[int]bool
	// uploadSeen: the allowlisted SignedUpload.url exception actually fired (the emulators may not sign uploads).
	uploadSeen bool
}

// ownUploadURL is the one allowlisted exception: the caller's own uid inside SignedUpload.url (object path u/<uid>/...).
func (s *uidScanState) ownUploadURL(proc string, h uidScanHit) bool {
	if proc != mediav1connect.MediaServiceCreateUploadProcedure || h.Label != s.r.w.F.Role {
		return false
	}
	ok := (h.norm() == "targets[].full.url" || h.norm() == "targets[].thumb.url") && strings.Contains(h.Value, "u/"+s.r.w.F.UID+"/")
	s.uploadSeen = s.uploadSeen || ok
	return ok
}

// filter drops the allowlisted exception and the documented known leaks (recording the latter as still leaking).
func (s *uidScanState) filter(proc string, hits []uidScanHit) []uidScanHit {
	var out []uidScanHit
	for _, h := range hits {
		if s.ownUploadURL(proc, h) {
			continue
		}
		known := false
		for i, k := range uidScanKnownLeaks {
			if k.matches(proc, h) {
				s.knownSeen[i], known = true, true
			}
		}
		if !known {
			out = append(out, h)
		}
	}
	return out
}

// check scans one response and reports every hit with its procedure, path, owner role and kind.
func (s *uidScanState) check(t *testing.T, proc string, c uidScanCase, call int, caller uidScanCaller, status int, hdr http.Header, body []byte) {
	t.Helper()
	kind := "response"
	if status != http.StatusOK {
		kind = "error"
	}
	for _, h := range s.filter(proc, uidScanFind(body, hdr, caller.needles)) {
		t.Errorf("LEAK in the %s of %s (call #%d, %s): %s found at %s", kind, strings.TrimPrefix(proc, "/dzeroth."), call, caller.name, h.Label, h.Path)
	}
	t.Logf("%s call #%d (%s): %d %s", uidScanShort(proc), call, caller.name, status, uidScanCode(body))
	// Outcomes are asserted for the flagged scanner, and for the control while no write has run on either chain (the read
	// phase); later the control repeats writes on a world they already changed and is only scanned. This is what keeps
	// the control from passing on a run where every call failed.
	if caller.view.Flagged || c.Phase == uidScanRead {
		s.outcome(t, proc, c, call, caller, status, body)
	}
	if call == 0 && c.MustHaveID && status == http.StatusOK {
		found := false
		for _, n := range caller.present {
			found = found || (n.Value != "" && strings.Contains(string(body), n.Value))
		}
		if !found {
			t.Errorf("VACUOUS %s (%s): the response holds no seeded %s, so a pass would prove nothing: %s", proc, caller.name, map[bool]string{true: "public id", false: "uid"}[caller.view.Flagged], uidScanMask(string(body), s.r.w.allNeedles()))
		}
	}
}

// uidScanCode is the Connect code of an error body ("ok" for a success body).
func uidScanCode(body []byte) string {
	var e struct {
		Code string `json:"code"`
	}
	if json.Unmarshal(body, &e) == nil && e.Code != "" {
		return e.Code
	}
	return "ok"
}

func (s *uidScanState) outcome(t *testing.T, proc string, c uidScanCase, call int, caller uidScanCaller, status int, body []byte) {
	t.Helper()
	switch {
	case status == http.StatusOK && c.Want == "error":
		t.Errorf("BUILDER %s call #%d (%s): expected a refusal (%s), got a success", proc, call, caller.name, c.Why)
	case status != http.StatusOK && c.Want == "ok":
		t.Errorf("BUILDER or SEEDING %s call #%d (%s): %d %s (a seeding failure is listed in the seed subtest)", proc, call, caller.name, status, uidScanMask(string(body), s.r.w.allNeedles()))
	}
}

// sweep calls every build of the case as caller and scans each answer.
func (s *uidScanState) sweep(t *testing.T, proc string, c uidScanCase, caller uidScanCaller) {
	t.Helper()
	for i, b := range append([]uidScanBuild{c.Build}, c.Also...) {
		body, err := protojson.Marshal(b(s.r.w, caller.view))
		if err != nil {
			t.Fatalf("marshal the request of %s: %v", proc, err)
		}
		status, hdr, out, err := uidScanPost(caller.url, caller.token, proc, body)
		if err != nil {
			t.Fatalf("%s (%s) call #%d: transport: %v", proc, caller.name, i, err)
		}
		s.check(t, proc, c, i, caller, status, hdr, out)
	}
}

func uidScanShort(proc string) string {
	return strings.ReplaceAll(strings.TrimPrefix(proc, "/dzeroth."), "/", ".")
}

// ---- the test --------------------------------------------------------------------------------------------------

func TestUIDScan_EndToEnd(t *testing.T) {
	skipIfNoLifecycleEmulators(t)
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	w := newUidScanWorld()
	fTok, fUID := uidScanEmailToken(t, cfg.ProjectID)
	aTok, aUID := mintToken(t, "")
	var (
		inline            *notifications.InlineEmitter
		jobsTopic, bucket string
	)
	flaggedCfg := uidScanCfg(flags.Allowlist, []string{fUID}, []string{fUID, aUID})
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		flaggedCfg(c)
		jobsTopic, bucket = c.JobsTopic, c.ExportBucket
	}, func(o *buildOpts) { o.inlineNotifications = func(em *notifications.InlineEmitter) { inline = em } })
	if inline == nil {
		t.Fatal("the chain did not wire the inline emitter")
	}
	r := &uidScanRig{
		t: t, e: e, w: w, tok: map[*uidScanUser]string{},
		lists:   listsv1connect.NewListServiceClient(http.DefaultClient, e.url),
		beacons: beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, e.url),
		comm:    communitiesv1connect.NewCommunityServiceClient(http.DefaultClient, e.url),
		msg:     messagingv1connect.NewMessagingServiceClient(http.DefaultClient, e.url),
		eng:     engagementv1connect.NewEngagementServiceClient(http.DefaultClient, e.url),
		art:     articlesv1connect.NewArticleServiceClient(http.DefaultClient, e.url),
	}
	// Minted first: public ids exist for everyone (the chain mints at signup while the flag is not globally off).
	r.newUser(w.F, fTok, fUID)
	r.newUser(w.A, aTok, aUID)
	for _, u := range []*uidScanUser{w.B, w.C, w.D, w.Y, w.P, w.E, w.S1, w.S2} {
		tok, uid := mintToken(t, "")
		r.newUser(u, tok, uid)
	}
	r.seed()
	inline.Wait() // every delivery the seeding started is done: the notification rows exist
	defer inline.Wait()

	t.Run("seed", func(t *testing.T) {
		for _, f := range r.failed {
			t.Errorf("seeding step failed (the builders that need it will fail too): %s", f)
		}
	})

	st := &uidScanState{r: r, knownSeen: map[int]bool{}}
	flagged := uidScanCaller{name: "flagged", url: e.url, token: fTok, view: uidScanView{Flagged: true}, needles: w.uidNeedles(), present: uidScanWithoutPlaceholder(w.pubNeedles())}

	t.Run("export", func(t *testing.T) { uidScanExport(t, r, st, fTok, fUID) })

	cases := uidScanCaseTable()
	procs := make([]string, 0, len(cases))
	for p := range cases {
		procs = append(procs, p)
	}
	sort.Strings(procs)

	var control uidScanCaller
	var controlInline *notifications.InlineEmitter
	defer func() {
		if controlInline != nil {
			controlInline.Wait()
		}
	}()
	for _, phase := range []uidScanPhase{uidScanRead, uidScanWrite, uidScanDestroy} {
		for _, isControl := range []bool{false, true} {
			if isControl && phase == uidScanDestroy {
				continue // removes fixtures: the control would find them gone
			}
			caller := flagged
			if isControl {
				if control.url == "" {
					// An unflagged caller on a chain where the flag is ON for someone else (the state the rollout passes
					// through), not globally off: the interceptor and the translation are live, just not for F.
					off := newChainWith(t, func(c *config.Config) {
						uidScanCfg(flags.Allowlist, []string{"NoSuchUidInTheControlAllowlist"}, []string{fUID, aUID})(c)
						c.JobsTopic, c.ExportBucket = jobsTopic, bucket
					}, nil, func(o *buildOpts) {
						o.inlineNotifications = func(em *notifications.InlineEmitter) { controlInline = em }
					})
					if controlInline == nil {
						t.Fatal("the control chain did not wire the inline emitter")
					}
					control = uidScanCaller{name: "flag-off control", url: off.url, token: fTok, view: uidScanView{Flagged: false}, needles: w.pubNeedles(), present: uidScanWithoutPlaceholder(w.uidNeedles())}
				}
				caller = control
			}
			for _, proc := range procs {
				if cases[proc].Phase != phase {
					continue
				}
				t.Run(fmt.Sprintf("sweep/%v/%s/%s", phase, strings.ReplaceAll(caller.name, " ", "-"), uidScanShort(proc)), func(t *testing.T) {
					st.sweep(t, proc, cases[proc], caller)
				})
			}
		}
	}

	t.Run("errors", func(t *testing.T) { uidScanErrors(t, r, st, flagged) })

	t.Run("known leaks are still leaking", func(t *testing.T) {
		for i, k := range uidScanKnownLeaks {
			if !st.knownSeen[i] {
				t.Errorf("uidScanKnownLeaks[%d] (%s at %s, fix in %s) no longer leaks: remove the entry", i, uidScanShort(k.Proc), k.Path, k.FixIn)
			}
		}
		t.Logf("%d known leak(s) documented; the goal is none", len(uidScanKnownLeaks))
	})
	t.Logf("%d HTTP calls; the SignedUpload.url exception fired: %v (false means the emulator chain did not sign an upload, so it is unexercised)", uidScanSeq.Load(), st.uploadSeen)
}

// uidScanErrors: for every inbound user-id RPC and field, send ids of every kind and scan the answer: an error (or
// a success) never contains a uid the client did not send.
func uidScanErrors(t *testing.T, r *uidScanRig, st *uidScanState, flagged uidScanCaller) {
	w := r.w
	_, methods := uidScanProcedures()
	fx := pubFixtures{listID: w.FList, communityID: w.KF, beaconID: w.FBeacon}
	type idCase struct{ name, value string }
	idCases := []idCase{
		{"unknown public id", pubUnknown()},
		{"raw uid of another user", w.B.UID},
		{"raw uid of the caller", w.F.UID},
		{"malformed", "not an id!"},
		{"tombstone", publicid.Tombstone},
		{"caller's own public id", w.F.Pub},
		{"public id of a user who blocks the caller", w.Y.Pub},
		{"public id of a user the caller blocked", w.C.Pub},
		{"public id of a user the caller muted", w.D.Pub},
		{"public id of a private user", w.P.Pub},
	}
	for _, proc := range publicIDInboundRPCs(t) {
		md, ok := methods[proc]
		if !ok {
			t.Errorf("%s is not registered", proc)
			continue
		}
		for _, path := range pubTranslateFields(md.Input(), nil, map[protoreflect.FullName]bool{}) {
			t.Run(uidScanShort(proc)+"/"+path.String(), func(t *testing.T) {
				for _, ic := range idCases {
					body := pubRequest(t, md, proc, fx, path, ic.value)
					status, hdr, out, err := uidScanPost(flagged.url, flagged.token, proc, []byte(body))
					if err != nil {
						t.Fatalf("%s: transport: %v", ic.name, err)
					}
					// The client sent ic.value: a uid it sent may come back, one it did not send never.
					var needles []uidScanNeedle
					for _, n := range flagged.needles {
						if n.Value != ic.value {
							needles = append(needles, n)
						}
					}
					kind := "response"
					if status != http.StatusOK {
						kind = "error"
					}
					for _, h := range st.filter(proc, uidScanFind(out, hdr, needles)) {
						t.Errorf("LEAK in the %s of %s for %q: %s found at %s", kind, uidScanShort(proc), ic.name, h.Label, h.Path)
					}
				}
			})
		}
	}
}

// uidScanExport runs F's account export through the real job and scans the raw archive. Chosen rule: no OTHER seeded
// user's uid appears anywhere (F's own uid is F's own data and is allowed); the other users appear by public id and handle.
func uidScanExport(t *testing.T, r *uidScanRig, st *uidScanState, fTok, fUID string) {
	w := r.w
	for _, step := range []struct {
		what string
		fn   func() error
	}{
		{"F reports C's account", func() error {
			resp, err := r.e.moderation.ReportContent(context.Background(), authed(fTok, &moderationv1.ReportContentRequest{
				IdempotencyKey: uidScanKey("srep"), TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_ACCOUNT, TargetId: w.C.Pub, Reason: moderationv1.ReportReason_REPORT_REASON_SPAM}))
			_ = resp
			return err
		}},
	} {
		if err := step.fn(); err != nil {
			t.Errorf("export fixture %q: %v", step.what, uidScanMask(err.Error(), w.allNeedles()))
		}
	}
	id, raw := r.e.exportOf(t, testUser{fTok, fUID}, uidScanKey("export"))
	w.ExportID = id
	text := string(raw)
	for _, u := range w.Users() {
		if u == w.F {
			continue
		}
		if strings.Contains(text, u.UID) {
			t.Errorf("LEAK in the export: the uid of %s is in the archive", u.Role)
		}
	}
	if strings.Contains(text, publicid.Tombstone) {
		t.Errorf("the export carries the placeholder id although every account is minted")
	}
	// Not vacuous: the people F follows, blocks and mutes are named by public id and handle.
	for _, u := range []*uidScanUser{w.A, w.C, w.D} {
		if !strings.Contains(text, u.Pub) {
			t.Errorf("the export does not name %s by public id", u.Role)
		}
		if !strings.Contains(text, u.Handle) {
			t.Errorf("the export does not name %s by handle", u.Role)
		}
	}
	// Which sections hold data (so a pass is known not to be empty-handed).
	var sections map[string]any
	if err := json.Unmarshal(raw, &sections); err != nil {
		t.Fatalf("the export is not a JSON object: %v", err)
	}
	var withData, empty []string
	for k, v := range sections {
		if uidScanHasData(v) {
			withData = append(withData, k)
		} else {
			empty = append(empty, k)
		}
	}
	sort.Strings(withData)
	sort.Strings(empty)
	t.Logf("export sections with data: %v; without: %v", withData, empty)
	for _, want := range []string{"graph", "lists", "messages", "reports", "notif", "commun", "beacon", "engag", "bookmark"} {
		found, populated := false, false
		for k, v := range sections {
			if strings.Contains(strings.ToLower(k), want) {
				found, populated = true, populated || uidScanHasData(v)
			}
		}
		switch {
		case !found:
			t.Logf("no export section matches %q (not exported, or named otherwise)", want)
		case !populated:
			t.Errorf("the export section matching %q is empty: the seeding did not fill it, so the scan proves nothing there", want)
		}
	}
}

func uidScanHasData(v any) bool {
	switch x := v.(type) {
	case map[string]any:
		for _, c := range x {
			if uidScanHasData(c) {
				return true
			}
		}
	case []any:
		return len(x) > 0
	case string:
		return x != ""
	}
	return false
}
