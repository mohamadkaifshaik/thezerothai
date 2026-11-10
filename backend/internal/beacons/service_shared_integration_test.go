//go:build integration

package beacons

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// sharedIT is the real repo (emulator) under the real service, with fake directory, graph and communities.
type sharedIT struct {
	*repoEnv
	svc   Service
	graph *fakeGraph
	comm  *fakeCommunities
	flags fakeFlags
}

const (
	itMe   = "it-me"
	itPeer = "it-peer"
	itHost = "it-host"
)

func newSharedIT(t *testing.T) *sharedIT {
	t.Helper()
	e := newRepoEnv(t)
	dir := &fakeDirectory{profiles: map[string]identity.Profile{}}
	for _, u := range []string{itMe, itPeer, itHost} {
		dir.profiles[u] = activeProfile(u)
	}
	s := &sharedIT{repoEnv: e, graph: &fakeGraph{snaps: map[string]graph.Snapshot{}}, comm: &fakeCommunities{roles: map[string]communities.Role{}},
		flags: fakeFlags{on: map[string]bool{communities.FlagName: true}, off: map[string]bool{}}}
	s.svc = New(Deps{
		Repo: e.repo, Directory: dir, Graph: s.graph, Communities: s.comm, CommunityFlags: s.flags,
		CursorKey: []byte("0123456789abcdef0123456789abcdef"), Limits: Limits{MaxOpenPerUser: 5, MaxPendingRequests: 10, MaxOpenSpots: 20},
		Now: func() time.Time { return e.now },
	})
	return s
}

// plan creates a beacon organised by itHost starting in `hours` hours, and makes each of who an ACCEPTED participant
// through the real request and accept transactions.
func (s *sharedIT) plan(t *testing.T, n, hours int, communityID string, who ...string) Beacon {
	t.Helper()
	b := s.create(t, itHost, fmt.Sprintf("integration-key-sh%02d", n), s.beaconAt(itHost, communityID, s.now.Add(time.Duration(hours)*time.Hour))).Beacon
	for i, u := range who {
		s.mustRequest(t, u, fmt.Sprintf("integration-key-sq%02d%02d", n, i), b.ID)
		if res, err := s.respond(itHost, fmt.Sprintf("integration-key-sr%02d%02d", n, i), b.ID, u, true, s.now); err != nil || res.Outcome != Written {
			t.Fatalf("accept %s: %+v, %v", u, res, err)
		}
	}
	return b
}

func (s *sharedIT) shared(t *testing.T, in SharedInput) Page {
	t.Helper()
	if in.PeerUID == "" {
		in.PeerUID = itPeer
	}
	p, err := s.svc.ListShared(context.Background(), itMe, in)
	if err != nil {
		t.Fatalf("ListShared: %v", err)
	}
	return p
}

func TestIntegrationListShared_RepoPaths(t *testing.T) {
	s := newSharedIT(t)
	ctx := context.Background()
	both := s.plan(t, 1, 2, "", itMe, itPeer)
	mineOnly := s.plan(t, 2, 3, "", itMe)
	peerOnly := s.plan(t, 3, 4, "", itPeer)
	requested := s.plan(t, 4, 5, "")
	s.mustRequest(t, itMe, "integration-key-sq0400", requested.ID)
	s.mustRequest(t, itPeer, "integration-key-sq0401", requested.ID)
	own := s.create(t, itMe, "integration-key-sh05", s.beaconAt(itMe, "", s.now.Add(6*time.Hour))).Beacon
	s.mustRequest(t, itPeer, "integration-key-sq0500", own.ID)
	if _, err := s.respond(itMe, "integration-key-sr0500", own.ID, itPeer, true, s.now); err != nil {
		t.Fatal(err)
	}

	// GetMemberships: one GetAll; a missing row is absent.
	got, err := s.repo.GetMemberships(ctx, itPeer, []string{both.ID, mineOnly.ID, peerOnly.ID, own.ID})
	if err != nil || len(got) != 3 || got[both.ID].Role != RoleParticipant || got[both.ID].State != PStateAccepted || got[own.ID].BeaconID != own.ID {
		t.Fatalf("GetMemberships = %+v, %v", got, err)
	}
	if _, ok := got[mineOnly.ID]; ok {
		t.Fatal("peer has no row on mineOnly")
	}
	if empty, err := s.repo.GetMemberships(ctx, itPeer, nil); err != nil || len(empty) != 0 {
		t.Fatalf("GetMemberships(nil) = %v, %v", empty, err)
	}

	// The organiser-or-participant role filter drops the viewer's REQUESTED rows at the query, and the page keeps only
	// beacons both are in: both (viewer accepted) and own (viewer organiser).
	page := s.shared(t, SharedInput{})
	if got := viewIDs(page.Views); fmt.Sprint(got) != fmt.Sprint([]string{both.ID, own.ID}) {
		t.Fatalf("shared = %v, want [%s %s]", got, both.ID, own.ID)
	}
	if page.Views[1].Viewer.Role != RoleOrganiser || page.Views[0].Viewer.ParticipantState != PStateAccepted {
		t.Fatalf("viewer states = %+v / %+v", page.Views[0].Viewer, page.Views[1].Viewer)
	}
}

// TestIntegrationListShared_Visibility: community (both sides still members), blocked and ended or cancelled.
func TestIntegrationListShared_Visibility(t *testing.T) {
	s := newSharedIT(t)
	ctx := context.Background()
	pub := s.plan(t, 1, 2, "", itMe, itPeer)
	com := s.plan(t, 2, 3, itCommunity, itMe, itPeer)
	s.comm.roles = map[string]communities.Role{itCommunity + "|" + itMe: communities.RoleMember, itCommunity + "|" + itPeer: communities.RoleMember}
	ids := func() []string { return viewIDs(s.shared(t, SharedInput{}).Views) }
	if got, want := ids(), []string{pub.ID, com.ID}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("both members: %v, want %v", got, want)
	}

	// The peer left the community: the community plan disappears for the viewer; the public one stays.
	s.comm.roles[itCommunity+"|"+itPeer] = communities.RoleNone
	if got := ids(); fmt.Sprint(got) != fmt.Sprint([]string{pub.ID}) {
		t.Fatalf("peer left the community: %v", got)
	}
	s.comm.roles[itCommunity+"|"+itPeer] = communities.RoleMember
	s.comm.roles[itCommunity+"|"+itMe] = communities.RoleBanned
	if got := ids(); fmt.Sprint(got) != fmt.Sprint([]string{pub.ID}) {
		t.Fatalf("viewer banned from the community: %v", got)
	}
	s.comm.roles[itCommunity+"|"+itMe] = communities.RoleMember

	// Cancelled drops; so does an ended plan (the clock moves past its end).
	if _, err := s.repo.Cancel(ctx, CancelParams{UID: itHost, BeaconID: com.ID, IdemKey: idempotency.Key(itHost, rpcCancelBeacon, "integration-key-sxc1"), RequestHash: idempotency.HashRequest(com.ID), Now: s.now}); err != nil {
		t.Fatal(err)
	}
	if got := ids(); fmt.Sprint(got) != fmt.Sprint([]string{pub.ID}) {
		t.Fatalf("cancelled: %v", got)
	}
	svcLater := New(Deps{
		Repo: s.repo, Directory: &fakeDirectory{profiles: map[string]identity.Profile{itMe: activeProfile(itMe), itPeer: activeProfile(itPeer), itHost: activeProfile(itHost)}},
		Graph: s.graph, Communities: s.comm, CommunityFlags: s.flags, CursorKey: []byte("0123456789abcdef0123456789abcdef"),
		Now: func() time.Time { return s.now.Add(3 * time.Hour) },
	})
	if p, err := svcLater.ListShared(ctx, itMe, SharedInput{PeerUID: itPeer}); err != nil || len(p.Views) != 0 {
		t.Fatalf("ended: %v, %v (the memberships query is upcoming-only, so the ended plan is not even read)", viewIDs(p.Views), err)
	}

	// A block either way hides everything.
	s.graph.snaps[itMe] = graph.Snapshot{Blocked: map[string]bool{itPeer: true}}
	if got := ids(); len(got) != 0 {
		t.Fatalf("blocked: %v", got)
	}
	s.graph.snaps[itMe] = graph.Snapshot{BlockedBy: map[string]bool{itPeer: true}}
	if got := ids(); len(got) != 0 {
		t.Fatalf("blocked by peer: %v", got)
	}
	// Leaving drops the plan for the peer's side too: the peer left pub, so it is no longer shared.
	s.graph.snaps[itMe] = graph.Snapshot{}
	if _, err := s.repo.Leave(ctx, s.state(itPeer, rpcLeaveBeacon, "integration-key-sxl1", pub.ID, itPeer, s.now)); err != nil {
		t.Fatal(err)
	}
	if got := ids(); len(got) != 0 {
		t.Fatalf("peer left the plan: %v", got)
	}
}
