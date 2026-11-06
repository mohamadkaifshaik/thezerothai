//go:build integration

package apiserver

// Beacon notifications over the real Build chain with the inline emitter (docs/beacons-plan.md PR 5): a join request
// writes users/{organiser}/notifications/beacon_request_{beacon}_{requester}; an acceptance writes
// users/{requester}/notifications/beacon_accepted_{beacon}; a cancellation writes beacon_cancelled_{beacon} under every
// accepted participant and nothing under the organiser; ListNotifications maps the row to its enum value with
// beacon_id set and post_id empty.

import (
	"context"
	"net/http"
	"testing"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	beaconsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	notificationsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func beaconNotifsOn(c *config.Config) {
	relaxLimits(c)
	c.FeatureBeacons = flags.Spec{Name: "beacons", Mode: flags.On}
	c.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
}

func TestBeaconNotifications_RequestAcceptCancelChain(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, beaconNotifsOn)
	bc := beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, e.url)
	nc := notificationsv1connect.NewNotificationServiceClient(http.DefaultClient, e.url)
	org, p1, p2 := e.newUser(t), e.newUser(t), e.newUser(t)

	cr, err := bc.CreateBeacon(ctx, authed(org.token, &beaconsv1.CreateBeaconRequest{
		IdempotencyKey: "bn-create-key-00000001", Audience: &beaconsv1.CreateBeaconRequest_Public{Public: true},
		Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Title: "Coffee", Venue: "Hall",
		StartAt: timestamppb.New(time.Now().Add(time.Hour)), DurationMinutes: 30, OpenSpots: 3,
		Cost: beaconsv1.BeaconCost_BEACON_COST_FREE, ChatPreference: beaconsv1.ChatPreference_CHAT_PREFERENCE_QUIET,
	}))
	if err != nil {
		t.Fatalf("CreateBeacon: %v", err)
	}
	id := cr.Msg.GetView().GetBeacon().GetBeaconId()

	request := func(u testUser, key string) {
		t.Helper()
		if _, err := bc.RequestToJoin(ctx, authed(u.token, &beaconsv1.RequestToJoinRequest{IdempotencyKey: key, BeaconId: id})); err != nil {
			t.Fatalf("RequestToJoin(%s): %v", key, err)
		}
	}
	accept := func(u testUser, key string) {
		t.Helper()
		if _, err := bc.RespondToJoinRequest(ctx, authed(org.token, &beaconsv1.RespondToJoinRequestRequest{
			IdempotencyKey: key, BeaconId: id, UserId: u.uid, Response: beaconsv1.JoinResponse_JOIN_RESPONSE_ACCEPT,
		})); err != nil {
			t.Fatalf("RespondToJoinRequest(%s): %v", key, err)
		}
	}

	// 1. p1 asks: one request row for the organiser, keyed on the beacon and the requester.
	request(p1, "bn-req1-key-000000001")
	waitForDoc(t, e.fs, "users/"+org.uid+"/notifications/beacon_request_"+id+"_"+p1.uid)
	snap, err := e.fs.Doc("users/" + org.uid + "/notifications/beacon_request_" + id + "_" + p1.uid).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if typ, _ := snap.DataAt("type"); typ != "beacon_request" {
		t.Errorf("type = %v, want beacon_request", typ)
	}
	if got, _ := snap.DataAt("beaconId"); got != id {
		t.Errorf("beaconId = %v, want %s", got, id)
	}
	// A replay of the same request writes nothing new (the row already exists; the service fires nothing on a replay).
	request(p1, "bn-req1-key-000000001")

	// 2. The organiser accepts p1: one accepted row for p1.
	accept(p1, "bn-acc1-key-000000001")
	waitForDoc(t, e.fs, "users/"+p1.uid+"/notifications/beacon_accepted_"+id)

	// 3. p2 asks and is accepted too.
	request(p2, "bn-req2-key-000000001")
	accept(p2, "bn-acc2-key-000000001")
	waitForDoc(t, e.fs, "users/"+org.uid+"/notifications/beacon_request_"+id+"_"+p2.uid)
	waitForDoc(t, e.fs, "users/"+p2.uid+"/notifications/beacon_accepted_"+id)

	// 4. The organiser cancels: a cancelled row under both participants, none under the organiser.
	if _, err := bc.CancelBeacon(ctx, authed(org.token, &beaconsv1.CancelBeaconRequest{IdempotencyKey: "bn-cancel-key-0000001", BeaconId: id})); err != nil {
		t.Fatalf("CancelBeacon: %v", err)
	}
	waitForDoc(t, e.fs, "users/"+p1.uid+"/notifications/beacon_cancelled_"+id)
	waitForDoc(t, e.fs, "users/"+p2.uid+"/notifications/beacon_cancelled_"+id)
	time.Sleep(200 * time.Millisecond) // let any stray concurrent delivery settle before counting

	got := map[string]bool{}
	for _, nid := range notifIDs(t, e.fs, org.uid) {
		got[nid] = true
	}
	if len(got) != 2 || !got["beacon_request_"+id+"_"+p1.uid] || !got["beacon_request_"+id+"_"+p2.uid] {
		t.Errorf("organiser rows = %v, want exactly the two request rows", got)
	}
	for _, uid := range []string{p1.uid, p2.uid} {
		ids := notifIDs(t, e.fs, uid)
		if len(ids) != 2 {
			t.Errorf("participant %s rows = %v, want accepted and cancelled only", uid, ids)
		}
	}

	// 5. ListNotifications maps the row: enum value, beacon_id set, post_id empty.
	lr, err := nc.ListNotifications(ctx, authed(p1.token, &notificationsv1.ListNotificationsRequest{PageSize: 20}))
	if err != nil {
		t.Fatalf("ListNotifications: %v", err)
	}
	found := false
	for _, n := range lr.Msg.GetNotifications() {
		if n.GetType() == notificationsv1.NotificationType_NOTIFICATION_TYPE_BEACON_CANCELLED {
			found = true
			if n.GetBeaconId() != id || n.GetPostId() != "" || n.GetActor().GetUserId() != org.uid {
				t.Errorf("cancelled row = %+v, want beacon_id %s, no post_id, actor the organiser", n, id)
			}
		}
	}
	if !found {
		t.Errorf("ListNotifications for p1 has no BEACON_CANCELLED row: %+v", lr.Msg.GetNotifications())
	}
}
