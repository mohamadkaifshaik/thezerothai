package lists

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// fakeGraph serves canned snapshots; a uid it does not know is an empty snapshot (graph.Reader's own behaviour). The fakes of
// one test are used by one goroutine, so there is no lock.
type fakeGraph struct {
	snaps map[string]graph.Snapshot
	err   error
	asked []string
}

func (g *fakeGraph) Snapshot(_ context.Context, uid string) (graph.Snapshot, error) {
	g.asked = append(g.asked, uid)
	return g.snaps[uid], g.err
}

func set(ids ...string) map[string]bool {
	m := map[string]bool{}
	for _, i := range ids {
		m[i] = true
	}
	return m
}

func active(uid string, private bool) identity.Profile {
	return identity.Profile{UserID: uid, Handle: uid, Status: identity.AccountStatusActive, IsPrivate: private}
}

type memberEnv struct {
	svc  *service
	repo *fakeRepo
	g    *fakeGraph
	dir  fakeDirectory
}

func newMemberEnv(created time.Time, profiles map[string]identity.Profile, snaps map[string]graph.Snapshot) memberEnv {
	repo := &fakeRepo{member: MemberResult{Outcome: Written, Header: Header{ID: testListID, Name: "Cricket", IsPrivate: true, MemberCount: 1}}}
	g := &fakeGraph{snaps: snaps}
	if _, ok := profiles[testUID]; !ok {
		profiles[testUID] = identity.Profile{UserID: testUID, Handle: "owner", Status: identity.AccountStatusActive, CreatedAt: created}
	}
	dir := fakeDirectory{profiles: profiles}
	s := New(Deps{
		Repo: repo, Directory: dir, IDs: fixedIDs{}, Graph: g, Now: func() time.Time { return testNow },
		Limits: Limits{
			MaxPerUser: 20, CreatesPerDay: 10, NewAccountCreatesPerDay: 3, NewAccountWindow: 24 * time.Hour, CacheEntries: 50,
			MaxMembers: 150, AddsPerDay: 300, NewAccountAddsPerDay: 50,
		},
	}).(*service)
	return memberEnv{svc: s, repo: repo, g: g, dir: dir}
}

// The verdict the service hands the repository, over the whole block / protected / status matrix. Every refusal of the target
// other than PROTECTED_ACCOUNT is the same ErrNotFound as a missing user, so neither the repository nor the client can tell them apart.
func TestAddMember_Verdict(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		target   string
		profiles map[string]identity.Profile
		owner    graph.Snapshot
		theirs   graph.Snapshot
		want     error
		asked    int
	}{
		{"plain public account", "u2", map[string]identity.Profile{"u2": active("u2", false)}, graph.Snapshot{}, graph.Snapshot{}, nil, 1},
		{"missing user", "u2", map[string]identity.Profile{}, graph.Snapshot{}, graph.Snapshot{}, ErrNotFound, 1},
		{"suspended user", "u2", map[string]identity.Profile{"u2": {UserID: "u2", Status: identity.AccountStatusSuspended}}, graph.Snapshot{}, graph.Snapshot{}, ErrNotFound, 1},
		{"owner blocks the target", "u2", map[string]identity.Profile{"u2": active("u2", false)}, graph.Snapshot{Blocked: set("u2")}, graph.Snapshot{}, ErrNotFound, 1},
		{"target blocks the owner", "u2", map[string]identity.Profile{"u2": active("u2", false)}, graph.Snapshot{BlockedBy: set("u2")}, graph.Snapshot{}, ErrNotFound, 1},
		{"overflow, target does not block", "u2", map[string]identity.Profile{"u2": active("u2", false)}, graph.Snapshot{BlockedByOverflow: true}, graph.Snapshot{}, nil, 2},
		{"overflow, target blocks the owner", "u2", map[string]identity.Profile{"u2": active("u2", false)}, graph.Snapshot{BlockedByOverflow: true}, graph.Snapshot{Blocked: set(testUID)}, ErrNotFound, 2},
		{"protected, not followed", "u2", map[string]identity.Profile{"u2": active("u2", true)}, graph.Snapshot{}, graph.Snapshot{}, ErrProtected, 1},
		{"protected, followed", "u2", map[string]identity.Profile{"u2": active("u2", true)}, graph.Snapshot{Following: set("u2")}, graph.Snapshot{}, nil, 1},
		{"protected that blocks the owner is NOT_FOUND, not PROTECTED", "u2", map[string]identity.Profile{"u2": active("u2", true)}, graph.Snapshot{BlockedBy: set("u2")}, graph.Snapshot{}, ErrNotFound, 1},
		{"self, even when the owner is protected", testUID, map[string]identity.Profile{testUID: {UserID: testUID, Status: identity.AccountStatusActive, IsPrivate: true}}, graph.Snapshot{}, graph.Snapshot{}, nil, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newMemberEnv(oldAccount(), tt.profiles, map[string]graph.Snapshot{testUID: tt.owner, tt.target: tt.theirs})
			_, err := e.svc.AddMember(context.Background(), testUID, testKey, testListID, tt.target)
			if (err != nil) != (tt.want != nil) { // the fake repository applies the refusal as the real one does after its reads
				t.Fatalf("service err = %v, want a refusal: %v", err, tt.want)
			}
			if got := e.repo.addedBy[0].Refusal; !errors.Is(got, tt.want) || (got == nil) != (tt.want == nil) {
				t.Errorf("refusal = %v, want %v", got, tt.want)
			}
			if len(e.g.asked) != tt.asked {
				t.Errorf("graph snapshots read = %v, want %d", e.g.asked, tt.asked)
			}
		})
	}
}

// What reaches the repository: ids, hash, caps, quota tier by account age, and the owner's blockedBy for the lazy drop.
func TestAddMember_Params(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name    string
		created time.Time
		quota   int64
	}{
		{"old account", oldAccount(), 300},
		{"new account", testNow.Add(-time.Hour), 50},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newMemberEnv(tt.created, map[string]identity.Profile{"u2": active("u2", false)},
				map[string]graph.Snapshot{testUID: {BlockedBy: set("bad")}})
			v, err := e.svc.AddMember(context.Background(), testUID, testKey, testListID, "u2")
			if err != nil {
				t.Fatal(err)
			}
			p := e.repo.addedBy[0]
			if p.UID != testUID || p.ListID != testListID || p.TargetID != "u2" || p.MaxMembers != 150 || p.QuotaLimit != tt.quota || !p.BlockedBy["bad"] {
				t.Errorf("params = %+v", p)
			}
			if p.IdemKey == "" || p.RequestHash == "" || p.RequestHash == memberHash(testListID, "u3") {
				t.Errorf("idem %q hash %q", p.IdemKey, p.RequestHash)
			}
			if v.Header.ID != testListID || v.Owner.Handle != "owner" {
				t.Errorf("view = %+v", v)
			}
		})
	}
}

func TestAddMember_Validation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name            string
		key, list, user string
		field           string
	}{
		{"short key", "short", testListID, "u2", "idempotency_key"},
		{"bad list id", testKey, "123", "u2", "list_id"},
		{"empty user", testKey, testListID, "", "user_id"},
		{"underscore user", testKey, testListID, "a_b", "user_id"},
		{"too long user", testKey, testListID, strings.Repeat("a", 129), "user_id"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newMemberEnv(oldAccount(), map[string]identity.Profile{}, nil)
			_, err := e.svc.AddMember(context.Background(), testUID, tt.key, tt.list, tt.user)
			wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": tt.field})
			_, err = e.svc.RemoveMember(context.Background(), testUID, tt.key, tt.list, tt.user)
			wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": tt.field})
			if e.repo.calls() != 0 || len(e.g.asked) != 0 {
				t.Errorf("validation touched storage: %d repo calls, %v graph reads", e.repo.calls(), e.g.asked)
			}
		})
	}
}

// The repository's sentinels map to the wire contract; an unwired graph fails closed instead of skipping the block checks.
func TestAddMember_ErrorMapping(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		err  error
		code connect.Code
		rsn  commonv1.ErrorReason
		meta map[string]string
	}{
		{"member cap", ErrMemberLimit, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "list_members"}},
		{"protected", ErrProtected, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, nil},
		{"not found", ErrNotFound, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil},
		{"key reused", ErrKeyReused, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil},
		{
			"quota passes through", apierr.New(connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "x").WithMeta("quota", "list_adds"),
			connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, map[string]string{"quota": "list_adds"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newMemberEnv(oldAccount(), map[string]identity.Profile{"u2": active("u2", false)}, nil)
			e.repo.err = tt.err
			_, err := e.svc.AddMember(context.Background(), testUID, testKey, testListID, "u2")
			wantAPI(t, err, tt.code, tt.rsn, tt.meta)
		})
	}
	t.Run("graph not wired", func(t *testing.T) {
		t.Parallel()
		e := newMemberEnv(oldAccount(), map[string]identity.Profile{"u2": active("u2", false)}, nil)
		e.svc.d.Graph = nil
		if _, err := e.svc.AddMember(context.Background(), testUID, testKey, testListID, "u2"); err == nil || e.repo.calls() != 0 {
			t.Errorf("err = %v, repo calls %d: want a failure before storage", err, e.repo.calls())
		}
	})
	t.Run("graph error", func(t *testing.T) {
		t.Parallel()
		e := newMemberEnv(oldAccount(), map[string]identity.Profile{"u2": active("u2", false)}, nil)
		e.g.err = errors.New("boom")
		if _, err := e.svc.AddMember(context.Background(), testUID, testKey, testListID, "u2"); err == nil || e.repo.calls() != 0 {
			t.Errorf("err = %v, repo calls %d: want a failure before storage", err, e.repo.calls())
		}
	})
	t.Run("caller without a profile", func(t *testing.T) {
		t.Parallel()
		e := newMemberEnv(oldAccount(), map[string]identity.Profile{}, nil)
		delete(e.dir.profiles, testUID)
		_, err := e.svc.AddMember(context.Background(), testUID, testKey, testListID, "u2")
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, nil)
	})
}

// The instance cache is filled from the written list, evicted for a private one, and left alone on a replay.
func TestMemberWrites_Cache(t *testing.T) {
	t.Parallel()
	pub := List{ID: testListID, OwnerID: testUID, MemberIDs: []string{"u2"}}
	priv := List{ID: testListID, OwnerID: testUID, IsPrivate: true, MemberIDs: []string{"u2"}}
	tests := []struct {
		name   string
		seed   bool
		result MemberResult
		cached bool
	}{
		{"public write fills", false, MemberResult{Outcome: Written, List: &pub}, true},
		{"private write evicts", true, MemberResult{Outcome: Written, List: &priv}, false},
		{"no-op on a public list refreshes", false, MemberResult{Outcome: Unchanged, List: &pub}, true},
		{"replay leaves the entry", true, MemberResult{Outcome: Replayed}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newMemberEnv(oldAccount(), map[string]identity.Profile{"u2": active("u2", false)}, nil)
			if tt.seed {
				e.svc.cache.put(pub)
			}
			e.repo.member = tt.result
			if _, err := e.svc.AddMember(context.Background(), testUID, testKey, testListID, "u2"); err != nil {
				t.Fatal(err)
			}
			if _, ok := e.svc.cache.get(testListID); ok != tt.cached {
				t.Errorf("cached = %v, want %v", ok, tt.cached)
			}
		})
	}
}

// RemoveMember reads the owner's graph only through the lazy hook (the repository decides whether to call it) and survives a
// graph failure: the clean-up is best effort.
func TestRemoveMember_LazyDropHook(t *testing.T) {
	t.Parallel()
	e := newMemberEnv(oldAccount(), map[string]identity.Profile{}, map[string]graph.Snapshot{testUID: {BlockedBy: set("bad")}})
	if _, err := e.svc.RemoveMember(context.Background(), testUID, testKey, testListID, "u2"); err != nil {
		t.Fatal(err)
	}
	if len(e.g.asked) != 0 {
		t.Errorf("RemoveMember read the graph itself: %v", e.g.asked)
	}
	p := e.repo.removedBy[0]
	if p.TargetID != "u2" || p.ListID != testListID || p.UID != testUID || !p.BlockedBy(context.Background())["bad"] {
		t.Errorf("params = %+v", p)
	}
	e.g.err = errors.New("boom")
	if got := p.BlockedBy(context.Background()); got != nil {
		t.Errorf("a failed graph read dropped %v, want nobody", got)
	}
}

func TestMemberHash_CoversListAndUser(t *testing.T) {
	t.Parallel()
	if memberHash("a", "b") == memberHash("a", "c") || memberHash("a", "b") == memberHash("c", "b") {
		t.Error("the request hash must cover list_id and user_id")
	}
}

// dropBlocking keeps the stored order, never aliases its input and returns a non-nil slice (an empty array is stored as an array).
func TestDropBlocking(t *testing.T) {
	t.Parallel()
	in := []string{"a", "b", "c", "d"}
	tests := []struct {
		name string
		by   map[string]bool
		skip string
		want []string
	}{
		{"nothing", nil, "", []string{"a", "b", "c", "d"}},
		{"blockers go", set("b", "d"), "", []string{"a", "c"}},
		{"skip goes", nil, "c", []string{"a", "b", "d"}},
		{"both", set("a"), "d", []string{"b", "c"}},
		{"everything", set("a", "b", "c", "d"), "", []string{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := dropBlocking(in, tt.by, tt.skip)
			if got == nil || len(got) != len(tt.want) {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Fatalf("got %v, want %v", got, tt.want)
				}
			}
		})
	}
	if len(in) != 4 || in[1] != "b" {
		t.Errorf("input was changed: %v", in)
	}
}
