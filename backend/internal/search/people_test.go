package search

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// fakeDir is identity.Directory's SearchHandles over an in-memory user list, in handleLower order, counting calls.
type fakeDir struct {
	mu    sync.Mutex
	users []identity.Profile
	calls []string // "prefix/limit" per call
	err   error
}

func (d *fakeDir) SearchHandles(_ context.Context, prefix string, limit int) ([]identity.Profile, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.calls = append(d.calls, fmt.Sprintf("%s/%d", prefix, limit))
	if d.err != nil {
		return nil, d.err
	}
	var out []identity.Profile
	for _, u := range d.users {
		if strings.HasPrefix(u.HandleLower, prefix) && len(out) < limit {
			out = append(out, u)
		}
	}
	return out, nil
}

func (d *fakeDir) callCount() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.calls)
}

// peopleFakeGraph serves a snapshot per viewer and counts reads.
type peopleFakeGraph struct {
	mu    sync.Mutex
	snaps map[string]graph.Snapshot
	reads int
	err   error
}

func (g *peopleFakeGraph) Snapshot(_ context.Context, uid string) (graph.Snapshot, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.reads++
	return g.snaps[uid], g.err
}

func set(uids ...string) map[string]bool {
	m := map[string]bool{}
	for _, u := range uids {
		m[u] = true
	}
	return m
}

func user(handle string, opts ...func(*identity.Profile)) identity.Profile {
	p := identity.Profile{UserID: "u-" + handle, Handle: handle, HandleLower: strings.ToLower(handle), DisplayName: "Name " + handle,
		Status: identity.AccountStatusActive}
	for _, o := range opts {
		o(&p)
	}
	return p
}

func withStatus(s identity.AccountStatus) func(*identity.Profile) {
	return func(p *identity.Profile) { p.Status = s }
}
func private(p *identity.Profile) { p.IsPrivate = true }

func newTestService(t *testing.T, dir *fakeDir, g *peopleFakeGraph, entries int) *Server {
	t.Helper()
	reg := flags.NewRegistry(flags.Spec{Name: FlagSearch, Mode: flags.On}, flags.Spec{Name: FlagTrends, Mode: flags.On})
	return NewServer(New(reg, WithPeople(PeopleDeps{Directory: dir, Graph: g, PrefixEntries: entries})))
}

func callPeople(t *testing.T, srv *Server, uid, query string, limit int32) (*searchv1.SearchPeopleResponse, error) {
	t.Helper()
	resp, err := srv.SearchPeople(signedIn(uid), connect.NewRequest(&searchv1.SearchPeopleRequest{Query: query, Limit: limit}))
	if err != nil {
		return nil, err
	}
	return resp.Msg, nil
}

func handles(r *searchv1.SearchPeopleResponse) []string {
	var out []string
	for _, u := range r.GetUsers() {
		out = append(out, u.GetUser().GetHandle())
	}
	return out
}

// TestPeopleFilters: the per-viewer rules of ADR-0028 D2 steps 3 to 7, one table.
func TestPeopleFilters(t *testing.T) {
	const me = "u-me"
	all := []identity.Profile{
		user("alice"),
		user("alicia", withStatus(identity.AccountStatusSuspended)),
		user("alina", withStatus(identity.AccountStatusDeleting)),
		user("alison", private),
		user("allan"),
		user("alma"),
		{UserID: me, Handle: "ali", HandleLower: "ali", Status: identity.AccountStatusActive},
	}
	// ali (the viewer) sorts before alice in handle order: reorder so the fake returns handle order.
	all = []identity.Profile{all[6], all[0], all[1], all[2], all[3], all[4], all[5]}
	tests := []struct {
		name string
		snap graph.Snapshot
		want []string
	}{
		{"no relationships: suspended and deleting are gone, the viewer stays",
			graph.Snapshot{}, []string{"ali", "alice", "alison", "allan", "alma"}},
		{"a user who blocked the viewer is absent",
			graph.Snapshot{BlockedBy: set("u-alice")}, []string{"ali", "alison", "allan", "alma"}},
		{"a user the viewer blocks or mutes stays",
			graph.Snapshot{Blocked: set("u-alice"), Muted: set("u-allan")}, []string{"ali", "alice", "alison", "allan", "alma"}},
		{"blockedBy overflow keeps the viewer and followed accounts only",
			graph.Snapshot{BlockedByOverflow: true, Following: set("u-alison", "u-alma")}, []string{"ali", "alison", "alma"}},
		{"blockedBy overflow, a followed account that also blocked the viewer is still dropped",
			graph.Snapshot{BlockedByOverflow: true, Following: set("u-alison"), BlockedBy: set("u-alison")}, []string{"ali"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			g := &peopleFakeGraph{snaps: map[string]graph.Snapshot{me: tc.snap}}
			srv := newTestService(t, &fakeDir{users: all}, g, 10)
			resp, err := callPeople(t, srv, me, "@Al", 20)
			if err != nil {
				t.Fatal(err)
			}
			if got := handles(resp); strings.Join(got, ",") != strings.Join(tc.want, ",") {
				t.Errorf("handles = %v, want %v", got, tc.want)
			}
			if resp.GetUnsupportedQuery() {
				t.Error("unsupported_query set on a handle prefix")
			}
		})
	}
}

// TestPeopleRelationshipsAndPrivacy: relationship fields come from the caller's snapshot; protected accounts are listed
// with is_private; since is unset.
func TestPeopleRelationshipsAndPrivacy(t *testing.T) {
	const me = "u-me"
	dir := &fakeDir{users: []identity.Profile{user("bob"), user("bobby", private), user("bobbi"), user("bobo"), user("bobz")}}
	snap := graph.Snapshot{
		Following: set("u-bob"), Requested: set("u-bobby"), Blocked: set("u-bobbi"), Muted: set("u-bobo"),
	}
	srv := newTestService(t, dir, &peopleFakeGraph{snaps: map[string]graph.Snapshot{me: snap}}, 10)
	resp, err := callPeople(t, srv, me, "bob", 0)
	if err != nil {
		t.Fatal(err)
	}
	type row struct {
		state    graphv1.FollowState
		blocking bool
		muting   bool
		private  bool
	}
	want := map[string]row{
		"bob":   {state: graphv1.FollowState_FOLLOW_STATE_FOLLOWING},
		"bobby": {state: graphv1.FollowState_FOLLOW_STATE_REQUESTED, private: true},
		"bobbi": {state: graphv1.FollowState_FOLLOW_STATE_NONE, blocking: true},
		"bobo":  {state: graphv1.FollowState_FOLLOW_STATE_NONE, muting: true},
		"bobz":  {state: graphv1.FollowState_FOLLOW_STATE_NONE},
	}
	if len(resp.GetUsers()) != len(want) {
		t.Fatalf("rows = %v, want %d", handles(resp), len(want))
	}
	for _, u := range resp.GetUsers() {
		w := want[u.GetUser().GetHandle()]
		r := u.GetRelationship()
		got := row{r.GetFollowState(), r.GetBlocking(), r.GetMuting(), u.GetUser().GetIsPrivate()}
		if got != w {
			t.Errorf("%s: %+v, want %+v", u.GetUser().GetHandle(), got, w)
		}
		if r.GetUserId() != u.GetUser().GetUserId() {
			t.Errorf("%s: relationship user id %q, want %q", u.GetUser().GetHandle(), r.GetUserId(), u.GetUser().GetUserId())
		}
		if u.GetSince() != nil {
			t.Errorf("%s: since set", u.GetUser().GetHandle())
		}
	}
}

// TestPeopleBlockOracle: a user who blocked the viewer leaves the same bytes as a user who does not exist.
func TestPeopleBlockOracle(t *testing.T) {
	const me = "u-me"
	run := func(users []identity.Profile, snap graph.Snapshot) []byte {
		srv := newTestService(t, &fakeDir{users: users}, &peopleFakeGraph{snaps: map[string]graph.Snapshot{me: snap}}, 10)
		resp, err := callPeople(t, srv, me, "carol", 20)
		if err != nil {
			t.Fatal(err)
		}
		b, err := proto.MarshalOptions{Deterministic: true}.Marshal(resp)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	others := []identity.Profile{user("carolyn"), user("carols")}
	withBlocker := run(append([]identity.Profile{user("carol")}, others...), graph.Snapshot{BlockedBy: set("u-carol")})
	withoutUser := run(others, graph.Snapshot{})
	if !bytes.Equal(withBlocker, withoutUser) {
		t.Errorf("blocked-by response differs from the missing-user response: %x vs %x", withBlocker, withoutUser)
	}
}

// TestPeopleCache: the entry is shared across viewers and filtered per viewer, keyed by (prefix, limit), and a warm hit
// reads nothing from identity.
func TestPeopleCache(t *testing.T) {
	dir := &fakeDir{users: []identity.Profile{user("dave"), user("davey"), user("david")}}
	g := &peopleFakeGraph{snaps: map[string]graph.Snapshot{
		"v1": {},
		"v2": {BlockedBy: set("u-davey")},
	}}
	srv := newTestService(t, dir, g, 10)

	r1, err := callPeople(t, srv, "v1", "@dav", 5)
	if err != nil {
		t.Fatal(err)
	}
	r2, err := callPeople(t, srv, "v2", "DAV", 5) // same prefix and limit, other viewer, other case
	if err != nil {
		t.Fatal(err)
	}
	if n := dir.callCount(); n != 1 {
		t.Errorf("identity calls = %d, want 1 (shared warm entry)", n)
	}
	if got := strings.Join(handles(r1), ","); got != "dave,davey,david" {
		t.Errorf("v1 = %s", got)
	}
	if got := strings.Join(handles(r2), ","); got != "dave,david" {
		t.Errorf("v2 = %s: the entry must be filtered per viewer", got)
	}
	// Another limit is another key.
	if _, err := callPeople(t, srv, "v1", "dav", 6); err != nil {
		t.Fatal(err)
	}
	if n := dir.callCount(); n != 2 {
		t.Errorf("identity calls = %d, want 2 after a different limit", n)
	}
	// A cached entry is not edited by filtering: v1 still sees davey afterwards.
	r3, _ := callPeople(t, srv, "v1", "dav", 5)
	if got := strings.Join(handles(r3), ","); got != "dave,davey,david" {
		t.Errorf("v1 after v2 = %s: the shared entry was mutated", got)
	}
}

// TestPeopleEmptyEntrySkipsGraph: no match, no graph read (7 reads at limit 5 become interceptor + 1).
func TestPeopleEmptyEntrySkipsGraph(t *testing.T) {
	g := &peopleFakeGraph{snaps: map[string]graph.Snapshot{}}
	srv := newTestService(t, &fakeDir{}, g, 10)
	resp, err := callPeople(t, srv, "v1", "zz", 5)
	if err != nil || len(resp.GetUsers()) != 0 || resp.GetUnsupportedQuery() {
		t.Fatalf("resp = %v, err %v; want an empty, supported answer", resp, err)
	}
	if g.reads != 0 {
		t.Errorf("graph reads = %d, want 0", g.reads)
	}
}

// TestPeopleLimit: 0 means 10, above 20 clamps, negative is VALIDATION; the post-filter cut keeps handle order.
func TestPeopleLimit(t *testing.T) {
	var users []identity.Profile
	for i := 0; i < 30; i++ {
		users = append(users, user(fmt.Sprintf("many%02d", i)))
	}
	tests := []struct {
		name     string
		limit    int32
		wantCall string
		wantRows int
		wantErr  string
	}{
		{"default", 0, "many/10", 10, ""},
		{"explicit", 5, "many/5", 5, ""},
		{"max", 20, "many/20", 20, ""},
		{"clamped", 99, "many/20", 20, ""},
		{"negative", -1, "", 0, "limit"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := &fakeDir{users: users}
			srv := newTestService(t, dir, &peopleFakeGraph{}, 10)
			resp, err := callPeople(t, srv, "v1", "many", tc.limit)
			if tc.wantErr != "" {
				ae := apiErr(t, err)
				if ae.Code != connect.CodeInvalidArgument || ae.Metadata["field"] != tc.wantErr {
					t.Errorf("err = %v / %v, want INVALID_ARGUMENT field=%s", ae.Code, ae.Metadata, tc.wantErr)
				}
				if dir.callCount() != 0 {
					t.Error("identity was called on a rejected limit")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if len(resp.GetUsers()) != tc.wantRows || dir.calls[0] != tc.wantCall {
				t.Errorf("rows = %d, call = %v; want %d and %s", len(resp.GetUsers()), dir.calls, tc.wantRows, tc.wantCall)
			}
			if got := resp.GetUsers()[0].GetUser().GetHandle(); got != "many00" {
				t.Errorf("first row = %s, want many00 (handle order)", got)
			}
		})
	}
}

// TestPeopleQueryRules: validation and unsupported answers cost 0 identity and graph reads.
func TestPeopleQueryRules(t *testing.T) {
	tests := []struct {
		name            string
		query           string
		wantInvalid     bool
		wantUnsupported bool
		tooShort        bool
	}{
		{"empty", "", true, false, false},
		{"sigil only", "@", true, false, false},
		{"51 characters", strings.Repeat("a", 51), true, false, false},
		{"control character", "a\tb", true, false, false},
		{"one character", "a", true, false, true},
		{"one character with @", "@a", true, false, true},
		{"tag sigil", "#go", false, true, false},
		{"two words", "go lang", false, true, false},
		{"16 characters", "abcdefghijklmnop", false, true, false},
		{"non-ASCII", "café", false, true, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir, g := &fakeDir{}, &peopleFakeGraph{}
			srv := newTestService(t, dir, g, 10)
			resp, err := callPeople(t, srv, "v1", tc.query, 0)
			if dir.callCount() != 0 || g.reads != 0 {
				t.Errorf("reads: identity %d, graph %d; want 0 and 0", dir.callCount(), g.reads)
			}
			if tc.wantInvalid {
				ae := apiErr(t, err)
				if ae.Code != connect.CodeInvalidArgument || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != "query" {
					t.Errorf("err = %v / %v / %v, want INVALID_ARGUMENT VALIDATION field=query", ae.Code, ae.Reason, ae.Metadata)
				}
				if tc.tooShort && !strings.Contains(ae.Message, "short") {
					t.Errorf("message %q does not say too short", ae.Message)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if resp.GetUnsupportedQuery() != tc.wantUnsupported || len(resp.GetUsers()) != 0 {
				t.Errorf("resp = %v, want unsupported_query=%v and no users", resp, tc.wantUnsupported)
			}
		})
	}
}

// TestPeopleFlagModes: with the reader wired, an RPC refused by its flag reads nothing, in every mode.
func TestPeopleFlagModes(t *testing.T) {
	const in, out = "uid-in", "uid-out"
	modes := []struct {
		name    string
		spec    flags.Spec
		wantIn  bool
		wantOut bool
	}{
		{"off", flags.Spec{Name: FlagSearch, Mode: flags.Off}, false, false},
		{"allowlist", flags.Spec{Name: FlagSearch, Mode: flags.Allowlist, Allowlist: map[string]struct{}{in: {}}}, true, false},
		{"percent 0 + allowlist", flags.Spec{Name: FlagSearch, Mode: flags.Percent, Percent: 0, Allowlist: map[string]struct{}{in: {}}}, true, false},
		{"percent 100", flags.Spec{Name: FlagSearch, Mode: flags.Percent, Percent: 100}, true, true},
		{"on", flags.Spec{Name: FlagSearch, Mode: flags.On}, true, true},
	}
	for _, m := range modes {
		t.Run(m.name, func(t *testing.T) {
			dir, g := &fakeDir{users: []identity.Profile{user("erin")}}, &peopleFakeGraph{}
			// FEATURE_TRENDS on must not open search.
			reg := flags.NewRegistry(m.spec, flags.Spec{Name: FlagTrends, Mode: flags.On})
			srv := NewServer(New(reg, WithPeople(PeopleDeps{Directory: dir, Graph: g})))
			for uid, wantOn := range map[string]bool{in: m.wantIn, out: m.wantOut} {
				resp, err := callPeople(t, srv, uid, "er", 0)
				if wantOn {
					if err != nil || len(resp.GetUsers()) != 1 {
						t.Errorf("%s: resp %v err %v, want one row", uid, resp, err)
					}
					continue
				}
				ae := apiErr(t, err)
				if ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != FlagSearch {
					t.Errorf("%s: %v %v, want FEATURE_DISABLED feature=search", uid, ae.Reason, ae.Metadata)
				}
			}
			if !m.wantOut && !m.wantIn && (dir.callCount() != 0 || g.reads != 0) {
				t.Errorf("a disabled flag read identity %d / graph %d times", dir.callCount(), g.reads)
			}
		})
	}
}

// TestPeopleErrors: dependency failures are INTERNAL without the caller's uid; a canceled call is not a server fault.
func TestPeopleErrors(t *testing.T) {
	boom := errors.New("firestore: rpc error for users/uid-secret")
	tests := []struct {
		name     string
		dirErr   error
		graphErr error
		wantCode connect.Code
		isAPI    bool
	}{
		{"identity fails", boom, nil, 0, false},
		{"graph fails", nil, boom, 0, false},
		{"canceled", context.Canceled, nil, connect.CodeCanceled, true},
		{"deadline", nil, context.DeadlineExceeded, connect.CodeDeadlineExceeded, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := &fakeDir{users: []identity.Profile{user("fran")}, err: tc.dirErr}
			g := &peopleFakeGraph{snaps: map[string]graph.Snapshot{}, err: tc.graphErr}
			_, err := callPeople(t, newTestService(t, dir, g, 10), "uid-secret", "fr", 0)
			if err == nil {
				t.Fatal("want an error")
			}
			if tc.isAPI {
				if ae := apiErr(t, err); ae.Code != tc.wantCode {
					t.Errorf("code = %v, want %v", ae.Code, tc.wantCode)
				}
				return
			}
			if !errors.Is(err, boom) {
				t.Errorf("cause lost: %v", err)
			}
			if strings.Contains(err.Error(), "uid-secret") {
				t.Errorf("error text leaks the caller's uid: %v", err)
			}
		})
	}
}
