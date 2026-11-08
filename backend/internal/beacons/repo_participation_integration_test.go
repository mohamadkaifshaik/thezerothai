//go:build integration

package beacons

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

func (e *repoEnv) request(uid, key, beaconID, note string, maxPending int, now time.Time) (ParticipantResult, error) {
	return e.repo.Request(context.Background(), RequestParams{
		UID: uid, BeaconID: beaconID, IdemKey: idempotency.Key(uid, rpcRequestToJoin, key), RequestHash: idempotency.HashRequest(beaconID + "|" + note),
		Note: note, MaxPending: maxPending, Now: now,
	})
}

func (e *repoEnv) respond(org, key, beaconID, target string, accept bool, now time.Time) (ParticipantResult, error) {
	return e.repo.Respond(context.Background(), RespondParams{
		UID: org, BeaconID: beaconID, TargetUID: target, IdemKey: idempotency.Key(org, rpcRespondToJoinRequest, key),
		RequestHash: idempotency.HashRequest(fmt.Sprintf("%s|%s|%v", beaconID, target, accept)), Accept: accept, Now: now,
	})
}

func (e *repoEnv) state(uid, rpc, key, beaconID, target string, now time.Time) StateParams {
	return StateParams{UID: uid, BeaconID: beaconID, TargetUID: target, IdemKey: idempotency.Key(uid, rpc, key), RequestHash: idempotency.HashRequest(beaconID + "|" + target), Now: now}
}

func (e *repoEnv) mustRequest(t *testing.T, uid, key, beaconID string) {
	t.Helper()
	if res, err := e.request(uid, key, beaconID, "", 10, e.now); err != nil || res.Outcome != Written {
		t.Fatalf("request %s: %+v, %v", uid, res.Outcome, err)
	}
}

func TestRepo_RequestWritesRowsAndReplays(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	b := e.create(t, "org-r1", itKeyA, e.beaconAt("org-r1", itCommunity, e.now.Add(time.Hour))).Beacon
	res, err := e.request("p1", "integration-key-rq01", b.ID, "  see you  ", 10, e.now)
	if err != nil || res.Outcome != Written {
		t.Fatalf("request = %+v, %v", res, err)
	}
	p := res.Participant
	if p.State != PStateRequested || p.UID != "p1" || p.Note != "  see you  " || !p.RequestedAt.Equal(e.now) || !p.ExpireAt.Equal(b.ExpireAt) {
		t.Fatalf("participant = %+v (expireAt want %v)", p, b.ExpireAt)
	}
	got, err := e.repo.GetParticipant(ctx, b.ID, "p1")
	if err != nil || got.State != PStateRequested || got.BeaconID != b.ID {
		t.Fatalf("GetParticipant = %+v, %v", got, err)
	}
	m, err := e.repo.membershipRef("p1", b.ID).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if m.Data()["role"] != RoleRequester || m.Data()["state"] != PStateRequested || m.Data()["communityId"] != itCommunity {
		t.Fatalf("membership = %v", m.Data())
	}
	if until, ok := m.Data()["pendingUntil"].(time.Time); !ok || !until.Equal(b.EndAt) {
		t.Fatalf("pendingUntil = %v, want the beacon's endAt %v", m.Data()["pendingUntil"], b.EndAt)
	}
	if _, ok := m.Data()["organiserId"]; ok {
		t.Fatal("membership row names another user (R3)")
	}
	// Replay answers the same row; a fresh key is already_requested.
	again, err := e.request("p1", "integration-key-rq01", b.ID, "  see you  ", 10, e.now)
	if err != nil || again.Outcome != Replayed || again.Participant.State != PStateRequested {
		t.Fatalf("replay = %+v, %v", again, err)
	}
	if _, err := e.request("p1", "integration-key-rq02", b.ID, "", 10, e.now); !errors.Is(err, ErrAlreadyRequested) {
		t.Fatalf("second request = %v, want ErrAlreadyRequested", err)
	}
	if _, err := e.repo.GetParticipant(ctx, b.ID, "nobody"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetParticipant(nobody) = %v, want ErrNotFound", err)
	}
}

func TestRepo_RequestRules(t *testing.T) {
	e := newRepoEnv(t)
	b := e.create(t, "org-r2", itKeyA, e.beaconAt("org-r2", "", e.now.Add(time.Hour))).Beacon
	if _, err := e.request("org-r2", "integration-key-rr01", b.ID, "", 10, e.now); !errors.Is(err, ErrOrganiser) {
		t.Fatalf("organiser self-request = %v, want ErrOrganiser", err)
	}
	if _, err := e.request("p1", "integration-key-rr02", b.ID, "", 10, b.EndAt); !errors.Is(err, ErrEnded) {
		t.Fatalf("ended = %v, want ErrEnded", err)
	}
	e.setField(t, b.ID, firestore.Update{Path: "status", Value: string(StatusFull)})
	if _, err := e.request("p1", "integration-key-rr03", b.ID, "", 10, e.now); !errors.Is(err, ErrFull) {
		t.Fatalf("full = %v, want ErrFull", err)
	}
	e.setField(t, b.ID, firestore.Update{Path: "status", Value: string(StatusCancelled)})
	if _, err := e.request("p1", "integration-key-rr04", b.ID, "", 10, e.now); !errors.Is(err, ErrCancelled) {
		t.Fatalf("cancelled = %v, want ErrCancelled", err)
	}
	e.setField(t, b.ID, firestore.Update{Path: "status", Value: string(StatusOpen)})
	e.mustRequest(t, "p1", "integration-key-rr05", b.ID)
	if _, err := e.respond("org-r2", "integration-key-rr06", b.ID, "p1", true, e.now); err != nil {
		t.Fatal(err)
	}
	res, err := e.request("p1", "integration-key-rr07", b.ID, "", 10, e.now)
	if err != nil || res.Outcome != Unchanged || res.Participant.State != PStateAccepted {
		t.Fatalf("request while accepted = %+v, %v, want Unchanged", res, err)
	}
	if _, err := e.request("p9", "integration-key-rr08", e.node.Generate(), "", 10, e.now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing beacon = %v, want ErrNotFound", err)
	}
}

func TestRepo_RequestAgainAfterDeclineWithdrawLeave(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	b := e.create(t, "org-r3", itKeyA, e.beaconAt("org-r3", "", e.now.Add(time.Hour))).Beacon
	e.mustRequest(t, "p1", "integration-key-ra01", b.ID)
	if res, err := e.respond("org-r3", "integration-key-ra02", b.ID, "p1", false, e.now); err != nil || res.Participant.State != PStateDeclined {
		t.Fatalf("decline = %+v, %v", res, err)
	}
	e.mustRequest(t, "p1", "integration-key-ra03", b.ID)
	if res, err := e.repo.Withdraw(ctx, e.state("p1", rpcWithdrawJoinRequest, "integration-key-ra04", b.ID, "p1", e.now)); err != nil || res.Participant.State != PStateWithdrawn {
		t.Fatalf("withdraw = %+v, %v", res, err)
	}
	if _, err := e.repo.Withdraw(ctx, e.state("p1", rpcWithdrawJoinRequest, "integration-key-ra05", b.ID, "p1", e.now)); !errors.Is(err, ErrNotRequested) {
		t.Fatalf("withdraw twice = %v, want ErrNotRequested", err)
	}
	e.mustRequest(t, "p1", "integration-key-ra06", b.ID)
	if _, err := e.respond("org-r3", "integration-key-ra07", b.ID, "p1", true, e.now); err != nil {
		t.Fatal(err)
	}
	if res, err := e.repo.Leave(ctx, e.state("p1", rpcLeaveBeacon, "integration-key-ra08", b.ID, "p1", e.now)); err != nil || res.Participant.State != PStateLeft {
		t.Fatalf("leave = %+v, %v", res, err)
	}
	e.mustRequest(t, "p1", "integration-key-ra09", b.ID)
	m, _ := e.repo.membershipRef("p1", b.ID).Get(ctx)
	if _, pending := m.Data()["pendingUntil"]; m.Data()["role"] != RoleRequester || !pending {
		t.Fatalf("membership after re-request = %v", m.Data())
	}
	docs, _ := e.client.Collection(beaconsCollection).Doc(b.ID).Collection(participantsSubcollection).Documents(ctx).GetAll()
	if len(docs) != 1 {
		t.Fatalf("participant docs = %d, want 1 (the row is reused)", len(docs))
	}
}

func TestRepo_PendingCapCountsLiveRequests(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	var ids []string
	for i := range 11 {
		ids = append(ids, e.createWithCap(t, "org-cap", fmt.Sprintf("integration-key-cp%02d", i), e.beaconAt("org-cap", "", e.now.Add(time.Duration(i+1)*time.Hour)), 50).Beacon.ID)
	}
	for i := range 10 {
		if res, err := e.request("cap", fmt.Sprintf("integration-key-cq%02d", i), ids[i], "", 10, e.now); err != nil || res.Outcome != Written {
			t.Fatalf("request %d: %+v, %v", i, res, err)
		}
	}
	if _, err := e.request("cap", "integration-key-cq10", ids[10], "", 10, e.now); !errors.Is(err, ErrPendingLimit) {
		t.Fatalf("11th request = %v, want ErrPendingLimit", err)
	}
	if _, err := e.repo.Withdraw(ctx, e.state("cap", rpcWithdrawJoinRequest, "integration-key-cw00", ids[0], "cap", e.now)); err != nil {
		t.Fatal(err)
	}
	if res, err := e.request("cap", "integration-key-cq11", ids[10], "", 10, e.now); err != nil || res.Outcome != Written {
		t.Fatalf("request after a withdrawal = %+v, %v, want Written", res, err)
	}
}

// TestRepo_PendingCapIgnoresEndedBeacons (review): unanswered requests on beacons that have ended stop counting, and such
// a request can still be withdrawn to clear it.
func TestRepo_PendingCapIgnoresEndedBeacons(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	var ids []string
	for i := range 10 {
		ids = append(ids, e.createWithCap(t, "org-dead", fmt.Sprintf("integration-key-dp%02d", i), e.beaconAt("org-dead", "", e.now.Add(time.Duration(i+1)*time.Hour)), 50).Beacon.ID)
	}
	for i := range 10 {
		if _, err := e.request("stale", fmt.Sprintf("integration-key-dq%02d", i), ids[i], "", 10, e.now); err != nil {
			t.Fatal(err)
		}
	}
	later := e.now.Add(12 * time.Hour) // every seeded beacon ended by now
	live := e.createWithCap(t, "org-dead", "integration-key-dp10", e.beaconAt("org-dead", "", e.now.Add(20*time.Hour)), 50).Beacon
	if res, err := e.request("stale", "integration-key-dq10", live.ID, "", 10, later); err != nil || res.Outcome != Written {
		t.Fatalf("request with 10 ended pending rows = %+v, %v, want Written", res, err)
	}
	// Withdrawing a request on an ended beacon is allowed and clears it.
	res, err := e.repo.Withdraw(ctx, e.state("stale", rpcWithdrawJoinRequest, "integration-key-dw00", ids[0], "stale", later))
	if err != nil || res.Participant.State != PStateWithdrawn {
		t.Fatalf("withdraw on an ended beacon = %+v, %v", res, err)
	}
	m, _ := e.repo.membershipRef("stale", ids[0]).Get(ctx)
	if _, pending := m.Data()["pendingUntil"]; pending {
		t.Fatalf("pendingUntil still set after withdrawal: %v", m.Data())
	}
}

// TestRepo_PendingCapIgnoresCancelledBeacons (B08): a cancel never clears the requesters' pendingUntil, so at the cap
// the counted rows are re-checked: requests on cancelled beacons stop counting and stop pending (in the admitting
// transaction), while requests on open beacons keep counting.
func TestRepo_PendingCapIgnoresCancelledBeacons(t *testing.T) {
	for _, tt := range []struct {
		name     string
		cancel   int
		admitted bool
	}{
		{name: "none cancelled", cancel: 0, admitted: false},
		{name: "one of ten cancelled", cancel: 1, admitted: true},
		{name: "all ten cancelled", cancel: 10, admitted: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newRepoEnv(t)
			ctx := context.Background()
			const org, req = "org-pcx", "req-pcx"
			var ids []string
			for i := range 10 {
				ids = append(ids, e.createWithCap(t, org, fmt.Sprintf("integration-key-px%02d", i), e.beaconAt(org, "", e.now.Add(time.Duration(i+1)*time.Hour)), 50).Beacon.ID)
			}
			for i := range 10 {
				if _, err := e.request(req, fmt.Sprintf("integration-key-pr%02d", i), ids[i], "", 10, e.now); err != nil {
					t.Fatal(err)
				}
			}
			for i := range tt.cancel {
				if _, err := e.repo.Cancel(ctx, CancelParams{
					UID: org, BeaconID: ids[i], IdemKey: idempotency.Key(org, rpcCancelBeacon, fmt.Sprintf("integration-key-pk%02d", i)),
					RequestHash: idempotency.HashRequest(ids[i]), Now: e.now,
				}); err != nil {
					t.Fatalf("cancel %d: %v", i, err)
				}
			}
			next := e.createWithCap(t, org, "integration-key-px10", e.beaconAt(org, "", e.now.Add(20*time.Hour)), 50).Beacon
			res, err := e.request(req, "integration-key-pr10", next.ID, "", 10, e.now)
			if !tt.admitted {
				if !errors.Is(err, ErrPendingLimit) {
					t.Fatalf("11th request with nothing cancelled = %+v, %v, want ErrPendingLimit", res, err)
				}
				return
			}
			if err != nil || res.Outcome != Written {
				t.Fatalf("request after %d cancels = %+v, %v, want Written", tt.cancel, res, err)
			}
			for i, id := range ids {
				m, err := e.repo.membershipRef(req, id).Get(ctx)
				if err != nil {
					t.Fatal(err)
				}
				_, pending := m.Data()["pendingUntil"]
				if want := i >= tt.cancel; pending != want {
					t.Errorf("beacon %d (cancelled %v): pendingUntil set = %v, want %v", i, i < tt.cancel, pending, want)
				}
			}
		})
	}
}

func TestRepo_RespondAcceptFillsAndDeclines(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	in := e.beaconAt("org-r5", "", e.now.Add(time.Hour))
	in.OpenSpots = 1
	b := e.create(t, "org-r5", itKeyA, in).Beacon
	e.mustRequest(t, "p1", "integration-key-rs01", b.ID)
	e.mustRequest(t, "p2", "integration-key-rs02", b.ID)
	if _, err := e.respond("someone", "integration-key-rs03", b.ID, "p1", true, e.now); !errors.Is(err, ErrNotOrganiser) {
		t.Fatalf("respond by a stranger = %v, want ErrNotOrganiser", err)
	}
	res, err := e.respond("org-r5", "integration-key-rs04", b.ID, "p1", true, e.now.Add(time.Minute))
	if err != nil || res.Outcome != Written || res.Participant.State != PStateAccepted || !res.Participant.RespondedAt.Equal(e.now.Add(time.Minute)) {
		t.Fatalf("accept = %+v, %v", res, err)
	}
	if res.Beacon.AcceptedCount != 1 || res.Beacon.Status != StatusFull {
		t.Fatalf("beacon after accept = count %d status %q, want 1 full", res.Beacon.AcceptedCount, res.Beacon.Status)
	}
	m, _ := e.repo.membershipRef("p1", b.ID).Get(ctx)
	if _, pending := m.Data()["pendingUntil"]; m.Data()["role"] != RoleParticipant || m.Data()["state"] != PStateAccepted || pending {
		t.Fatalf("membership after accept = %v", m.Data())
	}
	if _, err := e.respond("org-r5", "integration-key-rs05", b.ID, "p2", true, e.now); !errors.Is(err, ErrFull) {
		t.Fatalf("accept beyond capacity = %v, want ErrFull", err)
	}
	res, err = e.respond("org-r5", "integration-key-rs06", b.ID, "p2", false, e.now)
	if err != nil || res.Participant.State != PStateDeclined {
		t.Fatalf("decline = %+v, %v", res, err)
	}
	m, _ = e.repo.membershipRef("p2", b.ID).Get(ctx)
	if _, pending := m.Data()["pendingUntil"]; m.Data()["state"] != PStateDeclined || pending {
		t.Fatalf("membership after decline = %v", m.Data())
	}
	if _, err := e.respond("org-r5", "integration-key-rs07", b.ID, "p1", true, e.now); !errors.Is(err, ErrNotRequested) {
		t.Fatalf("respond to an accepted row = %v, want ErrNotRequested", err)
	}
	if _, err := e.respond("org-r5", "integration-key-rs08", b.ID, "nobody", true, e.now); !errors.Is(err, ErrNotRequested) {
		t.Fatalf("respond to a missing row = %v, want ErrNotRequested", err)
	}
	// Replay of the accept answers the stored outcome.
	again, err := e.respond("org-r5", "integration-key-rs04", b.ID, "p1", true, e.now.Add(time.Minute))
	if err != nil || again.Outcome != Replayed || again.Participant.State != PStateAccepted {
		t.Fatalf("replay = %+v, %v", again, err)
	}
}

// TestRepo_LastSpotRace (Review Focus 1): two concurrent accepts for the last seat: exactly one commits.
func TestRepo_LastSpotRace(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	in := e.beaconAt("org-r6", "", e.now.Add(time.Hour))
	in.OpenSpots = 1
	b := e.create(t, "org-r6", itKeyA, in).Beacon
	e.mustRequest(t, "p1", "integration-key-lr01", b.ID)
	e.mustRequest(t, "p2", "integration-key-lr02", b.ID)
	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i, target := range []string{"p1", "p2"} {
		wg.Add(1)
		go func(i int, target string) {
			defer wg.Done()
			_, errs[i] = e.respond("org-r6", "integration-key-lr1"+target, b.ID, target, true, e.now)
		}(i, target)
	}
	wg.Wait()
	won, full := 0, 0
	for _, err := range errs {
		switch {
		case err == nil:
			won++
		case errors.Is(err, ErrFull):
			full++
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if won != 1 || full != 1 {
		t.Fatalf("won %d full %d, want 1 and 1", won, full)
	}
	got, _ := e.repo.Get(ctx, b.ID)
	if got.AcceptedCount != 1 || got.Status != StatusFull {
		t.Fatalf("beacon after the race = count %d status %q", got.AcceptedCount, got.Status)
	}
}

func TestRepo_LeaveRemoveReopen(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	in := e.beaconAt("org-r7", "", e.now.Add(time.Hour))
	in.OpenSpots = 1
	b := e.create(t, "org-r7", itKeyA, in).Beacon
	e.mustRequest(t, "p1", "integration-key-lv01", b.ID)
	e.mustRequest(t, "p2", "integration-key-lv02", b.ID)
	if _, err := e.respond("org-r7", "integration-key-lv03", b.ID, "p1", true, e.now); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.Leave(ctx, e.state("p2", rpcLeaveBeacon, "integration-key-lv04", b.ID, "p2", e.now)); !errors.Is(err, ErrNotParticipant) {
		t.Fatalf("leave while requested = %v, want ErrNotParticipant", err)
	}
	res, err := e.repo.Leave(ctx, e.state("p1", rpcLeaveBeacon, "integration-key-lv05", b.ID, "p1", e.now))
	if err != nil || res.Participant.State != PStateLeft || res.Beacon.AcceptedCount != 0 || res.Beacon.Status != StatusOpen {
		t.Fatalf("leave = %+v, %v, want left, count 0, open", res, err)
	}
	m, _ := e.repo.membershipRef("p1", b.ID).Get(ctx)
	if _, pending := m.Data()["pendingUntil"]; m.Data()["state"] != PStateLeft || pending {
		t.Fatalf("membership after leave = %v", m.Data())
	}
	if _, err := e.repo.Leave(ctx, e.state("p1", rpcLeaveBeacon, "integration-key-lv06", b.ID, "p1", e.now)); !errors.Is(err, ErrNotParticipant) {
		t.Fatalf("leave twice = %v, want ErrNotParticipant", err)
	}
	if _, err := e.respond("org-r7", "integration-key-lv07", b.ID, "p2", true, e.now); err != nil {
		t.Fatalf("accept after the seat reopened: %v", err)
	}
	if _, err := e.repo.Remove(ctx, e.state("stranger", rpcRemoveParticipant, "integration-key-lv08", b.ID, "p2", e.now)); !errors.Is(err, ErrNotOrganiser) {
		t.Fatalf("remove by a stranger = %v, want ErrNotOrganiser", err)
	}
	res, err = e.repo.Remove(ctx, e.state("org-r7", rpcRemoveParticipant, "integration-key-lv09", b.ID, "p2", e.now))
	if err != nil || res.Participant.State != PStateRemoved || res.Beacon.AcceptedCount != 0 || res.Beacon.Status != StatusOpen {
		t.Fatalf("remove = %+v, %v", res, err)
	}
	if _, err := e.repo.Remove(ctx, e.state("org-r7", rpcRemoveParticipant, "integration-key-lv10", b.ID, "p1", e.now)); !errors.Is(err, ErrNotParticipant) {
		t.Fatalf("remove a left row = %v, want ErrNotParticipant", err)
	}
	if _, err := e.repo.Leave(ctx, e.state("p1", rpcLeaveBeacon, "integration-key-lv11", b.ID, "p1", b.EndAt)); !errors.Is(err, ErrEnded) {
		t.Fatalf("leave after the end = %v, want ErrEnded", err)
	}
}

func TestRepo_ListMembershipsParticipantsAndGetBeacons(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const me = "me-l1"
	// Organised: two upcoming (+1h, +3h) and one past (-2h). Requested: one upcoming (+2h). Accepted: one upcoming (+4h), one past (-1h).
	var organised, others []Beacon
	for _, h := range []int{1, 3, -2} {
		organised = append(organised, e.create(t, me, fmt.Sprintf("integration-key-mo%d", h+9), e.beaconAt(me, "", e.now.Add(time.Duration(h)*time.Hour))).Beacon)
	}
	for _, h := range []int{2, 4, -1} {
		others = append(others, e.create(t, "host-l1", fmt.Sprintf("integration-key-mh%d", h+9), e.beaconAt("host-l1", "", e.now.Add(time.Duration(h)*time.Hour))).Beacon)
	}
	e.mustRequest(t, me, "integration-key-mr01", others[0].ID)
	for i, h := range []int{4, -1} {
		// Requests and accepts are made "in the past" so the ended beacon accepts them.
		past := e.now.Add(time.Duration(h)*time.Hour - 2*time.Hour)
		if _, err := e.request(me, fmt.Sprintf("integration-key-ma%d", i), others[i+1].ID, "", 10, past); err != nil {
			t.Fatal(err)
		}
		if _, err := e.respond("host-l1", fmt.Sprintf("integration-key-mb%d", i), others[i+1].ID, me, true, past); err != nil {
			t.Fatal(err)
		}
	}
	// A dangling row: a beacon that no longer exists.
	if _, err := e.repo.membershipRef(me, "0000000000000000777").Set(ctx, membershipDoc{BeaconID: "0000000000000000777", Role: RoleParticipant, State: PStateAccepted, StartAt: e.now.Add(5 * time.Hour), EndAt: e.now.Add(6 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	upcoming, err := e.repo.ListMemberships(ctx, MembershipQuery{UID: me, Now: e.now, Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	wantUp := []string{organised[0].ID, others[0].ID, organised[1].ID, others[1].ID, "0000000000000000777"}
	if got := membershipIDs(upcoming); fmt.Sprint(got) != fmt.Sprint(wantUp) {
		t.Fatalf("upcoming all = %v, want %v", got, wantUp)
	}
	page, err := e.repo.ListMemberships(ctx, MembershipQuery{UID: me, Now: e.now, Limit: 2})
	if err != nil || len(page) != 2 {
		t.Fatalf("page 1 = %v, %v", membershipIDs(page), err)
	}
	last := page[1]
	page2, err := e.repo.ListMemberships(ctx, MembershipQuery{UID: me, Now: e.now, AfterEndAt: last.EndAt, AfterID: last.BeaconID, Limit: 2})
	if err != nil || fmt.Sprint(membershipIDs(page2)) != fmt.Sprint(wantUp[2:4]) {
		t.Fatalf("page 2 = %v, %v, want %v", membershipIDs(page2), err, wantUp[2:4])
	}
	org, err := e.repo.ListMemberships(ctx, MembershipQuery{UID: me, Roles: []string{RoleOrganiser}, Now: e.now, Limit: 10})
	if err != nil || fmt.Sprint(membershipIDs(org)) != fmt.Sprint([]string{organised[0].ID, organised[1].ID}) {
		t.Fatalf("upcoming organiser = %v, %v", membershipIDs(org), err)
	}
	part, err := e.repo.ListMemberships(ctx, MembershipQuery{UID: me, Roles: []string{RoleParticipant, RoleRequester}, Now: e.now, Limit: 10})
	if err != nil || fmt.Sprint(membershipIDs(part)) != fmt.Sprint([]string{others[0].ID, others[1].ID, "0000000000000000777"}) {
		t.Fatalf("upcoming participant = %v, %v", membershipIDs(part), err)
	}
	past, err := e.repo.ListMemberships(ctx, MembershipQuery{UID: me, Past: true, Now: e.now, Limit: 10})
	if err != nil || fmt.Sprint(membershipIDs(past)) != fmt.Sprint([]string{others[2].ID, organised[2].ID}) {
		t.Fatalf("past all = %v, %v (want most recent end first)", membershipIDs(past), err)
	}
	beacons, err := e.repo.GetBeacons(ctx, []string{organised[0].ID, "0000000000000000777", others[0].ID})
	if err != nil || len(beacons) != 2 || beacons[organised[0].ID].OrganiserID != me {
		t.Fatalf("GetBeacons = %d, %v", len(beacons), err)
	}
	// ListParticipants: on others[0] (requested by me) add two more requesters and accept one.
	e.mustRequest(t, "q1", "integration-key-mq1", others[0].ID)
	e.mustRequest(t, "q2", "integration-key-mq2", others[0].ID)
	if _, err := e.respond("host-l1", "integration-key-mq3", others[0].ID, "q1", true, e.now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	requested, err := e.repo.ListParticipants(ctx, ParticipantQuery{BeaconID: others[0].ID, State: PStateRequested, Limit: 10})
	if err != nil || len(requested) != 2 || requested[0].UID != me || requested[1].UID != "q2" {
		t.Fatalf("requested = %+v, %v (want me then q2, oldest first)", requested, err)
	}
	accepted, err := e.repo.ListParticipants(ctx, ParticipantQuery{BeaconID: others[0].ID, State: PStateAccepted, Limit: 10})
	if err != nil || len(accepted) != 1 || accepted[0].UID != "q1" {
		t.Fatalf("accepted = %+v, %v", accepted, err)
	}
	one, err := e.repo.ListParticipants(ctx, ParticipantQuery{BeaconID: others[0].ID, State: PStateRequested, Limit: 1})
	if err != nil || len(one) != 1 {
		t.Fatal(err)
	}
	rest, err := e.repo.ListParticipants(ctx, ParticipantQuery{BeaconID: others[0].ID, State: PStateRequested, AfterAt: one[0].RequestedAt, AfterUID: one[0].UID, Limit: 1})
	if err != nil || len(rest) != 1 || rest[0].UID != "q2" {
		t.Fatalf("requested page 2 = %+v, %v", rest, err)
	}
}

func membershipIDs(ms []Membership) []string {
	out := make([]string, 0, len(ms))
	for _, m := range ms {
		out = append(out, m.BeaconID)
	}
	return out
}
