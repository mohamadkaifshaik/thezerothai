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
)

// F28b on the emulator: a community plan made public (the one widening: community < public).

// audienceSvc is the real service over the real repository, with the organiser a JOINED member of itCommunity and the
// stranger in no community.
func audienceSvc(e *repoEnv, org string, uids ...string) Service {
	profiles := map[string]identity.Profile{org: activeProfile(org)}
	for _, u := range uids {
		profiles[u] = activeProfile(u)
	}
	fl := fakeFlags{on: map[string]bool{FlagName: true, communities.FlagName: true}, off: map[string]bool{}}
	return New(Deps{
		Repo: e.repo, Directory: &fakeDirectory{profiles: profiles}, Graph: &fakeGraph{snaps: map[string]graph.Snapshot{}},
		Communities:    &fakeCommunities{roles: map[string]communities.Role{itCommunity + "|" + org: communities.RoleMember}},
		CommunityFlags: fl, Flags: fl, Events: &fakeEvents{}, CursorKey: []byte("0123456789abcdef0123456789abcdef"),
		Limits: Limits{MaxOpenPerUser: 5, MaxPendingRequests: 10, MaxOpenSpots: 20},
		Now:    func() time.Time { return e.now },
	})
}

func (e *rescheduleEnv) docString(t *testing.T, path, field string) string {
	t.Helper()
	s, err := e.client.Doc(path).Get(context.Background())
	if err != nil {
		t.Fatalf("get %s: %v", path, err)
	}
	v, err := s.DataAt(field)
	if err != nil {
		t.Fatalf("%s.%s: %v", path, field, err)
	}
	str, _ := v.(string)
	return str
}

func listsBeacon(p Page, id string) bool {
	for _, v := range p.Views {
		if v.Beacon.ID == id {
			return true
		}
	}
	return false
}

// TestIntegrationUpdateBeacon_WidenCommunityToPublic: before the widening a stranger (no community) cannot see the plan
// and it is not on the public list; UpdateBeacon(public = true) by the organiser makes the beacon and every membership row
// public in one commit, without a notice; then the stranger sees it, finds it on the public list and asks to join; the
// accepted participants keep their seats. A same-key retry answers the same; moving it back into the community is refused
// as narrowing and changes nothing.
func TestIntegrationUpdateBeacon_WidenCommunityToPublic(t *testing.T) {
	const org, stranger = "it-wd-org", "it-wd-stranger"
	e := newRescheduleEnv(t, org)
	ctx := context.Background()
	svc := audienceSvc(e.repoEnv, org, stranger, "p1", "p2", "r1", "d1")

	_, err := svc.GetBeacon(ctx, stranger, e.b.ID)
	assertForbidden(t, err, "not_member")
	if page, err := svc.ListBeacons(ctx, stranger, ListInput{Public: true}); err != nil || listsBeacon(page, e.b.ID) {
		t.Fatalf("public list before = %+v, %v; want without the community plan", page.Views, err)
	}

	widen := UpdateInput{Key: "integration-key-wd01", BeaconID: e.b.ID, Audience: &AudienceInput{Public: true}}
	v, err := svc.UpdateBeacon(ctx, org, widen)
	if err != nil || v.Beacon.CommunityID != "" || v.Beacon.AcceptedCount != 2 {
		t.Fatalf("widen = %+v, %v", v.Beacon, err)
	}
	b, err := e.repo.Get(ctx, e.b.ID)
	if err != nil || b.CommunityID != "" || !b.StartAt.Equal(e.b.StartAt) || b.AcceptedCount != 2 {
		t.Fatalf("stored beacon = %+v, %v", b, err)
	}
	for _, u := range []string{org, "p1", "p2", "r1", "d1"} {
		if got := e.docString(t, "users/"+u+"/beaconMemberships/"+e.b.ID, "communityId"); got != "" {
			t.Errorf("membership %s communityId = %q, want public", u, got)
		}
	}
	for _, u := range []string{"p1", "p2"} {
		if p, err := e.repo.GetParticipant(ctx, e.b.ID, u); err != nil || p.State != PStateAccepted {
			t.Errorf("participant %s = %+v, %v; want still ACCEPTED", u, p, err)
		}
	}
	if again, err := svc.UpdateBeacon(ctx, org, widen); err != nil || again.Beacon.CommunityID != "" {
		t.Fatalf("same-key retry = %+v, %v", again.Beacon, err)
	}

	gv, err := svc.GetBeacon(ctx, stranger, e.b.ID)
	if err != nil || !gv.Viewer.CanRequest {
		t.Fatalf("stranger GetBeacon after = %+v, %v", gv.Viewer, err)
	}
	if page, err := svc.ListBeacons(ctx, stranger, ListInput{Public: true}); err != nil || !listsBeacon(page, e.b.ID) {
		t.Fatalf("public list after = %+v, %v; want the widened plan", page.Views, err)
	}
	vs, err := svc.RequestToJoin(ctx, stranger, "integration-key-wd02", e.b.ID, "Hi")
	if err != nil || vs.ParticipantState != PStateRequested {
		t.Fatalf("stranger RequestToJoin = %+v, %v", vs, err)
	}
	if got := e.docString(t, "users/"+stranger+"/beaconMemberships/"+e.b.ID, "communityId"); got != "" {
		t.Fatalf("new requester membership communityId = %q, want public", got)
	}

	_, err = svc.UpdateBeacon(ctx, org, UpdateInput{Key: "integration-key-wd03", BeaconID: e.b.ID, Audience: &AudienceInput{CommunityID: itCommunity}})
	assertAudienceRefused(t, err, reasonAudienceNarrowing)
	if b, err := e.repo.Get(ctx, e.b.ID); err != nil || b.CommunityID != "" {
		t.Fatalf("after the refused narrowing = %+v, %v; want still public", b, err)
	}
}

// TestRepo_AudienceDecidedInTheTransaction: the repository refuses on the stored doc, whatever the caller checked before:
// public into a community is ErrAudienceNarrowing and one community into another ErrAudienceIncompatible, each writing
// nothing (no idempotency record, so a corrected retry with the same key is free); the stored audience resent is
// Unchanged.
func TestRepo_AudienceDecidedInTheTransaction(t *testing.T) {
	e := newRescheduleEnv(t, "org-wd2")
	ctx := context.Background()
	other := "9876543210987654321"
	_, err := e.update("org-wd2", "integration-key-wd11", UpdateParams{AudienceCommunityID: &other, MaxEditRows: MaxEditRows})
	if !errors.Is(err, ErrAudienceIncompatible) {
		t.Fatalf("community -> other community = %v, want ErrAudienceIncompatible", err)
	}
	same := itCommunity
	if res, err := e.update("org-wd2", "integration-key-wd12", UpdateParams{AudienceCommunityID: &same, MaxEditRows: MaxEditRows}); err != nil || res.Outcome != Unchanged || res.Widened {
		t.Fatalf("stored audience resent = %+v, %v, want Unchanged", res, err)
	}
	public := ""
	res, err := e.update("org-wd2", "integration-key-wd11", UpdateParams{AudienceCommunityID: &public, MaxEditRows: MaxEditRows})
	if err != nil || res.Outcome != Written || !res.Widened || res.Rescheduled || res.Beacon.CommunityID != "" {
		t.Fatalf("widen after the refusal, same key = %+v, %v", res, err)
	}
	_, err = e.update("org-wd2", "integration-key-wd13", UpdateParams{AudienceCommunityID: &same, MaxEditRows: MaxEditRows})
	if !errors.Is(err, ErrAudienceNarrowing) {
		t.Fatalf("public -> community = %v, want ErrAudienceNarrowing", err)
	}
	if b, err := e.repo.Get(ctx, e.b.ID); err != nil || b.CommunityID != "" {
		t.Fatalf("beacon = %+v, %v; want still public", b, err)
	}
}

// TestRepo_WidenWithReschedule: one request that widens and moves the start writes each membership row once with both
// the new window and communityId "", and announces the reschedule (the widening adds no one).
func TestRepo_WidenWithReschedule(t *testing.T) {
	e := newRescheduleEnv(t, "org-wd3")
	newStart := e.now.Add(6 * time.Hour)
	public := ""
	res, err := e.update("org-wd3", "integration-key-wd21", UpdateParams{StartAt: &newStart, AudienceCommunityID: &public, MaxEditRows: MaxEditRows})
	if err != nil || res.Outcome != Written || !res.Widened || !res.Rescheduled || len(res.Accepted) != 2 {
		t.Fatalf("widen + reschedule = %+v, %v", res, err)
	}
	end := newStart.Add(time.Duration(e.b.DurationMin) * time.Minute)
	for _, u := range []string{"org-wd3", "p1", "p2", "r1", "d1"} {
		path := "users/" + u + "/beaconMemberships/" + e.b.ID
		if got := e.docString(t, path, "communityId"); got != "" {
			t.Errorf("membership %s communityId = %q, want public", u, got)
		}
		if s, en := e.docTime(t, path, "startAt"), e.docTime(t, path, "endAt"); !s.Equal(newStart) || !en.Equal(end) {
			t.Errorf("membership %s window = %v..%v, want %v..%v", u, s, en, newStart, end)
		}
	}
}

// TestRepo_WidenAfterStart: widening is allowed once the plan started (people may still ask to join) while a reschedule
// is not; on an ENDED plan it is refused like every edit.
func TestRepo_WidenAfterStart(t *testing.T) {
	e := newRescheduleEnv(t, "org-wd4")
	public := ""
	started := e.b.StartAt.Add(time.Minute)
	if res, err := e.update("org-wd4", "integration-key-wd31", UpdateParams{AudienceCommunityID: &public, MaxEditRows: MaxEditRows, Now: started}); err != nil || !res.Widened {
		t.Fatalf("widen after start = %+v, %v", res, err)
	}
	e2 := newRescheduleEnv(t, "org-wd5")
	if _, err := e2.update("org-wd5", "integration-key-wd32", UpdateParams{AudienceCommunityID: &public, MaxEditRows: MaxEditRows, Now: e2.b.EndAt}); !errors.Is(err, ErrEnded) {
		t.Fatalf("widen after end = %v, want ErrEnded", err)
	}
}
