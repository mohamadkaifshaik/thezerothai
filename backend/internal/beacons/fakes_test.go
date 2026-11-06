package beacons

import (
	"context"
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

const (
	testKey       = "0123456789abcdef0123"
	testBeaconID  = "0000000000000000042"
	testCommunity = "1234567890123456789"
	testOrganiser = "org-1"
	testViewer    = "viewer-1"
)

// fakeRepo records the params it was given and answers with canned results. Guarded by a mutex so a parallel test stays
// race free.
type fakeRepo struct {
	mu sync.Mutex

	create CreateResult
	update UpdateResult
	cancel CancelResult
	err    error

	createdBy   []CreateParams
	updatedBy   []UpdateParams
	cancelledBy []CancelParams

	// read side
	docs    map[string]Beacon
	rows    []Beacon
	queries []ListQuery
}

func (f *fakeRepo) Create(_ context.Context, p CreateParams) (CreateResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.createdBy = append(f.createdBy, p)
	if f.err != nil {
		return CreateResult{}, f.err
	}
	res := f.create
	if res.Beacon.ID == "" {
		res.Beacon = p.Beacon
		res.Beacon.ID, res.Beacon.OrganiserID, res.Beacon.Status = p.ID, p.UID, StatusOpen
	}
	return res, nil
}

func (f *fakeRepo) Update(_ context.Context, p UpdateParams) (UpdateResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.updatedBy = append(f.updatedBy, p)
	return f.update, f.err
}

func (f *fakeRepo) Cancel(_ context.Context, p CancelParams) (CancelResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cancelledBy = append(f.cancelledBy, p)
	return f.cancel, f.err
}

func (f *fakeRepo) Get(_ context.Context, id string) (Beacon, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if b, ok := f.docs[id]; ok {
		return b, nil
	}
	return Beacon{}, ErrNotFound
}

func (f *fakeRepo) ListByAudience(_ context.Context, q ListQuery) ([]Beacon, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.queries = append(f.queries, q)
	if f.err != nil {
		return nil, f.err
	}
	n := min(len(f.rows), max(q.Limit, 0))
	return append([]Beacon(nil), f.rows[:n]...), nil
}

func (f *fakeRepo) calls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.createdBy) + len(f.updatedBy) + len(f.cancelledBy) + len(f.queries)
}

// fakeDirectory serves one profile map; the embedded nil interface panics on any method the service must not call.
type fakeDirectory struct {
	identity.Directory
	profiles map[string]identity.Profile
	err      error
	mu       sync.Mutex
	calls    int
}

func (d *fakeDirectory) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	d.mu.Lock()
	d.calls++
	d.mu.Unlock()
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if p, ok := d.profiles[u]; ok {
			out[u] = p
		}
	}
	return out, d.err
}

// fakeGraph serves one snapshot per uid; an unknown uid is an empty snapshot.
type fakeGraph struct {
	snaps map[string]graph.Snapshot
	err   error
}

func (g *fakeGraph) Snapshot(_ context.Context, uid string) (graph.Snapshot, error) {
	if g.err != nil {
		return graph.Snapshot{}, g.err
	}
	return g.snaps[uid], nil
}

// fakeCommunities answers Role from a "cid|uid" map (absent = RoleNone) and counts the calls.
type fakeCommunities struct {
	communities.Reader
	roles map[string]communities.Role
	err   error
	mu    sync.Mutex
	calls int
}

func (c *fakeCommunities) Role(_ context.Context, communityID, uid string) (communities.Role, error) {
	c.mu.Lock()
	c.calls++
	c.mu.Unlock()
	if c.err != nil {
		return communities.RoleNone, c.err
	}
	return c.roles[communityID+"|"+uid], nil
}

// fakeFlags: Enabled answers on[name] for any uid; GloballyOff answers off[name].
type fakeFlags struct {
	on  map[string]bool
	off map[string]bool
}

func (f fakeFlags) Enabled(_, name string) bool  { return f.on[name] }
func (f fakeFlags) GloballyOff(name string) bool { return f.off[name] }

func activeProfile(uid string) identity.Profile {
	return identity.Profile{UserID: uid, Handle: uid, DisplayName: uid, Status: identity.AccountStatusActive}
}

// env is one service under test with every fake reachable.
type env struct {
	repo  *fakeRepo
	dir   *fakeDirectory
	graph *fakeGraph
	comm  *fakeCommunities
	flags fakeFlags
	now   time.Time
	svc   Service
}

func newEnv() *env {
	e := &env{
		repo:  &fakeRepo{docs: map[string]Beacon{}},
		dir:   &fakeDirectory{profiles: map[string]identity.Profile{testOrganiser: activeProfile(testOrganiser), testViewer: activeProfile(testViewer)}},
		graph: &fakeGraph{snaps: map[string]graph.Snapshot{}},
		comm:  &fakeCommunities{roles: map[string]communities.Role{}},
		flags: fakeFlags{on: map[string]bool{communities.FlagName: true}, off: map[string]bool{}},
		now:   testNow,
	}
	e.svc = New(Deps{
		Repo: e.repo, Directory: e.dir, Graph: e.graph, Communities: e.comm, CommunityFlags: e.flags, IDs: fakeIDs{},
		CursorKey: []byte("0123456789abcdef0123456789abcdef"), Limits: Limits{MaxOpenPerUser: 5, MaxPendingRequests: 10, MaxOpenSpots: 20},
		Now: func() time.Time { return e.now },
	})
	return e
}

type fakeIDs struct{}

func (fakeIDs) Generate() string { return testBeaconID }

// openBeacon is a visible public beacon organised by testOrganiser, starting in an hour.
func (e *env) openBeacon() Beacon {
	start := e.now.Add(time.Hour)
	return Beacon{
		ID: testBeaconID, OrganiserID: testOrganiser, Activity: ActivityCoffee, Title: "Coffee", Venue: "Hall",
		StartAt: start, EndAt: start.Add(25 * time.Minute), DurationMin: 25, OpenSpots: 3, Cost: CostFree, ChatPref: ChatQuiet,
		Status: StatusOpen, CreatedAt: e.now, UpdatedAt: e.now,
	}
}

func validCreate() CreateInput {
	return CreateInput{
		Key: testKey, Public: true, Activity: ActivityCoffee, Title: "Coffee", Details: "", Venue: "Hall",
		StartAt: testNow.Add(time.Hour), DurationMin: 25, OpenSpots: 3, Cost: CostFree, ChatPref: ChatQuiet,
	}
}
