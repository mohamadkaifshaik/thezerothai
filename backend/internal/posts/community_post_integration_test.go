//go:build integration

package posts

import (
	"context"
	"errors"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

const commCID = "0000000000000000801"

// newCommunityInstance is a createInstance with the real communities gate wired the way apiserver wires it (a separate communities
// service, hence a separate community and member cache, per instance). capPerDay is COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY.
func newCommunityInstance(t *testing.T, client *firestore.Client, capPerDay int64) (*createInstance, communities.Reader) {
	t.Helper()
	in := newCreateInstance(t, client, time.Nanosecond)
	repo := communities.NewFirestoreRepo(client, idempotency.New(client))
	svc := communities.New(communities.Deps{
		Repo: repo, Directory: in.svc.directory, Graph: in.svc.graph,
		Limits: communities.Limits{MaxOwned: 2, MaxJoined: 50, MaxRules: 10, ModlogMax: 100, CacheEntries: 100, MembersCacheEntries: 100},
	})
	rd := svc.(communities.Reader)
	in.svc.SetCommunityGate(communities.NewPostGate(rd, repo, ratelimit.NewDailyCap(capPerDay)))
	in.svc.communityPostsPerDay, in.svc.newAccountCommunityPostsPerDay = 50, 10
	return in, rd
}

func seedCommunityDoc(t *testing.T, client *firestore.Client, cid, name, status string) {
	t.Helper()
	now := time.Now().UTC()
	_, err := client.Doc("communities/"+cid).Set(context.Background(), map[string]any{
		"name": name, "description": "", "rules": []any{}, "ownerId": "uid-owner", "moderatorIds": []string{}, "memberCount": int64(1),
		"status": status, "visibility": "PUBLIC", "recentRemovals": []any{}, "modlog": []any{}, "modlogSeq": int64(0), "createdAt": now, "updatedAt": now,
	})
	if err != nil {
		t.Fatal(err)
	}
}

func seedMember(t *testing.T, client *firestore.Client, cid, uid, state string) {
	t.Helper()
	now := time.Now().UTC()
	d := map[string]any{"uid": uid, "state": state}
	if state == "JOINED" {
		d["joinedAt"] = now
	} else {
		d["bannedAt"] = now
	}
	if _, err := client.Doc("communities/"+cid+"/communityMembers/"+uid).Set(context.Background(), d); err != nil {
		t.Fatal(err)
	}
}

// postIn creates a post (optionally quoting) into cid as uid. warm pre-loads the author profile outside the measured call.
func (in *createInstance) postIn(t *testing.T, uid, key, cid, quoteOf string) (*Post, *budget.Counter, error) {
	t.Helper()
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
	if !in.cold {
		if _, err := in.svc.directory.GetProfiles(context.Background(), []string{uid}); err != nil {
			t.Errorf("warm profile: %v", err)
		}
	}
	ctx, c := budget.WithCounter(ctx)
	p, err := in.svc.Create(ctx, uid, CreateInput{IdempotencyKey: key, Text: "hello community", CommunityID: cid, CommunitiesEnabled: cid != "",
		QuoteOfPostID: quoteOf, QuotesEnabled: quoteOf != ""})
	return p, c, err
}

func wantRefusal(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, meta, val string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != code || ae.Reason != reason || (meta != "" && ae.Metadata[meta] != val) {
		t.Fatalf("err = %v, want %v / %v %s=%s", err, code, reason, meta, val)
	}
}

// TestCommunityPost_StoresFieldsAndBudgetDelta: the doc fields, one quota Set for both counters, +0 writes, and +2 cold / +1 warm
// reads over a plain CreatePost measured in the same test.
func TestCommunityPost_StoresFieldsAndBudgetDelta(t *testing.T) {
	client := newTestClient(t)
	in, _ := newCommunityInstance(t, client, 100)
	in.signUp(t, "uid-alice", "alice")
	seedCommunityDoc(t, client, commCID, "Go Lang", "ACTIVE")
	seedMember(t, client, commCID, "uid-alice", "JOINED")

	_, plain, err := in.create(t, "uid-alice", key(1), "plain")
	if err != nil {
		t.Fatal(err)
	}
	// Cold: the communities cache of this instance is empty (community doc read: +1) and the member doc is read: +1.
	p, cold, err := in.postIn(t, "uid-alice", key(2), commCID, "")
	if err != nil {
		t.Fatal(err)
	}
	if cold.Reads() != plain.Reads()+2 || cold.Writes() != plain.Writes() {
		t.Fatalf("cold: reads %d writes %d, want plain %d/%d + 2 reads, +0 writes", cold.Reads(), cold.Writes(), plain.Reads(), plain.Writes())
	}
	budgettest.Assert(t, "CreatePost into a community, cold", cold, budgettest.Budget{Reads: 4, Writes: 4})
	_, warm, err := in.postIn(t, "uid-alice", key(3), commCID, "")
	if err != nil {
		t.Fatal(err)
	}
	if warm.Reads() != plain.Reads()+1 || warm.Writes() != plain.Writes() {
		t.Fatalf("warm: reads %d writes %d, want plain %d/%d + 1 read, +0 writes", warm.Reads(), warm.Writes(), plain.Reads(), plain.Writes())
	}
	budgettest.Assert(t, "CreatePost into a community, warm", warm, budgettest.Budget{Reads: 3, Writes: 4})

	snap, err := client.Collection(postsCollection).Doc(p.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d postDoc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	if d.CommunityID != commCID || d.ConversationCommunityID != commCID || d.Community == nil || d.Community.ID != commCID || d.Community.Name != "Go Lang" {
		t.Fatalf("stored community fields = %+v", d)
	}
	if got := fieldInt(t, client, "quotas/uid-alice", "posts"); got != 3 {
		t.Fatalf("quotas.posts = %d, want 3", got)
	}
	if got := fieldInt(t, client, "quotas/uid-alice", "communityPosts"); got != 2 {
		t.Fatalf("quotas.communityPosts = %d, want 2", got)
	}
	if got := fieldInt(t, client, "users/uid-alice", "postsCount"); got != 3 {
		t.Fatalf("postsCount = %d, want 3", got)
	}
	// A plain post stores none of the fields.
	pl, _, _ := in.create(t, "uid-alice", key(4), "another plain")
	snap, _ = client.Collection(postsCollection).Doc(pl.ID).Get(context.Background())
	if _, err := snap.DataAt("communityId"); err == nil {
		t.Fatal("a plain post stored communityId")
	}
}

// TestCommunityPost_Refusals: every refusal writes nothing.
func TestCommunityPost_Refusals(t *testing.T) {
	client := newTestClient(t)
	in, _ := newCommunityInstance(t, client, 100)
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")
	seedCommunityDoc(t, client, commCID, "Go", "ACTIVE")
	seedCommunityDoc(t, client, "0000000000000000802", "Old", "ARCHIVED")
	seedCommunityDoc(t, client, "0000000000000000803", "Off", "SUSPENDED")
	seedMember(t, client, commCID, "uid-bob", "BANNED")
	base, _, err := in.create(t, "uid-bob", key(1), "bobs plain post, the quote target")
	if err != nil {
		t.Fatal(err)
	}
	posts0 := countDocs(t, client, postsCollection)

	tests := []struct {
		name   string
		uid    string
		cid    string
		quote  string
		code   connect.Code
		reason commonv1.ErrorReason
		meta   string
		val    string
	}{
		{"non-member", "uid-alice", commCID, "", connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "not_member"},
		{"non-member quoting is not a vanished parent", "uid-alice", commCID, base.ID, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "not_member"},
		{"banned", "uid-bob", commCID, "", connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "banned"},
		{"archived", "uid-alice", "0000000000000000802", "", connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "reason", "community_archived"},
		{"suspended", "uid-alice", "0000000000000000803", "", connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", ""},
		{"missing", "uid-alice", "0000000000000000899", "", connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", ""},
	}
	for i, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, c, err := in.postIn(t, tt.uid, key(100+i), tt.cid, tt.quote)
			wantRefusal(t, err, tt.code, tt.reason, tt.meta, tt.val)
			if c.Writes() != 0 {
				t.Fatalf("writes = %d, want 0", c.Writes())
			}
		})
	}
	if n := countDocs(t, client, postsCollection); n != posts0 {
		t.Fatalf("posts = %d, want %d", n, posts0)
	}
	if _, ok := client.Doc("quotas/uid-alice").Get(context.Background()); ok == nil {
		t.Fatal("a refused post created a quota doc")
	}
}

// TestCommunityPost_BanOnAnotherInstanceStopsTheNextPost: the member doc is read fresh in the transaction, so a ban written a second ago
// by another instance wins over this instance's cached member state.
func TestCommunityPost_BanOnAnotherInstanceStopsTheNextPost(t *testing.T) {
	client := newTestClient(t)
	in, rd := newCommunityInstance(t, client, 100)
	in.signUp(t, "uid-alice", "alice")
	seedCommunityDoc(t, client, commCID, "Go", "ACTIVE")
	seedMember(t, client, commCID, "uid-alice", "JOINED")

	if _, _, err := in.postIn(t, "uid-alice", key(1), commCID, ""); err != nil {
		t.Fatal(err)
	}
	// Warm this instance's own cached member state (JOINED), as a read path on it would have.
	if r, err := rd.Role(context.Background(), commCID, "uid-alice"); err != nil || r != communities.RoleMember {
		t.Fatalf("role = %v, %v", r, err)
	}
	seedMember(t, client, commCID, "uid-alice", "BANNED") // "another instance" bans her
	_, c, err := in.postIn(t, "uid-alice", key(2), commCID, "")
	wantRefusal(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "banned")
	if c.Writes() != 0 {
		t.Fatalf("writes = %d", c.Writes())
	}
	if got := fieldInt(t, client, "quotas/uid-alice", "communityPosts"); got != 1 {
		t.Fatalf("communityPosts = %d, want 1 (the refused post is not charged)", got)
	}
}

// TestCommunityPost_QuotaAndCap: the 51st community post of the day is QUOTA_EXCEEDED community_posts (posts is not charged either);
// the per-community cap is RATE_LIMITED, and a replay is charged to neither the cap nor the quota.
func TestCommunityPost_QuotaAndCap(t *testing.T) {
	client := newTestClient(t)
	in, _ := newCommunityInstance(t, client, 2)
	in.signUp(t, "uid-alice", "alice")
	seedCommunityDoc(t, client, commCID, "Go", "ACTIVE")
	seedMember(t, client, commCID, "uid-alice", "JOINED")

	first, _, err := in.postIn(t, "uid-alice", key(1), commCID, "")
	if err != nil {
		t.Fatal(err)
	}
	again, c, err := in.postIn(t, "uid-alice", key(1), commCID, "") // replay
	if err != nil || again.ID != first.ID || c.Writes() != 0 {
		t.Fatalf("replay: %v %v writes=%d", again, err, c.Writes())
	}
	if _, _, err := in.postIn(t, "uid-alice", key(2), commCID, ""); err != nil {
		t.Fatal(err)
	}
	_, c, err = in.postIn(t, "uid-alice", key(3), commCID, "")
	wantRefusal(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "limit", communities.LimitPostsPerCommunityDaily)
	if c.Writes() != 0 {
		t.Fatalf("writes = %d", c.Writes())
	}
	if got := fieldInt(t, client, "quotas/uid-alice", "communityPosts"); got != 2 {
		t.Fatalf("communityPosts = %d, want 2", got)
	}

	// The daily quota: seed 50 used, the next post is refused with 0 writes and nothing is charged.
	in2, _ := newCommunityInstance(t, client, 1000)
	if _, err := client.Doc("quotas/uid-alice").Set(context.Background(), map[string]any{"day": quota.Today(), "posts": int64(60), "communityPosts": int64(50)}); err != nil {
		t.Fatal(err)
	}
	_, c, err = in2.postIn(t, "uid-alice", key(4), commCID, "")
	wantRefusal(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "quota", "community_posts")
	if c.Writes() != 0 {
		t.Fatalf("writes = %d", c.Writes())
	}
	if got := fieldInt(t, client, "quotas/uid-alice", "posts"); got != 60 {
		t.Fatalf("posts = %d, want 60 (a refusal charges nothing)", got)
	}
}

// TestCommunityPost_QuoteIntoCommunity: a quote is accepted into a community and carries the fields and the embed.
func TestCommunityPost_QuoteIntoCommunity(t *testing.T) {
	client := newTestClient(t)
	in, _ := newCommunityInstance(t, client, 100)
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")
	seedCommunityDoc(t, client, commCID, "Go", "ACTIVE")
	seedMember(t, client, commCID, "uid-alice", "JOINED")
	base, _, err := in.create(t, "uid-bob", key(1), "to be quoted")
	if err != nil {
		t.Fatal(err)
	}
	q, _, err := in.postIn(t, "uid-alice", key(2), commCID, base.ID)
	if err != nil || q.Kind != KindQuote || q.CommunityID != commCID || q.Embedded == nil {
		t.Fatalf("quote = %+v err = %v", q, err)
	}
}

// TestByCommunity_PagesNewestFirst: 25 community posts page as 20 + 5, newest first, with the Before bound (older page) and the After
// bounds (since, and the settle sentinel); a plain post is never returned; reads are len(result).
func TestByCommunity_PagesNewestFirst(t *testing.T) {
	client := newTestClient(t)
	in, _ := newCommunityInstance(t, client, 1000)
	in.signUp(t, "uid-alice", "alice")
	seedCommunityDoc(t, client, commCID, "Go", "ACTIVE")
	seedCommunityDoc(t, client, "0000000000000000804", "Other", "ACTIVE")
	seedMember(t, client, commCID, "uid-alice", "JOINED")
	seedMember(t, client, "0000000000000000804", "uid-alice", "JOINED")
	if _, _, err := in.create(t, "uid-alice", key(900), "plain, never in the feed"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := in.postIn(t, "uid-alice", key(901), "0000000000000000804", ""); err != nil {
		t.Fatal(err)
	}
	var made []string // oldest first
	for i := 1; i <= 25; i++ {
		p, _, err := in.postIn(t, "uid-alice", key(i), commCID, "")
		if err != nil {
			t.Fatalf("post %d: %v", i, err)
		}
		made = append(made, p.ID)
		time.Sleep(2 * time.Millisecond) // distinct milliseconds, so the sentinel case is exact
	}
	newest := func(i int) string { return made[len(made)-1-i] }

	ctx, c := budget.WithCounter(context.Background())
	page1, err := in.svc.ByCommunity(ctx, commCID, Window{}, 20)
	if err != nil || len(page1) != 20 {
		t.Fatalf("page 1: %d posts, %v", len(page1), err)
	}
	budgettest.Assert(t, "ByCommunity page 1", c, budgettest.Budget{Reads: 20})
	for i, p := range page1 {
		if p.ID != newest(i) || p.CommunityID != commCID {
			t.Fatalf("page 1[%d] = %s, want %s", i, p.ID, newest(i))
		}
	}
	last := page1[19]
	ctx, c = budget.WithCounter(context.Background())
	page2, err := in.svc.ByCommunity(ctx, commCID, Window{Before: &Position{CreatedAt: last.CreatedAt, ID: last.ID}}, 20)
	if err != nil || len(page2) != 5 {
		t.Fatalf("page 2: %d posts, %v", len(page2), err)
	}
	budgettest.Assert(t, "ByCommunity page 2", c, budgettest.Budget{Reads: 5})
	for i, p := range page2 {
		if p.ID != newest(20+i) {
			t.Fatalf("page 2[%d] = %s, want %s", i, p.ID, newest(20+i))
		}
	}

	// since: After a real id returns strictly newer posts.
	ref := page1[4]
	since, err := in.svc.ByCommunity(context.Background(), commCID, Window{After: &Position{CreatedAt: ref.CreatedAt, ID: ref.ID}}, 50)
	if err != nil || len(since) != 4 || since[0].ID != newest(0) || since[3].ID != newest(3) {
		t.Fatalf("since: %d posts, %v", len(since), err)
	}
	// The settle sentinel: After{W, zeroID} includes the post created in W itself (EndAt of the smallest id of W).
	w := ref.CreatedAt
	sent, err := in.svc.ByCommunity(context.Background(), commCID, Window{After: &Position{CreatedAt: w, ID: zeroPostID}}, 50)
	if err != nil || len(sent) != 5 || sent[4].ID != ref.ID {
		t.Fatalf("sentinel: %d posts, %v", len(sent), err)
	}
	// A gap window: both bounds, the ids strictly between the old since (10th newest) and the resume point (5th newest).
	gap, err := in.svc.ByCommunity(context.Background(), commCID, Window{
		Before: &Position{CreatedAt: ref.CreatedAt, ID: ref.ID}, After: &Position{CreatedAt: page1[9].CreatedAt, ID: page1[9].ID}}, 50)
	if err != nil || len(gap) != 4 || gap[0].ID != page1[5].ID {
		t.Fatalf("gap: %d posts, %v", len(gap), err)
	}
	// An empty query still bills 1 read.
	ctx, c = budget.WithCounter(context.Background())
	none, err := in.svc.ByCommunity(ctx, "0000000000000000899", Window{}, 20)
	if err != nil || len(none) != 0 {
		t.Fatalf("empty: %d, %v", len(none), err)
	}
	budgettest.Assert(t, "ByCommunity empty", c, budgettest.Budget{Reads: 1})
	if c.Reads() != 1 {
		t.Fatalf("empty query reads = %d, want 1", c.Reads())
	}
}
