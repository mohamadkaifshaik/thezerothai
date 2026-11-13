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

	// participation (PR 3)
	participants map[string]Participant // key beaconID|uid
	presult      ParticipantResult
	perr         error
	requestedBy  []RequestParams
	respondedBy  []RespondParams
	transitioned []StateParams
	memberships  []Membership
	// theirs is the peer side of GetMemberships, keyed uid|beaconID; mgets records each batch.
	theirs        map[string]Membership
	mgets         []participantBatch
	mqueries      []MembershipQuery
	plist         []Participant
	plistErr      error // ListParticipants only (the shared err would also fail the cancel)
	plistFails    int   // with plistErr: fail only the first plistFails calls (0 = every call)
	pqueries      []ParticipantQuery
	beaconBatches [][]string
	respondDone   map[string]ParticipantResult // idempotency key + request hash -> committed Respond result
	requestDone   map[string]ParticipantResult // idempotency key + request hash -> committed Request result
	prechecks     int                          // Request prechecks run
	// GetParticipants calls: the uid and the beacon ids of each batch.
	participantBatches []participantBatch
}

type participantBatch struct {
	uid string
	ids []string
}

func (f *fakeRepo) GetParticipants(_ context.Context, uid string, beaconIDs []string) (map[string]Participant, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.participantBatches = append(f.participantBatches, participantBatch{uid: uid, ids: append([]string(nil), beaconIDs...)})
	out := map[string]Participant{}
	for _, id := range beaconIDs {
		if p, ok := f.participants[f.pkey(id, uid)]; ok {
			out[id] = p
		}
	}
	return out, f.err
}

func (f *fakeRepo) pkey(beaconID, uid string) string { return beaconID + "|" + uid }

// Request emulates the repository's idempotency like Respond: a key in requestDone replays its stored result without
// running p.Precheck; otherwise a canned perr refuses first (the beacon and row checks precede Precheck), then Precheck
// runs (a refusal writes nothing and is not recorded) and a success is stored.
func (f *fakeRepo) Request(ctx context.Context, p RequestParams) (ParticipantResult, error) {
	f.mu.Lock()
	if res, ok := f.requestDone[p.IdemKey+"|"+p.RequestHash]; ok {
		f.mu.Unlock()
		res.Outcome = Replayed
		return res, nil
	}
	if f.perr != nil {
		defer f.mu.Unlock()
		f.requestedBy = append(f.requestedBy, p)
		return f.presult, f.perr
	}
	f.mu.Unlock()
	if p.Precheck != nil {
		f.mu.Lock()
		f.prechecks++
		f.mu.Unlock()
		if err := p.Precheck(ctx); err != nil {
			return ParticipantResult{}, err
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requestedBy = append(f.requestedBy, p)
	if f.requestDone == nil {
		f.requestDone = map[string]ParticipantResult{}
	}
	f.requestDone[p.IdemKey+"|"+p.RequestHash] = f.presult
	return f.presult, f.perr
}

func (f *fakeRepo) Withdraw(_ context.Context, p StateParams) (ParticipantResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.transitioned = append(f.transitioned, p)
	return f.presult, f.perr
}

// Respond emulates the repository's idempotency: a key in respondDone replays its stored result without running
// p.Precheck; otherwise Precheck runs first (a refusal writes nothing and is not recorded) and a success is stored.
func (f *fakeRepo) Respond(ctx context.Context, p RespondParams) (ParticipantResult, error) {
	f.mu.Lock()
	if res, ok := f.respondDone[p.IdemKey+"|"+p.RequestHash]; ok {
		f.mu.Unlock()
		res.Outcome = Replayed
		return res, nil
	}
	f.mu.Unlock()
	if p.Precheck != nil {
		if err := p.Precheck(ctx); err != nil {
			return ParticipantResult{}, err
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.respondedBy = append(f.respondedBy, p)
	if f.perr == nil {
		if f.respondDone == nil {
			f.respondDone = map[string]ParticipantResult{}
		}
		f.respondDone[p.IdemKey+"|"+p.RequestHash] = f.presult
	}
	return f.presult, f.perr
}

func (f *fakeRepo) Leave(_ context.Context, p StateParams) (ParticipantResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.transitioned = append(f.transitioned, p)
	return f.presult, f.perr
}

func (f *fakeRepo) Remove(_ context.Context, p StateParams) (ParticipantResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.transitioned = append(f.transitioned, p)
	return f.presult, f.perr
}

func (f *fakeRepo) GetParticipant(_ context.Context, beaconID, uid string) (Participant, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if p, ok := f.participants[f.pkey(beaconID, uid)]; ok {
		return p, nil
	}
	return Participant{}, ErrNotFound
}

func (f *fakeRepo) ListMemberships(_ context.Context, q MembershipQuery) ([]Membership, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.mqueries = append(f.mqueries, q)
	n := min(len(f.memberships), max(q.Limit, 0))
	return append([]Membership(nil), f.memberships[:n]...), f.err
}

func (f *fakeRepo) GetMemberships(_ context.Context, uid string, beaconIDs []string) (map[string]Membership, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.mgets = append(f.mgets, participantBatch{uid: uid, ids: append([]string(nil), beaconIDs...)})
	out := map[string]Membership{}
	for _, id := range beaconIDs {
		if m, ok := f.theirs[uid+"|"+id]; ok {
			out[id] = m
		}
	}
	return out, f.err
}

func (f *fakeRepo) GetBeacons(_ context.Context, ids []string) (map[string]Beacon, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.beaconBatches = append(f.beaconBatches, ids)
	out := map[string]Beacon{}
	for _, id := range ids {
		if b, ok := f.docs[id]; ok {
			out[id] = b
		}
	}
	return out, f.err
}

func (f *fakeRepo) ListParticipants(_ context.Context, q ParticipantQuery) ([]Participant, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pqueries = append(f.pqueries, q)
	if f.plistErr != nil && (f.plistFails == 0 || len(f.pqueries) <= f.plistFails) {
		return nil, f.plistErr
	}
	n := min(len(f.plist), max(q.Limit, 0))
	return append([]Participant(nil), f.plist[:n]...), f.err
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
	if f.err == nil && f.cancel.Outcome == Written && p.Stage != nil {
		p.Stage(nil, f.cancel.Beacon) // the in-transaction stage of a committed cancel
	}
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
	rows := f.rows
	if q.Activity != "" {
		rows = nil
		for _, b := range f.rows {
			if b.Activity == q.Activity {
				rows = append(rows, b)
			}
		}
	}
	n := min(len(rows), max(q.Limit, 0))
	return append([]Beacon(nil), rows[:n]...), nil
}

func (f *fakeRepo) calls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.createdBy) + len(f.updatedBy) + len(f.cancelledBy) + len(f.queries) +
		len(f.requestedBy) + len(f.respondedBy) + len(f.transitioned) + len(f.mqueries) + len(f.pqueries) + len(f.beaconBatches) + len(f.participantBatches) + len(f.mgets)
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

// fakeGraph serves one snapshot per uid; an unknown uid is an empty snapshot. err fails every read, errs[uid] only
// that uid's; calls counts the reads per uid.
type fakeGraph struct {
	snaps map[string]graph.Snapshot
	err   error
	errs  map[string]error
	mu    sync.Mutex
	calls map[string]int
	// lookups records the candidates of each FollowersAmong call (graph.FollowLookup); lookupErr fails every call.
	lookups   [][]string
	lookupErr error
}

// FollowersAmong answers from the candidates' own snapshots (Following[viewer]: the candidate follows the viewer; a
// Requested entry is not a follow) and records the call; it reads no snapshot (calls is untouched).
func (g *fakeGraph) FollowersAmong(_ context.Context, viewer string, candidates []string) (map[string]bool, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.lookups = append(g.lookups, append([]string(nil), candidates...))
	if g.lookupErr != nil {
		return nil, g.lookupErr
	}
	out := map[string]bool{}
	for _, c := range candidates {
		if g.snaps[c].Following[viewer] {
			out[c] = true
		}
	}
	return out, nil
}

func (g *fakeGraph) lookupCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.lookups)
}

func (g *fakeGraph) Snapshot(_ context.Context, uid string) (graph.Snapshot, error) {
	g.mu.Lock()
	if g.calls == nil {
		g.calls = map[string]int{}
	}
	g.calls[uid]++
	g.mu.Unlock()
	if g.err != nil {
		return graph.Snapshot{}, g.err
	}
	if err := g.errs[uid]; err != nil {
		return graph.Snapshot{}, err
	}
	return g.snaps[uid], nil
}

func (g *fakeGraph) readsOf(uid string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.calls[uid]
}

// fakeCommunities answers Role from a "cid|uid" map (absent = RoleNone) and Get from status (absent = ACTIVE; missing[cid]
// = ErrNotFound; getErr fails every Get), and counts the calls of both (calls) and of Get alone (gets).
type fakeCommunities struct {
	communities.Reader
	roles   map[string]communities.Role
	err     error
	status  map[string]communities.Status
	missing map[string]bool
	getErr  error
	mu      sync.Mutex
	calls   int
	gets    map[string]int
}

func (c *fakeCommunities) Get(_ context.Context, communityID string) (communities.Community, error) {
	c.mu.Lock()
	c.calls++
	if c.gets == nil {
		c.gets = map[string]int{}
	}
	c.gets[communityID]++
	c.mu.Unlock()
	if c.getErr != nil {
		return communities.Community{}, c.getErr
	}
	if c.missing[communityID] {
		return communities.Community{}, communities.ErrNotFound
	}
	st := communities.StatusActive
	if s, ok := c.status[communityID]; ok {
		st = s
	}
	return communities.Community{ID: communityID, Status: st}, nil
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
	repo   *fakeRepo
	dir    *fakeDirectory
	graph  *fakeGraph
	comm   *fakeCommunities
	flags  fakeFlags
	events *fakeEvents
	now    time.Time
	deps   Deps
	svc    Service
}

// fakeEvents records the outbound seam.
type fakeEvents struct {
	requested []ParticipationEvent
	accepted  []ParticipationEvent
	cancelled []CancelEvent
	updated   []UpdateEvent
	updateErr error
	// cancelErr fails the first cancelFails Cancelled calls (0 = every call) after recording them.
	cancelErr   error
	cancelFails int
}

func (f *fakeEvents) JoinRequested(_ context.Context, e ParticipationEvent) {
	f.requested = append(f.requested, e)
}
func (f *fakeEvents) RequestAccepted(_ context.Context, e ParticipationEvent) {
	f.accepted = append(f.accepted, e)
}
func (f *fakeEvents) Updated(_ context.Context, e UpdateEvent) error {
	f.updated = append(f.updated, e)
	return f.updateErr
}

func (f *fakeEvents) Cancelled(_ context.Context, e CancelEvent) error {
	f.cancelled = append(f.cancelled, e)
	if f.cancelErr != nil && (f.cancelFails == 0 || len(f.cancelled) <= f.cancelFails) {
		return f.cancelErr
	}
	return nil
}

func newEnv() *env {
	e := &env{
		repo:   &fakeRepo{docs: map[string]Beacon{}},
		dir:    &fakeDirectory{profiles: map[string]identity.Profile{testOrganiser: activeProfile(testOrganiser), testViewer: activeProfile(testViewer)}},
		graph:  &fakeGraph{snaps: map[string]graph.Snapshot{}},
		comm:   &fakeCommunities{roles: map[string]communities.Role{}},
		flags:  fakeFlags{on: map[string]bool{communities.FlagName: true}, off: map[string]bool{}},
		events: &fakeEvents{},
		now:    testNow,
	}
	e.deps = Deps{
		Repo: e.repo, Directory: e.dir, Graph: e.graph, Communities: e.comm, CommunityFlags: e.flags, Flags: e.flags, Follows: e.graph, IDs: fakeIDs{},
		CursorKey: []byte("0123456789abcdef0123456789abcdef"), Limits: Limits{MaxOpenPerUser: 5, MaxPendingRequests: 10, MaxOpenSpots: 20},
		Events: e.events, Now: func() time.Time { return e.now },
	}
	e.svc = New(e.deps)
	return e
}

// rebuild is a service over the same fakes with mod applied to the dependencies.
func (e *env) rebuild(mod func(*Deps)) Service {
	d := e.deps
	mod(&d)
	return New(d)
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
