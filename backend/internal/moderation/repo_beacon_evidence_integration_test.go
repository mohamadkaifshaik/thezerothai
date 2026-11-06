//go:build integration

package moderation

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// A BEACON report keeps the organiser's handle and the beacon's title, details and venue in the report document (the LIST
// shape): no evidence child document, the post evidence's retention (resolved + 90 days).
func TestRepo_BeaconEvidenceRoundTripAndRetention(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client, quota.New(client))
	t0 := time.Date(2026, 11, 6, 0, 0, 0, 0, time.UTC)
	beaconID := pidN(88)

	rep := sampleReport("u-rep", TargetBeacon, beaconID, "u-organiser", t0)
	rep.Evidence = &Evidence{AuthorHandle: "mallory", BeaconTitle: "Coffee", BeaconDetails: "bring cash", BeaconVenue: "Hall", PostCreatedAt: t0.Add(-time.Hour)}
	ctx := context.Background()
	if _, err := repo.Create(ctx, CreateParams{Report: rep, QuotaLimit: 5}); err != nil {
		t.Fatal(err)
	}
	got, err := repo.Get(ctx, rep.ID)
	if err != nil || got.Evidence == nil {
		t.Fatalf("stored = %+v err=%v", got, err)
	}
	e := got.Evidence
	if got.TargetType != TargetBeacon || got.TargetOwnerID != "u-organiser" || e.BeaconTitle != "Coffee" || e.BeaconDetails != "bring cash" || e.BeaconVenue != "Hall" || e.AuthorHandle != "mallory" {
		t.Fatalf("report = %+v evidence = %+v", got, e)
	}
	if e.TextExpired || e.Text != "" || e.ListName != "" {
		t.Errorf("beacon evidence carries another target's fields: %+v", e)
	}
	kids, err := client.Collection("reports").Doc(rep.ID).Collection("evidence").Documents(ctx).GetAll()
	if err != nil || len(kids) != 0 {
		t.Fatalf("evidence children = %d err=%v, want 0", len(kids), err)
	}
	if !got.ExpireAt.IsZero() {
		t.Errorf("an OPEN beacon report has expireAt %v", got.ExpireAt)
	}
	res, err := repo.Resolve(ctx, rep.ID, ResolutionTakedown, "beacon hidden", t0.Add(time.Hour))
	if err != nil || !res.ExpireAt.Equal(t0.Add(time.Hour+Retention)) {
		t.Fatalf("resolve = %+v err=%v, want expireAt resolvedAt + 90 days", res, err)
	}
}
