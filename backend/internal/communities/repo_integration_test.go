//go:build integration

package communities

import (
	"context"
	"fmt"
	"math/rand"
	"os"
	"slices"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// The budgets below are the service's own reads on top of the account-status interceptor's one profile read (the interceptor is not
// part of this harness): ADR-0031 "Cost impact" lists Create 3 / Update 4 / Get 15 including it.

type env struct {
	client *firestore.Client
	repo   *FirestoreRepo
	svc    *service
	dir    *fakeDirectory
	gr     *fakeGraph
	node   *snowflake.Node
}

func newEnv(t *testing.T, modlogMax int) *env {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int63()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	repo := NewFirestoreRepo(client, idempotency.New(client))
	dir := &fakeDirectory{profiles: map[string]identity.Profile{}}
	for _, u := range []string{"owner", "mod1", "mod2", "mod3", "member", "stranger"} {
		dir.profiles[u] = profile(u, identity.AccountStatusActive)
	}
	gr := &fakeGraph{}
	svc := New(Deps{
		Repo: repo, Directory: dir, Graph: gr, IDs: node, Creators: []string{"owner", "stranger"},
		Limits: Limits{MaxOwned: 2, MaxJoined: 50, MaxRules: 10, ModlogMax: modlogMax, CacheEntries: 100, MembersCacheEntries: 100},
	}).(*service)
	return &env{client: client, repo: repo, svc: svc, dir: dir, gr: gr, node: node}
}

func measured(t *testing.T, name string, b budgettest.Budget, fn func(ctx context.Context)) *budget.Counter {
	t.Helper()
	ctx, c := budget.WithCounter(context.Background())
	fn(ctx)
	budgettest.Assert(t, name, c, b)
	return c
}

func key(n int) string { return fmt.Sprintf("integration-key-%04d", n) }

func (e *env) data(t *testing.T, path string) (map[string]any, bool) {
	t.Helper()
	snap, err := e.client.Doc(path).Get(context.Background())
	if err != nil {
		return nil, false
	}
	return snap.Data(), true
}

func (e *env) community(t *testing.T, id string) Community {
	t.Helper()
	c, err := e.repo.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("community %s: %v", id, err)
	}
	return c
}

func (e *env) memberships(t *testing.T, uid string) (Memberships, bool) {
	t.Helper()
	m, ok, err := e.repo.LoadMemberships(context.Background(), uid)
	if err != nil {
		t.Fatal(err)
	}
	return m, ok
}

func (e *env) create(t *testing.T, uid string, n int, name string) Community {
	t.Helper()
	v, err := e.svc.CreateCommunity(context.Background(), uid, CreateInput{Key: key(n), Name: name})
	if err != nil {
		t.Fatalf("create %q: %v", name, err)
	}
	return v.Community
}

// seedCommunity writes a community document and (when joined) its member doc, bypassing the service.
func (e *env) seedCommunity(t *testing.T, c Community, members map[string]MemberState) {
	t.Helper()
	ctx := context.Background()
	if c.Status == "" {
		c.Status = StatusActive
	}
	now := time.Now().UTC()
	doc := communityDoc{
		Name: c.Name, Description: c.Description, Rules: ruleDocs(c.Rules), OwnerID: c.OwnerID, ModeratorIDs: nonNil(c.ModeratorIDs),
		MemberCount: c.MemberCount, Status: string(c.Status), Visibility: VisibilityPublic, RecentRemovals: []removalDoc{},
		Modlog: logDocs(c.Modlog), ModlogSeq: c.ModlogSeq, CreatedAt: now, UpdatedAt: now,
	}
	if _, err := e.repo.ref(c.ID).Set(ctx, doc); err != nil {
		t.Fatal(err)
	}
	for uid, st := range members {
		md := memberDoc{UID: uid, State: string(st)}
		if st == MemberJoined {
			md.JoinedAt = &now
		} else {
			md.BannedAt = &now
		}
		if _, err := e.repo.memberRef(c.ID, uid).Set(ctx, md); err != nil {
			t.Fatal(err)
		}
	}
}

func (e *env) seedMemberships(t *testing.T, uid string, m Memberships) {
	t.Helper()
	d := membershipsDoc{Joined: nonNil(m.Joined), Owned: nonNil(m.Owned), Banned: nonNil(m.Banned), Modlogged: nonNil(m.Modlogged), UpdatedAt: time.Now().UTC()}
	if _, err := e.repo.membershipsRef(uid).Set(context.Background(), d); err != nil {
		t.Fatal(err)
	}
}

func TestCreate_WritesThreeDocsAndTheRecordWithinBudget(t *testing.T) {
	e := newEnv(t, 100)
	var got View
	c := measured(t, "CreateCommunity", budgettest.Budget{Reads: 2, Writes: 4}, func(ctx context.Context) {
		var err error
		got, err = e.svc.CreateCommunity(ctx, "owner", CreateInput{
			Key: key(1), Name: "Cricket", Description: "Talk cricket", Rules: []Rule{{Title: "Be kind", Text: "Always."}, {Title: "No spam"}},
		})
		if err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 2 || c.Writes() != 4 || c.Deletes() != 0 {
		t.Errorf("Create = %d reads, %d writes, %d deletes, want 2, 4, 0 (ADR-0031: 3 / 4 with the interceptor)", c.Reads(), c.Writes(), c.Deletes())
	}
	id := got.Community.ID
	if len(id) != 19 {
		t.Fatalf("id = %q, want a 19-digit Snowflake", id)
	}
	cm := e.community(t, id)
	if cm.OwnerID != "owner" || cm.Status != StatusActive || cm.Visibility != "PUBLIC" || cm.MemberCount != 1 || len(cm.ModeratorIDs) != 0 ||
		len(cm.Rules) != 2 || cm.Rules[1].Title != "No spam" || cm.ModlogSeq != 0 || cm.CreatedAt.IsZero() {
		t.Errorf("community = %+v", cm)
	}
	raw, _ := e.data(t, "communities/"+id)
	for _, f := range []string{"recentRemovals", "modlog", "moderatorIds", "rules"} {
		if _, ok := raw[f].([]any); !ok {
			t.Errorf("%s = %T, want an array (never null)", f, raw[f])
		}
	}
	if _, has := raw["removalsTruncatedAt"]; has {
		t.Error("removalsTruncatedAt written at creation (absent = never)")
	}
	member, ok := e.data(t, "communities/"+id+"/communityMembers/owner")
	if !ok || member["state"] != "JOINED" || member["uid"] != "owner" || member["joinedAt"] == nil || member["bannedAt"] != nil {
		t.Errorf("owner member doc = %v", member)
	}
	if _, hasRole := member["role"]; hasRole {
		t.Error("a member doc stores a role")
	}
	ms, ok := e.memberships(t, "owner")
	if !ok || !slices.Equal(ms.Owned, []string{id}) || !slices.Equal(ms.Joined, []string{id}) || len(ms.Banned) != 0 || len(ms.Modlogged) != 0 {
		t.Errorf("memberships = %+v", ms)
	}
	rawMs, _ := e.data(t, "communityMemberships/owner")
	for _, f := range []string{"banned", "modlogged"} {
		if _, ok := rawMs[f].([]any); !ok {
			t.Errorf("memberships.%s = %T, want an empty array", f, rawMs[f])
		}
	}
	rec, ok := e.data(t, "idempotency/"+idempotency.Key("owner", "CreateCommunity", key(1)))
	if !ok || rec["expireAt"] == nil || rec["rpc"] != "CreateCommunity" {
		t.Errorf("idempotency record = %v", rec)
	}
	if res, _ := rec["result"].(map[string]any); res["id"] != id || len(res) != 1 {
		t.Errorf("the record holds %v, want the id only", rec["result"])
	}
}

func TestCreate_ReplayWritesNothingAndAnotherBodyIsRefused(t *testing.T) {
	e := newEnv(t, 100)
	first := e.create(t, "owner", 1, "Cricket")
	var again View
	c := measured(t, "CreateCommunity replay", budgettest.Budget{Reads: 2, Writes: 0, Deletes: 0}, func(ctx context.Context) {
		var err error
		again, err = e.svc.CreateCommunity(ctx, "owner", CreateInput{Key: key(1), Name: "Cricket"})
		if err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 2 || c.Writes() != 0 {
		t.Errorf("replay = %d reads, %d writes, want 2, 0", c.Reads(), c.Writes())
	}
	if again.Community.ID != first.ID || again.Role != RoleOwner {
		t.Errorf("replay answered %+v, want the first community", again)
	}
	// a replay re-reads: a rename in between shows
	newName := "Test cricket"
	if _, err := e.svc.UpdateCommunity(context.Background(), "owner", UpdateInput{Key: key(2), CommunityID: first.ID, Name: &newName}); err != nil {
		t.Fatal(err)
	}
	again, err := e.svc.CreateCommunity(context.Background(), "owner", CreateInput{Key: key(1), Name: "Cricket"})
	if err != nil || again.Community.Name != "Test cricket" {
		t.Errorf("replay after a rename = %+v, %v, want the current name", again.Community, err)
	}
	// the same key with another body
	for name, in := range map[string]CreateInput{
		"name": {Key: key(1), Name: "Football"}, "description": {Key: key(1), Name: "Cricket", Description: "x"},
		"rules": {Key: key(1), Name: "Cricket", Rules: []Rule{{Title: "r"}}},
	} {
		c := measured(t, "reused "+name, budgettest.Budget{Reads: 1, Writes: 0}, func(ctx context.Context) {
			_, err := e.svc.CreateCommunity(ctx, "owner", in)
			wantAPIErr(t, err, connect.CodeInvalidArgument, rKeyReused, nil)
		})
		_ = c
	}
	// a replay of a community that went SUSPENDED is the one NOT_FOUND
	if _, err := e.repo.ref(first.ID).Update(context.Background(), []firestore.Update{{Path: "status", Value: "SUSPENDED"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.CreateCommunity(context.Background(), "owner", CreateInput{Key: key(1), Name: "Cricket"}); err == nil {
		t.Error("replay of a SUSPENDED community answered")
	}
}

// Four racers on one key: a racer that loses the transaction and exhausts its re-runs answers a retryable
// UNAVAILABLE ("temporarily busy"); what must never happen is a second community. As in lists, this used to
// demand that all four succeed, and a slow CI runner failed it with a correct product answer. Now: at least one
// succeeds, every success is the same community, a busy racer's retry with the same key replays it, and there is
// exactly one community, owned and joined once.
func TestCreate_ConcurrentSameKeyCreatesOne(t *testing.T) {
	e := newEnv(t, 100)
	var wg sync.WaitGroup
	ids := make([]string, 4)
	errs := make([]error, 4)
	for i := range ids {
		wg.Add(1)
		go func() {
			defer wg.Done()
			v, err := e.svc.CreateCommunity(context.Background(), "owner", CreateInput{Key: key(7), Name: "Racers"})
			ids[i], errs[i] = v.Community.ID, err
		}()
	}
	wg.Wait()
	winner := ""
	for i := range ids {
		if errs[i] != nil {
			wantAPIErr(t, errs[i], connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil) // a lost race: retryable, nothing written
			continue
		}
		if winner == "" {
			winner = ids[i]
		}
		if ids[i] != winner {
			t.Errorf("request %d answered %s, want %s: one key, one community", i, ids[i], winner)
		}
	}
	if winner == "" {
		t.Fatalf("no racer succeeded: %v", errs)
	}
	for i := range ids {
		if errs[i] == nil {
			continue
		}
		again, err := e.svc.CreateCommunity(context.Background(), "owner", CreateInput{Key: key(7), Name: "Racers"})
		if err != nil || again.Community.ID != winner {
			t.Errorf("retry of busy request %d: id=%s err=%v, want the replayed community %s", i, again.Community.ID, err, winner)
		}
	}
	docs, err := e.client.Collection("communities").Documents(context.Background()).GetAll()
	if err != nil || len(docs) != 1 {
		t.Errorf("communities = %d (err %v), want exactly 1", len(docs), err)
	}
	if ms, _ := e.memberships(t, "owner"); len(ms.Owned) != 1 || len(ms.Joined) != 1 {
		t.Errorf("memberships = %+v, want one owned and one joined", ms)
	}
}

func TestCreate_CapsAreExactAndWriteNothing(t *testing.T) {
	e := newEnv(t, 100)
	e.create(t, "owner", 1, "One")
	e.create(t, "owner", 2, "Two")
	c := measured(t, "owned cap", budgettest.Budget{Reads: 2, Writes: 0}, func(ctx context.Context) {
		_, err := e.svc.CreateCommunity(ctx, "owner", CreateInput{Key: key(3), Name: "Three"})
		wantAPIErr(t, err, connect.CodeFailedPrecondition, rLimit, map[string]string{"limit": "communities_owned"})
	})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("the owned cap wrote %d / %d", c.Writes(), c.Deletes())
	}
	if _, ok := e.data(t, "idempotency/"+idempotency.Key("owner", "CreateCommunity", key(3))); ok {
		t.Error("a refusal stored an idempotency record")
	}
	if docs, _ := e.client.Collection("communities").Documents(context.Background()).GetAll(); len(docs) != 2 {
		t.Errorf("communities = %d, want 2", len(docs))
	}
	// the joined cap: 50 joined, 0 owned
	joined := make([]string, 50)
	for i := range joined {
		joined[i] = fmt.Sprintf("%019d", 9000+i)
	}
	e.seedMemberships(t, "stranger", Memberships{Joined: joined})
	_ = measured(t, "joined cap", budgettest.Budget{Reads: 2, Writes: 0}, func(ctx context.Context) {
		_, err := e.svc.CreateCommunity(ctx, "stranger", CreateInput{Key: key(4), Name: "Late"})
		wantAPIErr(t, err, connect.CodeFailedPrecondition, rLimit, map[string]string{"limit": "communities_joined"})
	})
	// 49 joined: the 50th is allowed, and appends to the existing doc (field-level Update)
	e.seedMemberships(t, "stranger", Memberships{Joined: joined[:49], Banned: []string{"b1"}, Modlogged: []string{"m1"}})
	v, err := e.svc.CreateCommunity(context.Background(), "stranger", CreateInput{Key: key(5), Name: "Fifty"})
	if err != nil {
		t.Fatal(err)
	}
	ms, _ := e.memberships(t, "stranger")
	if len(ms.Joined) != 50 || ms.Joined[49] != v.Community.ID || !slices.Equal(ms.Owned, []string{v.Community.ID}) ||
		!slices.Equal(ms.Banned, []string{"b1"}) || !slices.Equal(ms.Modlogged, []string{"m1"}) {
		t.Errorf("memberships after the 50th = %+v", ms)
	}
}

func TestUpdate_BudgetsModlogAndMemberships(t *testing.T) {
	e := newEnv(t, 3)
	com := e.create(t, "owner", 1, "Old name")
	str := func(s string) *string { return &s }
	// the first edit: community + idempotency + memberships.modlogged
	var v View
	c := measured(t, "UpdateCommunity first edit", budgettest.Budget{Reads: 3, Writes: 3}, func(ctx context.Context) {
		var err error
		v, err = e.svc.UpdateCommunity(ctx, "owner", UpdateInput{Key: key(2), CommunityID: com.ID, Name: str("New name"), Rules: &[]Rule{{Title: "One"}}})
		if err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 3 || c.Writes() != 3 {
		t.Errorf("first edit = %d reads, %d writes, want 3, 3", c.Reads(), c.Writes())
	}
	if v.Community.Name != "New name" || len(v.Community.Rules) != 1 || v.Role != RoleOwner {
		t.Errorf("view = %+v", v)
	}
	cm := e.community(t, com.ID)
	if cm.Name != "New name" || cm.Description != "" || len(cm.Rules) != 1 || cm.ModlogSeq != 1 || len(cm.Modlog) != 1 ||
		cm.Modlog[0].Action != "EDIT" || cm.Modlog[0].Actor != "owner" || cm.Modlog[0].Target != "" || cm.Modlog[0].PostID != "" || !cm.UpdatedAt.After(cm.CreatedAt) {
		t.Errorf("community = %+v", cm)
	}
	if ms, _ := e.memberships(t, "owner"); !slices.Equal(ms.Modlogged, []string{com.ID}) || !slices.Equal(ms.Owned, []string{com.ID}) {
		t.Errorf("memberships = %+v, want modlogged to hold the community (I-L)", ms)
	}
	// a later edit: community + idempotency only
	c = measured(t, "UpdateCommunity later edit", budgettest.Budget{Reads: 3, Writes: 2}, func(ctx context.Context) {
		if _, err := e.svc.UpdateCommunity(ctx, "owner", UpdateInput{Key: key(3), CommunityID: com.ID, Description: str("About us")}); err != nil {
			t.Fatal(err)
		}
	})
	if c.Writes() != 2 {
		t.Errorf("later edit wrote %d, want 2", c.Writes())
	}
	// nothing changes: the idempotency record only, and no log entry
	c = measured(t, "UpdateCommunity unchanged", budgettest.Budget{Reads: 2, Writes: 1}, func(ctx context.Context) {
		if _, err := e.svc.UpdateCommunity(ctx, "owner", UpdateInput{Key: key(4), CommunityID: com.ID, Name: str("New name"), Description: str("About us")}); err != nil {
			t.Fatal(err)
		}
	})
	if c.Writes() != 1 || c.Reads() != 2 {
		t.Errorf("unchanged = %d reads, %d writes, want 2, 1", c.Reads(), c.Writes())
	}
	if cm = e.community(t, com.ID); cm.ModlogSeq != 2 || len(cm.Modlog) != 2 {
		t.Errorf("an unchanged request logged: seq %d, %d entries", cm.ModlogSeq, len(cm.Modlog))
	}
	// replay: 0 writes, and it re-reads the community
	c = measured(t, "UpdateCommunity replay", budgettest.Budget{Reads: 2, Writes: 0}, func(ctx context.Context) {
		got, err := e.svc.UpdateCommunity(ctx, "owner", UpdateInput{Key: key(3), CommunityID: com.ID, Description: str("About us")})
		if err != nil || got.Community.Description != "About us" {
			t.Errorf("replay = %+v, %v", got.Community, err)
		}
	})
	if c.Writes() != 0 {
		t.Errorf("replay wrote %d", c.Writes())
	}
	// the same key, another body
	_, err := e.svc.UpdateCommunity(context.Background(), "owner", UpdateInput{Key: key(3), CommunityID: com.ID, Description: str("Other")})
	wantAPIErr(t, err, connect.CodeInvalidArgument, rKeyReused, nil)
	// an empty rule list is a value: it removes every rule; unset leaves them
	empty := []Rule{}
	if _, err := e.svc.UpdateCommunity(context.Background(), "owner", UpdateInput{Key: key(5), CommunityID: com.ID, Rules: &empty}); err != nil {
		t.Fatal(err)
	}
	if cm = e.community(t, com.ID); len(cm.Rules) != 0 {
		t.Errorf("rules after an empty list = %v", cm.Rules)
	}
	// COMMUNITY_MODLOG_MAX = 3: the newest 3 entries are kept, seq keeps counting
	for i := range 4 {
		if _, err := e.svc.UpdateCommunity(context.Background(), "owner", UpdateInput{Key: key(10 + i), CommunityID: com.ID, Name: str(fmt.Sprintf("Name %d", i))}); err != nil {
			t.Fatal(err)
		}
	}
	cm = e.community(t, com.ID)
	if len(cm.Modlog) != 3 || cm.ModlogSeq != 7 || cm.Modlog[0].Seq != 5 || cm.Modlog[2].Seq != 7 {
		t.Errorf("modlog seq %d, entries %v, want the newest 3 (5, 6, 7)", cm.ModlogSeq, cm.Modlog)
	}
}

func TestUpdate_RefusalsWriteNothing(t *testing.T) {
	e := newEnv(t, 100)
	com := e.create(t, "owner", 1, "Mine")
	str := func(s string) *string { return &s }
	archived := e.create(t, "owner", 2, "Quiet")
	suspended := e.create(t, "stranger", 3, "Gone")
	ownerless := fmt.Sprintf("%019d", 77)
	e.seedCommunity(t, Community{ID: ownerless, Name: "Orphan", Status: StatusArchived}, nil)
	for id, st := range map[string]string{archived.ID: "ARCHIVED", suspended.ID: "SUSPENDED"} {
		if _, err := e.repo.ref(id).Update(context.Background(), []firestore.Update{{Path: "status", Value: st}}); err != nil {
			t.Fatal(err)
		}
	}
	tests := []struct {
		name   string
		uid    string
		id     string
		code   connect.Code
		reason commonv1.ErrorReason
		meta   map[string]string
	}{
		{"someone else", "stranger", com.ID, connect.CodePermissionDenied, rForbidden, map[string]string{"reason": "not_owner"}},
		{"a member who is not the owner", "member", com.ID, connect.CodePermissionDenied, rForbidden, map[string]string{"reason": "not_owner"}},
		{"missing", "owner", fmt.Sprintf("%019d", 12345), connect.CodeNotFound, rNone, nil},
		{"archived, by its owner", "owner", archived.ID, connect.CodeFailedPrecondition, rState, map[string]string{"reason": "community_archived"}},
		{"suspended, even by its owner", "stranger", suspended.ID, connect.CodeNotFound, rNone, nil},
		{"archived with no owner: everyone is a non-owner", "owner", ownerless, connect.CodePermissionDenied, rForbidden, map[string]string{"reason": "not_owner"}},
	}
	for i, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := measured(t, tt.name, budgettest.Budget{Reads: 3, Writes: 0}, func(ctx context.Context) {
				_, err := e.svc.UpdateCommunity(ctx, tt.uid, UpdateInput{Key: key(100 + i), CommunityID: tt.id, Name: str("Hijack")})
				wantAPIErr(t, err, tt.code, tt.reason, tt.meta)
			})
			if c.Writes() != 0 {
				t.Errorf("a refusal wrote %d", c.Writes())
			}
		})
	}
	if cm := e.community(t, com.ID); cm.Name != "Mine" || cm.ModlogSeq != 0 {
		t.Errorf("a refused update changed the community: %+v", cm)
	}
	// nothing was recorded for a refusal: the same key now works for the owner
	if _, err := e.svc.UpdateCommunity(context.Background(), "owner", UpdateInput{Key: key(100), CommunityID: com.ID, Name: str("Hijack")}); err != nil {
		t.Errorf("key of a refused call is spent: %v", err)
	}
}

func TestGet_ColdAndWarmReads(t *testing.T) {
	e := newEnv(t, 100)
	com := e.create(t, "owner", 1, "Cricket")
	e.seedCommunity(t, Community{ID: "0000000000000000900", Name: "Seeded", OwnerID: "owner", ModeratorIDs: []string{"mod1", "mod2", "mod3"}, MemberCount: 5},
		map[string]MemberState{"member": MemberJoined, "banned": MemberBanned})
	cid := "0000000000000000900"
	// a fresh service instance = a cold cache
	cold := func() *service {
		return New(Deps{Repo: e.repo, Directory: e.dir, Graph: e.gr, IDs: e.node, Limits: Limits{CacheEntries: 10, MembersCacheEntries: 10}}).(*service)
	}
	tests := []struct {
		uid  string
		want Role
	}{{"owner", RoleOwner}, {"mod2", RoleModerator}, {"member", RoleMember}, {"banned", RoleBanned}, {"stranger", RoleNone}}
	for _, tt := range tests {
		t.Run(tt.uid, func(t *testing.T) {
			s := cold()
			e.dir.asked, e.gr.calls = 0, 0
			var d Detail
			c := measured(t, "GetCommunity cold", budgettest.Budget{Reads: 1 + 1 + 1 + 4, Writes: 0}, func(ctx context.Context) {
				var err error
				if d, err = s.GetCommunity(ctx, tt.uid, cid); err != nil {
					t.Fatal(err)
				}
			})
			if d.View.Role != tt.want || d.View.Community.Name != "Seeded" || len(d.Moderators) != 3 || d.Owner == nil {
				t.Errorf("detail = %+v", d)
			}
			wantRepo := int64(2) // community + member doc
			if tt.want == RoleOwner || tt.want == RoleModerator {
				wantRepo = 1
			}
			if got := c.Reads() - int64(e.dir.asked) - int64(e.gr.calls); got != wantRepo {
				t.Errorf("repo reads = %d, want %d", got, wantRepo)
			}
			warm := measured(t, "GetCommunity warm", budgettest.Budget{Reads: 0 + 1 + 4, Writes: 0}, func(ctx context.Context) { // profiles and graph are charged by the fakes every time
				if _, err := s.GetCommunity(ctx, tt.uid, cid); err != nil {
					t.Fatal(err)
				}
			})
			if warm.Reads() != int64(1+4) {
				t.Errorf("warm Get = %d reads, want only the fakes' graph + 4 profiles (the repo is not read)", warm.Reads())
			}
		})
	}
	// the community created through the service was cached on the writing instance: its owner's first Get reads nothing from Firestore
	e.dir.asked, e.gr.calls = 0, 0
	c := measured(t, "GetCommunity after the write", budgettest.Budget{Reads: 2, Writes: 0}, func(ctx context.Context) {
		if _, err := e.svc.GetCommunity(ctx, "owner", com.ID); err != nil {
			t.Fatal(err)
		}
	})
	if got := c.Reads() - int64(e.dir.asked) - int64(e.gr.calls); got != 0 {
		t.Errorf("repo reads after the write = %d, want 0", got)
	}
}

func TestGet_SuspendedAndMissingCostTheSame(t *testing.T) {
	e := newEnv(t, 100)
	com := e.create(t, "owner", 1, "Cricket")
	if _, err := e.repo.ref(com.ID).Update(context.Background(), []firestore.Update{{Path: "status", Value: "SUSPENDED"}}); err != nil {
		t.Fatal(err)
	}
	fresh := func() *service {
		return New(Deps{Repo: e.repo, Directory: e.dir, Graph: e.gr, IDs: e.node, Limits: Limits{CacheEntries: 10, MembersCacheEntries: 10}}).(*service)
	}
	cs := measured(t, "suspended", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		_, err := fresh().GetCommunity(ctx, "stranger", com.ID)
		wantAPIErr(t, err, connect.CodeNotFound, rNone, nil)
	})
	cm := measured(t, "missing", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		_, err := fresh().GetCommunity(ctx, "stranger", fmt.Sprintf("%019d", 4242))
		wantAPIErr(t, err, connect.CodeNotFound, rNone, nil)
	})
	if cs.Reads() != cm.Reads() {
		t.Errorf("SUSPENDED costs %d reads, missing %d: the cost tells them apart", cs.Reads(), cm.Reads())
	}
	d, err := fresh().GetCommunity(context.Background(), "owner", com.ID)
	if err != nil || d.View.Community.Status != StatusSuspended {
		t.Errorf("owner of a SUSPENDED community: %+v, %v", d.View.Community.Status, err)
	}
}

func TestRepo_MemberStates(t *testing.T) {
	e := newEnv(t, 100)
	e.seedCommunity(t, Community{ID: testCID, Name: "x", OwnerID: "owner"}, map[string]MemberState{"member": MemberJoined, "banned": MemberBanned})
	for uid, want := range map[string]MemberState{"member": MemberJoined, "banned": MemberBanned, "stranger": MemberNone} {
		c := measured(t, "Member "+uid, budgettest.Budget{Reads: 1}, func(ctx context.Context) {
			got, err := e.repo.Member(ctx, testCID, uid)
			if err != nil || got != want {
				t.Errorf("Member(%s) = %q, %v, want %q", uid, got, err, want)
			}
		})
		if c.Reads() != 1 {
			t.Errorf("a point read costs %d", c.Reads())
		}
	}
	if _, err := e.repo.Get(context.Background(), "0000000000000000001"); err != ErrNotFound {
		t.Errorf("Get(missing) = %v", err)
	}
}

const (
	rNone      = commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED
	rKeyReused = commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED
	rLimit     = commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED
	rForbidden = commonv1.ErrorReason_ERROR_REASON_FORBIDDEN
	rState     = commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE
)
