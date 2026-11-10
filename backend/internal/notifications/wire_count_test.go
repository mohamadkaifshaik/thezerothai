package notifications

import (
	"context"
	"slices"
	"testing"
	"time"
)

// TestList_WireActorCountExcludesHiddenActors pins the "and N others" count as the client sees it: List then
// ToProto. visible() subtracts the actors the caller blocks or mutes (and, after a blockedBy overflow, the actors the
// graph lookup reports as blockers); ToProto must not undo that by re-maxing with the stored ActorIDs, which still
// hold the hidden ids. Covered on the snapshot path and the overflow path, for current and legacy rows.
func TestList_WireActorCountExcludesHiddenActors(t *testing.T) {
	t.Parallel()
	at := func(m int) time.Time { return t0.Add(time.Duration(m) * time.Minute) }
	row := func(id string, m, count int, ids ...string) Notification {
		return Notification{ID: id, Type: TypeLike, Actor: Actor{UserID: "F"}, ActorIDs: ids, ActorCount: count, CreatedAt: at(m)}
	}
	rows := []Notification{
		row("blocked", 9, 3, "B", "x", "F"),
		row("muted", 8, 3, "M", "x", "F"),
		// Written before actorCount existed: the field reads 0 and the count falls back to the ids.
		row("legacy_blocked", 7, 0, "B", "x", "F"),
		// A pre-field row folded once after the field existed: Increment(1) on a missing field stores 1, so the stored
		// count is below len(ActorIDs). The ids are the truth here; this is why the wire count keeps a max.
		row("legacy_folded", 6, 1, "a", "b", "F"),
		row("legacy_folded_muted", 5, 1, "M", "b", "F"),
		// More folded actors than ActorIDs keeps: the stored count is the truth, minus the hidden one.
		row("big", 4, 40, "B", "F"),
		row("clean", 3, 3, "a", "b", "F"),
		row("blocker", 2, 3, "O", "x", "F"), // O blocked the caller; only the overflow lookup knows it
	}
	base := map[string]int32{
		"blocked": 2, "muted": 2, "legacy_blocked": 2, "legacy_folded": 3, "legacy_folded_muted": 2, "big": 39, "clean": 3,
	}
	snapPath := map[string]int32{"blocker": 3} // the snapshot alone does not know O
	overflowPath := map[string]int32{"blocker": 2}
	for k, v := range base {
		snapPath[k], overflowPath[k] = v, v
	}
	cases := []struct {
		name     string
		overflow bool
		want     map[string]int32
	}{
		{"snapshot path", false, snapPath},
		{"overflow path", true, overflowPath},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			repo.rows["me"] = map[string]Notification{}
			stored := map[string][]string{}
			for _, n := range rows {
				n.ActorIDs = slices.Clone(n.ActorIDs)
				repo.rows["me"][n.ID] = n
				stored[n.ID] = slices.Clone(n.ActorIDs)
			}
			snap := graphSnap{Blocked: map[string]bool{"B": true}, Muted: map[string]bool{"M": true}, BlockedByOverflow: tc.overflow}
			blocks := &fakeBlocks{blockers: map[string]map[string]bool{"me": {"O": true}}}
			svc := newOverflowService(repo, &fakeSocial{snaps: map[string]graphSnap{"me": snap}}, blocks)
			res, err := svc.List(context.Background(), "me", ListInput{PageSize: MaxPageSize})
			mustNoErr(t, err)
			if len(res.Notifications) != len(rows) {
				t.Fatalf("rows = %v, want all %d (every displayed actor is visible)", idsOf(res.Notifications), len(rows))
			}
			for _, n := range res.Notifications {
				if got, want := ToProto(n).GetActorCount(), tc.want[n.ID]; got != want {
					t.Errorf("%s: wire actor_count = %d, want %d", n.ID, got, want)
				}
			}
			// Pruning must not write through to the repo's (shared) slices.
			for id, ids := range stored {
				if !slices.Equal(repo.rows["me"][id].ActorIDs, ids) {
					t.Errorf("%s: stored ActorIDs changed to %v, want %v", id, repo.rows["me"][id].ActorIDs, ids)
				}
			}
		})
	}
}
