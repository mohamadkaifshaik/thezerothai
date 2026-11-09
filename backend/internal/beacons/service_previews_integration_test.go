//go:build integration

package beacons

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// TestIntegrationPreviews_OverTheRealRepo: embed rules, a cancelled plan renders cancelled, and the audience leak (a viewer
// outside the community gets nothing for a community plan) over the emulator.
func TestIntegrationPreviews_OverTheRealRepo(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const host, member, outsider = "pv-host", "pv-member", "pv-outsider"
	dir := &fakeDirectory{profiles: map[string]identity.Profile{host: activeProfile(host), member: activeProfile(member), outsider: activeProfile(outsider)}}
	g := &fakeGraph{snaps: map[string]graph.Snapshot{}}
	comm := &fakeCommunities{roles: map[string]communities.Role{itCommunity + "|" + member: communities.RoleMember}}
	flags := fakeFlags{on: map[string]bool{FlagName: true, communities.FlagName: true}, off: map[string]bool{}}
	svc := New(Deps{
		Repo: e.repo, Directory: dir, Graph: g, Communities: comm, CommunityFlags: flags,
		CursorKey: []byte("0123456789abcdef0123456789abcdef"), Limits: Limits{MaxOpenPerUser: 5, MaxPendingRequests: 10, MaxOpenSpots: 20},
		Now: func() time.Time { return e.now },
	})

	pub := e.create(t, host, "integration-key-pv01", e.beaconAt(host, "", e.now.Add(2*time.Hour))).Beacon
	com := e.create(t, host, "integration-key-pv02", e.beaconAt(host, itCommunity, e.now.Add(3*time.Hour))).Beacon
	gone := e.create(t, host, "integration-key-pv03", e.beaconAt(host, "", e.now.Add(4*time.Hour))).Beacon
	ids := []string{pub.ID, com.ID, gone.ID, "0000000000000000999"}

	// One batch for a feed page: the member sees the public and the community plan; the outsider only the public one; an
	// unknown id is absent for both.
	got, err := svc.Previews(ctx, member, ids)
	if err != nil || len(got) != 3 || got[pub.ID].Status != StatusOpen || got[com.ID].CommunityID != itCommunity || got[com.ID].Title != "Coffee" {
		t.Fatalf("member previews = %+v, %v", got, err)
	}
	got, err = svc.Previews(ctx, outsider, ids)
	if err != nil || len(got) != 2 {
		t.Fatalf("outsider previews = %+v, %v; want the two public plans only", got, err)
	}
	if _, leaked := got[com.ID]; leaked {
		t.Fatal("a community plan leaked to a non-member")
	}

	// A cancelled plan still renders, as cancelled.
	if _, err := e.repo.Cancel(ctx, CancelParams{UID: host, BeaconID: gone.ID, IdemKey: idempotency.Key(host, rpcCancelBeacon, "integration-key-pv04"), RequestHash: idempotency.HashRequest(gone.ID), Now: e.now}); err != nil {
		t.Fatal(err)
	}
	got, err = svc.Previews(ctx, outsider, []string{gone.ID})
	if err != nil || got[gone.ID].Status != StatusCancelled {
		t.Fatalf("cancelled preview = %+v, %v", got, err)
	}

	// A block either way makes the plan unavailable.
	g.snaps[outsider] = graph.Snapshot{Blocked: map[string]bool{host: true}}
	if got, err = svc.Previews(ctx, outsider, []string{pub.ID}); err != nil || len(got) != 0 {
		t.Fatalf("blocked preview = %+v, %v", got, err)
	}

	// EmbedTarget: the organiser's own live plan only; cancelled and someone else's are refused; the plan seen live.
	if _, err := svc.EmbedTarget(ctx, host, pub.ID); err != nil {
		t.Fatalf("own plan: %v", err)
	}
	if _, err := svc.EmbedTarget(ctx, host, gone.ID); !errors.Is(err, ErrCancelled) {
		t.Fatalf("cancelled: %v", err)
	}
	if _, err := svc.EmbedTarget(ctx, member, pub.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("someone else's plan: %v", err)
	}
}
