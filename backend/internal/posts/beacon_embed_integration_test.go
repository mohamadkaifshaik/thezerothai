//go:build integration

package posts

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// TestBeaconEmbed_StoresAndRoundTrips: against the real repo, a post that shares a plan stores beaconId and the frozen
// snapshot on the post doc, reads them back through GetAll, replays on the same key, refuses another plan under it, exports
// the id, and a plain post stores neither field (so existing docs and exports are byte-identical).
func TestBeaconEmbed_StoresAndRoundTrips(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.signUp(t, "uid-alice", "alice")
	plans := &fakePlans{target: liveCoffee()}
	in.svc.beacons = plans
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-alice", SignInProvider: authn.SignInProviderGoogle})
	req := CreateInput{IdempotencyKey: key1, Text: "coffee at 4?", BeaconID: testBeacon, BeaconEmbedEnabled: true}

	if _, err := in.svc.directory.GetProfiles(context.Background(), []string{"uid-alice"}); err != nil {
		t.Fatal(err)
	}
	p, err := in.svc.Create(ctx, "uid-alice", req)
	if err != nil {
		t.Fatal(err)
	}
	snap, err := client.Collection(postsCollection).Doc(p.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d postDoc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	if d.BeaconID != testBeacon || d.Beacon == nil || d.Beacon.Title != "Coffee" || d.Beacon.Activity != int32(beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE) ||
		!d.Beacon.StartAt.Equal(beaconStart) || d.Beacon.CommunityID != "" {
		t.Fatalf("stored plan fields = %q %+v", d.BeaconID, d.Beacon)
	}

	// Read back through the repo: the post carries the id and the snapshot.
	all, err := in.repo.GetAll(context.Background(), []string{p.ID})
	got := all[p.ID]
	if err != nil || got == nil || got.BeaconID != testBeacon || got.Beacon == nil || got.Beacon.Title != "Coffee" {
		t.Fatalf("GetAll = %+v, %v", got, err)
	}

	// Replay: same key, same body returns the same post; another plan under the key is refused.
	again, err := in.svc.Create(ctx, "uid-alice", req)
	if err != nil || again.ID != p.ID {
		t.Fatalf("replay = %v, %v; want post %s", again, err, p.ID)
	}
	req.BeaconID = testBeacon2
	if _, err := in.svc.Create(ctx, "uid-alice", req); err == nil {
		t.Fatal("another plan under the same key must be refused")
	}

	// A plain post stores neither field.
	pl, err := in.create(t, "uid-alice", key(2), "just text")
	if err != nil {
		t.Fatal(err)
	}
	plain, err := client.Collection(postsCollection).Doc(pl.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"beaconId", "beacon"} {
		if _, err := plain.DataAt(f); err == nil {
			t.Fatalf("a plain post stored %s", f)
		}
	}

	// The export carries beaconId on the plan post only.
	var sb strings.Builder
	if err := in.repo.ExportUser(context.Background(), "uid-alice", &sb); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Posts []map[string]any `json:"posts"`
	}
	if err := json.Unmarshal([]byte(sb.String()), &out); err != nil {
		t.Fatal(err)
	}
	withPlan := 0
	for _, e := range out.Posts {
		if id, ok := e["beaconId"]; ok {
			withPlan++
			if id != testBeacon || e["id"] != p.ID {
				t.Fatalf("exported plan post = %v", e)
			}
		}
	}
	if len(out.Posts) != 2 || withPlan != 1 {
		t.Fatalf("exported %d posts, %d with a plan; want 2 and 1", len(out.Posts), withPlan)
	}
}
