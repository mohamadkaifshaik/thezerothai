package graph

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// Unit tests of ListSuggestedUsers (ADR-0024 D8, ticket W3-12) over fakes. The reads the fakes charge to the budget
// counter mirror the real repo and Directory (a snapshot read 1, an edge query one per document with a minimum of 1,
// hydration one per uid), so the cold and warm read caps are asserted here too. The interceptor's read is not part of
// the service: the documented 32 is 31 here plus that one (the config default EdgeLimit 20, ADR-0024 Amendment 2
// B1(b); 42 and 41 when a test pins EdgeLimit to 30).

const sugViewer = "uid-v"

// defaultColdReads is the most the service itself reads on a cold call at the default limits: the caller's graph 1,
// at most the default EdgeLimit 20 edges and at most the default HydrateMax 10 profiles.
const defaultColdReads = 1 + 20 + 10

// w312Server is w3Server with a repo, cache and directory behind it, for the flag matrix cases that pass the gate.
func w312Server(repo Repo, specs ...flags.Spec) *Server {
	svc := New(Deps{Flags: flags.NewRegistry(specs...), Repo: repo, Cache: NewCache(time.Minute)})
	svc.SetDirectory(&fakeDirectory{})
	return NewServer(svc)
}

type sugQuery struct {
	followers []string
	limit     int
}

// ListEdgesByFollowers satisfies Repo for the tests that never ask for suggestions: no edges, and the one read an
// empty query bills. sugRepo below replaces it with a real filter.
func (f *fakeRepo) ListEdgesByFollowers(ctx context.Context, _ []string, _ int) ([]Edge, error) {
	budget.FromContext(ctx).AddReads(1)
	return nil, nil
}

// sugRepo is fakeRepo plus the friends-of-friends query.
type sugRepo struct {
	*fakeRepo
	follows []Edge // every follow edge, newest first (the order the real query returns)
	queries []sugQuery
	edgeErr error
}

func (r *sugRepo) ListEdgesByFollowers(ctx context.Context, followers []string, limit int) ([]Edge, error) {
	r.queries = append(r.queries, sugQuery{followers: slices.Clone(followers), limit: limit})
	if r.edgeErr != nil {
		budget.FromContext(ctx).AddReads(1)
		return nil, r.edgeErr
	}
	var out []Edge
	for _, e := range r.follows {
		if slices.Contains(followers, e.FollowerID) && len(out) < limit {
			out = append(out, e)
		}
	}
	budget.FromContext(ctx).AddReads(int64(max(len(out), 1)))
	return out, nil
}

func (r *sugRepo) GetSnapshot(ctx context.Context, uid string) (Snapshot, error) {
	budget.FromContext(ctx).AddReads(1)
	return r.fakeRepo.GetSnapshot(ctx, uid)
}

// sugDir is fakeDirectory that records each hydration call and charges one read per uid (all cold).
type sugDir struct {
	*fakeDirectory
	calls [][]string
	// pause stops recording, for a Follow or Block in the middle of a test whose own Directory calls are not hydrations.
	pause bool
}

func (d *sugDir) GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error) {
	if !d.pause {
		d.calls = append(d.calls, slices.Clone(uids))
	}
	budget.FromContext(ctx).AddReads(int64(len(uids)))
	return d.fakeDirectory.GetProfiles(ctx, uids)
}

type sugEnv struct {
	svc  *service
	repo *sugRepo
	dir  *sugDir
	now  time.Time
}

// mkSnap builds a Snapshot for an account that follows following (oldest first, the stored order).
func mkSnap(following ...string) Snapshot {
	s := Snapshot{
		Following: map[string]bool{}, Blocked: map[string]bool{}, Muted: map[string]bool{},
		Requested: map[string]bool{}, BlockedBy: map[string]bool{},
		RecentFollowing: newestFirst(following, recentFollowingMax),
	}
	for _, f := range following {
		s.Following[f] = true
	}
	return s
}

// edgesOf builds follow edges newest first: each pair is {follower, followee}.
func edgesOf(pairs ...[2]string) []Edge {
	base := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	out := make([]Edge, len(pairs))
	for i, p := range pairs {
		out[i] = Edge{DocID: p[0] + "_" + p[1], FollowerID: p[0], FolloweeID: p[1], CreatedAt: base.Add(-time.Duration(i) * time.Minute)}
	}
	return out
}

// newSugEnv wires a service for the viewer sugViewer with the follow_suggestions flag on for every uid named in
// flagged (the viewer is always flagged). active are the uids that have an ACTIVE profile.
func newSugEnv(t *testing.T, lim SuggestionLimits, snap Snapshot, follows []Edge, active []string, opts ...func(*Deps)) *sugEnv {
	t.Helper()
	repo := &sugRepo{fakeRepo: newFakeRepo(), follows: follows}
	repo.snapshots[sugViewer] = snap
	dir := &sugDir{fakeDirectory: &fakeDirectory{profiles: map[string]identity.Profile{}}}
	for _, uid := range active {
		dir.profiles[uid] = identity.Profile{UserID: uid, Handle: "h" + uid, DisplayName: "N " + uid, Status: identity.AccountStatusActive}
	}
	on := map[string]bool{}
	for _, u := range []string{sugViewer, "uid-w"} {
		on[u+":graph"], on[u+":"+FollowSuggestionsFlagName] = true, true
	}
	deps := Deps{Flags: &fakeFlags{on: on}, Suggestions: lim}
	for _, o := range opts {
		o(&deps)
	}
	env := &sugEnv{repo: repo, dir: dir, now: time.Date(2026, 10, 27, 9, 0, 0, 0, time.UTC)}
	deps.Repo, deps.Cache = repo, NewCache(time.Minute)
	env.svc = New(deps)
	env.svc.SetDirectory(dir)
	env.svc.now = func() time.Time { return env.now }
	return env
}

func (e *sugEnv) list(t *testing.T, viewer string, maxRes int32) ([]string, *budget.Counter) {
	t.Helper()
	ctx, counter := budget.WithCounter(context.Background())
	items, err := e.svc.ListSuggestedUsers(ctx, viewer, maxRes)
	if err != nil {
		t.Fatalf("ListSuggestedUsers: %v", err)
	}
	return rowUIDs(items), counter
}

// follow, block and mute run the caller's mutation on this instance without recording its own Directory calls as
// hydrations.
func (e *sugEnv) follow(t *testing.T, target string) {
	t.Helper()
	e.dir.pause = true
	defer func() { e.dir.pause = false }()
	if _, err := e.svc.Follow(context.Background(), sugViewer, validKey, target); err != nil {
		t.Fatalf("Follow: %v", err)
	}
}

func (e *sugEnv) block(t *testing.T, target string) {
	t.Helper()
	e.dir.pause = true
	defer func() { e.dir.pause = false }()
	if _, err := e.svc.Block(context.Background(), sugViewer, validKey, target); err != nil {
		t.Fatalf("Block: %v", err)
	}
}

func (e *sugEnv) mute(t *testing.T, target string) {
	t.Helper()
	e.dir.pause = true
	defer func() { e.dir.pause = false }()
	if _, err := e.svc.Mute(context.Background(), sugViewer, validKey, target); err != nil {
		t.Fatalf("Mute: %v", err)
	}
}

func rowUIDs(items []ListItem) []string {
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.User.UserID
	}
	return out
}

func names(prefix string, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("%s-%02d", prefix, i)
	}
	return out
}

// TestListSuggestedUsers_ExclusionMatrix: self, following, requested, blocked, blockedBy and muted never come back,
// each on its own (ADR-0024 D8 step 4), and an excluded uid is not even sent to hydration (0 reads spent on it).
func TestListSuggestedUsers_ExclusionMatrix(t *testing.T) {
	tests := []struct {
		name string
		x    string // the candidate the matrix must drop
		mark func(*Snapshot, string)
	}{
		{"self", sugViewer, func(*Snapshot, string) {}},
		{"already following", "fe-02", func(*Snapshot, string) {}}, // fe-02 is one of the viewer's followees
		{"requested", "ca-x", func(s *Snapshot, x string) { s.Requested[x] = true }},
		{"blocked", "ca-x", func(s *Snapshot, x string) { s.Blocked[x] = true }},
		{"blockedBy", "ca-x", func(s *Snapshot, x string) { s.BlockedBy[x] = true }},
		{"muted", "ca-x", func(s *Snapshot, x string) { s.Muted[x] = true }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			snap := mkSnap("fe-00", "fe-01", "fe-02")
			tt.mark(&snap, tt.x)
			follows := edgesOf(
				[2]string{"fe-00", tt.x}, [2]string{"fe-00", "ca-1"},
				[2]string{"fe-01", "ca-2"}, [2]string{"fe-02", "ca-3"},
			)
			env := newSugEnv(t, SuggestionLimits{}, snap, follows, []string{tt.x, "ca-1", "ca-2", "ca-3"})
			got, _ := env.list(t, sugViewer, 5)
			if slices.Contains(got, tt.x) {
				t.Fatalf("result %v contains the excluded %s", got, tt.x)
			}
			if len(got) != 3 {
				t.Fatalf("result %v, want the three eligible friends of friends", got)
			}
			if len(env.dir.calls) != 1 || slices.Contains(env.dir.calls[0], tt.x) {
				t.Errorf("hydration calls %v: want exactly one, without %s", env.dir.calls, tt.x)
			}
		})
	}
}

// TestListSuggestedUsers_Ranking: more mutual followees first, then the stable hash of (viewer, candidate, IST day)
// for equal counts; the order is the same all day and is recomputed from the hash on another day.
func TestListSuggestedUsers_Ranking(t *testing.T) {
	snap := mkSnap("fe-00", "fe-01", "fe-02")
	follows := edgesOf(
		[2]string{"fe-00", "ca-a"}, [2]string{"fe-01", "ca-a"}, [2]string{"fe-02", "ca-a"}, // 3 mutual
		[2]string{"fe-00", "ca-b"}, [2]string{"fe-01", "ca-b"}, // 2
		[2]string{"fe-00", "ca-c"}, [2]string{"fe-01", "ca-d"}, [2]string{"fe-02", "ca-e"}, [2]string{"fe-02", "ca-f"}, // 1 each
	)
	active := []string{"ca-a", "ca-b", "ca-c", "ca-d", "ca-e", "ca-f"}
	ones := []string{"ca-c", "ca-d", "ca-e", "ca-f"}

	wantOn := func(day time.Time) []string {
		d := quota.TodayAt(day)
		sorted := slices.Clone(ones)
		slices.SortFunc(sorted, func(a, b string) int {
			ha, hb := tieBreak(sugViewer, a, d), tieBreak(sugViewer, b, d)
			switch {
			case ha < hb:
				return -1
			case ha > hb:
				return 1
			}
			return strings.Compare(a, b)
		})
		return append([]string{"ca-a", "ca-b"}, sorted...)
	}

	env := newSugEnv(t, SuggestionLimits{HydrateMax: 6, MaxResults: 5}, snap, follows, active)
	orders := map[string]bool{}
	for day := 0; day < 6; day++ {
		env.now = time.Date(2026, 10, 27, 9, 0, 0, 0, time.UTC).AddDate(0, 0, day)
		env.svc.suggested = newSuggestionCache(time.Hour) // a new day starts without the previous day's cache
		got, _ := env.list(t, sugViewer, 5)
		want := wantOn(env.now)[:5]
		if !slices.Equal(got, want) {
			t.Fatalf("day +%d: got %v, want %v", day, got, want)
		}
		again := slices.Clone(got)
		env.svc.suggested = newSuggestionCache(time.Hour)
		if got2, _ := env.list(t, sugViewer, 5); !slices.Equal(got2, again) {
			t.Fatalf("day +%d: a second computation changed the order: %v then %v", day, again, got2)
		}
		orders[strings.Join(got, ",")] = true
	}
	if len(orders) < 2 {
		t.Errorf("the order never changed across six days: %v", orders)
	}
}

// TestListSuggestedUsers_Sources: friends of friends versus the curated list (ADR-0024 D8 fallback), decided after the
// exclusion matrix; curated rows that are blocked, deleted or suspended are dropped.
func TestListSuggestedUsers_Sources(t *testing.T) {
	curated := []string{"cu-1", "cu-2", "cu-3", "cu-4"}
	tests := []struct {
		name        string
		snap        Snapshot
		follows     []Edge
		curated     []string
		active      []string
		wantUIDs    []string // exact, in order; nil = any order check via wantLen
		wantLen     int
		wantSource  string
		wantQueries int
	}{
		{
			name:    "three friends of friends: curated is not used",
			snap:    mkSnap("fe-00", "fe-01", "fe-02"),
			follows: edgesOf([2]string{"fe-00", "ca-1"}, [2]string{"fe-01", "ca-1"}, [2]string{"fe-02", "ca-2"}, [2]string{"fe-00", "ca-3"}),
			curated: curated, active: append([]string{"ca-1", "ca-2", "ca-3"}, curated...),
			wantLen: 3, wantSource: SuggestionSourceFriendsOfFriends, wantQueries: 1,
		},
		{
			name: "empty graph: curated only, no edge query",
			snap: mkSnap(), curated: curated, active: curated,
			wantUIDs: curated, wantSource: SuggestionSourceCurated, wantQueries: 0,
		},
		{
			name: "follows two accounts: curated only, no edge query",
			snap: mkSnap("fe-00", "fe-01"), follows: edgesOf([2]string{"fe-00", "ca-1"}, [2]string{"fe-01", "ca-2"}), curated: curated,
			active:   append([]string{"ca-1", "ca-2"}, curated...),
			wantUIDs: curated, wantSource: SuggestionSourceCurated, wantQueries: 0,
		},
		{
			name: "two friends of friends: they come first, curated fills after",
			snap: mkSnap("fe-00", "fe-01", "fe-02"), follows: edgesOf([2]string{"fe-00", "ca-1"}, [2]string{"fe-01", "ca-2"}), curated: curated,
			active:  append([]string{"ca-1", "ca-2"}, curated...),
			wantLen: 6, wantSource: SuggestionSourceCurated, wantQueries: 1,
		},
		{
			name: "no friends of friends at all: curated",
			snap: mkSnap("fe-00", "fe-01", "fe-02"), curated: curated, active: curated,
			wantUIDs: curated, wantSource: SuggestionSourceCurated, wantQueries: 1,
		},
		{
			name:    "a friend of friends the matrix drops does not count toward three",
			snap:    func() Snapshot { s := mkSnap("fe-00", "fe-01", "fe-02"); s.Blocked["ca-3"] = true; return s }(),
			follows: edgesOf([2]string{"fe-00", "ca-1"}, [2]string{"fe-01", "ca-2"}, [2]string{"fe-02", "ca-3"}), curated: curated,
			active:  append([]string{"ca-1", "ca-2", "ca-3"}, curated...),
			wantLen: 6, wantSource: SuggestionSourceCurated, wantQueries: 1,
		},
		{
			name:     "curated blocked, followed, deleted and suspended are dropped",
			snap:     func() Snapshot { s := mkSnap(); s.Blocked["cu-1"] = true; s.Following["cu-2"] = true; return s }(),
			curated:  append(slices.Clone(curated), "cu-gone", "cu-susp", "cu-ok"),
			active:   append(slices.Clone(curated), "cu-ok"), // cu-gone has no profile, cu-susp is suspended below
			wantUIDs: []string{"cu-3", "cu-4", "cu-ok"}, wantSource: SuggestionSourceCurated, wantQueries: 0,
		},
		{
			name: "a curated uid that is also a friend of friends appears once",
			snap: mkSnap("fe-00", "fe-01", "fe-02"), follows: edgesOf([2]string{"fe-00", "cu-1"}), curated: curated,
			active:   curated,
			wantUIDs: curated, wantSource: SuggestionSourceCurated, wantQueries: 1,
		},
		{
			name: "no curated list and an empty graph: nothing, no error",
			snap: mkSnap(), active: nil,
			wantUIDs: []string{}, wantSource: SuggestionSourceCurated, wantQueries: 0,
		},
		{
			name: "two friends of friends and no curated list: just those",
			snap: mkSnap("fe-00", "fe-01", "fe-02"), follows: edgesOf([2]string{"fe-00", "ca-1"}, [2]string{"fe-01", "ca-2"}),
			active:  []string{"ca-1", "ca-2"},
			wantLen: 2, wantSource: SuggestionSourceFriendsOfFriends, wantQueries: 1,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			lim := SuggestionLimits{CuratedUIDs: tt.curated, MaxResults: 5, HydrateMax: 10}
			env := newSugEnv(t, lim, tt.snap, tt.follows, tt.active)
			env.dir.profiles["cu-susp"] = identity.Profile{UserID: "cu-susp", Status: identity.AccountStatusSuspended}
			ctx, info := obsCtx()
			ctx, counter := budget.WithCounter(ctx)
			items, err := env.svc.ListSuggestedUsers(ctx, sugViewer, 10)
			if err != nil {
				t.Fatalf("ListSuggestedUsers: %v", err)
			}
			got := rowUIDs(items)
			if tt.wantUIDs != nil {
				// MaxResults 5 caps the visible rows; compare against the first five expected.
				want := tt.wantUIDs[:min(len(tt.wantUIDs), 5)]
				if !slices.Equal(got, want) {
					t.Errorf("rows = %v, want %v", got, want)
				}
			} else if len(got) != min(tt.wantLen, 5) {
				t.Errorf("rows = %v, want %d of them", got, min(tt.wantLen, 5))
			}
			if len(env.repo.queries) != tt.wantQueries {
				t.Errorf("edge queries = %d, want %d", len(env.repo.queries), tt.wantQueries)
			}
			if got := field(info, fieldSuggestSource); got != tt.wantSource {
				t.Errorf("source log field = %v, want %s", got, tt.wantSource)
			}
			budgettest.Assert(t, "ListSuggestedUsers", counter, budgettest.Budget{Reads: defaultColdReads})
			if len(items) > 0 && items[0].Relationship.FollowState != FollowStateNone {
				t.Errorf("relationship = %+v, want FollowStateNone", items[0].Relationship)
			}
		})
	}
}

// TestListSuggestedUsers_CapsAndCache: with 40 followees and 60 candidates the sample is the newest 30 followees, the
// query asks for EdgeLimit edges, hydration is ONE call of HydrateMax uids, the cold call reads exactly 1 + EdgeLimit +
// HydrateMax (31 at the config default 20, whose documented cap is 32 with the interceptor; 41 with EdgeLimit pinned to
// 30, cap 42, ADR-0024 Amendment 2 B1(b)) and the warm call reads nothing.
func TestListSuggestedUsers_CapsAndCache(t *testing.T) {
	for _, tt := range []struct {
		name                        string
		edgeLimit, wantLimit, reads int // edgeLimit 0 is the default that normalized() fills in
	}{
		{"config default edge limit 20: cold cap 32", 0, 20, 31},
		{"edge limit pinned to 30: cold cap 42", 30, 30, 41},
	} {
		t.Run(tt.name, func(t *testing.T) { checkCapsAndCache(t, tt.edgeLimit, tt.wantLimit, int64(tt.reads)) })
	}
}

func checkCapsAndCache(t *testing.T, edgeLimit, wantLimit int, wantCold int64) {
	t.Helper()
	followees := names("fe", 40) // oldest first, the stored order
	snap := mkSnap(followees...)
	var pairs [][2]string
	cands := names("ca", 60)
	for i, c := range cands {
		pairs = append(pairs, [2]string{followees[39-(i%30)], c}) // only the newest 30 followees follow candidates
	}
	env := newSugEnv(t, SuggestionLimits{SampleFollowees: 30, EdgeLimit: edgeLimit, HydrateMax: 10, MaxResults: 5}, snap, edgesOf(pairs...), cands)

	ctx, info := obsCtx()
	ctx, cold := budget.WithCounter(ctx)
	items, err := env.svc.ListSuggestedUsers(ctx, sugViewer, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 5 {
		t.Fatalf("rows = %d, want 5", len(items))
	}
	if len(env.repo.queries) != 1 {
		t.Fatalf("edge queries = %d, want 1", len(env.repo.queries))
	}
	q := env.repo.queries[0]
	if q.limit != wantLimit || len(q.followers) != 30 || q.followers[0] != "fe-39" || q.followers[29] != "fe-10" {
		t.Errorf("query = {limit %d, %d followers from %s to %s}, want the newest 30 followees fe-39..fe-10 and limit %d", q.limit, len(q.followers), q.followers[0], q.followers[len(q.followers)-1], wantLimit)
	}
	if len(env.dir.calls) != 1 || len(env.dir.calls[0]) != 10 {
		t.Fatalf("hydration calls = %v, want exactly one of 10 uids", env.dir.calls)
	}
	budgettest.Assert(t, "ListSuggestedUsers cold", cold, budgettest.Budget{Reads: wantCold})
	if cold.Reads() != wantCold {
		t.Errorf("cold reads = %d, want exactly %d (1 graph + %d edges + 10 profiles): the fixture must reach the cap", cold.Reads(), wantCold, wantLimit)
	}
	t.Logf("BUDGET ListSuggestedUsers cold reads=%d (+1 interceptor = %d, cap %d)", cold.Reads(), cold.Reads()+1, wantCold+1)
	if got := field(info, fieldSuggestCacheHit); got != false {
		t.Errorf("suggestions_cache_hit = %v on the cold call", got)
	}

	ctx2, info2 := obsCtx()
	ctx2, warm := budget.WithCounter(ctx2)
	again, err := env.svc.ListSuggestedUsers(ctx2, sugViewer, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(rowUIDs(again), rowUIDs(items)) {
		t.Errorf("warm rows %v differ from cold rows %v", rowUIDs(again), rowUIDs(items))
	}
	budgettest.Assert(t, "ListSuggestedUsers warm", warm, budgettest.Budget{})
	if len(env.repo.queries) != 1 || len(env.dir.calls) != 1 {
		t.Errorf("warm call touched storage: %d queries, %d hydrations", len(env.repo.queries), len(env.dir.calls))
	}
	if field(info2, fieldSuggestCacheHit) != true || field(info2, fieldSuggestSource) != SuggestionSourceFriendsOfFriends || field(info2, fieldSuggestCandidates) != int64(10) {
		t.Errorf("warm log fields: hit=%v source=%v candidates=%v", field(info2, fieldSuggestCacheHit), field(info2, fieldSuggestSource), field(info2, fieldSuggestCandidates))
	}

	// The caller cannot reach the cache through the returned slice.
	again[0] = ListItem{}
	if third, _ := env.list(t, sugViewer, 0); third[0] != items[0].User.UserID {
		t.Errorf("mutating a returned slice changed the cache: %v", third)
	}
}

// TestListSuggestedUsers_CuratedReadCap: the curated path reads the snapshot and hydration only (12 with the
// interceptor).
func TestListSuggestedUsers_CuratedReadCap(t *testing.T) {
	curated := names("cu", 20)
	env := newSugEnv(t, SuggestionLimits{CuratedUIDs: curated}, mkSnap(), nil, curated)
	got, counter := env.list(t, sugViewer, 5)
	if len(got) != 5 {
		t.Fatalf("rows = %v, want 5", got)
	}
	budgettest.Assert(t, "ListSuggestedUsers curated", counter, budgettest.Budget{Reads: 11})
	if len(env.repo.queries) != 0 {
		t.Errorf("edge queries = %d on the curated path", len(env.repo.queries))
	}
}

func TestListSuggestedUsers_MaxResults(t *testing.T) {
	curated := names("cu", 10)
	tests := []struct {
		req  int32
		want int
	}{{0, 5}, {-3, 5}, {1, 1}, {3, 3}, {5, 5}, {6, 5}, {1000, 5}}
	for _, tt := range tests {
		t.Run(fmt.Sprint(tt.req), func(t *testing.T) {
			env := newSugEnv(t, SuggestionLimits{CuratedUIDs: curated}, mkSnap(), nil, curated)
			if got, _ := env.list(t, sugViewer, tt.req); len(got) != tt.want {
				t.Errorf("max_results %d => %d rows, want %d", tt.req, len(got), tt.want)
			}
		})
	}
	t.Run("a smaller configured cap wins", func(t *testing.T) {
		env := newSugEnv(t, SuggestionLimits{CuratedUIDs: curated, MaxResults: 2}, mkSnap(), nil, curated)
		if got, _ := env.list(t, sugViewer, 5); len(got) != 2 {
			t.Errorf("rows = %v, want 2", got)
		}
	})
}

// TestListSuggestedUsers_CacheEviction: this instance's own mutations take the user out of the cached rows at once,
// the entry's expiry never stretches, and a warm hit is re-checked against a snapshot that is already cached.
func TestListSuggestedUsers_CacheEviction(t *testing.T) {
	curated := names("cu", 8)
	build := func(t *testing.T) *sugEnv {
		t.Helper()
		env := newSugEnv(t, SuggestionLimits{CuratedUIDs: curated, HydrateMax: 8, CacheTTL: time.Hour}, mkSnap(), nil, append(slices.Clone(curated), sugViewer, "uid-t"))
		env.repo.followResult = Relationship{UserID: "cu-00", FollowState: FollowStateFollowing}
		env.repo.followOutcome = OutcomeCreated
		return env
	}

	t.Run("Follow removes the followed uid and the tail refills", func(t *testing.T) {
		env := build(t)
		first, _ := env.list(t, sugViewer, 5)
		if !slices.Equal(first, curated[:5]) {
			t.Fatalf("first = %v", first)
		}
		env.follow(t, "cu-00")
		got, counter := env.list(t, sugViewer, 5)
		if want := curated[1:6]; !slices.Equal(got, want) {
			t.Errorf("after Follow = %v, want %v (cu-00 gone, the sixth row moved up)", got, want)
		}
		// Follow invalidated the caller's 60 s snapshot, so the re-filter of this warm hit loads graph/{viewer} once
		// (W3-22 L-1: the documented +1 on a warm hit without a cached snapshot). Nothing else is read: no edge query,
		// no hydration; the next call finds the refilled snapshot cache and costs 0.
		budgettest.Assert(t, "after Follow", counter, budgettest.Budget{Reads: 1})
		if len(env.repo.queries) != 0 || len(env.dir.calls) != 1 {
			t.Errorf("storage touched again: %d hydrations", len(env.dir.calls))
		}
		_, again := env.list(t, sugViewer, 5)
		budgettest.Assert(t, "second call after Follow", again, budgettest.Budget{})
	})

	t.Run("Block removes both directions", func(t *testing.T) {
		env := build(t)
		env.list(t, sugViewer, 5)
		// uid-t has its own cached rows naming the viewer.
		env.svc.suggested.put("uid-t", suggestionEntry{items: []ListItem{{User: identity.Profile{UserID: sugViewer}}, {User: identity.Profile{UserID: "cu-07"}}}}, env.now)
		env.repo.blockResult = BlockResult{Outcome: OutcomeCreated, Relationship: Relationship{UserID: "cu-00", Blocking: true}}
		env.block(t, "cu-00")
		if got, _ := env.list(t, sugViewer, 5); slices.Contains(got, "cu-00") {
			t.Errorf("blocked user still suggested: %v", got)
		}
		env.repo.blockResult = BlockResult{Outcome: OutcomeCreated, Relationship: Relationship{UserID: "uid-t", Blocking: true}}
		env.block(t, "uid-t")
		e, ok := env.svc.suggested.get("uid-t", env.now)
		if !ok || slices.Contains(rowUIDs(e.items), sugViewer) || !slices.Contains(rowUIDs(e.items), "cu-07") {
			t.Errorf("uid-t's rows = %v, want the viewer removed and cu-07 kept", rowUIDs(e.items))
		}
	})

	t.Run("Mute removes the muted uid", func(t *testing.T) {
		env := build(t)
		env.list(t, sugViewer, 5)
		env.repo.muteResult, env.repo.muteOutcome = Relationship{UserID: "cu-01", Muting: true}, OutcomeCreated
		env.mute(t, "cu-01")
		if got, _ := env.list(t, sugViewer, 5); slices.Contains(got, "cu-01") {
			t.Errorf("muted user still suggested: %v", got)
		}
	})

	t.Run("a replayed or failed Follow removes nothing", func(t *testing.T) {
		env := build(t)
		env.list(t, sugViewer, 5)
		env.repo.followOutcome = OutcomeReplay
		env.follow(t, "cu-00")
		if got, _ := env.list(t, sugViewer, 5); !slices.Equal(got, curated[:5]) {
			t.Errorf("after a replay = %v", got)
		}
	})

	t.Run("expiry is the original bound, not the last removal", func(t *testing.T) {
		env := build(t)
		env.list(t, sugViewer, 5)
		env.now = env.now.Add(50 * time.Minute)
		env.follow(t, "cu-00")
		env.list(t, sugViewer, 5) // still the 50 minute old entry
		if len(env.dir.calls) != 1 {
			t.Fatalf("hydrations = %d before expiry, want 1", len(env.dir.calls))
		}
		env.now = env.now.Add(11 * time.Minute) // 61 minutes after the build, 11 after the removal
		env.list(t, sugViewer, 5)
		if len(env.dir.calls) != 2 {
			t.Errorf("hydrations = %d after the original hour, want a rebuild (2)", len(env.dir.calls))
		}
	})

	t.Run("a cached snapshot hides a user who blocked the viewer", func(t *testing.T) {
		env := build(t)
		env.list(t, sugViewer, 5)
		snap := mkSnap()
		snap.BlockedBy["cu-02"] = true
		env.svc.cache.Set(sugViewer, snap)
		got, counter := env.list(t, sugViewer, 5)
		if want := []string{"cu-00", "cu-01", "cu-03", "cu-04", "cu-05"}; !slices.Equal(got, want) {
			t.Errorf("rows = %v, want %v (cu-02 hidden, the tail refilled)", got, want)
		}
		budgettest.Assert(t, "re-filtered hit", counter, budgettest.Budget{})
		// With an overflowed blockedBy nothing is shown from the cache either.
		snap.BlockedByOverflow = true
		env.svc.cache.Set(sugViewer, snap)
		if got, _ := env.list(t, sugViewer, 5); len(got) != 0 {
			t.Errorf("rows = %v with BlockedByOverflow, want none", got)
		}
	})

	t.Run("an empty answer is cached too", func(t *testing.T) {
		env := newSugEnv(t, SuggestionLimits{}, mkSnap(), nil, nil)
		env.list(t, sugViewer, 5)
		_, counter := env.list(t, sugViewer, 5)
		budgettest.Assert(t, "empty warm", counter, budgettest.Budget{})
		if len(env.dir.calls) != 0 {
			t.Errorf("hydration called for no candidates: %v", env.dir.calls)
		}
	})

	t.Run("entries are per viewer", func(t *testing.T) {
		env := build(t)
		env.repo.snapshots["uid-w"] = mkSnap()
		env.list(t, sugViewer, 5)
		env.svc.suggested.put("uid-w", suggestionEntry{items: []ListItem{{User: identity.Profile{UserID: "only-w"}}}}, env.now)
		if got, _ := env.list(t, "uid-w", 5); !slices.Equal(got, []string{"only-w"}) {
			t.Errorf("uid-w rows = %v", got)
		}
		if got, _ := env.list(t, sugViewer, 5); slices.Contains(got, "only-w") {
			t.Errorf("viewer rows = %v leak uid-w's entry", got)
		}
	})
}

// TestListSuggestedUsers_BlockedByOverflow: with an incomplete blockedBy a blocker could be suggested, so nothing is.
func TestListSuggestedUsers_BlockedByOverflow(t *testing.T) {
	snap := mkSnap("fe-00", "fe-01", "fe-02")
	snap.BlockedByOverflow = true
	env := newSugEnv(t, SuggestionLimits{CuratedUIDs: names("cu", 5)}, snap, edgesOf([2]string{"fe-00", "ca-1"}), append(names("cu", 5), "ca-1"))
	ctx, info := obsCtx()
	items, err := env.svc.ListSuggestedUsers(ctx, sugViewer, 5)
	if err != nil || len(items) != 0 {
		t.Fatalf("items %v err %v, want none", rowUIDs(items), err)
	}
	if len(env.repo.queries) != 0 || len(env.dir.calls) != 0 {
		t.Errorf("queries %d hydrations %d, want 0 and 0", len(env.repo.queries), len(env.dir.calls))
	}
	if got := field(info, fieldSuggestSource); got != SuggestionSourceNone {
		t.Errorf("source = %v, want %s", got, SuggestionSourceNone)
	}
}

// TestListSuggestedUsers_Errors: a storage failure is an error (nothing cached, the next call tries again) and its text
// carries no raw uid; a canceled request is CANCELED, not INTERNAL.
func TestListSuggestedUsers_Errors(t *testing.T) {
	snap := mkSnap("fe-00", "fe-01", "fe-02")
	follows := edgesOf([2]string{"fe-00", "ca-1"})
	t.Run("edge query", func(t *testing.T) {
		env := newSugEnv(t, SuggestionLimits{}, snap, follows, []string{"ca-1"})
		env.repo.edgeErr = errors.New("rpc error: documents/follows where followerId in [fe-00 fe-01 fe-02] for uid-v")
		_, err := env.svc.ListSuggestedUsers(context.Background(), sugViewer, 5)
		if err == nil {
			t.Fatal("want an error")
		}
		for _, raw := range []string{sugViewer, "fe-00", "fe-01", "fe-02"} {
			if strings.Contains(err.Error(), raw) {
				t.Errorf("error %q names the raw uid %s", err.Error(), raw)
			}
		}
		env.repo.edgeErr = nil
		if got, _ := env.list(t, sugViewer, 5); len(got) != 1 {
			t.Errorf("retry after the failure = %v, want the one candidate (a failure must not be cached)", got)
		}
		if len(env.repo.queries) != 2 {
			t.Errorf("queries = %d, want 2", len(env.repo.queries))
		}
	})
	t.Run("hydration", func(t *testing.T) {
		env := newSugEnv(t, SuggestionLimits{}, snap, follows, []string{"ca-1"})
		env.dir.err = errors.New("get ca-1 failed for uid-v")
		_, err := env.svc.ListSuggestedUsers(context.Background(), sugViewer, 5)
		if err == nil || strings.Contains(err.Error(), "ca-1") || strings.Contains(err.Error(), sugViewer) {
			t.Errorf("err = %v, want an error without raw uids", err)
		}
	})
	t.Run("snapshot", func(t *testing.T) {
		env := newSugEnv(t, SuggestionLimits{}, snap, follows, []string{"ca-1"})
		env.repo.err = errors.New("boom")
		if _, err := env.svc.ListSuggestedUsers(context.Background(), sugViewer, 5); err == nil {
			t.Error("want an error")
		}
	})
	t.Run("canceled", func(t *testing.T) {
		env := newSugEnv(t, SuggestionLimits{}, snap, follows, []string{"ca-1"})
		env.repo.edgeErr = fmt.Errorf("query: %w", context.Canceled)
		_, err := env.svc.ListSuggestedUsers(context.Background(), sugViewer, 5)
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Code != connect.CodeCanceled {
			t.Errorf("err = %v, want CANCELED", err)
		}
	})
}

// funcSuggester is a Suggester built from a function: the seam for option (b) or a precomputed source.
type funcSuggester func(ctx context.Context, viewer string, snap Snapshot) (Suggestion, error)

func (f funcSuggester) Suggest(ctx context.Context, viewer string, snap Snapshot) (Suggestion, error) {
	return f(ctx, viewer, snap)
}

// TestListSuggestedUsers_CustomSuggester: a different source changes no caller, and whatever it returns still goes
// through the exclusion matrix, de-duplication, the uid check and the HydrateMax cap before the one hydration call.
func TestListSuggestedUsers_CustomSuggester(t *testing.T) {
	snap := mkSnap("fe-00")
	snap.Blocked["bad-blocked"] = true
	snap.BlockedBy["bad-blockedby"] = true
	raw := []string{sugViewer, "fe-00", "bad-blocked", "bad-blockedby", "", "bad id!", "ok-1", "ok-1"}
	raw = append(raw, names("ok", 30)...)
	env := newSugEnv(t, SuggestionLimits{HydrateMax: 6}, snap, nil, names("ok", 30), func(d *Deps) {
		d.Suggester = funcSuggester(func(context.Context, string, Snapshot) (Suggestion, error) {
			return Suggestion{Source: "precomputed", Candidates: raw}, nil
		})
	})
	ctx, info := obsCtx()
	items, err := env.svc.ListSuggestedUsers(ctx, sugViewer, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(env.dir.calls) != 1 {
		t.Fatalf("hydration calls = %v, want one", env.dir.calls)
	}
	want := []string{"ok-1", "ok-00", "ok-01", "ok-02", "ok-03", "ok-04"}
	if !slices.Equal(env.dir.calls[0], want) {
		t.Errorf("hydrated %v, want %v", env.dir.calls[0], want)
	}
	if len(items) != 5 {
		t.Errorf("rows = %d, want 5", len(items))
	}
	if got := field(info, fieldSuggestSource); got != "precomputed" {
		t.Errorf("source = %v", got)
	}
}

// TestSuggestionCache_Concurrent: the viewer cache is safe for parallel reads, removals and rebuilds
// (run with -race).
func TestSuggestionCache_Concurrent(t *testing.T) {
	c := newSuggestionCache(time.Hour)
	now := time.Now()
	items := func() []ListItem {
		out := make([]ListItem, 8)
		for i := range out {
			out[i] = ListItem{User: identity.Profile{UserID: fmt.Sprintf("u-%d", i)}}
		}
		return out
	}
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				c.put("v", suggestionEntry{items: items()}, now)
				c.remove("v", fmt.Sprintf("u-%d", i%8))
				if e, ok := c.get("v", now); ok {
					for _, it := range e.items {
						_ = it.User.UserID
					}
				}
			}
		}()
	}
	wg.Wait()
}

func TestSuggestionCache_Expiry(t *testing.T) {
	c := newSuggestionCache(time.Hour)
	t0 := time.Date(2026, 10, 27, 0, 0, 0, 0, time.UTC)
	c.put("v", suggestionEntry{items: []ListItem{{User: identity.Profile{UserID: "a"}}}}, t0)
	if _, ok := c.get("v", t0.Add(59*time.Minute+59*time.Second)); !ok {
		t.Error("entry gone before its hour")
	}
	if _, ok := c.get("v", t0.Add(time.Hour)); ok {
		t.Error("entry alive at its hour")
	}
	c.remove("missing", "a") // no entry: no panic, no new entry
	if _, ok := c.get("missing", t0); ok {
		t.Error("remove created an entry")
	}
}

func TestSuggestionLimits_Normalized(t *testing.T) {
	tests := []struct {
		name string
		in   SuggestionLimits
		want SuggestionLimits
	}{
		{"zero is the config default", SuggestionLimits{}, SuggestionLimits{SampleFollowees: 30, EdgeLimit: 20, HydrateMax: 10, MaxResults: 5, CacheTTL: time.Hour}},
		{"in range is kept", SuggestionLimits{SampleFollowees: 7, EdgeLimit: 12, HydrateMax: 20, MaxResults: 3, CacheTTL: time.Minute}, SuggestionLimits{SampleFollowees: 7, EdgeLimit: 12, HydrateMax: 20, MaxResults: 3, CacheTTL: time.Minute}},
		{"above the bound is clamped", SuggestionLimits{SampleFollowees: 99, EdgeLimit: 99, HydrateMax: 99, MaxResults: 99}, SuggestionLimits{SampleFollowees: 30, EdgeLimit: 50, HydrateMax: 50, MaxResults: 5, CacheTTL: time.Hour}},
		{"negative is the default", SuggestionLimits{SampleFollowees: -1, EdgeLimit: -1, HydrateMax: -1, MaxResults: -1, CacheTTL: -time.Second}, SuggestionLimits{SampleFollowees: 30, EdgeLimit: 20, HydrateMax: 10, MaxResults: 5, CacheTTL: time.Hour}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.in.normalized()
			if got.SampleFollowees != tt.want.SampleFollowees || got.EdgeLimit != tt.want.EdgeLimit || got.HydrateMax != tt.want.HydrateMax || got.MaxResults != tt.want.MaxResults || got.CacheTTL != tt.want.CacheTTL {
				t.Errorf("normalized() = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestNewestFirst(t *testing.T) {
	tests := []struct {
		name string
		in   []string
		n    int
		want []string
	}{
		{"empty", nil, 30, nil},
		{"fewer than n", []string{"a", "b", "c"}, 30, []string{"c", "b", "a"}},
		{"exactly n", []string{"a", "b"}, 2, []string{"b", "a"}},
		{"more than n keeps the tail", []string{"a", "b", "c", "d", "e"}, 2, []string{"e", "d"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			in := slices.Clone(tt.in)
			got := newestFirst(in, tt.n)
			if !slices.Equal(got, tt.want) {
				t.Errorf("newestFirst(%v, %d) = %v, want %v", tt.in, tt.n, got, tt.want)
			}
			if len(got) > 0 {
				got[0] = "changed"
				if !slices.Equal(in, tt.in) {
					t.Errorf("newestFirst aliased its input: %v", in)
				}
			}
		})
	}
}

func TestDocToSnapshot_RecentFollowing(t *testing.T) {
	following := names("f", 45)
	s := doc{Following: following}.toSnapshot()
	if len(s.RecentFollowing) != 30 || s.RecentFollowing[0] != "f-44" || s.RecentFollowing[29] != "f-15" {
		t.Errorf("RecentFollowing = %v, want f-44 down to f-15", s.RecentFollowing)
	}
	if len(s.Following) != 45 {
		t.Errorf("Following set has %d entries, want all 45", len(s.Following))
	}
}

func TestClampMaxResults(t *testing.T) {
	tests := []struct {
		req   int32
		limit int
		want  int
	}{{0, 5, 5}, {-1, 5, 5}, {1, 5, 1}, {5, 5, 5}, {9, 5, 5}, {4, 2, 2}, {1, 2, 1}}
	for _, tt := range tests {
		if got := clampMaxResults(tt.req, tt.limit); got != tt.want {
			t.Errorf("clampMaxResults(%d, %d) = %d, want %d", tt.req, tt.limit, got, tt.want)
		}
	}
}

// TestListSuggestedUsers_WarmHitReloadsSnapshot (W3-22 L-1): a warm hit is re-filtered against the viewer's snapshot
// even when the 60 s snapshot cache no longer holds it, at the price of ONE read (graph/{viewer}), so a user who
// blocked the viewer on another instance is hidden within 60 s instead of at the end of the 1 h entry. A failure
// to load it is an error, never a cached-looking empty answer.
func TestListSuggestedUsers_WarmHitReloadsSnapshot(t *testing.T) {
	curated := names("cu", 8)
	build := func(t *testing.T) *sugEnv {
		t.Helper()
		return newSugEnv(t, SuggestionLimits{CuratedUIDs: curated, HydrateMax: 8, CacheTTL: time.Hour}, mkSnap(), nil, curated)
	}
	// blockedBySnapshot is what another instance's Block of the viewer by blocker leaves in graph/{viewer}. It is a
	// new Snapshot value with its own maps: the cold call's cached snapshot is not edited in place.
	blockedBySnapshot := func(blockers ...string) Snapshot {
		snap := mkSnap()
		for _, b := range blockers {
			snap.BlockedBy[b] = true
		}
		return snap
	}

	t.Run("a blocker added on another instance is dropped on the next call", func(t *testing.T) {
		env := build(t)
		first, _ := env.list(t, sugViewer, 5)
		if !slices.Equal(first, curated[:5]) {
			t.Fatalf("first = %v", first)
		}
		// Another instance wrote blockedBy; this instance's 60 s snapshot entry is gone (or never existed here).
		env.repo.snapshots[sugViewer] = blockedBySnapshot("cu-02")
		env.svc.cache.Invalidate(sugViewer)

		got, counter := env.list(t, sugViewer, 5)
		if want := []string{"cu-00", "cu-01", "cu-03", "cu-04", "cu-05"}; !slices.Equal(got, want) {
			t.Errorf("rows = %v, want %v (cu-02 hidden, the tail refilled)", got, want)
		}
		budgettest.Assert(t, "warm hit without a cached snapshot", counter, budgettest.Budget{Reads: 1})
		if len(env.repo.queries) != 0 || len(env.dir.calls) != 1 {
			t.Errorf("the re-filter touched storage beyond the snapshot: %d queries, %d hydrations", len(env.repo.queries), len(env.dir.calls))
		}
		// The loaded snapshot is cached for 60 s: the next warm call is free again.
		_, again := env.list(t, sugViewer, 5)
		budgettest.Assert(t, "next warm hit", again, budgettest.Budget{})
	})

	t.Run("a block of the viewer by an uncached viewer entry is hidden although the entry was built before it", func(t *testing.T) {
		// The same, with the whole cold path before the block: the entry is 59 minutes old.
		env := build(t)
		env.list(t, sugViewer, 5)
		env.now = env.now.Add(59 * time.Minute)
		env.repo.snapshots[sugViewer] = blockedBySnapshot("cu-00", "cu-01")
		env.svc.cache.Invalidate(sugViewer)
		got, counter := env.list(t, sugViewer, 5)
		if want := []string{"cu-02", "cu-03", "cu-04", "cu-05", "cu-06"}; !slices.Equal(got, want) {
			t.Errorf("rows = %v, want %v", got, want)
		}
		budgettest.Assert(t, "59 minute old entry", counter, budgettest.Budget{Reads: 1})
	})

	t.Run("the re-filter never rewrites the entry or stretches its expiry", func(t *testing.T) {
		env := build(t)
		env.list(t, sugViewer, 5)
		before, ok := env.svc.suggested.get(sugViewer, env.now)
		if !ok {
			t.Fatal("no entry after the cold call")
		}
		env.repo.snapshots[sugViewer] = blockedBySnapshot("cu-02")
		env.svc.cache.Invalidate(sugViewer)
		env.now = env.now.Add(30 * time.Minute)
		env.list(t, sugViewer, 5)
		after, ok := env.svc.suggested.get(sugViewer, env.now)
		if !ok || !after.expiresAt.Equal(before.expiresAt) || len(after.items) != len(before.items) {
			t.Errorf("entry changed by a warm hit: expiresAt %v -> %v, rows %d -> %d", before.expiresAt, after.expiresAt, len(before.items), len(after.items))
		}
		env.now = env.now.Add(31 * time.Minute) // 61 minutes after the build
		env.list(t, sugViewer, 5)
		if len(env.dir.calls) != 2 {
			t.Errorf("hydrations = %d after the original hour, want a rebuild (2)", len(env.dir.calls))
		}
	})

	t.Run("a snapshot read error is an error without raw uids, and the entry survives it", func(t *testing.T) {
		env := build(t)
		first, _ := env.list(t, sugViewer, 5)
		env.svc.cache.Invalidate(sugViewer)
		env.repo.err = errors.New("rpc error: documents/graph/" + sugViewer + " unavailable")
		items, err := env.svc.ListSuggestedUsers(context.Background(), sugViewer, 5)
		if err == nil || len(items) != 0 {
			t.Fatalf("items %v, err %v: want no rows and an error (an empty OK would be cached by the client for 24 h)", rowUIDs(items), err)
		}
		if strings.Contains(err.Error(), sugViewer) {
			t.Errorf("error %q names the raw uid", err.Error())
		}
		env.repo.err = nil
		got, _ := env.list(t, sugViewer, 5)
		if !slices.Equal(got, first) || len(env.dir.calls) != 1 {
			t.Errorf("after the failure rows = %v (hydrations %d), want the same entry %v", got, len(env.dir.calls), first)
		}
	})

	t.Run("an overflowed blockedBy loaded on a warm hit shows nothing", func(t *testing.T) {
		env := build(t)
		env.list(t, sugViewer, 5)
		snap := mkSnap()
		snap.BlockedByOverflow = true
		env.repo.snapshots[sugViewer] = snap
		env.svc.cache.Invalidate(sugViewer)
		got, counter := env.list(t, sugViewer, 5)
		if len(got) != 0 {
			t.Errorf("rows = %v with BlockedByOverflow, want none", got)
		}
		budgettest.Assert(t, "overflow on a warm hit", counter, budgettest.Budget{Reads: 1})
	})

	t.Run("a cached snapshot still costs nothing", func(t *testing.T) {
		env := build(t)
		env.list(t, sugViewer, 5)
		_, counter := env.list(t, sugViewer, 5)
		budgettest.Assert(t, "warm hit with a cached snapshot", counter, budgettest.Budget{})
	})
}
