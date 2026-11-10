package beacons

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// previewBeacon stores one open public beacon organised by testOrganiser, number n.
func (e *env) previewBeacon(n int) Beacon {
	b := e.openBeacon()
	b.ID = fmt.Sprintf("%019d", 400+n)
	e.repo.docs[b.ID] = b
	return b
}

func TestPreviews_PerViewerRules(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(e *env, b *Beacon)
		viewer string
		want   bool
		status Status
	}{
		{"open public", func(*env, *Beacon) {}, testViewer, true, StatusOpen},
		{"full", func(_ *env, b *Beacon) { b.Status = StatusFull }, testViewer, true, StatusFull},
		{"cancelled renders cancelled", func(_ *env, b *Beacon) { b.Status = StatusCancelled }, testViewer, true, StatusCancelled},
		{"ended renders ended", func(e *env, b *Beacon) { b.EndAt = e.now.Add(-time.Minute) }, testViewer, true, StatusEnded},
		{"hidden is unavailable", func(_ *env, b *Beacon) { b.Hidden = true }, testViewer, false, ""},
		{"hidden still shows to its organiser", func(_ *env, b *Beacon) { b.Hidden = true }, testOrganiser, true, StatusOpen},
		{"viewer blocked the organiser", func(e *env, _ *Beacon) {
			e.graph.snaps[testViewer] = graph.Snapshot{Blocked: map[string]bool{testOrganiser: true}}
		}, testViewer, false, ""},
		{"organiser blocked the viewer", func(e *env, _ *Beacon) {
			e.graph.snaps[testViewer] = graph.Snapshot{BlockedBy: map[string]bool{testOrganiser: true}}
		}, testViewer, false, ""},
		{"community plan, viewer a member", func(e *env, b *Beacon) {
			b.CommunityID = testCommunity
			e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
		}, testViewer, true, StatusOpen},
		{"community plan, viewer not a member (audience leak)", func(_ *env, b *Beacon) { b.CommunityID = testCommunity }, testViewer, false, ""},
		{"community plan, viewer banned", func(e *env, b *Beacon) {
			b.CommunityID = testCommunity
			e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleBanned
		}, testViewer, false, ""},
		{"community plan, community suspended", func(e *env, b *Beacon) {
			b.CommunityID = testCommunity
			e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
			e.comm.status = map[string]communities.Status{testCommunity: communities.StatusSuspended}
		}, testViewer, false, ""},
		{"community plan, communities flag globally off", func(e *env, b *Beacon) {
			b.CommunityID = testCommunity
			e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
			e.flags.off[communities.FlagName] = true
		}, testViewer, false, ""},
		{"community plan, an organiser who left still sees their own", func(_ *env, b *Beacon) { b.CommunityID = testCommunity }, testOrganiser, true, StatusOpen},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			b := e.previewBeacon(0)
			tc.mutate(e, &b)
			e.repo.docs[b.ID] = b
			got, err := e.svc.Previews(context.Background(), tc.viewer, []string{b.ID})
			if err != nil {
				t.Fatal(err)
			}
			p, ok := got[b.ID]
			if ok != tc.want {
				t.Fatalf("present = %v, want %v (%+v)", ok, tc.want, got)
			}
			if ok && (p.Status != tc.status || p.Title != b.Title || p.OrganiserID != testOrganiser || p.CommunityID != b.CommunityID || !p.StartAt.Equal(b.StartAt)) {
				t.Fatalf("preview = %+v", p)
			}
		})
	}
}

func TestPreviews_BatchAndBounds(t *testing.T) {
	e := newEnv()
	a, b := e.previewBeacon(0), e.previewBeacon(1)
	got, err := e.svc.Previews(context.Background(), testViewer, []string{a.ID, b.ID, a.ID, "junk", "0000000000000000999"})
	if err != nil || len(got) != 2 {
		t.Fatalf("previews = %v, %v; want the two real plans", got, err)
	}
	if len(e.repo.beaconBatches) != 1 || fmt.Sprint(e.repo.beaconBatches[0]) != fmt.Sprint([]string{a.ID, b.ID, "0000000000000000999"}) {
		t.Fatalf("beacon batches = %v, want one deduplicated GetAll", e.repo.beaconBatches)
	}
	if len(e.repo.participantBatches) != 0 || len(e.repo.mqueries) != 0 || e.dir.calls != 1 {
		t.Fatalf("previews read no participant rows or memberships and one organiser batch (profiles: %d)", e.dir.calls)
	}
	// No valid id: no read. The cap: at most maxPreviewIDs ids go to the one batch.
	e2 := newEnv()
	if got, err := e2.svc.Previews(context.Background(), testViewer, []string{"junk", ""}); err != nil || len(got) != 0 || e2.repo.calls() != 0 {
		t.Fatalf("no valid id: %v, %v, calls=%d", got, err, e2.repo.calls())
	}
	var many []string
	for i := range maxPreviewIDs + 20 {
		many = append(many, fmt.Sprintf("%019d", 1000+i))
	}
	if _, err := e2.svc.Previews(context.Background(), testViewer, many); err != nil {
		t.Fatal(err)
	}
	if len(e2.repo.beaconBatches) != 1 || len(e2.repo.beaconBatches[0]) != maxPreviewIDs {
		t.Fatalf("batch size = %v, want %d", len(e2.repo.beaconBatches[0]), maxPreviewIDs)
	}
}

func TestPreviews_FlagAndErrors(t *testing.T) {
	e := newEnv()
	b := e.previewBeacon(0)
	e.flags.off[FlagName] = true
	if got, err := e.svc.Previews(context.Background(), testViewer, []string{b.ID}); err != nil || len(got) != 0 || e.repo.calls() != 0 {
		t.Fatalf("beacons globally off: %v, %v, calls=%d; want empty and no read", got, err, e.repo.calls())
	}
	e = newEnv()
	b = e.previewBeacon(0)
	e.repo.err = errors.New("boom")
	if _, err := e.svc.Previews(context.Background(), testViewer, []string{b.ID}); err == nil {
		t.Fatal("a failed read must be an error, so the caller degrades closed")
	}
	e = newEnv()
	b = e.previewBeacon(0)
	e.graph.err = errors.New("graph down")
	if _, err := e.svc.Previews(context.Background(), testViewer, []string{b.ID}); err == nil {
		t.Fatal("a failed graph read must not render the plan")
	}
	// The organiser's own plan needs no graph read at all.
	e = newEnv()
	b = e.previewBeacon(0)
	e.graph.err = errors.New("graph down")
	if got, err := e.svc.Previews(context.Background(), testOrganiser, []string{b.ID}); err != nil || len(got) != 1 {
		t.Fatalf("organiser preview = %v, %v", got, err)
	}
}

func TestEmbedTarget(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(e *env, b *Beacon)
		uid    string
		flagOn bool
		err    error
		feat   string
	}{
		{"own open plan", func(*env, *Beacon) {}, testOrganiser, true, nil, ""},
		{"own full plan", func(_ *env, b *Beacon) { b.Status = StatusFull }, testOrganiser, true, nil, ""},
		{"another user's plan is not found", func(*env, *Beacon) {}, testViewer, true, ErrNotFound, ""},
		{"hidden is not found", func(_ *env, b *Beacon) { b.Hidden = true }, testOrganiser, true, ErrNotFound, ""},
		{"cancelled", func(_ *env, b *Beacon) { b.Status = StatusCancelled }, testOrganiser, true, ErrCancelled, ""},
		{"ended", func(e *env, b *Beacon) { b.EndAt = e.now.Add(-time.Second) }, testOrganiser, true, ErrEnded, ""},
		{"beacons flag off for the caller", func(*env, *Beacon) {}, testOrganiser, false, nil, FlagName},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			e.flags.on[FlagName] = tc.flagOn
			b := e.previewBeacon(0)
			tc.mutate(e, &b)
			e.repo.docs[b.ID] = b
			p, err := e.svc.EmbedTarget(context.Background(), tc.uid, b.ID)
			switch {
			case tc.feat != "":
				assertDisabled(t, err, tc.feat)
				if e.repo.calls() != 0 {
					t.Fatal("a disabled flag must do no Firestore work")
				}
			case tc.err != nil:
				if !errors.Is(err, tc.err) {
					t.Fatalf("err = %v, want %v", err, tc.err)
				}
			default:
				if err != nil || p.BeaconID != b.ID || p.OrganiserID != testOrganiser || p.Title != b.Title {
					t.Fatalf("target = %+v, %v", p, err)
				}
			}
		})
	}
	e := newEnv()
	e.flags.on[FlagName] = true
	if _, err := e.svc.EmbedTarget(context.Background(), testOrganiser, "junk"); !errors.Is(err, ErrNotFound) || e.repo.calls() != 0 {
		t.Fatalf("a malformed id is not found with no read: %v", err)
	}
	if _, err := e.svc.EmbedTarget(context.Background(), testOrganiser, "0000000000000000999"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("a missing plan: %v", err)
	}
}

// Security review Low 2: a plan whose organiser is SUSPENDED, DELETING or has no users doc renders "Plan unavailable" (absent
// from the map), like a missing or hidden plan. The organisers are read in one batch, never for the viewer's own plans, and a
// Directory failure fails the call (the caller degrades closed).
func TestPreviews_OrganiserStatus(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  func(e *env)
		want bool
	}{
		{"ACTIVE organiser", func(*env) {}, true},
		{"SUSPENDED organiser", func(e *env) {
			e.dir.profiles[testOrganiser] = identity.Profile{UserID: testOrganiser, Status: identity.AccountStatusSuspended}
		}, false},
		{"DELETING organiser", func(e *env) {
			e.dir.profiles[testOrganiser] = identity.Profile{UserID: testOrganiser, Status: identity.AccountStatusDeleting}
		}, false},
		{"organiser with no users doc", func(e *env) { delete(e.dir.profiles, testOrganiser) }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			b := e.previewBeacon(0)
			tc.set(e)
			got, err := e.svc.Previews(context.Background(), testViewer, []string{b.ID})
			if err != nil {
				t.Fatal(err)
			}
			if _, ok := got[b.ID]; ok != tc.want {
				t.Fatalf("present = %v, want %v", ok, tc.want)
			}
		})
	}

	// Many plans by distinct organisers: one batch.
	e := newEnv()
	var ids []string
	for i := range 5 {
		b := e.previewBeacon(i)
		b.OrganiserID = fmt.Sprintf("uid-org-%d", i)
		e.repo.docs[b.ID] = b
		if i != 3 {
			e.dir.profiles[b.OrganiserID] = activeProfile(b.OrganiserID)
		}
		ids = append(ids, b.ID)
	}
	got, err := e.svc.Previews(context.Background(), testViewer, ids)
	if err != nil || len(got) != 4 || e.dir.calls != 1 {
		t.Fatalf("previews = %d, err %v, profile calls %d; want 4 and one batch", len(got), err, e.dir.calls)
	}

	// The viewer's own plans need no profile read; a failure fails the call.
	e = newEnv()
	b := e.previewBeacon(0)
	e.dir.err = errors.New("down")
	if got, err := e.svc.Previews(context.Background(), testOrganiser, []string{b.ID}); err != nil || len(got) != 1 || e.dir.calls != 0 {
		t.Fatalf("own plan: %v, %v, calls %d", got, err, e.dir.calls)
	}
	if _, err := e.svc.Previews(context.Background(), testViewer, []string{b.ID}); err == nil {
		t.Fatal("a Directory failure must not render the plan")
	}
}
