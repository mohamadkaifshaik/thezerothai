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

type qjAllOn struct{}

func (qjAllOn) Enabled(string, string) bool { return true }

// TestIntegrationRequestToJoin_QuickJoinFollowGated drives the real beacons service over the real repository, the real
// graph service (the follow edge is made by graph.Follow, never by writing graph storage) and the real identity
// directory on the emulator. With FEATURE_BEACON_QUICK_JOIN on: the followed caller sees quick_join_allowed and joins
// with an empty note; the caller the organiser does not follow sees false, is refused note_required with nothing written,
// and joins with a note. With the flag off the same empty note is accepted. Each service is a cold instance (fresh graph
// and identity caches) so no 60 s cache hides the edge.
func TestIntegrationRequestToJoin_QuickJoinFollowGated(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const (
		org      = "it-qj-org"
		friend   = "it-qj-friend"
		stranger = "it-qj-stranger"
		other    = "it-qj-other"
	)
	graphRepo := graph.NewFirestoreRepo(e.client)
	identityRepo := identity.NewFirestoreRepo(e.client, graphRepo)
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)
	type graphSvc interface {
		graph.Service
		graph.Reader
	}
	cold := func() (graphSvc, identity.Directory) {
		g := graph.New(graph.Deps{Repo: graphRepo, Cache: graph.NewCache(time.Minute), Flags: qjAllOn{}})
		i := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour)
		g.SetDirectory(i.(identity.Directory))
		return g, i.(identity.Directory)
	}
	idSvc := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour)
	for uid, h := range map[string]string{org: "qjorg", friend: "qjfriend", stranger: "qjstranger", other: "qjother"} {
		if _, err := idSvc.CreateProfile(ctx, uid, "0123456789abcdef", h, "N"); err != nil {
			t.Fatalf("CreateProfile %s: %v", uid, err)
		}
	}
	g, _ := cold()
	if rel, err := g.Follow(ctx, org, "integration-key-qjf1", friend); err != nil || rel.FollowState != graph.FollowStateFollowing {
		t.Fatalf("organiser follows friend: %+v, %v", rel, err)
	}
	// The stranger follows the organiser: the wrong direction never unlocks a one-tap join.
	if _, err := g.Follow(ctx, stranger, "integration-key-qjf2", org); err != nil {
		t.Fatalf("stranger follows organiser: %v", err)
	}
	b := e.create(t, org, itKeyA, e.beaconAt(org, "", e.now.Add(2*time.Hour))).Beacon

	svcWith := func(quick bool) Service {
		gs, dir := cold()
		fl := fakeFlags{on: map[string]bool{FlagName: true, QuickJoinFlagName: quick, communities.FlagName: true}, off: map[string]bool{}}
		return New(Deps{
			Repo: e.repo, Directory: dir, Graph: gs, Communities: &fakeCommunities{roles: map[string]communities.Role{}},
			CommunityFlags: fl, Flags: fl, CursorKey: []byte("0123456789abcdef0123456789abcdef"),
			Limits: Limits{MaxOpenPerUser: 5, MaxPendingRequests: 10, MaxOpenSpots: 20},
			Now:    func() time.Time { return e.now },
		})
	}

	on := svcWith(true)
	for _, tc := range []struct {
		uid  string
		want bool
	}{{friend, true}, {stranger, false}} {
		v, err := on.GetBeacon(ctx, tc.uid, b.ID)
		if err != nil || v.Viewer.QuickJoinAllowed != tc.want || !v.Viewer.CanRequest {
			t.Fatalf("GetBeacon(%s) = %+v, %v, want quick_join_allowed %v", tc.uid, v.Viewer, err, tc.want)
		}
	}

	// The followed caller joins with an empty (whitespace) note.
	vs, err := svcWith(true).RequestToJoin(ctx, friend, "integration-key-qjr1", b.ID, "  ")
	if err != nil || vs.ParticipantState != PStateRequested {
		t.Fatalf("friend one-tap = %+v, %v", vs, err)
	}
	if p, err := e.repo.GetParticipant(ctx, b.ID, friend); err != nil || p.State != PStateRequested || p.Note != "" {
		t.Fatalf("friend row = %+v, %v", p, err)
	}

	// The caller the organiser does not follow is refused, and nothing is written.
	_, err = svcWith(true).RequestToJoin(ctx, stranger, "integration-key-qjr2", b.ID, "")
	assertPrecondition(t, err, "note_required")
	if _, err := e.repo.GetParticipant(ctx, b.ID, stranger); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stranger row after refusal: %v, want ErrNotFound", err)
	}
	// With a note the same caller may ask.
	if vs, err := svcWith(true).RequestToJoin(ctx, stranger, "integration-key-qjr3", b.ID, "I bring snacks"); err != nil || vs.ParticipantState != PStateRequested {
		t.Fatalf("stranger with note = %+v, %v", vs, err)
	}

	// Flag off: the note stays optional for everyone, and quick_join_allowed stays false.
	off := svcWith(false)
	if v, err := off.GetBeacon(ctx, other, b.ID); err != nil || v.Viewer.QuickJoinAllowed {
		t.Fatalf("flag off GetBeacon = %+v, %v", v.Viewer, err)
	}
	if vs, err := off.RequestToJoin(ctx, other, "integration-key-qjr4", b.ID, ""); err != nil || vs.ParticipantState != PStateRequested {
		t.Fatalf("flag off empty note = %+v, %v", vs, err)
	}
}

// TestRepo_RequestPrecheckOnlyWhenWriting: RequestParams.Precheck runs after the idempotency lookup missed and after the
// state checks: a refusal writes nothing, a same-key replay never runs it, an ACCEPTED caller's request and an
// already-requested one answer without it.
func TestRepo_RequestPrecheckOnlyWhenWriting(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	b := e.create(t, "org-rq", itKeyA, e.beaconAt("org-rq", "", e.now.Add(time.Hour))).Beacon
	ran := 0
	ok := func(context.Context) error { ran++; return nil }
	refuse := func(context.Context) error { ran++; return ErrNoteRequired }
	params := func(uid, key string, pre func(context.Context) error) RequestParams {
		return RequestParams{
			UID: uid, BeaconID: b.ID, IdemKey: idempotency.Key(uid, rpcRequestToJoin, key), RequestHash: idempotency.HashRequest(b.ID + "|"),
			MaxPending: 10, Now: e.now, Precheck: pre,
		}
	}
	if _, err := e.repo.Request(ctx, params("rq-p1", "integration-key-rq01", refuse)); !errors.Is(err, ErrNoteRequired) || ran != 1 {
		t.Fatalf("refused = %v (ran %d), want ErrNoteRequired", err, ran)
	}
	if _, err := e.repo.GetParticipant(ctx, b.ID, "rq-p1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("row after a refusal: %v, want ErrNotFound", err)
	}
	res, err := e.repo.Request(ctx, params("rq-p1", "integration-key-rq02", ok))
	if err != nil || res.Outcome != Written || ran != 2 {
		t.Fatalf("allowed = %+v, %v (ran %d)", res.Outcome, err, ran)
	}
	res, err = e.repo.Request(ctx, params("rq-p1", "integration-key-rq02", refuse))
	if err != nil || res.Outcome != Replayed || ran != 2 {
		t.Fatalf("same-key retry = %+v, %v (ran %d), want a replay without the precheck", res.Outcome, err, ran)
	}
	if _, err := e.repo.Request(ctx, params("rq-p1", "integration-key-rq03", refuse)); !errors.Is(err, ErrAlreadyRequested) || ran != 2 {
		t.Fatalf("already requested = %v (ran %d), want ErrAlreadyRequested before the precheck", err, ran)
	}
}
