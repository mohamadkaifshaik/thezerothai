//go:build integration

package notifications

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// TestIntegration_ListHidesOmittedBlockerAfterBlockedByOverflow is F-04 end to end on the emulator: B's blockedBy is
// full (10,000 synthetic blockers, one array on one doc), so A's Block sets blockedByOverflow and leaves A out of the
// array. A's old notification to B must disappear from B's list, and A must drop out of a collapsed row's count.
func TestIntegration_ListHidesOmittedBlockerAfterBlockedByOverflow(t *testing.T) {
	client := newTestClient(t) // a fresh random project per test: unique ids, no shared emulator state
	ctx := context.Background()
	suffix := fmt.Sprintf("%d", time.Now().UnixNano())
	a, b, c := "ovA"+suffix, "ovB"+suffix, "ovC"+suffix

	// Seed graph docs. B's blockedBy is at the cap and does not contain A.
	full := make([]string, 10_000)
	for i := range full {
		full[i] = fmt.Sprintf("blocker%05d", i)
	}
	empty := []string{}
	seed := func(uid string, blockedBy []string) {
		t.Helper()
		_, err := client.Collection("graph").Doc(uid).Set(ctx, map[string]any{
			"following": empty, "blocked": empty, "muted": empty, "requested": empty,
			"blockedBy": blockedBy, "blockedByOverflow": false, "updatedAt": t0,
		})
		mustNoErr(t, err)
	}
	seed(a, empty)
	seed(b, full)
	seed(c, empty)

	// Old notifications to B: A's own row, and a collapsed like row C shows with A folded in.
	notifRepo := NewFirestoreRepo(client)
	for _, n := range []Notification{
		row("follow_"+a, TypeFollow, a, t0.Add(2*time.Minute)),
		{ID: "like_" + c, Type: TypeLike, Actor: Actor{UserID: c, Handle: "h_" + c}, ActorIDs: []string{a, c}, ActorCount: 2, PostID: postA, CreatedAt: t0.Add(time.Minute)},
	} {
		created, err := notifRepo.Create(ctx, b, n)
		mustNoErr(t, err)
		if !created {
			t.Fatalf("seed %s not created", n.ID)
		}
	}

	// A blocks B through the real graph transaction: the overflow branch.
	graphRepo := graph.NewFirestoreRepo(client)
	res, err := graphRepo.Block(ctx, a, b, t0.Add(time.Hour))
	mustNoErr(t, err)
	if !res.BlockedByOverflowHit {
		t.Fatal("Block did not take the overflow branch")
	}
	bSnap, err := graphRepo.GetSnapshot(ctx, b)
	mustNoErr(t, err)
	if !bSnap.BlockedByOverflow || bSnap.BlockedBy[a] {
		t.Fatalf("B overflow=%v blockedBy[A]=%v, want true/false", bSnap.BlockedByOverflow, bSnap.BlockedBy[a])
	}

	// A fresh graph service (a fresh 60 s cache, as after a refresh) serves both seams, as apiserver wires it.
	graphSvc := graph.New(graph.Deps{Repo: graphRepo, Cache: graph.NewCache(time.Minute)})
	svc := NewService(Deps{Repo: notifRepo, Directory: newDirectory(b), Social: graphSvc, Blocks: graphSvc, Seen: &fakeSeen{},
		CursorKey: testKey, Now: func() time.Time { return t0.Add(2 * time.Hour) }})
	list, err := svc.List(ctx, b, ListInput{PageSize: 10})
	mustNoErr(t, err)
	if got := strings.Join(idsOf(list.Notifications), ","); got != "like_"+c {
		t.Fatalf("B's notifications = %q, want only like_%s (A's row hidden)", got, c)
	}
	if n := list.Notifications[0]; n.Actor.UserID != c || n.ActorCount != 1 {
		t.Errorf("collapsed row actor=%s count=%d, want %s and 1 (A subtracted)", n.Actor.UserID, n.ActorCount, c)
	}
}
