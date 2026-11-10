package notifications

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// fakeUnreadStore serves the badge's two reads from a newest-first list of displayed actor ids (all unseen) and counts
// every call, so the tests can bound the cost.
type fakeUnreadStore struct {
	actors      []string // newest first
	countCalls  int
	actorCalls  int
	countLimits []int
	actorLimits []int
	err         error
}

func (f *fakeUnreadStore) CountUnread(_ context.Context, _ string, _ time.Time, limit int) (int64, error) {
	f.countCalls++
	f.countLimits = append(f.countLimits, limit)
	if f.err != nil {
		return 0, f.err
	}
	return int64(min(len(f.actors), limit)), nil
}

func (f *fakeUnreadStore) UnreadActors(_ context.Context, _ string, _ time.Time, limit int) ([]string, error) {
	f.actorCalls++
	f.actorLimits = append(f.actorLimits, limit)
	if f.err != nil {
		return nil, f.err
	}
	return append([]string(nil), f.actors[:min(len(f.actors), limit)]...), nil
}

func manyActors(prefix string, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("%s%03d", prefix, i)
	}
	return out
}

// TestUnreadBadge_ExcludesHiddenRows: the GetMe badge counts only the unseen rows List would show. A row is hidden
// when its displayed actor is blocked or muted by the caller, or blocks the caller (snapshot or overflow lookup); the
// count is capped at UnreadBadgeCap, and the cost is one bounded query (plus at most one lookup on overflow).
func TestUnreadBadge_ExcludesHiddenRows(t *testing.T) {
	t.Parallel()
	mixed := []string{"F", "B", "M", "BB", "O", "G"}
	cases := []struct {
		name       string
		actors     []string
		snap       graph.Snapshot
		blockers   map[string]bool
		want       int64
		wantCount  int // CountUnread calls (the aggregation path)
		wantActors int // UnreadActors calls (the filtered path)
		wantLookup int
	}{
		{
			name: "nothing hidden: the plain aggregation", actors: mixed,
			want: 6, wantCount: 1,
		},
		{
			name: "blocked, muted and blocked-by actors are not counted", actors: mixed,
			snap: graph.Snapshot{Blocked: map[string]bool{"B": true}, Muted: map[string]bool{"M": true}, BlockedBy: map[string]bool{"BB": true}},
			want: 3, wantActors: 1,
		},
		{
			name: "overflow: a blocker only the lookup knows is not counted", actors: mixed,
			snap:     graph.Snapshot{Blocked: map[string]bool{"B": true}, BlockedByOverflow: true},
			blockers: map[string]bool{"O": true},
			want:     4, wantActors: 1, wantLookup: 1,
		},
		{
			name: "overflow without a hide set still takes the filtered path", actors: []string{"F", "O"},
			snap:     graph.Snapshot{BlockedByOverflow: true},
			blockers: map[string]bool{"O": true},
			want:     1, wantActors: 1, wantLookup: 1,
		},
		{
			name: "cap holds on the aggregation path", actors: manyActors("u", UnreadBadgeCap+50),
			want: UnreadBadgeCap, wantCount: 1,
		},
		{
			name: "cap holds on the filtered path", actors: manyActors("u", UnreadBadgeCap+50),
			snap: graph.Snapshot{Muted: map[string]bool{"zz": true}},
			want: UnreadBadgeCap, wantActors: 1,
		},
		{
			name: "filtered path reads the newest UnreadBadgeCap rows only", actors: append(manyActors("u", UnreadBadgeCap), "B"),
			snap: graph.Snapshot{Blocked: map[string]bool{"B": true}},
			want: UnreadBadgeCap, wantActors: 1,
		},
		{
			name: "overflow over a full window: one lookup of at most MaxBlockLookup", actors: manyActors("u", UnreadBadgeCap+50),
			snap:     graph.Snapshot{BlockedByOverflow: true},
			blockers: map[string]bool{"u000": true, "u001": true},
			want:     UnreadBadgeCap - 2, wantActors: 1, wantLookup: 1,
		},
		{
			name: "no unseen rows", actors: nil,
			snap: graph.Snapshot{Blocked: map[string]bool{"B": true}},
			want: 0, wantActors: 1,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store := &fakeUnreadStore{actors: tc.actors}
			blocks := &fakeBlocks{blockers: map[string]map[string]bool{"me": tc.blockers}}
			badge := NewUnreadBadge(store, &fakeSocial{snaps: map[string]graph.Snapshot{"me": tc.snap}}, blocks)
			got, err := badge.UnreadNotifications(context.Background(), "me", t0)
			mustNoErr(t, err)
			if got != tc.want {
				t.Errorf("badge = %d, want %d", got, tc.want)
			}
			if store.countCalls != tc.wantCount || store.actorCalls != tc.wantActors {
				t.Errorf("reads = %d aggregations + %d row queries, want %d + %d", store.countCalls, store.actorCalls, tc.wantCount, tc.wantActors)
			}
			for _, l := range append(append([]int(nil), store.countLimits...), store.actorLimits...) {
				if l != UnreadBadgeCap {
					t.Errorf("query limit = %d, want %d", l, UnreadBadgeCap)
				}
			}
			if blocks.calls != tc.wantLookup {
				t.Errorf("lookups = %d, want %d", blocks.calls, tc.wantLookup)
			}
			for _, asked := range blocks.asked {
				if len(asked) > graph.MaxBlockLookup {
					t.Errorf("lookup asked %d candidates, over graph.MaxBlockLookup %d", len(asked), graph.MaxBlockLookup)
				}
			}
		})
	}
}

// A failed read never turns into the raw (over-counting) number: the error goes to the caller.
func TestUnreadBadge_FailuresAreErrors(t *testing.T) {
	t.Parallel()
	hide := graph.Snapshot{Blocked: map[string]bool{"B": true}}
	cases := []struct {
		name   string
		store  *fakeUnreadStore
		social *fakeSocial
		blocks BlockLookup
	}{
		{"snapshot fails", &fakeUnreadStore{actors: []string{"F"}}, &fakeSocial{err: errBoom}, &fakeBlocks{}},
		{"row query fails", &fakeUnreadStore{actors: []string{"F"}, err: errBoom}, &fakeSocial{snaps: map[string]graph.Snapshot{"me": hide}}, &fakeBlocks{}},
		{"aggregation fails", &fakeUnreadStore{actors: []string{"F"}, err: errBoom}, &fakeSocial{}, &fakeBlocks{}},
		{"overflow lookup fails", &fakeUnreadStore{actors: []string{"F"}}, &fakeSocial{snaps: map[string]graph.Snapshot{"me": {BlockedByOverflow: true}}}, &fakeBlocks{err: errBoom}},
		{"overflow with no lookup wired", &fakeUnreadStore{actors: []string{"F"}}, &fakeSocial{snaps: map[string]graph.Snapshot{"me": {BlockedByOverflow: true}}}, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			n, err := NewUnreadBadge(tc.store, tc.social, tc.blocks).UnreadNotifications(context.Background(), "me", t0)
			if err == nil || n != 0 {
				t.Fatalf("badge = %d, %v; want 0 and an error", n, err)
			}
			if tc.name != "overflow with no lookup wired" && !errors.Is(err, errBoom) {
				t.Errorf("err = %v, want it to wrap the cause", err)
			}
		})
	}
}
