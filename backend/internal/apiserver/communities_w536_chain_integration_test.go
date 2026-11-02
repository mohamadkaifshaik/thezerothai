//go:build integration

package apiserver

// W5-36 (Part B backend tests): communities over the real Build chain on the emulators. The package tests below the interceptors pin the
// repositories and the feed; what only the chain can prove is pinned here: flag gates and the creators list at the interceptor's one read,
// W5-29 acceptance 3 end to end, a suspension in the middle of a pagination, the COMMUNITY report with its evidence and budget, the F14
// reply-hint edge with a real block, and the removal-log overflow reset on the wire.
//
// Caches: the community document is cached 60 s per instance and the platform levers (opsctl) write Firestore directly, so every read
// that must SEE a lever runs on a fresh Build (cold caches), exactly as another Cloud Run instance would. Within one instance the levers
// take effect inside the documented 60 s bound; that bound is not asserted here (no sleeping for sync).
//
// The takedown half of acceptance 3 calls the same two repository methods as opsctl (cmd/opsctl/moderation.go Takedown, community.go
// Append); the CLI glue itself is pinned by TestTakedownAndSuspend_Integration_CommunityRemovals in cmd/opsctl (package main cannot be
// imported here).

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	rpcCreateCommunity   = "/dzeroth.communities.v1.CommunityService/CreateCommunity"
	rpcGetCommunity      = "/dzeroth.communities.v1.CommunityService/GetCommunity"
	rpcHideCommunityPost = "/dzeroth.communities.v1.CommunityService/HideCommunityPost"
)

// w536 is a communities chain with the community and graph clients, and the reports, replies and the community buckets lifted.
type w536 struct {
	*cmChain
	cm communitiesv1connect.CommunityServiceClient
	gr graphv1connect.GraphServiceClient
}

func w536Config(extra func(*config.Config)) func(*config.Config) {
	return func(c *config.Config) {
		communitiesOn(c)
		c.RateLimit.CommunitiesWritePerUserPerMinute = 1_000_000
		c.RateLimit.CommunitiesReadPerUserPerMinute = 1_000_000
		c.RateLimit.ReportPerMinute = 1_000_000
		c.FeatureReports = flags.Spec{Name: "reports", Mode: flags.On}
		c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
		if extra != nil {
			extra(c)
		}
	}
}

func newW536(t *testing.T, extra func(*config.Config)) *w536 {
	t.Helper()
	e := &cmChain{newChain(t, w536Config(extra))}
	return &w536{
		cmChain: e,
		cm:      communitiesv1connect.NewCommunityServiceClient(http.DefaultClient, e.url),
		gr:      graphv1connect.NewGraphServiceClient(http.DefaultClient, e.url),
	}
}

// w536Seed describes one community document and its member docs.
type w536Seed struct {
	owner, name, desc string
	status            string // "" = ACTIVE
	mods              []string
	members           []string // JOINED, owner and moderators included automatically
	banned            []string
	rules             []map[string]any
}

func (s w536Seed) write(t *testing.T, fs *firestore.Client) string {
	t.Helper()
	ctx := context.Background()
	cid := seedCommunity(t, fs, s.owner, "", cmpOr(s.status, "ACTIVE"))
	upd := []firestore.Update{
		{Path: "moderatorIds", Value: append([]string{}, s.mods...)},
		{Path: "name", Value: cmpOr(s.name, "Seeded")},
		{Path: "description", Value: s.desc},
	}
	if s.rules != nil {
		upd = append(upd, firestore.Update{Path: "rules", Value: s.rules})
	}
	if _, err := fs.Collection("communities").Doc(cid).Update(ctx, upd); err != nil {
		t.Fatalf("seed community: %v", err)
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	joined := slices.Concat([]string{s.owner}, s.mods, s.members)
	for _, u := range joined {
		if u == "" {
			continue
		}
		if _, err := fs.Collection("communities").Doc(cid).Collection("communityMembers").Doc(u).Set(ctx, map[string]any{"uid": u, "state": "JOINED", "joinedAt": now}); err != nil {
			t.Fatalf("seed member: %v", err)
		}
		own := []string{}
		if u == s.owner {
			own = []string{cid}
		}
		if _, err := fs.Collection("communityMemberships").Doc(u).Set(ctx, map[string]any{"joined": []string{cid}, "owned": own, "banned": []string{}, "modlogged": []string{}, "updatedAt": now}, firestore.MergeAll); err != nil {
			t.Fatalf("seed memberships: %v", err)
		}
	}
	for _, u := range s.banned {
		if _, err := fs.Collection("communities").Doc(cid).Collection("communityMembers").Doc(u).Set(ctx, map[string]any{"uid": u, "state": "BANNED", "bannedAt": now}); err != nil {
			t.Fatalf("seed banned: %v", err)
		}
	}
	return cid
}

func cmpOr(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

// feedErr runs GetCommunityTimeline and returns the error code with the whole-request budget of its request line.
func (e *w536) feedBudget(t *testing.T, u ltUser, cid string, size int32, since, page string) (*timelinev1.GetCommunityTimelineResponse, budgettest.Budget, error) {
	t.Helper()
	resp, err := e.feed(u, cid, size, since, page)
	c := e.lineBudget(t, rpcGetCommunityTimeline)
	return resp, budgettest.Budget{Reads: c.Reads(), Writes: c.Writes()}, err
}

// ---------------------------------------------------------------------------------------------------------------------------------
// W5-29 acceptance 3 end to end: a takedown of a community post, then the next GetCommunityTimeline refresh lists it in removed_ids.
// ---------------------------------------------------------------------------------------------------------------------------------

func TestW536_TakedownThenRefreshListsRemovedIDs(t *testing.T) {
	ctx := context.Background()
	a := newW536(t, nil)
	owner, viewer, author := a.user(t), a.user(t), a.user(t)
	cid := w536Seed{owner: owner.uid, members: []string{viewer.uid, author.uid}}.write(t, a.fs)
	ids := seedCommunityPosts(t, a.fs, cid, author.uid, 5)

	first, err := a.feed(viewer, cid, 20, "", "")
	if err != nil || !slices.Equal(feedIDs(first), ids) || first.GetSinceToken() == "" {
		t.Fatalf("open: ids=%v since=%q err=%v", feedIDs(first), first.GetSinceToken(), err)
	}
	victim := ids[2]

	// What `opsctl takedown-post` does: Takedown reads the post (and returns its community), Append lists it in recentRemovals.
	now := time.Now().UTC()
	res, err := posts.NewFirestoreRepo(a.fs).Takedown(ctx, victim, now)
	if err != nil || res.CommunityID != cid || res.After != posts.ModerationTakenDown {
		t.Fatalf("Takedown = %+v, %v", res, err)
	}
	crepo := communities.NewFirestoreRepo(a.fs, nil)
	if n, err := crepo.Append(ctx, res.CommunityID, []string{victim}, now, 0); err != nil || n != 1 {
		t.Fatalf("Append = %d, %v", n, err)
	}

	// The next refresh, on an instance that has never read the community (another Cloud Run instance, or this one after its 60 s cache):
	// the token of the first instance is accepted, nothing new, and the taken-down id is listed. Whole request: interceptor, community,
	// member doc, one empty query.
	b := newW536(t, nil)
	r, err := b.feed(viewer, cid, 20, first.GetSinceToken(), "")
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if !slices.Equal(r.GetRemovedIds(), []string{victim}) || len(r.GetPosts()) != 0 {
		t.Fatalf("refresh: removed_ids=%v posts=%v, want [%s] and no posts", r.GetRemovedIds(), feedIDs(r), victim)
	}
	budgettest.Assert(t, "refresh after a takedown", b.lineBudget(t, rpcGetCommunityTimeline), budgettest.Budget{Reads: 4})

	// A cold open drops the post and carries no removed_ids; so does a refresh from the token after the removal was recorded.
	c := newW536(t, nil)
	cold, err := c.feed(viewer, cid, 20, "", "")
	if err != nil || slices.Contains(feedIDs(cold), victim) || len(feedIDs(cold)) != 4 || len(cold.GetRemovedIds()) != 0 {
		t.Fatalf("cold open: ids=%v removed=%v err=%v", feedIDs(cold), cold.GetRemovedIds(), err)
	}
	// A second takedown of the same post lists nothing new: the removal log is idempotent.
	if n, err := crepo.Append(ctx, cid, []string{victim}, now.Add(time.Second), 0); err != nil || n != 0 {
		t.Fatalf("repeat Append = %d, %v, want 0 (already listed)", n, err)
	}
}

// A community moderator's HideCommunityPost over the wire (W5-28): the post stays on the author's profile and in GetPost without its label,
// a refresh on another instance lists it in removed_ids, a RESTORE brings the label back on a cold open, and the budget is the documented
// one (5 reads cold, 3 writes, +1 on the moderator's first action).
func TestW536_ModeratorHideLeavesTheProfileRowUnlabelledAndListsRemovedIDs(t *testing.T) {
	ctx := context.Background()
	a := newW536(t, nil)
	owner, mod, viewer, author := a.user(t), a.user(t), a.user(t), a.user(t)
	cid := w536Seed{owner: owner.uid, mods: []string{mod.uid}, members: []string{viewer.uid, author.uid}}.write(t, a.fs)
	ids := seedCommunityPosts(t, a.fs, cid, author.uid, 3)
	first, err := a.feed(viewer, cid, 20, "", "")
	if err != nil || len(feedIDs(first)) != 3 {
		t.Fatalf("open: %v %v", feedIDs(first), err)
	}
	for _, v := range first.GetPosts() {
		if v.GetPost().GetCommunity().GetId() != cid {
			t.Fatalf("label missing before the hide: %v", v.GetPost())
		}
	}

	// A member may not hide.
	_, err = a.cm.HideCommunityPost(ctx, authed(viewer.token, &communitiesv1.HideCommunityPostRequest{IdempotencyKey: contractKey("hide"), CommunityId: cid, PostId: ids[1]}))
	if d := wireError(t, err, connect.CodePermissionDenied); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FORBIDDEN || d.GetMetadata()["reason"] != "not_moderator" {
		t.Fatalf("member hide: %v", d)
	}

	hide := newW536(t, nil) // a cold instance: the documented cold budget
	if _, err := hide.cm.HideCommunityPost(ctx, authed(mod.token, &communitiesv1.HideCommunityPostRequest{IdempotencyKey: contractKey("hide"), CommunityId: cid, PostId: ids[1]})); err != nil {
		t.Fatalf("hide: %v", err)
	}
	budgettest.Assert(t, "HideCommunityPost cold, first action of the moderator", hide.lineBudget(t, rpcHideCommunityPost), budgettest.Budget{Reads: 5, Writes: 4})

	// The post stays on the author's profile, without the label (the real document: communityHidden set, communityId deleted).
	other := newW536(t, nil)
	prof, err := other.timeline.GetUserTimeline(ctx, authed(viewer.token, &timelinev1.GetUserTimelineRequest{UserId: author.uid}))
	if err != nil {
		t.Fatal(err)
	}
	var onProfile bool
	for _, v := range prof.Msg.GetPosts() {
		if v.GetPost().GetPostId() == ids[1] {
			onProfile = true
			if v.GetPost().GetCommunity() != nil {
				t.Errorf("the hidden post still carries a label on the profile: %v", v.GetPost().GetCommunity())
			}
		} else if v.GetPost().GetCommunity().GetId() != cid {
			t.Errorf("a visible post lost its label: %v", v.GetPost().GetPostId())
		}
	}
	if !onProfile {
		t.Fatalf("the hidden post left the author's profile: %d rows", len(prof.Msg.GetPosts()))
	}
	got, err := other.posts.GetPost(ctx, authed(viewer.token, &postsv1.GetPostRequest{PostId: ids[1]}))
	if err != nil || got.Msg.GetPost().GetPost().GetCommunity() != nil {
		t.Fatalf("GetPost of the hidden post: community=%v err=%v", got.Msg.GetPost().GetPost().GetCommunity(), err)
	}

	// The next community refresh lists it; a cold open drops it.
	r, err := other.feed(viewer, cid, 20, first.GetSinceToken(), "")
	if err != nil || !slices.Equal(r.GetRemovedIds(), []string{ids[1]}) {
		t.Fatalf("refresh: removed_ids=%v err=%v", r.GetRemovedIds(), err)
	}
	cold, err := newW536(t, nil).feed(viewer, cid, 20, "", "")
	if err != nil || !slices.Equal(feedIDs(cold), []string{ids[0], ids[2]}) {
		t.Fatalf("cold open after the hide: %v %v", feedIDs(cold), err)
	}

	// Restore: the label returns on a cold open (the post is listed again; a refresh from an older token cannot add a row back).
	restore := newW536(t, nil)
	if _, err := restore.cm.RestoreCommunityPost(ctx, authed(mod.token, &communitiesv1.RestoreCommunityPostRequest{IdempotencyKey: contractKey("restore"), CommunityId: cid, PostId: ids[1]})); err != nil {
		t.Fatalf("restore: %v", err)
	}
	back, err := newW536(t, nil).feed(viewer, cid, 20, "", "")
	if err != nil || !slices.Equal(feedIDs(back), ids) {
		t.Fatalf("cold open after the restore: %v %v", feedIDs(back), err)
	}
	for _, v := range back.GetPosts() {
		if v.GetPost().GetCommunity().GetId() != cid {
			t.Errorf("label missing after the restore: %v", v.GetPost().GetPostId())
		}
	}
}

// ---------------------------------------------------------------------------------------------------------------------------------
// SUSPENDED in the middle of a pagination (W5-29 acceptance 2, ADR-0031 N3).
// ---------------------------------------------------------------------------------------------------------------------------------

func TestW536_SuspendedMidPagination(t *testing.T) {
	ctx := context.Background()
	a := newW536(t, nil)
	owner, viewer, outsider := a.user(t), a.user(t), a.user(t)
	cid := w536Seed{owner: owner.uid, members: []string{viewer.uid}}.write(t, a.fs)
	seedCommunityPosts(t, a.fs, cid, owner.uid, 45)

	p1, err := a.feed(viewer, cid, 20, "", "")
	if err != nil || len(p1.GetPosts()) != 20 || p1.GetNextPageToken() == "" || p1.GetSinceToken() == "" {
		t.Fatalf("page 1: n=%d next=%q since=%q err=%v", len(p1.GetPosts()), p1.GetNextPageToken(), p1.GetSinceToken(), err)
	}

	// The platform suspends the community (opsctl community suspend).
	crepo := communities.NewFirestoreRepo(a.fs, nil)
	if changed, _, after, err := crepo.SetSuspended(ctx, cid, true, time.Now().UTC()); err != nil || !changed || after != communities.StatusSuspended {
		t.Fatalf("SetSuspended = %v %v %v", changed, after, err)
	}

	// Another instance, each of the callers on a fresh Build: the page token, the since token, a cold open (owner and outsider), the header.
	// All answer the one NOT_FOUND of a missing id, within the interceptor's read plus the community's (no member doc, no query).
	missing := fmt.Sprintf("%019d", 7_000_000_000_000_001)
	var want string
	check := func(name string, who ltUser, id, since, page string) {
		t.Helper()
		b := newW536(t, nil)
		_, bud, err := b.feedBudget(t, who, id, 20, since, page)
		d := wireError(t, err, connect.CodeNotFound)
		got := fmt.Sprintf("%s|%s", marshalDet(t, d), err.Error())
		if want == "" {
			want = got
		} else if got != want {
			t.Errorf("%s answers %q, want the bytes of a missing id %q", name, got, want)
		}
		if bud.Reads > 2 || bud.Writes != 0 {
			t.Errorf("%s: reads=%d writes=%d, want at most 2 and 0", name, bud.Reads, bud.Writes)
		}
	}
	check("missing id", viewer, missing, "", "")
	check("page 2 of the open pagination", viewer, cid, "", p1.GetNextPageToken())
	check("since refresh", viewer, cid, p1.GetSinceToken(), "")
	check("cold open, owner", owner, cid, "", "")
	check("cold open, outsider", outsider, cid, "", "")

	b := newW536(t, nil)
	// GetCommunity is the one RPC that still shows it, to its owner alone, with status SUSPENDED (ADR-0031 N3); everyone else gets NOT_FOUND.
	got, err := b.cm.GetCommunity(ctx, authed(owner.token, &communitiesv1.GetCommunityRequest{CommunityId: cid}))
	if err != nil || got.Msg.GetCommunity().GetStatus() != communitiesv1.CommunityStatus_COMMUNITY_STATUS_SUSPENDED {
		t.Fatalf("owner's GetCommunity: %v %v, want the community with status SUSPENDED", got, err)
	}
	for name, who := range map[string]ltUser{"member": viewer, "outsider": outsider} {
		_, err = newW536(t, nil).cm.GetCommunity(ctx, authed(who.token, &communitiesv1.GetCommunityRequest{CommunityId: cid}))
		if connect.CodeOf(err) != connect.CodeNotFound {
			t.Errorf("%s GetCommunity of a suspended community: %v, want NOT_FOUND", name, err)
		}
	}

	// A member's post into it is refused as NOT_FOUND and writes nothing.
	_, err = b.posts.CreatePost(ctx, authed(viewer.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("cp"), Text: "into a suspended community", CommunityId: cid}))
	wireError(t, err, connect.CodeNotFound)
	if n := countPostsInCommunity(t, b.fs, cid); n != 45 {
		t.Errorf("community posts = %d, want the 45 seeded (a refused post wrote)", n)
	}

	// Restore: the very tokens work again on a cold instance (nothing was invalidated).
	if changed, _, after, err := crepo.SetSuspended(ctx, cid, false, time.Now().UTC()); err != nil || !changed || after != communities.StatusActive {
		t.Fatalf("restore = %v %v %v", changed, after, err)
	}
	c := newW536(t, nil)
	p2, err := c.feed(viewer, cid, 20, "", p1.GetNextPageToken())
	if err != nil || len(p2.GetPosts()) != 20 {
		t.Fatalf("page 2 after the restore: n=%d err=%v", len(p2.GetPosts()), err)
	}
	if _, err := c.feed(viewer, cid, 20, p1.GetSinceToken(), ""); err != nil {
		t.Fatalf("refresh after the restore: %v", err)
	}
}

func countPostsInCommunity(t *testing.T, fs *firestore.Client, cid string) int {
	t.Helper()
	docs, err := fs.Collection("posts").Where("conversationCommunityId", "==", cid).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatalf("count posts: %v", err)
	}
	return len(docs)
}

// ---------------------------------------------------------------------------------------------------------------------------------
// The COMMUNITY report (W5-29 acceptance 1, ADR-0031 D14).
// ---------------------------------------------------------------------------------------------------------------------------------

func TestW536_CommunityReportThroughTheChain(t *testing.T) {
	ctx := context.Background()
	setup := newW536(t, nil)
	owner, mod, r1, r2, member := setup.user(t), setup.user(t), setup.user(t), setup.user(t), setup.user(t)
	rules := []map[string]any{{"title": "Be kind", "text": "No insults."}, {"title": "On topic", "text": ""}}
	cid := w536Seed{owner: owner.uid, mods: []string{mod.uid}, members: []string{member.uid}, name: "Gophers", desc: "People who write Go", rules: rules}.write(t, setup.fs)
	ownerHandle := func() string {
		s, err := setup.fs.Collection("users").Doc(owner.uid).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		h, _ := s.DataAt("handle")
		return fmt.Sprint(h)
	}()

	report := func(e *w536, who ltUser, target string) (*moderationv1.ReportContentResponse, error) {
		r, err := e.moderation.ReportContent(ctx, authed(who.token, &moderationv1.ReportContentRequest{
			IdempotencyKey: contractKey("crep"), TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_COMMUNITY, TargetId: target,
			Reason: moderationv1.ReportReason_REPORT_REASON_SPAM, Note: "looks wrong",
		}))
		if err != nil {
			return nil, err
		}
		return r.Msg, nil
	}

	// Cold: interceptor 1, community 1, owner's users 1, report doc 1, quotas 1 = 5 reads, 2 writes.
	e := newW536(t, nil)
	res, err := report(e, r1, cid)
	if err != nil || res.GetAlreadyReported() {
		t.Fatalf("report: %v %v", res, err)
	}
	budgettest.Assert(t, "ReportContent COMMUNITY cold", e.lineBudget(t, rpcReportContent), budgettest.Budget{Reads: 5, Writes: 2})
	if res.GetReportId() != moderation.ReportID(r1.uid, moderation.TargetCommunity, cid) {
		t.Errorf("report id = %q", res.GetReportId())
	}

	snap, err := e.fs.Collection("reports").Doc(res.GetReportId()).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	doc := snap.Data()
	ev, _ := doc["evidence"].(map[string]any)
	if doc["targetType"] != "COMMUNITY" || doc["targetId"] != cid || doc["targetOwnerId"] != owner.uid || doc["reporterId"] != r1.uid ||
		doc["status"] != "OPEN" || doc["reason"] != "SPAM" || doc["note"] != "looks wrong" {
		t.Errorf("report = %v", doc)
	}
	if ev["authorHandle"] != ownerHandle || ev["communityName"] != "Gophers" || ev["communityDescription"] != "People who write Go" || ev["postCreatedAt"] == nil {
		t.Errorf("evidence = %v, want the owner's handle %q, the name, the description and the creation time", ev, ownerHandle)
	}
	gotRules, _ := ev["communityRules"].([]any)
	if len(gotRules) != 2 || fmt.Sprint(gotRules[0]) != fmt.Sprint(map[string]any{"title": "Be kind", "text": "No insults."}) {
		t.Errorf("rules = %v", gotRules)
	}
	// No member id and no moderator id is copied into the evidence.
	if raw := fmt.Sprint(ev); strings.Contains(raw, mod.uid) || strings.Contains(raw, member.uid) || strings.Contains(raw, owner.uid) {
		t.Errorf("evidence names an account id: %v", ev)
	}
	if kids, err := e.fs.Collection("reports").Doc(res.GetReportId()).Collection("evidence").Documents(ctx).GetAll(); err != nil || len(kids) != 0 {
		t.Errorf("community evidence children = %d (%v), want none", len(kids), err)
	}

	// Warm: another reporter on the same instance after their own GetMe (so the interceptor read is warm): report doc and quotas only.
	if _, err := e.identity.GetMe(ctx, authed(r2.token, &identityv1.GetMeRequest{})); err != nil {
		t.Fatal(err)
	}
	if _, err := report(e, r2, cid); err != nil {
		t.Fatalf("second reporter: %v", err)
	}
	budgettest.Assert(t, "ReportContent COMMUNITY warm", e.lineBudget(t, rpcReportContent), budgettest.Budget{Reads: 2, Writes: 2})

	// A repeat is already_reported with no write; the owner's own community is VALIDATION target_id; a missing id and a suspended one answer
	// the same NOT_FOUND.
	if again, err := report(e, r1, cid); err != nil || !again.GetAlreadyReported() || again.GetReportId() != res.GetReportId() {
		t.Errorf("repeat = %v %v", again, err)
	}
	_, err = report(e, owner, cid)
	if d := wireError(t, err, connect.CodeInvalidArgument); d.GetMetadata()["field"] != "target_id" {
		t.Errorf("own community: %v", d)
	}
	susp := w536Seed{owner: owner.uid, status: "SUSPENDED"}.write(t, e.fs)
	missing := fmt.Sprintf("%019d", 7_000_000_000_000_002)
	var want string
	for name, id := range map[string]string{"suspended": susp, "missing": missing} {
		_, err := report(newW536(t, nil), r1, id)
		d := wireError(t, err, connect.CodeNotFound)
		got := fmt.Sprintf("%s|%s", marshalDet(t, d), err.Error())
		if want == "" {
			want = got
		} else if got != want {
			t.Errorf("%s answers %q, want %q", name, got, want)
		}
	}

	// The report line names the target type and never the community.
	for _, l := range e.logs.requestLines(rpcReportContent) {
		if l["report_target"] != "COMMUNITY" {
			t.Errorf("report line report_target = %v", l["report_target"])
		}
	}
	e.logs.mu.Lock()
	text := e.logs.buf.String()
	e.logs.mu.Unlock()
	for _, secret := range []string{cid, "Gophers", "People who write Go", "looks wrong", owner.uid, r1.uid} {
		if strings.Contains(text, secret) {
			t.Errorf("the API log contains %q", secret)
		}
	}
}

// ---------------------------------------------------------------------------------------------------------------------------------
// Flag modes and the creators allowlist on the wire (W5-23 acceptance 1, W5-22).
// ---------------------------------------------------------------------------------------------------------------------------------

func TestW536_FlagModesAndTheCreatorsList(t *testing.T) {
	ctx := context.Background()

	type who int
	const (
		creatorCaller who = iota
		plainCaller
	)
	// cfg builds the config from the two uids of the case: creators = [creator]; the allowlist names the given callers.
	mode := func(m flags.Mode, percent int, allow ...who) func(creator, plain string) func(*config.Config) {
		return func(creator, plain string) func(*config.Config) {
			return func(c *config.Config) {
				c.Communities.Creators = []string{creator}
				set := map[string]struct{}{}
				for _, w := range allow {
					set[map[who]string{creatorCaller: creator, plainCaller: plain}[w]] = struct{}{}
				}
				c.FeatureCommunities = flags.Spec{Name: "communities", Mode: m, Allowlist: set, Percent: percent}
			}
		}
	}
	tests := []struct {
		name     string
		cfg      func(creator, plain string) func(*config.Config)
		caller   who
		disabled bool   // FEATURE_DISABLED feature=communities
		reason   string // else FORBIDDEN reason=
		listed   bool   // GetMe enabled_features carries communities
	}{
		{"off, creator", mode(flags.Off, 0), creatorCaller, true, "", false},
		{"allowlist with the creator, creator", mode(flags.Allowlist, 0, creatorCaller), creatorCaller, false, "", true},
		{"allowlist with the creator, other caller", mode(flags.Allowlist, 0, creatorCaller), plainCaller, true, "", false},
		{"allowlist without the creator, creator", mode(flags.Allowlist, 0, plainCaller), creatorCaller, true, "", false},
		{"percent 0, creator", mode(flags.Percent, 0), creatorCaller, true, "", false},
		{"percent 100, creator", mode(flags.Percent, 100), creatorCaller, false, "", true},
		{"percent 100, not a creator", mode(flags.Percent, 100), plainCaller, false, "not_creator", true},
		{"on, creator", mode(flags.On, 0), creatorCaller, false, "", true},
		{"on, not a creator", mode(flags.On, 0), plainCaller, false, "not_creator", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Profiles are created through another instance, so the instance under test reads the caller's profile cold (the interceptor's
			// one read) and a count of 1 means the service itself read nothing.
			setup := newW536(t, nil)
			creator, plain := setup.user(t), setup.user(t)
			e := newW536(t, tt.cfg(creator.uid, plain.uid))
			caller := map[who]ltUser{creatorCaller: creator, plainCaller: plain}[tt.caller]

			me, err := e.identity.GetMe(ctx, authed(caller.token, &identityv1.GetMeRequest{}))
			if err != nil {
				t.Fatal(err)
			}
			if has := slices.Contains(me.Msg.GetEnabledFeatures(), "communities"); has != tt.listed {
				t.Errorf("GetMe enabled_features has communities = %v, want %v (the client hides gated UI on this)", has, tt.listed)
			}

			// The read RPCs share the gate. A missing id keeps the call cheap: through the gate it is the one NOT_FOUND.
			missing := fmt.Sprintf("%019d", 7_000_000_000_000_003)
			_, getErr := e.cm.GetCommunity(ctx, authed(caller.token, &communitiesv1.GetCommunityRequest{CommunityId: missing}))
			_, feedErr := e.feed(caller, missing, 20, "", "")
			for name, rerr := range map[string]error{"GetCommunity": getErr, "GetCommunityTimeline": feedErr} {
				if tt.disabled {
					d := wireError(t, rerr, connect.CodeFailedPrecondition)
					if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || d.GetMetadata()["feature"] != "communities" {
						t.Errorf("%s: %v", name, d)
					}
				} else {
					wireError(t, rerr, connect.CodeNotFound) // the gate let it through; the id does not exist
				}
			}
			if bud := e.lineBudget(t, rpcGetCommunityTimeline); tt.disabled && (bud.Reads() > 1 || bud.Writes() != 0) {
				t.Errorf("a disabled call cost reads=%d writes=%d, want at most the interceptor's 1 and 0", bud.Reads(), bud.Writes())
			}

			_, cerr := e.cm.CreateCommunity(ctx, authed(caller.token, &communitiesv1.CreateCommunityRequest{IdempotencyKey: contractKey("cc"), Name: "Flag mode", Description: "d"}))
			bud := e.lineBudget(t, rpcCreateCommunity)
			switch {
			case tt.disabled:
				d := wireError(t, cerr, connect.CodeFailedPrecondition)
				if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || d.GetMetadata()["feature"] != "communities" {
					t.Errorf("CreateCommunity disabled: %v", d)
				}
				if bud.Reads() > 1 || bud.Writes() != 0 {
					t.Errorf("CreateCommunity disabled: reads=%d writes=%d", bud.Reads(), bud.Writes())
				}
			case tt.reason != "":
				d := wireError(t, cerr, connect.CodePermissionDenied)
				if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FORBIDDEN || d.GetMetadata()["reason"] != tt.reason {
					t.Errorf("CreateCommunity: %v, want FORBIDDEN reason=%s", d, tt.reason)
				}
				// The creators check is first (W5-23): the service reads nothing, so the whole request is the interceptor's one read.
				if bud.Reads() > 1 || bud.Writes() != 0 {
					t.Errorf("CreateCommunity not_creator: reads=%d writes=%d, want at most 1 (the interceptor) and 0", bud.Reads(), bud.Writes())
				}
			default:
				if cerr != nil {
					t.Fatalf("CreateCommunity: %v", cerr)
				}
				if bud.Writes() == 0 {
					t.Errorf("CreateCommunity wrote nothing")
				}
			}
		})
	}
}

// ---------------------------------------------------------------------------------------------------------------------------------
// F14 on the wire: the moderator's ALLOWED hint on a row whose author blocks them, while the reply itself is NOT_FOUND.
// ---------------------------------------------------------------------------------------------------------------------------------

func TestW536_F14ReplyHintOnTheWire(t *testing.T) {
	ctx := context.Background()
	a := newW536(t, nil)
	owner, mod, raider, member := a.user(t), a.user(t), a.user(t), a.user(t)
	cid := w536Seed{owner: owner.uid, mods: []string{mod.uid}, members: []string{raider.uid, member.uid}}.write(t, a.fs)
	ids := seedCommunityPosts(t, a.fs, cid, raider.uid, 1)

	if _, err := a.gr.Block(ctx, authed(raider.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("blk"), UserId: mod.uid})); err != nil {
		t.Fatalf("block: %v", err)
	}
	b := newW536(t, nil)
	m, err := b.feed(mod, cid, 20, "", "")
	if err != nil || !slices.Equal(feedIDs(m), ids) {
		t.Fatalf("moderator's feed = %v, %v; want the raider's row kept (F14)", feedIDs(m), err)
	}
	if got := m.GetPosts()[0].GetViewerReplyPermission(); got != postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED {
		t.Errorf("moderator's hint = %v, want ALLOWED (NOT_ALLOWED would be a block oracle)", got)
	}
	// The reply itself: NOT_FOUND, the same answer as a missing post (no oracle either way).
	_, err = b.posts.CreatePost(ctx, authed(mod.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("rep"), Text: "reply from the blocked moderator", ReplyToPostId: ids[0]}))
	wireError(t, err, connect.CodeNotFound)

	// A plain member the raider does not block: the row is there, the hint is ALLOWED and the reply goes through (the hint is truthful).
	f, err := b.feed(member, cid, 20, "", "")
	if err != nil || !slices.Equal(feedIDs(f), ids) || f.GetPosts()[0].GetViewerReplyPermission() != postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED {
		t.Fatalf("member's feed: %v %v", feedIDs(f), err)
	}
	if _, err := b.posts.CreatePost(ctx, authed(member.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("rep"), Text: "reply from a member", ReplyToPostId: ids[0]})); err != nil {
		t.Errorf("member's reply: %v", err)
	}
	// Members-only replies on the wire (F8): a non-member sees NOT_ALLOWED and the reply is FORBIDDEN not_member with nothing written.
	outsider := a.user(t)
	o, err := b.feed(outsider, cid, 20, "", "")
	if err != nil || len(o.GetPosts()) != 1 || o.GetPosts()[0].GetViewerReplyPermission() != postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED {
		t.Fatalf("outsider's feed: %v %v", feedIDs(o), err)
	}
	before := countReplies(t, b.fs, ids[0])
	_, err = b.posts.CreatePost(ctx, authed(outsider.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("rep"), Text: "reply from an outsider", ReplyToPostId: ids[0]}))
	if d := wireError(t, err, connect.CodePermissionDenied); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FORBIDDEN || d.GetMetadata()["reason"] != "not_member" {
		t.Errorf("outsider's reply: %v", d)
	}
	if after := countReplies(t, b.fs, ids[0]); after != before {
		t.Errorf("replies %d -> %d, a refused reply wrote", before, after)
	}
	// A member the raider blocks does not see the row at all.
	if _, err := a.gr.Block(ctx, authed(raider.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("blk"), UserId: member.uid})); err != nil {
		t.Fatal(err)
	}
	g, err := newW536(t, nil).feed(member, cid, 20, "", "")
	if err != nil || len(g.GetPosts()) != 0 {
		t.Fatalf("a blocked member sees %v (%v)", feedIDs(g), err)
	}
}

// ---------------------------------------------------------------------------------------------------------------------------------
// recentRemovals overflow and the token reset on the wire (ADR-0031 A3).
// ---------------------------------------------------------------------------------------------------------------------------------

func TestW536_RemovalsOverflowResetsTheSinceToken(t *testing.T) {
	ctx := context.Background()
	a := newW536(t, nil)
	owner, viewer := a.user(t), a.user(t)
	cid := w536Seed{owner: owner.uid, members: []string{viewer.uid}}.write(t, a.fs)
	seedCommunityPosts(t, a.fs, cid, owner.uid, 3)
	first, err := a.feed(viewer, cid, 20, "", "")
	if err != nil || first.GetSinceToken() == "" {
		t.Fatalf("open: %v %v", err, first)
	}

	// 50 removals fit: the array is full, nothing was dropped, the refresh lists all 50 (newest first, at most 50).
	crepo := communities.NewFirestoreRepo(a.fs, nil)
	now := time.Now().UTC()
	var ids []string
	for i := range 51 {
		ids = append(ids, fmt.Sprintf("%019d", 6_000_000_000_000_000+i))
	}
	if n, err := crepo.Append(ctx, cid, ids[:50], now, 0); err != nil || n != 50 {
		t.Fatalf("Append 50 = %d, %v", n, err)
	}
	b := newW536(t, nil)
	r, err := b.feed(viewer, cid, 20, first.GetSinceToken(), "")
	if err != nil || len(r.GetRemovedIds()) != 50 {
		t.Fatalf("full array: removed=%d err=%v, want all 50 and no reset", len(r.GetRemovedIds()), err)
	}

	// The 51st drops the oldest: removalsTruncatedAt is set, the old token is rejected like an expired one before any post is read (2 reads:
	// the interceptor and the community), and a cold open still works.
	if n, err := crepo.Append(ctx, cid, ids[50:], now.Add(time.Second), 0); err != nil || n != 1 {
		t.Fatalf("Append 51st = %d, %v", n, err)
	}
	c := newW536(t, nil)
	_, bud, err := c.feedBudget(t, viewer, cid, 20, first.GetSinceToken(), "")
	d := wireError(t, err, connect.CodeInvalidArgument)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION || d.GetMetadata()["field"] != "since_token" {
		t.Errorf("reset: %v", d)
	}
	if bud.Reads != 2 || bud.Writes != 0 {
		t.Errorf("reset cost reads=%d writes=%d, want 2 and 0", bud.Reads, bud.Writes)
	}
	cold, err := newW536(t, nil).feed(viewer, cid, 20, "", "")
	if err != nil || len(cold.GetPosts()) != 3 {
		t.Fatalf("cold open after the overflow: %v %v", feedIDs(cold), err)
	}

	// By design (posts.RemovalLag, the Home rule): a token issued right after the truncation is still inside the lag window, so it is
	// rejected too until RemovalLag has passed. Moving the truncation 5 minutes into the past stands for that time passing.
	_, err = newW536(t, nil).feed(viewer, cid, 20, cold.GetSinceToken(), "")
	wireError(t, err, connect.CodeInvalidArgument)
	if _, err := a.fs.Collection("communities").Doc(cid).Update(ctx, []firestore.Update{{Path: "removalsTruncatedAt", Value: now.Add(-5 * time.Minute)}}); err != nil {
		t.Fatal(err)
	}
	if _, err := newW536(t, nil).feed(viewer, cid, 20, cold.GetSinceToken(), ""); err != nil {
		t.Errorf("a token issued after the lag window is still rejected: %v", err)
	}
}

// countReplies is the number of reply documents to post id (a direct query: the test's own view of "nothing was written").
func countReplies(t *testing.T, fs *firestore.Client, id string) int {
	t.Helper()
	docs, err := fs.Collection("posts").Where("replyToId", "==", id).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatalf("count replies: %v", err)
	}
	return len(docs)
}

// A hide and a restore through the RPC take effect at once ON THE SAME INSTANCE, although it holds a shared feed entry that still lists the
// post and caches the community document for 60 s: the write fills the community cache from the written data and drops the instance's
// feed entry (ForgetCommunityFeed). The bound for OTHER instances is the 60 s of the community cache (not asserted here, no sleeping).
func TestW536_HideAndRestoreAreImmediateOnTheSameInstance(t *testing.T) {
	ctx := context.Background()
	a := newW536(t, nil)
	owner, mod, viewer := a.user(t), a.user(t), a.user(t) // the owner acts: F16 (W5-53) bars a moderator from the owner's posts
	cid := w536Seed{owner: owner.uid, mods: []string{mod.uid}, members: []string{viewer.uid}}.write(t, a.fs)
	ids := seedCommunityPosts(t, a.fs, cid, owner.uid, 4)

	first, err := a.feed(viewer, cid, 20, "", "") // fills this instance's entry and caches the community
	if err != nil || !slices.Equal(feedIDs(first), ids) {
		t.Fatalf("open: %v %v", feedIDs(first), err)
	}
	if _, err := a.cm.HideCommunityPost(ctx, authed(owner.token, &communitiesv1.HideCommunityPostRequest{IdempotencyKey: contractKey("hide"), CommunityId: cid, PostId: ids[1]})); err != nil {
		t.Fatalf("hide: %v", err)
	}
	cold, err := a.feed(viewer, cid, 20, "", "")
	if err != nil || slices.Contains(feedIDs(cold), ids[1]) || len(feedIDs(cold)) != 3 {
		t.Fatalf("cold open right after the hide on the same instance: %v %v (the cached entry still lists the post)", feedIDs(cold), err)
	}
	r, err := a.feed(viewer, cid, 20, first.GetSinceToken(), "")
	if err != nil || !slices.Equal(r.GetRemovedIds(), []string{ids[1]}) {
		t.Fatalf("refresh right after the hide: removed_ids=%v err=%v", r.GetRemovedIds(), err)
	}
	if _, err := a.cm.RestoreCommunityPost(ctx, authed(owner.token, &communitiesv1.RestoreCommunityPostRequest{IdempotencyKey: contractKey("restore"), CommunityId: cid, PostId: ids[1]})); err != nil {
		t.Fatalf("restore: %v", err)
	}
	back, err := a.feed(viewer, cid, 20, "", "")
	if err != nil || !slices.Equal(feedIDs(back), ids) {
		t.Fatalf("cold open right after the restore: %v %v", feedIDs(back), err)
	}
}

// D-1 repro (test-report-communities-part-b, section 4): timeline.Server.ForgetCommunityFeed is never called by production code, so a RESTORE on
// the instance that served it does not bring back a post that was hidden BEFORE that instance filled its entry: the row stays out until the
// entry expires (<= 5 min). Fixed by W5-57 (communities.Deps.OnPostRestored = timeline.Server.ForgetCommunityFeed); this test guards the wiring.
func TestW536_RestoreOnTheSameInstanceReturnsAHiddenPostAtOnce(t *testing.T) {
	ctx := context.Background()
	a := newW536(t, nil)
	owner, mod, viewer := a.user(t), a.user(t), a.user(t) // the owner acts: F16 (W5-53) bars a moderator from the owner's posts
	cid := w536Seed{owner: owner.uid, mods: []string{mod.uid}, members: []string{viewer.uid}}.write(t, a.fs)
	ids := seedCommunityPosts(t, a.fs, cid, owner.uid, 3)

	if _, err := a.cm.HideCommunityPost(ctx, authed(owner.token, &communitiesv1.HideCommunityPostRequest{IdempotencyKey: contractKey("hide-d1"), CommunityId: cid, PostId: ids[1]})); err != nil {
		t.Fatalf("hide: %v", err)
	}
	filled, err := a.feed(viewer, cid, 20, "", "") // this instance fills its entry without the hidden post
	if err != nil || len(feedIDs(filled)) != 2 {
		t.Fatalf("open after the hide: %v %v", feedIDs(filled), err)
	}
	if _, err := a.cm.RestoreCommunityPost(ctx, authed(owner.token, &communitiesv1.RestoreCommunityPostRequest{IdempotencyKey: contractKey("restore-d1"), CommunityId: cid, PostId: ids[1]})); err != nil {
		t.Fatalf("restore: %v", err)
	}
	back, err := a.feed(viewer, cid, 20, "", "")
	if err != nil || !slices.Equal(feedIDs(back), ids) {
		t.Fatalf("cold open right after the restore: %v %v, want all 3 rows", feedIDs(back), err)
	}
}
