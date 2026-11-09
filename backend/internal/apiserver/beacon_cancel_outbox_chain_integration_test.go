//go:build integration

package apiserver

// Durable beacon cancellation notices (B07) over the real Build chain (Firestore, Auth emulators; inline emitter):
// CancelBeacon's inline hand-off is lost, the outbox item staged in the cancel transaction survives, the cron sweep
// re-runs it through the real notifier, and every accepted participant ends with exactly one beacon_cancelled row,
// whatever further sweeps and a replayed cancel do. A cancel whose notices went out inline leaves no item.
//
// Shard safety: the chain tests share one emulator project, so every assertion is scoped to this test's beacon, its
// item path and its users, and the due sweep repeats (bounded) until this test's item is gone.

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	beaconsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
)

// lostCancelNotices passes requests and acceptances through and loses every inline cancellation hand-off.
type lostCancelNotices struct {
	beacons.Events
	calls atomic.Int32
}

func (l *lostCancelNotices) Cancelled(context.Context, beacons.CancelEvent) error {
	l.calls.Add(1)
	return errors.New("pubsub unavailable")
}

// beaconWithAccepted creates a public beacon organised by org and has every participant request and be accepted.
func beaconWithAccepted(t *testing.T, bc beaconsv1connect.BeaconServiceClient, prefix string, org testUser, ps ...testUser) string {
	t.Helper()
	ctx := context.Background()
	cr, err := bc.CreateBeacon(ctx, authed(org.token, &beaconsv1.CreateBeaconRequest{
		IdempotencyKey: prefix + "-create-key-0001", Audience: &beaconsv1.CreateBeaconRequest_Public{Public: true},
		Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Title: "Coffee", Venue: "Hall",
		StartAt: timestamppb.New(time.Now().Add(time.Hour)), DurationMinutes: 30, OpenSpots: int32(len(ps) + 1),
		Cost: beaconsv1.BeaconCost_BEACON_COST_FREE, ChatPreference: beaconsv1.ChatPreference_CHAT_PREFERENCE_QUIET,
	}))
	if err != nil {
		t.Fatalf("CreateBeacon: %v", err)
	}
	id := cr.Msg.GetView().GetBeacon().GetBeaconId()
	for i, p := range ps {
		suffix := string(rune('a' + i))
		if _, err := bc.RequestToJoin(ctx, authed(p.token, &beaconsv1.RequestToJoinRequest{IdempotencyKey: prefix + "-req-key-000" + suffix, BeaconId: id})); err != nil {
			t.Fatalf("RequestToJoin: %v", err)
		}
		if _, err := bc.RespondToJoinRequest(ctx, authed(org.token, &beaconsv1.RespondToJoinRequestRequest{
			IdempotencyKey: prefix + "-acc-key-000" + suffix, BeaconId: id, UserId: p.uid, Response: beaconsv1.JoinResponse_JOIN_RESPONSE_ACCEPT,
		})); err != nil {
			t.Fatalf("RespondToJoinRequest: %v", err)
		}
	}
	return id
}

func cancelledRows(t *testing.T, e *lifecycleEnv, uid string) int {
	t.Helper()
	n := 0
	for _, id := range notifIDs(t, e.fs, uid) {
		if strings.HasPrefix(id, "beacon_cancelled_") {
			n++
		}
	}
	return n
}

func TestBeaconCancelOutbox_LostNoticesAreSweptExactlyOnce(t *testing.T) {
	ctx := context.Background()
	clock := &atomicClock{}
	clock.ns.Store(time.Now().UnixNano())
	lost := &lostCancelNotices{}
	e := newLifecycleEnvCfg(t, nil, beaconNotifsOn,
		func(o *buildOpts) { o.outboxNow = clock.now },
		func(o *buildOpts) {
			o.inlineBeaconEvents = func(ev beacons.Events) beacons.Events { lost.Events = ev; return lost }
		})
	bc := beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, e.url)
	org, p1, p2, p3 := e.newUser(t), e.newUser(t), e.newUser(t), e.newUser(t)
	id := beaconWithAccepted(t, bc, "bco1", org, p1, p2, p3)
	itemPath := outbox.Collection + "/" + beacons.CancelOutboxKind + ":" + id

	cancel := func() {
		t.Helper()
		if _, err := bc.CancelBeacon(ctx, authed(org.token, &beaconsv1.CancelBeaconRequest{IdempotencyKey: "bco1-cancel-key-00001", BeaconId: id})); err != nil {
			t.Fatalf("CancelBeacon: %v (a lost notice must never fail the cancel)", err)
		}
	}
	cancel()
	if lost.calls.Load() != 1 {
		t.Fatalf("inline hand-offs = %d, want 1", lost.calls.Load())
	}
	if !fsDocExists(t, e.fs, itemPath) {
		t.Fatal("no outbox item after a cancel whose notices were lost")
	}
	for _, p := range []testUser{p1, p2, p3} {
		if n := cancelledRows(t, e, p.uid); n != 0 {
			t.Fatalf("participant has %d cancelled rows before the sweep", n)
		}
	}

	// Due: the sweep re-runs the item through the real notifier (not the lost inline seam).
	clock.advance(outbox.DefaultInitialDelay)
	for i := 0; i < maxSweepsForOwnItem && fsDocExists(t, e.fs, itemPath); i++ {
		if code := e.cron(t, "/internal/cron/outbox-sweep"); code != http.StatusNoContent {
			t.Fatalf("sweep = %d", code)
		}
	}
	if fsDocExists(t, e.fs, itemPath) {
		t.Fatalf("the item is still there after %d sweeps", maxSweepsForOwnItem)
	}
	for _, p := range []testUser{p1, p2, p3} {
		waitForDoc(t, e.fs, "users/"+p.uid+"/notifications/beacon_cancelled_"+id)
	}

	// Re-runs change nothing: another sweep, and a replayed cancel (its item is gone, so RunNow finds nothing).
	clock.advance(time.Hour)
	if code := e.cron(t, "/internal/cron/outbox-sweep"); code != http.StatusNoContent {
		t.Fatalf("second sweep = %d", code)
	}
	cancel()
	if lost.calls.Load() != 1 {
		t.Fatalf("the replay handed off inline again (%d calls)", lost.calls.Load())
	}
	for _, p := range []testUser{p1, p2, p3} {
		if n := cancelledRows(t, e, p.uid); n != 1 {
			t.Errorf("participant has %d cancelled rows, want exactly 1", n)
		}
	}
	if n := cancelledRows(t, e, org.uid); n != 0 {
		t.Errorf("organiser has %d cancelled rows, want 0", n)
	}
}

// A replayed cancel re-runs a still-present item at once, without waiting for the sweep.
func TestBeaconCancelOutbox_ReplayRetriggers(t *testing.T) {
	ctx := context.Background()
	lost := &lostCancelNotices{}
	e := newLifecycleEnvCfg(t, nil, beaconNotifsOn,
		func(o *buildOpts) {
			o.inlineBeaconEvents = func(ev beacons.Events) beacons.Events { lost.Events = ev; return lost }
		})
	bc := beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, e.url)
	org, p1 := e.newUser(t), e.newUser(t)
	id := beaconWithAccepted(t, bc, "bco2", org, p1)
	itemPath := outbox.Collection + "/" + beacons.CancelOutboxKind + ":" + id
	req := &beaconsv1.CancelBeaconRequest{IdempotencyKey: "bco2-cancel-key-00001", BeaconId: id}
	if _, err := bc.CancelBeacon(ctx, authed(org.token, req)); err != nil {
		t.Fatalf("CancelBeacon: %v", err)
	}
	if !fsDocExists(t, e.fs, itemPath) {
		t.Fatal("no outbox item after a lost hand-off")
	}
	if _, err := bc.CancelBeacon(ctx, authed(org.token, req)); err != nil {
		t.Fatalf("replayed CancelBeacon: %v", err)
	}
	if fsDocExists(t, e.fs, itemPath) {
		t.Fatal("the replay did not run the item")
	}
	waitForDoc(t, e.fs, "users/"+p1.uid+"/notifications/beacon_cancelled_"+id)
	if n := cancelledRows(t, e, p1.uid); n != 1 {
		t.Errorf("participant has %d cancelled rows, want 1", n)
	}
}

// With a working notifier the item is staged and removed in the same request.
func TestBeaconCancelOutbox_DeliveredCancelLeavesNoItem(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, beaconNotifsOn)
	bc := beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, e.url)
	org, p1 := e.newUser(t), e.newUser(t)
	id := beaconWithAccepted(t, bc, "bco3", org, p1)
	if _, err := bc.CancelBeacon(ctx, authed(org.token, &beaconsv1.CancelBeaconRequest{IdempotencyKey: "bco3-cancel-key-00001", BeaconId: id})); err != nil {
		t.Fatalf("CancelBeacon: %v", err)
	}
	waitForDoc(t, e.fs, "users/"+p1.uid+"/notifications/beacon_cancelled_"+id)
	if fsDocExists(t, e.fs, outbox.Collection+"/"+beacons.CancelOutboxKind+":"+id) {
		t.Fatal("a delivered cancel left its outbox item")
	}
}
