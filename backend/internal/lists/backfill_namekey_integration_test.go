//go:build integration

package lists

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

// TestBackfillNameKeys_OnFirestore: a list written before nameLower (seeded without it) and one with a stale key are found by a
// dry run, fixed by --write, matched by SearchByName afterwards, and a second run finds nothing; paging resumes by id.
func TestBackfillNameKeys_OnFirestore(t *testing.T) {
	e := newListsEnv(t, time.Now().Add(-48*time.Hour))
	ctx := context.Background()
	now := time.Now().UTC()
	legacy, stale := "0000000000000000101", "0000000000000000102"
	for id, d := range map[string]map[string]any{
		legacy: {"ownerId": "owner", "name": "Legacy Club", "description": "", "isPrivate": false, "memberIds": []string{}, "createdAt": now, "updatedAt": now},
		stale:  {"ownerId": "owner", "name": "Fresh Name", namekey.Field: "old name", "description": "", "isPrivate": false, "memberIds": []string{}, "createdAt": now, "updatedAt": now},
	} {
		if _, err := e.client.Collection("lists").Doc(id).Set(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	e.seedNamed(t, 1, "owner", "Current", false) // written by Create: already keyed

	dry, err := e.repo.BackfillNameKeys(ctx, "", 200, false)
	if err != nil || dry.Scanned != 3 || dry.Stale != 2 || dry.Written != 0 || !dry.Done {
		t.Fatalf("dry run = %+v, %v", dry, err)
	}
	if got, _ := e.repo.SearchByName(ctx, "legacy", nil, 20); len(got) != 0 {
		t.Fatal("a dry run wrote a key")
	}
	first, err := e.repo.BackfillNameKeys(ctx, "", 1, true)
	if err != nil || first.Scanned != 1 || first.Last != legacy || first.Done {
		t.Fatalf("page 1 = %+v, %v", first, err)
	}
	rest, err := e.repo.BackfillNameKeys(ctx, first.Last, 200, true)
	if err != nil || rest.Written != 1 || !rest.Done {
		t.Fatalf("rest = %+v, %v", rest, err)
	}
	if got, _ := e.repo.SearchByName(ctx, "legacy", nil, 20); len(got) != 1 || got[0].ID != legacy {
		t.Fatalf("legacy after the backfill = %v", got)
	}
	if got, _ := e.repo.SearchByName(ctx, "fresh", nil, 20); len(got) != 1 || got[0].ID != stale {
		t.Fatalf("stale after the backfill = %v", got)
	}
	again, err := e.repo.BackfillNameKeys(ctx, "", 200, true)
	if err != nil || again.Stale != 0 || again.Written != 0 {
		t.Fatalf("second run = %+v, %v", again, err)
	}
}
