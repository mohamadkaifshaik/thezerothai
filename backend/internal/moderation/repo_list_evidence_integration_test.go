//go:build integration

package moderation

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// Plan W5-44 against the Firestore emulator: a LIST report keeps the list's name and description (and the owner's handle) in
// the report document, with the same 2 reads and 2 writes as a POST or ACCOUNT report, no evidence child document, and the
// post evidence's retention (resolved + 90 days).
func TestRepo_ListEvidenceRoundTripAndRetention(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client, quota.New(client))
	t0 := time.Date(2026, 10, 31, 0, 0, 0, 0, time.UTC)
	listID := pidN(77)

	rep := sampleReport("u-rep", TargetList, listID, "u-owner", t0)
	rep.Evidence = &Evidence{AuthorHandle: "mallory", ListName: "targets", ListDescription: "people to watch", PostCreatedAt: t0.Add(-time.Hour)}
	ctx, c := counted()
	if _, err := repo.Create(ctx, CreateParams{Report: rep, QuotaLimit: 5}); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "Create list report", c, budgettest.Budget{Reads: 2, Writes: 2})
	if c.Reads() != 2 || c.Writes() != 2 {
		t.Errorf("reads=%d writes=%d, want exactly 2 2", c.Reads(), c.Writes())
	}

	got, err := repo.Get(context.Background(), rep.ID)
	if err != nil || got.Evidence == nil {
		t.Fatalf("stored = %+v err=%v", got, err)
	}
	e := got.Evidence
	if got.TargetType != TargetList || got.TargetOwnerID != "u-owner" || e.ListName != "targets" || e.ListDescription != "people to watch" || e.AuthorHandle != "mallory" {
		t.Fatalf("report = %+v evidence = %+v", got, e)
	}
	if e.TextExpired || e.Text != "" {
		t.Errorf("list evidence has message-text semantics: %+v", e)
	}

	// No child document: the snapshot lives in the report document and follows its retention.
	kids, err := client.Collection("reports").Doc(rep.ID).Collection("evidence").Documents(context.Background()).GetAll()
	if err != nil || len(kids) != 0 {
		t.Fatalf("evidence children = %d err=%v, want 0", len(kids), err)
	}

	// An empty description is stored and read back (omitempty field).
	bare := sampleReport("u-rep2", TargetList, listID, "u-owner", t0)
	bare.Evidence = &Evidence{AuthorHandle: "mallory", ListName: "x"}
	if _, err := repo.Create(context.Background(), CreateParams{Report: bare, QuotaLimit: 5}); err != nil {
		t.Fatal(err)
	}
	if g, err := repo.Get(context.Background(), bare.ID); err != nil || g.Evidence.ListName != "x" || g.Evidence.ListDescription != "" {
		t.Fatalf("bare = %+v err=%v", g, err)
	}

	// Retention: open has no expireAt; resolved sets resolvedAt + 90 days (the existing rule for every non-message target).
	if !got.ExpireAt.IsZero() {
		t.Errorf("an OPEN list report has expireAt %v", got.ExpireAt)
	}
	res, err := repo.Resolve(context.Background(), rep.ID, ResolutionNoAction, "list hidden", t0.Add(time.Hour))
	if err != nil || !res.ExpireAt.Equal(t0.Add(time.Hour+Retention)) {
		t.Fatalf("resolve = %+v err=%v, want expireAt resolvedAt + 90 days", res, err)
	}
}
