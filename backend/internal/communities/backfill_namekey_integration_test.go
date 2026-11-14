//go:build integration

package communities

import (
	"context"
	"testing"
)

// TestBackfillNameKeys_OnFirestore: communities seeded without nameLower (every status) are keyed by --write, an ACTIVE one is then
// found by SearchByName, and a second run finds nothing.
func TestBackfillNameKeys_OnFirestore(t *testing.T) {
	e := newListEnv(t)
	ctx := context.Background()
	e.seedCommunity(t, Community{ID: "0000000000000000961", Name: "Legacy Runners", OwnerID: "owner", MemberCount: 1}, nil)
	e.seedCommunity(t, Community{ID: "0000000000000000962", Name: "Legacy Suspended", OwnerID: "owner", MemberCount: 1, Status: StatusSuspended}, nil)

	dry, err := e.repo.BackfillNameKeys(ctx, "", 200, false)
	if err != nil || dry.Scanned != 2 || dry.Stale != 2 || dry.Written != 0 {
		t.Fatalf("dry run = %+v, %v", dry, err)
	}
	done, err := e.repo.BackfillNameKeys(ctx, "", 200, true)
	if err != nil || done.Written != 2 || !done.Done {
		t.Fatalf("write = %+v, %v", done, err)
	}
	got, err := e.repo.SearchByName(ctx, "legacy", nil, 20)
	if err != nil || len(got) != 1 || got[0].ID != "0000000000000000961" {
		t.Fatalf("search after the backfill = %+v, %v", got, err)
	}
	again, err := e.repo.BackfillNameKeys(ctx, "", 200, true)
	if err != nil || again.Stale != 0 {
		t.Fatalf("second run = %+v, %v", again, err)
	}
}
