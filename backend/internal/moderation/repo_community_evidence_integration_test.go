//go:build integration

package moderation

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// Plan against the Firestore emulator: a COMMUNITY report keeps the community's name, description and rules (and the
// owner's handle) in the report document, with the same 2 reads and 2 writes as every other report, no evidence child document, and the
// post evidence's retention (resolved + 90 days). An archived community's report has an empty target owner.
func TestRepo_CommunityEvidenceRoundTripAndRetention(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client, quota.New(client))
	t0 := time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC)
	cid := pidN(88)
	rules := []CommunityRule{{Title: "Be kind", Text: "No insults."}, {Title: "On topic", Text: ""}}

	rep := sampleReport("u-rep", TargetCommunity, cid, "u-owner", t0)
	rep.Evidence = &Evidence{AuthorHandle: "mallory", CommunityName: "targets", CommunityDescription: "people to watch", CommunityRules: rules, PostCreatedAt: t0.Add(-time.Hour)}
	ctx, c := counted()
	if _, err := repo.Create(ctx, CreateParams{Report: rep, QuotaLimit: 5}); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "Create community report", c, budgettest.Budget{Reads: 2, Writes: 2})
	if c.Reads() != 2 || c.Writes() != 2 {
		t.Errorf("reads=%d writes=%d, want exactly 2 2", c.Reads(), c.Writes())
	}

	got, err := repo.Get(context.Background(), rep.ID)
	if err != nil || got.Evidence == nil {
		t.Fatalf("stored = %+v err=%v", got, err)
	}
	e := got.Evidence
	if got.TargetType != TargetCommunity || got.TargetOwnerID != "u-owner" || e.CommunityName != "targets" || e.CommunityDescription != "people to watch" || e.AuthorHandle != "mallory" {
		t.Fatalf("report = %+v evidence = %+v", got, e)
	}
	if !reflect.DeepEqual(e.CommunityRules, rules) {
		t.Errorf("rules = %+v, want %+v", e.CommunityRules, rules)
	}
	if e.TextExpired || e.Text != "" {
		t.Errorf("community evidence has message-text semantics: %+v", e)
	}
	kids, err := client.Collection("reports").Doc(rep.ID).Collection("evidence").Documents(context.Background()).GetAll()
	if err != nil || len(kids) != 0 {
		t.Fatalf("evidence children = %d err=%v, want 0", len(kids), err)
	}

	// An archived community: no owner, no handle, no rules; the report is still stored and read back.
	bare := sampleReport("u-rep2", TargetCommunity, cid, "", t0)
	bare.Evidence = &Evidence{CommunityName: "x"}
	if _, err := repo.Create(context.Background(), CreateParams{Report: bare, QuotaLimit: 5}); err != nil {
		t.Fatal(err)
	}
	if g, err := repo.Get(context.Background(), bare.ID); err != nil || g.TargetOwnerID != "" || g.Evidence.CommunityName != "x" || g.Evidence.CommunityDescription != "" || len(g.Evidence.CommunityRules) != 0 {
		t.Fatalf("bare = %+v err=%v", g, err)
	}

	if !got.ExpireAt.IsZero() {
		t.Errorf("an OPEN community report has expireAt %v", got.ExpireAt)
	}
	res, err := repo.Resolve(context.Background(), rep.ID, ResolutionTakedown, "community suspended", t0.Add(time.Hour))
	if err != nil || !res.ExpireAt.Equal(t0.Add(time.Hour+Retention)) {
		t.Fatalf("resolve = %+v err=%v, want expireAt resolvedAt + 90 days", res, err)
	}
}
