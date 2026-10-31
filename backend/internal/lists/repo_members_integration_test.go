//go:build integration

package lists

import (
	"context"
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// Member writes (W5-6). What is measured here: the service's own Firestore operations on a cold path with the real graph
// repository (graph.FirestoreRepo.GetSnapshot, one real read per call, no instance cache) and a directory that charges one
// read for every profile but the owner's (the account-status interceptor has loaded the owner's own). The interceptor's one read
// is not part of this harness: add 1 to compare with lists.proto (AddListMember 6 cold, RemoveListMember 3 cold + the graph).

// chargingDirectory serves profiles and charges one read per uid it returns other than "owner", as a cold identity.Directory.
type chargingDirectory struct {
	identity.Directory
	profiles map[string]identity.Profile
}

func (d chargingDirectory) GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error) {
	out := map[string]identity.Profile{}
	for _, u := range uids {
		p, ok := d.profiles[u]
		if !ok {
			continue
		}
		out[u] = p
		if u != "owner" {
			budget.FromContext(ctx).AddReads(1)
		}
	}
	return out, nil
}

// graphFromRepo adapts graph.FirestoreRepo.GetSnapshot (a real, charged read) to graph.Reader.
type graphFromRepo struct{ repo *graph.FirestoreRepo }

func (g graphFromRepo) Snapshot(ctx context.Context, uid string) (graph.Snapshot, error) {
	return g.repo.GetSnapshot(ctx, uid)
}

type membersEnv struct {
	*listsEnv
	svc      *service
	profiles map[string]identity.Profile
}

func newMembersEnv(t *testing.T, created time.Time) *membersEnv {
	t.Helper()
	base := newListsEnv(t, created)
	profiles := map[string]identity.Profile{"owner": active("owner", false)}
	p := profiles["owner"]
	p.CreatedAt = created
	profiles["owner"] = p
	for _, u := range []string{"u1", "u2", "u3", "u4"} {
		profiles[u] = active(u, false)
	}
	base.repo.SetTxProfiles(txProfilesFromMap{profiles: profiles})
	svc := New(Deps{
		Repo: base.repo, Directory: chargingDirectory{profiles: profiles}, IDs: base.node, Graph: graphFromRepo{graph.NewFirestoreRepo(base.client)},
		Limits: Limits{
			MaxPerUser: 20, CreatesPerDay: 10, NewAccountCreatesPerDay: 3, NewAccountWindow: 24 * time.Hour, CacheEntries: 100,
			MaxMembers: 150, AddsPerDay: 300, NewAccountAddsPerDay: 50,
		},
	}).(*service)
	return &membersEnv{listsEnv: base, svc: svc, profiles: profiles}
}

// seedGraph writes graph/{uid} with the given sets (BulkWriter-free: one Set).
func (e *membersEnv) seedGraph(t *testing.T, uid string, following, blocked, blockedBy []string, overflow bool) {
	t.Helper()
	nz := func(s []string) []string {
		if s == nil {
			return []string{}
		}
		return s
	}
	_, err := e.client.Collection("graph").Doc(uid).Set(context.Background(), map[string]any{
		"following": nz(following), "blocked": nz(blocked), "muted": []string{}, "requested": []string{}, "blockedBy": nz(blockedBy),
		"blockedByOverflow": overflow, "updatedAt": time.Now().UTC(),
	})
	if err != nil {
		t.Fatal(err)
	}
}

func (e *membersEnv) members(t *testing.T, id string) []string {
	t.Helper()
	d, ok := e.doc(t, id)
	if !ok {
		t.Fatalf("list %s is missing", id)
	}
	raw, isArray := d["memberIds"].([]any)
	if !isArray {
		t.Fatalf("memberIds = %#v, want an array (never null)", d["memberIds"])
	}
	out := make([]string, len(raw))
	for i, v := range raw {
		out[i] = v.(string)
	}
	return out
}

func (e *membersEnv) seedQuota(t *testing.T, uid string, adds int64) {
	t.Helper()
	if _, err := e.client.Collection("quotas").Doc(uid).Set(context.Background(), quota.Record{Day: quota.Today(), ListAdds: adds}); err != nil {
		t.Fatal(err)
	}
}

func (e *membersEnv) add(ctx context.Context, n int, listID, target string) (View, error) {
	return e.svc.AddMember(ctx, "owner", key(n), listID, target)
}

func manyMembers(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("m%03d", i)
	}
	return out
}

// wantCode asserts err is an apierr with this code and reason and returns it.
func wantCode(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason) *apierr.Error {
	t.Helper()
	var ae *apierr.Error
	if !asAPI(err, &ae) || ae.Code != code || ae.Reason != reason {
		t.Fatalf("err = %v, want %v/%v", err, code, reason)
	}
	return ae
}

// AddListMember: 6 service reads (graph, target profile, idempotency, list, target users fresh in the txn, quotas) and 3 writes; the stored document keeps
// the order and stays reachable by the eraser's array-contains query.
func TestAddMember_Integration_Budget(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, []string{"u1"})[0]
	var view View
	c := measured(t, "AddListMember", budgettest.Budget{Reads: 6, Writes: 3}, func(ctx context.Context) {
		v, err := e.add(ctx, 1, id, "u2")
		if err != nil {
			t.Fatal(err)
		}
		view = v
	})
	if c.Reads() != 6 || c.Writes() != 3 || c.Deletes() != 0 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want exactly 6/3/0", c.Reads(), c.Writes(), c.Deletes())
	}
	if view.Header.MemberCount != 2 || view.Header.ID != id {
		t.Errorf("header = %+v", view.Header)
	}
	if got := e.members(t, id); !slices.Equal(got, []string{"u1", "u2"}) {
		t.Errorf("memberIds = %v, want [u1 u2] in add order", got)
	}
	if n := e.quotaCount(t, "owner", "listAdds"); n != 1 {
		t.Errorf("quotas.listAdds = %d, want 1", n)
	}
	snaps, err := e.client.Collection("lists").Where("memberIds", "array-contains", "u2").Limit(5).Documents(context.Background()).GetAll()
	if err != nil || len(snaps) != 1 {
		t.Errorf("array-contains u2: %d docs, err %v: memberIds must stay indexed for the eraser", len(snaps), err)
	}
	if !e.cacheHas(id) {
		t.Error("the written public list was not put in the instance cache")
	}
}

// cacheHas reports whether the instance cache holds id. A seeded list is private=false (seedLists writes no isPrivate), so a write fills it.
func (e *membersEnv) cacheHas(id string) bool { _, ok := e.svc.cache.get(id); return ok }

// Already a member: success with the idempotency document only (1 write), no quota spent; a different key is the same.
func TestAddMember_Integration_AlreadyMember(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, []string{"u1", "u2"})[0]
	c := measured(t, "AddListMember already a member", budgettest.Budget{Reads: 4, Writes: 1}, func(ctx context.Context) {
		v, err := e.add(ctx, 1, id, "u2")
		if err != nil || v.Header.MemberCount != 2 {
			t.Fatalf("view %+v err %v", v, err)
		}
	})
	if c.Writes() != 1 || c.Reads() != 4 {
		t.Errorf("reads/writes = %d/%d, want 4/1", c.Reads(), c.Writes())
	}
	if n := e.quotaCount(t, "owner", "listAdds"); n != 0 {
		t.Errorf("an existing member spent quota: %d", n)
	}
	if got := e.members(t, id); !slices.Equal(got, []string{"u1", "u2"}) {
		t.Errorf("memberIds = %v", got)
	}
}

// A replay answers with 0 writes and 4 reads (graph, profile, idempotency, the list for its current header, W5-45 / L-3), spends no quota, even after the
// member was removed in between (a late retry never re-adds) and even after the target started blocking the owner.
func TestAddMember_Integration_Replay(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, nil)[0]
	first, err := e.add(context.Background(), 1, id, "u2")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.RemoveMember(context.Background(), "owner", key(2), id, "u2"); err != nil {
		t.Fatal(err)
	}
	e.seedGraph(t, "owner", nil, nil, []string{"u2"}, false) // u2 now blocks the owner
	c := measured(t, "AddListMember replay", budgettest.Budget{Reads: 4}, func(ctx context.Context) {
		v, err := e.add(ctx, 1, id, "u2")
		if err != nil {
			t.Fatalf("replay err = %v, want the stored outcome", err)
		}
		want := first.Header
		want.MemberCount = 0 // the replay answers the list as it is now: u2 was removed in between
		if v.Header != want {
			t.Errorf("replay header = %+v, want %+v", v.Header, want)
		}
	})
	if c.Writes() != 0 {
		t.Errorf("a replay wrote %d", c.Writes())
	}
	if got := e.members(t, id); len(got) != 0 {
		t.Errorf("a replay re-added the member: %v", got)
	}
	if n := e.quotaCount(t, "owner", "listAdds"); n != 1 {
		t.Errorf("listAdds = %d, want 1", n)
	}
	// The same key for another user is a different request.
	_, err = e.add(context.Background(), 1, id, "u3")
	wantCode(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
}

// Two requests with the same key at once: one writes, the other replays (the AlreadyExists re-run), one quota unit is spent.
func TestAddMember_Integration_ConcurrentSameKey(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, nil)[0]
	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i := range errs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, errs[i] = e.add(context.Background(), 1, id, "u2")
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("call %d: %v", i, err)
		}
	}
	if got := e.members(t, id); !slices.Equal(got, []string{"u2"}) {
		t.Errorf("memberIds = %v", got)
	}
	if n := e.quotaCount(t, "owner", "listAdds"); n != 1 {
		t.Errorf("listAdds = %d, want 1", n)
	}
}

// The cap of 150 is exact: a full list refuses with LIMIT_REACHED list_members and writes nothing, reading no more than a normal add.
func TestAddMember_Integration_Cap(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, append(manyMembers(149), "u1"))[0]
	c := measured(t, "AddListMember at the cap", budgettest.Budget{Reads: 5}, func(ctx context.Context) {
		_, err := e.add(ctx, 1, id, "u2")
		ae := wantCode(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
		if ae.Metadata["limit"] != "list_members" {
			t.Errorf("metadata = %v", ae.Metadata)
		}
	})
	if c.Writes() != 0 {
		t.Errorf("a refused add wrote %d", c.Writes())
	}
	if got := e.members(t, id); len(got) != 150 {
		t.Errorf("members = %d", len(got))
	}
	// An existing member at the cap is still success (no-op).
	if _, err := e.add(context.Background(), 2, id, "u1"); err != nil {
		t.Errorf("re-adding a member of a full list: %v", err)
	}
	// The 150th member fits.
	id2 := e.seedLists(t, "owner", 1, manyMembers(149))[0]
	c = measured(t, "AddListMember 150th", budgettest.Budget{Reads: 6, Writes: 3}, func(ctx context.Context) {
		if _, err := e.add(ctx, 3, id2, "u2"); err != nil {
			t.Fatal(err)
		}
	})
	if got := e.members(t, id2); len(got) != 150 || got[149] != "u2" {
		t.Errorf("members = %d", len(got))
	}
	_ = c
}

// Two adds of different users race at 149 members: exactly one wins, the other is LIMIT_REACHED, and the list ends at 150.
func TestAddMember_Integration_CapRace(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, manyMembers(149))[0]
	targets := []string{"u2", "u3"}
	errs := make([]error, len(targets))
	var wg sync.WaitGroup
	for i, tgt := range targets {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, errs[i] = e.add(context.Background(), i+1, id, tgt)
		}()
	}
	wg.Wait()
	ok, full := 0, 0
	for _, err := range errs {
		var ae *apierr.Error
		switch {
		case err == nil:
			ok++
		case asAPI(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED:
			full++
		default:
			t.Errorf("unexpected error: %v", err)
		}
	}
	if ok != 1 || full != 1 {
		t.Errorf("successes %d, LIMIT_REACHED %d, want 1 and 1", ok, full)
	}
	if got := e.members(t, id); len(got) != 150 {
		t.Errorf("members = %d, want exactly 150", len(got))
	}
	if n := e.quotaCount(t, "owner", "listAdds"); n != 1 {
		t.Errorf("listAdds = %d: the refused add spent quota", n)
	}
}

// The daily quota is exact in the transaction: at 300 the add is QUOTA_EXCEEDED list_adds with 0 writes; a new account has 50.
func TestAddMember_Integration_Quota(t *testing.T) {
	t.Run("established account", func(t *testing.T) {
		e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
		id := e.seedLists(t, "owner", 1, nil)[0]
		e.seedQuota(t, "owner", 299)
		if _, err := e.add(context.Background(), 1, id, "u2"); err != nil {
			t.Fatalf("the 300th add: %v", err)
		}
		c := measured(t, "AddListMember over quota", budgettest.Budget{Reads: 6}, func(ctx context.Context) {
			_, err := e.add(ctx, 2, id, "u3")
			ae := wantCode(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
			if ae.Metadata["quota"] != "list_adds" {
				t.Errorf("metadata = %v", ae.Metadata)
			}
		})
		if c.Writes() != 0 {
			t.Errorf("wrote %d", c.Writes())
		}
		if got := e.members(t, id); !slices.Equal(got, []string{"u2"}) {
			t.Errorf("members = %v", got)
		}
	})
	t.Run("new account", func(t *testing.T) {
		e := newMembersEnv(t, time.Now().Add(-time.Hour))
		id := e.seedLists(t, "owner", 1, nil)[0]
		e.seedQuota(t, "owner", 50)
		_, err := e.add(context.Background(), 1, id, "u2")
		wantCode(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
		e.seedQuota(t, "owner", 49)
		if _, err := e.add(context.Background(), 2, id, "u2"); err != nil {
			t.Fatalf("the 50th add of a new account: %v", err)
		}
	})
	t.Run("an add that changes nothing is free", func(t *testing.T) {
		e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
		id := e.seedLists(t, "owner", 1, []string{"u2"})[0]
		e.seedQuota(t, "owner", 300)
		if _, err := e.add(context.Background(), 1, id, "u2"); err != nil {
			t.Fatalf("existing member at the quota: %v", err)
		}
	})
}

// The block matrix: every way a target can be unusable is the same NOT_FOUND, byte for byte, as a user that does not exist,
// and as a list that is not the caller's; nothing is written.
func TestAddMember_Integration_BlockMatrix(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, nil)[0]
	foreign := e.seedLists(t, "stranger", 1, nil)[0]
	e.profiles["u4"] = identity.Profile{UserID: "u4", Handle: "u4", Status: identity.AccountStatusSuspended}
	e.profiles["u3"] = active("u3", false)
	e.seedGraph(t, "owner", nil, []string{"u1"}, []string{"u2"}, false)
	e.seedGraph(t, "u3", nil, []string{"owner"}, nil, false)

	type answer struct{ code, msg, reason, meta string }
	get := func(listID, target string, n int) answer {
		var out answer
		c := measured(t, "AddListMember refused", budgettest.Budget{Reads: 5}, func(ctx context.Context) {
			_, err := e.add(ctx, n, listID, target)
			var ae *apierr.Error
			if !asAPI(err, &ae) {
				t.Fatalf("%s: err = %v", target, err)
			}
			out = answer{ae.Code.String(), ae.Message, ae.Reason.String(), fmt.Sprint(ae.Metadata)}
		})
		if c.Writes() != 0 {
			t.Errorf("%s: a refusal wrote %d", target, c.Writes())
		}
		return out
	}
	missing := get(id, "nobody", 1)
	if missing.code != connect.CodeNotFound.String() {
		t.Fatalf("missing user: %+v", missing)
	}
	for i, tc := range []struct{ name, listID, target string }{
		{"the owner blocks the target", id, "u1"},
		{"the target blocks the owner", id, "u2"},
		{"suspended target", id, "u4"},
		{"someone else's list", foreign, "u3"},
	} {
		if got := get(tc.listID, tc.target, 10+i); got != missing {
			t.Errorf("%s: %+v differs from a missing user %+v", tc.name, got, missing)
		}
	}
	if got := e.members(t, id); len(got) != 0 {
		t.Errorf("members = %v", got)
	}

	// The owner's blockedBy overflowed: the target's own graph decides (+1 read), fail closed.
	e.seedGraph(t, "owner", nil, nil, nil, true)
	if got := get(id, "u3", 20); got != missing {
		t.Errorf("overflow: %+v differs from a missing user", got)
	}
	if _, err := e.add(context.Background(), 21, id, "u2"); err != nil {
		t.Errorf("overflow, target does not block: %v", err)
	}
}

// Overflow costs exactly one more read for an allowed target.
func TestAddMember_Integration_OverflowBudget(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, nil)[0]
	e.seedGraph(t, "owner", nil, nil, nil, true)
	c := measured(t, "AddListMember overflow", budgettest.Budget{Reads: 7, Writes: 3}, func(ctx context.Context) {
		if _, err := e.add(ctx, 1, id, "u2"); err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 7 {
		t.Errorf("reads = %d, want 7 (6 + the target's graph)", c.Reads())
	}
}

// A protected target needs the owner to follow it; the owner may always add itself; a protected target that blocks the owner stays NOT_FOUND.
func TestAddMember_Integration_Protected(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, nil)[0]
	e.profiles["u2"] = active("u2", true)
	e.profiles["u3"] = active("u3", true)
	e.profiles["owner"] = func() identity.Profile { p := e.profiles["owner"]; p.IsPrivate = true; return p }()
	e.seedGraph(t, "owner", []string{"u3"}, nil, nil, false)

	c := measured(t, "AddListMember protected", budgettest.Budget{Reads: 4}, func(ctx context.Context) {
		_, err := e.add(ctx, 1, id, "u2")
		wantCode(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT)
	})
	if c.Writes() != 0 {
		t.Errorf("wrote %d", c.Writes())
	}
	if _, err := e.add(context.Background(), 2, id, "u3"); err != nil {
		t.Errorf("followed protected account: %v", err)
	}
	if _, err := e.add(context.Background(), 3, id, "owner"); err != nil {
		t.Errorf("a protected owner adding itself: %v", err)
	}
	if got := e.members(t, id); !slices.Equal(got, []string{"u3", "owner"}) {
		t.Errorf("members = %v", got)
	}
}

// F4 lazy drop: the write of an add or a remove also removes members who block the owner, keeps the order, and costs no write.
func TestMembers_Integration_LazyDrop(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	e.seedGraph(t, "owner", nil, nil, []string{"b", "d"}, false)
	id := e.seedLists(t, "owner", 1, []string{"a", "b", "c", "d"})[0]
	c := measured(t, "AddListMember with drop", budgettest.Budget{Reads: 6, Writes: 3}, func(ctx context.Context) {
		v, err := e.add(ctx, 1, id, "u2")
		if err != nil {
			t.Fatal(err)
		}
		if v.Header.MemberCount != 3 {
			t.Errorf("member count = %d, want 3", v.Header.MemberCount)
		}
	})
	_ = c
	if got := e.members(t, id); !slices.Equal(got, []string{"a", "c", "u2"}) {
		t.Errorf("after add: %v, want [a c u2]", got)
	}

	id2 := e.seedLists(t, "owner", 1, []string{"a", "b", "c", "d"})[0]
	c = measured(t, "RemoveListMember with drop", budgettest.Budget{Reads: 3, Writes: 2}, func(ctx context.Context) {
		if _, err := e.svc.RemoveMember(ctx, "owner", key(2), id2, "a"); err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 3 || c.Writes() != 2 {
		t.Errorf("remove reads/writes = %d/%d, want 3/2", c.Reads(), c.Writes())
	}
	if got := e.members(t, id2); !slices.Equal(got, []string{"c"}) {
		t.Errorf("after remove: %v, want [c]", got)
	}

	// A full list whose lazy drop frees room takes the add.
	id3 := e.seedLists(t, "owner", 1, append(manyMembers(149), "b"))[0]
	if _, err := e.add(context.Background(), 3, id3, "u2"); err != nil {
		t.Errorf("add to a full list where a blocker can be dropped: %v", err)
	}
	if got := e.members(t, id3); len(got) != 150 || slices.Contains(got, "b") {
		t.Errorf("members = %d, contains b: %v", len(got), slices.Contains(got, "b"))
	}
}

// RemoveListMember: 2 service reads (idempotency, list) + the graph for a real removal; a non-member is the idempotency document
// only; a replay is 1 read; a list that is not the caller's, missing or deleted is the one NOT_FOUND; the list is never recreated.
func TestRemoveMember_Integration(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, []string{"u1", "u2"})[0]

	c := measured(t, "RemoveListMember", budgettest.Budget{Reads: 3, Writes: 2}, func(ctx context.Context) {
		v, err := e.svc.RemoveMember(ctx, "owner", key(1), id, "u1")
		if err != nil || v.Header.MemberCount != 1 {
			t.Fatalf("view %+v err %v", v, err)
		}
	})
	if c.Reads() != 3 || c.Writes() != 2 || c.Deletes() != 0 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 3/2/0", c.Reads(), c.Writes(), c.Deletes())
	}
	if got := e.members(t, id); !slices.Equal(got, []string{"u2"}) {
		t.Errorf("members = %v", got)
	}

	c = measured(t, "RemoveListMember not a member", budgettest.Budget{Reads: 2, Writes: 1}, func(ctx context.Context) {
		v, err := e.svc.RemoveMember(ctx, "owner", key(2), id, "u3")
		if err != nil || v.Header.MemberCount != 1 {
			t.Fatalf("view %+v err %v", v, err)
		}
	})
	if c.Writes() != 1 {
		t.Errorf("a no-op remove wrote %d, want 1 (the idempotency document)", c.Writes())
	}

	c = measured(t, "RemoveListMember replay", budgettest.Budget{Reads: 2}, func(ctx context.Context) {
		if _, err := e.svc.RemoveMember(ctx, "owner", key(1), id, "u1"); err != nil {
			t.Fatal(err)
		}
	})
	if c.Writes() != 0 {
		t.Errorf("a replay wrote %d", c.Writes())
	}
	// A later re-add by another call is not undone by a late retry of the first remove.
	if _, err := e.add(context.Background(), 3, id, "u1"); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.RemoveMember(context.Background(), "owner", key(1), id, "u1"); err != nil {
		t.Fatal(err)
	}
	if got := e.members(t, id); !slices.Equal(got, []string{"u2", "u1"}) {
		t.Errorf("a late retry undid a newer change: %v", got)
	}

	// Removing the last members leaves an empty array, not null.
	if _, err := e.svc.RemoveMember(context.Background(), "owner", key(4), id, "u1"); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.RemoveMember(context.Background(), "owner", key(5), id, "u2"); err != nil {
		t.Fatal(err)
	}
	if got := e.members(t, id); len(got) != 0 {
		t.Errorf("members = %v", got)
	}

	// NOT_FOUND: someone else's list, a missing one and a deleted one are the same answer; nothing is recreated.
	foreign := e.seedLists(t, "stranger", 1, []string{"u1"})[0]
	missing := e.node.Generate()
	if err := e.svc.DeleteList(context.Background(), "owner", key(6), id); err != nil {
		t.Fatal(err)
	}
	var first *apierr.Error
	for i, lid := range []string{foreign, missing, id} {
		c := measured(t, "RemoveListMember not found", budgettest.Budget{Reads: 2}, func(ctx context.Context) {
			_, err := e.svc.RemoveMember(ctx, "owner", key(20+i), lid, "u1")
			var ae *apierr.Error
			if !asAPI(err, &ae) || ae.Code != connect.CodeNotFound {
				t.Fatalf("list %d: err = %v", i, err)
			}
			if first == nil {
				first = ae
			} else if ae.Message != first.Message || ae.Reason != first.Reason {
				t.Errorf("list %d: %q differs from %q", i, ae.Message, first.Message)
			}
		})
		if c.Writes() != 0 {
			t.Errorf("list %d: wrote %d", i, c.Writes())
		}
	}
	if d, _ := e.doc(t, foreign); len(d["memberIds"].([]any)) != 1 {
		t.Error("another user's list was changed")
	}
	if _, ok := e.doc(t, id); ok {
		t.Error("RemoveMember or AddMember recreated a deleted list")
	}
	_, err := e.add(context.Background(), 40, id, "u2")
	wantCode(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if _, ok := e.doc(t, id); ok {
		t.Error("AddMember recreated a deleted list")
	}
}

// txProfilesFromMap is identity.TxProfiles over the harness's profile map (the real users documents are not seeded): it
// charges the one read ProfileInTx costs and answers the map's status, so a test can make the fresh read disagree with the
// cache-first directory (W5-45 / L-4).
type txProfilesFromMap struct{ profiles map[string]identity.Profile }

func (t txProfilesFromMap) ProfileInTx(ctx context.Context, _ *firestore.Transaction, uid string) (identity.Profile, error) {
	budget.FromContext(ctx).AddReads(1)
	p, ok := t.profiles[uid]
	if !ok {
		return identity.Profile{}, identity.ErrNotFound
	}
	return p, nil
}

// L-4 (W5-45): the cache-first directory still says u2 is ACTIVE (a 60 s old entry), but users/{u2} read fresh inside the
// transaction says DELETING: the add is the same NOT_FOUND as a missing user, nothing is written, no quota is spent. The fresh
// read is the +1 of a real add and is also charged on the refusal (5 reads: graph, directory, idempotency, list, fresh status).
func TestAddMember_Integration_FreshTargetStatus(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	id := e.seedLists(t, "owner", 1, nil)[0]
	fresh := map[string]identity.Profile{"u2": active("u2", false)}
	p := fresh["u2"]
	p.Status = identity.AccountStatusDeleting
	fresh["u2"] = p
	e.repo.SetTxProfiles(txProfilesFromMap{profiles: fresh})

	c := measured(t, "AddListMember deleting target", budgettest.Budget{Reads: 5}, func(ctx context.Context) {
		_, err := e.add(ctx, 1, id, "u2")
		wantCode(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	})
	if c.Writes() != 0 {
		t.Errorf("a refusal wrote %d", c.Writes())
	}
	if got := e.members(t, id); len(got) != 0 {
		t.Errorf("members = %v, want none", got)
	}
	if n := e.quotaCount(t, "owner", "listAdds"); n != 0 {
		t.Errorf("a refused add spent quota: %d", n)
	}
	// A user the fresh read does not find at all is the same answer.
	_, err := e.add(context.Background(), 2, id, "u3")
	wantCode(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
}

// L-3 (W5-45): the idempotency record of every list mutation holds the list id and nothing else, and a replay after the list
// was deleted is NOT_FOUND instead of the old name.
func TestListMutations_Integration_IdempotencyHoldsIDOnly(t *testing.T) {
	e := newMembersEnv(t, time.Now().Add(-72*time.Hour))
	v, err := create(t, e.listsEnv, "owner", 1, "Secret plans", nil)
	if err != nil {
		t.Fatal(err)
	}
	id := v.Header.ID
	if _, err := e.add(context.Background(), 2, id, "u1"); err != nil {
		t.Fatal(err)
	}
	for _, k := range []struct {
		rpc string
		n   int
	}{{rpcCreateList, 1}, {rpcAddListMember, 2}} {
		snap, err := e.client.Collection("idempotency").Doc(idempotency.Key("owner", k.rpc, key(k.n))).Get(context.Background())
		if err != nil {
			t.Fatalf("%s: %v", k.rpc, err)
		}
		raw, _ := snap.DataAt("result")
		res, _ := raw.(map[string]any)
		if len(res) != 1 || res["id"] != id {
			t.Errorf("%s record result = %v, want only the id", k.rpc, res)
		}
	}
	if err := e.svc.DeleteList(context.Background(), "owner", key(3), id); err != nil {
		t.Fatal(err)
	}
	_, err = create(t, e.listsEnv, "owner", 1, "Secret plans", nil)
	wantCode(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
}
