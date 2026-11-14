//go:build integration

package apiserver

// The real emitter error path of a beacon cancellation (B07 follow-up). The other cancel-outbox chain tests lose the
// inline hand-off at the Events seam (inlineBeaconEvents); here nothing is faked: notifications are delivered through
// the production PubSubEmitter to a topic that does not exist yet, so the Pub/Sub emulator refuses the publish
// (NOT_FOUND), the emitter returns the error through beaconNotifier and DeliverCancelNotices, and the outbox item staged
// in the cancel transaction stays. Once the topic exists, the cron sweep publishes the cancellation event; pushing it
// to the fan-out endpoint gives every accepted participant exactly one beacon_cancelled row, redelivery included.
//
// Shard safety: every assertion is scoped to this test's beacon, item path, topic and users.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"testing"
	"time"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	beaconsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
)

// deliverNotification posts one pulled notifications message to the fan-out endpoint like a push subscription and
// returns the HTTP status.
func (e *lifecycleEnv) deliverNotification(t *testing.T, msg map[string]any) int {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"message": map[string]any{"data": msg["_data"], "messageId": "1"}, "subscription": "s", "deliveryAttempt": 1})
	resp, err := http.Post(e.url+"/internal/pubsub/notifications-fanout", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("deliver notification: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

func TestBeaconCancelOutbox_PubSubPublishFailureKeepsItem(t *testing.T) {
	ctx := context.Background()
	clock := &atomicClock{}
	clock.ns.Store(time.Now().UnixNano())
	topic := fmt.Sprintf("notif-bcps-%d", rand.Int63()) // not created until the sweep step
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		beaconNotifsOn(c)
		c.NotificationsDelivery = "pubsub"
		c.NotificationsTopic = topic
	}, func(o *buildOpts) { o.outboxNow = clock.now })
	bc := beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, e.url)
	org, p1, p2 := e.newUser(t), e.newUser(t), e.newUser(t)
	id := beaconWithAccepted(t, bc, "bcps", org, p1, p2) // their request/accept notices fail to publish too (best effort)
	itemPath := outbox.Collection + "/" + beacons.CancelOutboxKind + ":" + id

	cancel := func() {
		t.Helper()
		if _, err := bc.CancelBeacon(ctx, authed(org.token, &beaconsv1.CancelBeaconRequest{IdempotencyKey: "bcps-cancel-key-00001", BeaconId: id})); err != nil {
			t.Fatalf("CancelBeacon: %v (a failed publish must never fail the cancel)", err)
		}
	}
	cancel()
	if !fsDocExists(t, e.fs, itemPath) {
		t.Fatal("no outbox item after a cancel whose publish failed: the emitter error did not reach the outbox")
	}
	for _, p := range []testUser{p1, p2} {
		if n := cancelledRows(t, e, p.uid); n != 0 {
			t.Fatalf("participant has %d cancelled rows before any delivery", n)
		}
	}

	// The topic appears; the due sweep re-runs the item through the same real emitter, which now publishes.
	sub := e.w328bSubscribe(t, topic)
	clock.advance(outbox.DefaultInitialDelay)
	for i := 0; i < maxSweepsForOwnItem && fsDocExists(t, e.fs, itemPath); i++ {
		if code := e.cron(t, "/internal/cron/outbox-sweep"); code != http.StatusNoContent {
			t.Fatalf("sweep = %d", code)
		}
	}
	if fsDocExists(t, e.fs, itemPath) {
		t.Fatalf("the item is still there after %d sweeps", maxSweepsForOwnItem)
	}

	// Exactly one cancellation event for this beacon, from the organiser, naming both participants. The publish was
	// acknowledged before the sweep answered, so a bounded number of pulls finds it.
	var events []map[string]any
	for i := 0; i < 20 && len(events) == 0; i++ {
		for _, m := range e.w328bPullSub(t, sub) {
			if m["beaconId"] == id {
				events = append(events, m)
			}
		}
	}
	if len(events) != 1 {
		t.Fatalf("cancellation events for the beacon = %d, want 1: %v", len(events), events)
	}
	ev := events[0]
	if ev["type"] != "beacon_cancelled" || ev["actorId"] != org.uid {
		t.Fatalf("event type=%v actor=%v, want beacon_cancelled by the organiser", ev["type"], ev["actorId"])
	}
	got := map[string]bool{}
	for _, r := range ev["recipientIds"].([]any) {
		got[r.(string)] = true
	}
	if len(got) != 2 || !got[p1.uid] || !got[p2.uid] {
		t.Fatalf("recipients = %v, want exactly the two accepted participants", ev["recipientIds"])
	}

	// The push delivery writes one row per participant; a redelivery and a replayed cancel (its item is gone) add none.
	for i := 0; i < 2; i++ {
		if code := e.deliverNotification(t, ev); code != http.StatusNoContent {
			t.Fatalf("delivery %d = %d", i+1, code)
		}
	}
	cancel()
	for _, p := range []testUser{p1, p2} {
		waitForDoc(t, e.fs, "users/"+p.uid+"/notifications/beacon_cancelled_"+id)
		if n := cancelledRows(t, e, p.uid); n != 1 {
			t.Errorf("participant has %d cancelled rows, want exactly 1", n)
		}
	}
	if n := cancelledRows(t, e, org.uid); n != 0 {
		t.Errorf("organiser has %d cancelled rows, want 0", n)
	}
}
