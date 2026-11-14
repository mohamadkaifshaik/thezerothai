//go:build integration

package notifications

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// TestIntegration_UnreadBadgeOverflowPath (I2) drives the badge's overflow branch on the emulator beyond the F-04 test's
// single assertion. B's blockedBy is full (9,999 synthetic blockers plus one real one, X, still in the array), so two
// later blocks by A1 and A2 take the overflow branch and are known only to the BlockLookup. Unseen rows: two by A1, one
// by A2, one by X, two by friend C; one more row by C sits exactly at seenAt. The badge counts C's two unseen rows only:
//   - every row of an overflow blocker is excluded, not just the first;
//   - the in-array blocker and the overflow blockers are excluded in the same window;
//   - the cut at seenAt is strict (createdAt > since) on the filtered path too.
func TestIntegration_UnreadBadgeOverflowPath(t *testing.T) {
	client := newTestClient(t) // a fresh random project per test: unique ids, no shared emulator state
	ctx := context.Background()
	sfx := fmt.Sprintf("%d", time.Now().UnixNano())
	b, a1, a2, x, c := "boB"+sfx, "boA1"+sfx, "boA2"+sfx, "boX"+sfx, "boC"+sfx

	full := make([]string, 0, 10_000)
	for i := range 9_999 {
		full = append(full, fmt.Sprintf("blocker%05d", i))
	}
	full = append(full, x)
	empty := []string{}
	seed := func(uid string, blockedBy []string) {
		t.Helper()
		_, err := client.Collection("graph").Doc(uid).Set(ctx, map[string]any{
			"following": empty, "blocked": empty, "muted": empty, "requested": empty,
			"blockedBy": blockedBy, "blockedByOverflow": false, "updatedAt": t0,
		})
		mustNoErr(t, err)
	}
	seed(b, full)
	for _, uid := range []string{a1, a2, x, c} {
		seed(uid, empty)
	}

	graphRepo := graph.NewFirestoreRepo(client)
	for i, blocker := range []string{a1, a2} {
		res, err := graphRepo.Block(ctx, blocker, b, t0.Add(time.Duration(i+1)*time.Hour))
		mustNoErr(t, err)
		if !res.BlockedByOverflowHit {
			t.Fatalf("block %d did not take the overflow branch", i+1)
		}
	}
	snap, err := graphRepo.GetSnapshot(ctx, b)
	mustNoErr(t, err)
	if !snap.BlockedByOverflow || snap.BlockedBy[a1] || snap.BlockedBy[a2] || !snap.BlockedBy[x] {
		t.Fatalf("B overflow=%v blockedBy A1=%v A2=%v X=%v, want true/false/false/true",
			snap.BlockedByOverflow, snap.BlockedBy[a1], snap.BlockedBy[a2], snap.BlockedBy[x])
	}

	since := t0.Add(time.Minute)
	at := func(m int) time.Time { return since.Add(time.Duration(m) * time.Minute) }
	repo := NewFirestoreRepo(client)
	for _, n := range []Notification{
		row("follow_"+a1, TypeFollow, a1, at(1)),
		row("mention_"+a1, TypeMention, a1, at(2)),
		row("follow_"+a2, TypeFollow, a2, at(3)),
		row("follow_"+x, TypeFollow, x, at(4)),
		row("follow_"+c, TypeFollow, c, at(5)),
		row("reply_"+c, TypeReply, c, at(6)),
		row("mention_"+c, TypeMention, c, since), // exactly at seenAt: already seen
	} {
		created, err := repo.Create(ctx, b, n)
		mustNoErr(t, err)
		if !created {
			t.Fatalf("seed %s not created", n.ID)
		}
	}
	if raw, err := repo.CountUnread(ctx, b, since, UnreadBadgeCap); err != nil || raw != 6 {
		t.Fatalf("raw unseen count = %d, %v; want 6 (the row at seenAt is not unseen)", raw, err)
	}

	// A fresh graph service (a fresh 60 s cache) serves both seams, as apiserver wires it.
	graphSvc := graph.New(graph.Deps{Repo: graphRepo, Cache: graph.NewCache(time.Minute)})
	n, err := NewUnreadBadge(repo, graphSvc, graphSvc).UnreadNotifications(ctx, b, since)
	mustNoErr(t, err)
	if n != 2 {
		t.Errorf("badge = %d, want 2 (C's follow and reply; A1's two rows, A2's and X's excluded, C's row at seenAt seen)", n)
	}
}
