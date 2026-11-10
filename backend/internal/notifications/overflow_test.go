package notifications

import (
	"context"
	"fmt"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// fakeBlocks is a counting BlockLookup: blockers[viewer][actor] means actor blocked viewer.
type fakeBlocks struct {
	blockers map[string]map[string]bool
	err      error
	calls    int
	asked    [][]string
}

func (f *fakeBlocks) BlockersAmong(_ context.Context, viewer string, candidates []string) (map[string]bool, error) {
	f.calls++
	f.asked = append(f.asked, append([]string(nil), candidates...))
	if len(candidates) > graph.MaxBlockLookup {
		return nil, fmt.Errorf("fake: %d candidates over the cap", len(candidates))
	}
	if f.err != nil {
		return nil, f.err
	}
	out := map[string]bool{}
	for _, c := range candidates {
		if f.blockers[viewer][c] {
			out[c] = true
		}
	}
	return out, nil
}

func newOverflowService(repo *fakeRepo, social Social, blocks BlockLookup) Service {
	return NewService(Deps{Repo: repo, Directory: newDirectory("me"), Social: social, Blocks: blocks, Seen: &fakeSeen{},
		CursorKey: testKey, Now: func() time.Time { return t0.Add(time.Hour) }})
}

func likeRow(id, shown string, at time.Time, ids ...string) Notification {
	return Notification{ID: id, Type: TypeLike, Actor: Actor{UserID: shown, Handle: "h_" + shown}, ActorIDs: ids, ActorCount: len(ids), CreatedAt: at}
}

// TestList_BlockedByOverflow covers F-04: once the caller's blockedBy overflowed its cap, an actor who blocked the caller
// may be missing from snapshot.BlockedBy, so the read path asks the graph module (one batched call per page).
func TestList_BlockedByOverflow(t *testing.T) {
	t.Parallel()
	overflowed := graphSnap{BlockedByOverflow: true, BlockedBy: map[string]bool{"listed": true}}
	cases := []struct {
		name      string
		rows      []Notification
		snap      graphSnap
		blockers  map[string]bool // actors that blocked "me" but are not in the snapshot's BlockedBy
		wantIDs   string
		wantCount map[string]int // row id -> ActorCount on the wire
		wantCalls int
	}{
		{
			name: "omitted blocker's single-actor row is hidden",
			rows: []Notification{
				likeRow("ra", "A", t0.Add(3*time.Minute), "A"),
				likeRow("rf", "F", t0.Add(2*time.Minute), "F"),
			},
			snap: overflowed, blockers: map[string]bool{"A": true},
			wantIDs: "rf", wantCalls: 1,
		},
		{
			name: "collapsed row: A shown hides the row, A folded drops the count",
			rows: []Notification{
				likeRow("shown", "A", t0.Add(3*time.Minute), "F", "G", "A"),
				likeRow("folded", "F", t0.Add(2*time.Minute), "A", "G", "F"),
			},
			snap: overflowed, blockers: map[string]bool{"A": true},
			wantIDs: "folded", wantCount: map[string]int{"folded": 2}, wantCalls: 1,
		},
		{
			name: "collapsed count keeps the extra folded actors beyond ActorIDs",
			rows: []Notification{
				{ID: "big", Type: TypeLike, Actor: Actor{UserID: "F"}, ActorIDs: []string{"A", "F"}, ActorCount: 40, CreatedAt: t0},
			},
			snap: overflowed, blockers: map[string]bool{"A": true},
			wantIDs: "big", wantCount: map[string]int{"big": 39}, wantCalls: 1,
		},
		{
			name: "overflow but nobody on the page blocked the caller",
			rows: []Notification{
				likeRow("r1", "F", t0.Add(time.Minute), "F", "G"),
			},
			snap:    overflowed,
			wantIDs: "r1", wantCount: map[string]int{"r1": 2}, wantCalls: 1,
		},
		{
			name: "no overflow: the snapshot alone decides, zero lookups",
			rows: []Notification{
				likeRow("ra", "A", t0.Add(3*time.Minute), "A"),
				likeRow("rl", "listed", t0.Add(2*time.Minute), "listed"),
				likeRow("rf", "F", t0.Add(time.Minute), "listed", "F"),
			},
			snap:     graphSnap{BlockedBy: map[string]bool{"listed": true}},
			blockers: map[string]bool{"A": true}, // the graph would say so, but the snapshot is complete: not asked
			wantIDs:  "ra,rf", wantCount: map[string]int{"rf": 1}, wantCalls: 0,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			repo.rows["me"] = map[string]Notification{}
			for _, n := range tc.rows {
				repo.rows["me"][n.ID] = n
			}
			blocks := &fakeBlocks{blockers: map[string]map[string]bool{"me": tc.blockers}}
			svc := newOverflowService(repo, &fakeSocial{snaps: map[string]graphSnap{"me": tc.snap}}, blocks)
			res, err := svc.List(context.Background(), "me", ListInput{PageSize: 10})
			mustNoErr(t, err)
			if got := strings.Join(idsOf(res.Notifications), ","); got != tc.wantIDs {
				t.Fatalf("rows = %q, want %q", got, tc.wantIDs)
			}
			for _, n := range res.Notifications {
				// The domain count and the wire count agree: visible() prunes the hidden ids, so ToProto's max with
				// len(ActorIDs) cannot bring them back (TestList_WireActorCountExcludesHiddenActors).
				if want, ok := tc.wantCount[n.ID]; ok && (n.ActorCount != want || int(ToProto(n).GetActorCount()) != want) {
					t.Errorf("%s actor count = %d (wire %d), want %d", n.ID, n.ActorCount, ToProto(n).GetActorCount(), want)
				}
				if tc.snap.BlockedByOverflow && tc.blockers[n.Actor.UserID] {
					t.Errorf("%s shows blocker %s as its actor", n.ID, n.Actor.UserID)
				}
			}
			if blocks.calls != tc.wantCalls {
				t.Errorf("lookups = %d, want %d", blocks.calls, tc.wantCalls)
			}
		})
	}
}

// The lookup is asked once, for the page's distinct actors only, minus those the snapshot already hides.
func TestList_BlockedByOverflow_AsksOnceForDistinctUnknownActors(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	repo.rows["me"] = map[string]Notification{
		"r1": likeRow("r1", "A", t0.Add(3*time.Minute), "B", "A"),
		"r2": likeRow("r2", "B", t0.Add(2*time.Minute), "A", "M", "B"),
		"r3": likeRow("r3", "C", t0.Add(time.Minute), "listed", "C"),
	}
	snap := graphSnap{BlockedByOverflow: true, BlockedBy: map[string]bool{"listed": true}, Muted: map[string]bool{"M": true}}
	blocks := &fakeBlocks{}
	svc := newOverflowService(repo, &fakeSocial{snaps: map[string]graphSnap{"me": snap}}, blocks)
	_, err := svc.List(context.Background(), "me", ListInput{PageSize: 10})
	mustNoErr(t, err)
	if blocks.calls != 1 {
		t.Fatalf("lookups = %d, want 1 batched call", blocks.calls)
	}
	got := append([]string(nil), blocks.asked[0]...)
	sort.Strings(got)
	if strings.Join(got, ",") != "A,B,C" {
		t.Errorf("asked = %v, want A,B,C (distinct, without the muted and listed ids)", blocks.asked[0])
	}
}

// A failed lookup leaves the page's visibility unknown: fail closed like a failed caller-graph read (the whole page
// errors, the client retries), never an unfiltered row, and no token moves past rows that were never shown.
func TestList_BlockedByOverflow_LookupErrorFailsClosed(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	repo.rows["me"] = map[string]Notification{"ra": likeRow("ra", "A", t0, "A")}
	snap := graphSnap{BlockedByOverflow: true}
	for name, blocks := range map[string]BlockLookup{"lookup error": &fakeBlocks{err: errBoom}, "lookup not wired": nil} {
		t.Run(name, func(t *testing.T) {
			svc := newOverflowService(repo, &fakeSocial{snaps: map[string]graphSnap{"me": snap}}, blocks)
			res, err := svc.List(context.Background(), "me", ListInput{PageSize: 10})
			if err == nil {
				t.Fatalf("an unknown block state must not show the row: got %v", idsOf(res.Notifications))
			}
			if strings.Contains(err.Error(), "\"me\"") || strings.Contains(err.Error(), "/me") {
				t.Errorf("error names the caller: %v", err)
			}
		})
	}
}

// A full page whose every row is suppressed by the lookup is empty but still pages on from the raw oldest row.
func TestList_BlockedByOverflow_FullySuppressedPageStillAdvances(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	repo.rows["me"] = map[string]Notification{}
	for i := 0; i < 3; i++ {
		id := fmt.Sprintf("r%d", i)
		repo.rows["me"][id] = likeRow(id, "A", t0.Add(time.Duration(i)*time.Minute), "A")
	}
	repo.rows["me"]["old"] = likeRow("old", "F", t0.Add(-time.Hour), "F")
	blocks := &fakeBlocks{blockers: map[string]map[string]bool{"me": {"A": true}}}
	svc := newOverflowService(repo, &fakeSocial{snaps: map[string]graphSnap{"me": {BlockedByOverflow: true}}}, blocks)
	p1, err := svc.List(context.Background(), "me", ListInput{PageSize: 3})
	mustNoErr(t, err)
	if len(p1.Notifications) != 0 || p1.NextPageToken == "" || p1.SinceToken == "" {
		t.Fatalf("page 1 = %v next=%q since=%q: a fully suppressed full page is empty and still carries its tokens",
			idsOf(p1.Notifications), p1.NextPageToken, p1.SinceToken)
	}
	p2, err := svc.List(context.Background(), "me", ListInput{PageSize: 3, PageToken: p1.NextPageToken})
	mustNoErr(t, err)
	if got := idsOf(p2.Notifications); len(got) != 1 || got[0] != "old" {
		t.Fatalf("page 2 = %v, want [old]", got)
	}
	// The refresh from page 1's since token does not re-read the suppressed rows forever.
	again, err := svc.List(context.Background(), "me", ListInput{PageSize: 3, SinceToken: p1.SinceToken})
	mustNoErr(t, err)
	if len(again.Notifications) != 0 {
		t.Errorf("refresh = %v, want nothing visible", idsOf(again.Notifications))
	}
}

// More distinct actors than one lookup accepts: every shown actor is always asked; folded actors past the cap are
// not, and count as suppressed (the count fails closed; no row is hidden for them).
func TestList_BlockedByOverflow_CapCoversShownActorsFirst(t *testing.T) {
	t.Parallel()
	if graph.MaxBlockLookup < MaxPageSize {
		t.Fatalf("graph.MaxBlockLookup = %d < MaxPageSize %d: the shown actors of a full page would not fit", graph.MaxBlockLookup, MaxPageSize)
	}
	repo := newFakeRepo()
	repo.rows["me"] = map[string]Notification{}
	// MaxPageSize rows, each with its own shown actor and MaxActorIDs-1 folded actors of its own.
	for i := 0; i < MaxPageSize; i++ {
		id := fmt.Sprintf("r%02d", i)
		shown := fmt.Sprintf("s%02d", i)
		ids := make([]string, 0, MaxActorIDs)
		for j := 0; j < MaxActorIDs-1; j++ {
			ids = append(ids, fmt.Sprintf("f%02d_%02d", i, j))
		}
		ids = append(ids, shown)
		repo.rows["me"][id] = likeRow(id, shown, t0.Add(time.Duration(i)*time.Minute), ids...)
	}
	blocks := &fakeBlocks{blockers: map[string]map[string]bool{"me": {"s00": true}}}
	svc := newOverflowService(repo, &fakeSocial{snaps: map[string]graphSnap{"me": {BlockedByOverflow: true}}}, blocks)
	res, err := svc.List(context.Background(), "me", ListInput{PageSize: MaxPageSize})
	mustNoErr(t, err)
	if blocks.calls != 1 || len(blocks.asked[0]) != graph.MaxBlockLookup {
		t.Fatalf("lookups = %d asked = %d, want 1 call of %d", blocks.calls, len(blocks.asked[0]), graph.MaxBlockLookup)
	}
	for i := 0; i < MaxPageSize; i++ {
		if !slices.Contains(blocks.asked[0], fmt.Sprintf("s%02d", i)) {
			t.Fatalf("shown actor s%02d was not asked", i)
		}
	}
	if len(res.Notifications) != MaxPageSize-1 {
		t.Fatalf("rows = %d, want %d (only s00's row hidden)", len(res.Notifications), MaxPageSize-1)
	}
	asked := map[string]bool{}
	for _, id := range blocks.asked[0] {
		asked[id] = true
	}
	for _, n := range res.Notifications {
		unknown := 0
		for _, id := range repo.rows["me"][n.ID].ActorIDs { // the stored ids: the returned ones are pruned
			if !asked[id] {
				unknown++
			}
		}
		want := max(MaxActorIDs-unknown, 1)
		if n.ActorCount != want || int(ToProto(n).GetActorCount()) != want {
			t.Errorf("%s count = %d (wire %d), want %d (%d folded actors unchecked)", n.ID, n.ActorCount, ToProto(n).GetActorCount(), want, unknown)
		}
		for _, id := range n.ActorIDs {
			if !asked[id] {
				t.Errorf("%s still carries unchecked folded actor %s", n.ID, id)
			}
		}
	}
}
