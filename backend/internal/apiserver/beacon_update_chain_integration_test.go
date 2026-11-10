//go:build integration

package apiserver

// F28 over the real Build chain (Firestore, Auth emulators; inline emitter): UpdateBeacon moving the start notifies each
// accepted participant with exactly one beacon_updated row per edit, a replay of the same key adds nothing, a second
// edit (cost) adds a second row, a requester and the organiser get none, and the accepted people stay accepted.
//
// Shard safety: every assertion is scoped to this test's beacon and users.

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	beaconsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
)

func updatedRows(t *testing.T, e *lifecycleEnv, uid, beaconID string) []string {
	t.Helper()
	var out []string
	for _, id := range notifIDs(t, e.fs, uid) {
		if strings.HasPrefix(id, "beacon_updated_"+beaconID+"_") {
			out = append(out, id)
		}
	}
	return out
}

// updatedRowID is the notification row id of the edit whose response is b (beacon_updated_<beacon>_<updatedAt ms>).
func updatedRowID(b *beaconsv1.Beacon) string {
	return "beacon_updated_" + b.GetBeaconId() + "_" + strconv.FormatInt(b.GetUpdatedAt().AsTime().UnixMilli(), 10)
}

func TestBeaconUpdate_RescheduleNotifiesAcceptedOncePerEdit(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, beaconNotifsOn)
	bc := beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, e.url)
	org, p1, p2, req := e.newUser(t), e.newUser(t), e.newUser(t), e.newUser(t)
	id := beaconWithAccepted(t, bc, "bup1", org, p1, p2)
	if _, err := bc.RequestToJoin(ctx, authed(req.token, &beaconsv1.RequestToJoinRequest{IdempotencyKey: "bup1-req-key-requester", BeaconId: id})); err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}

	newStart := time.Now().Add(26 * time.Hour).UTC().Truncate(time.Second)
	move := &beaconsv1.UpdateBeaconRequest{IdempotencyKey: "bup1-update-key-0001", BeaconId: id, StartAt: timestamppb.New(newStart)}
	res, err := bc.UpdateBeacon(ctx, authed(org.token, move))
	if err != nil {
		t.Fatalf("UpdateBeacon: %v", err)
	}
	b := res.Msg.GetView().GetBeacon()
	if !b.GetStartAt().AsTime().Equal(newStart) || b.GetAcceptedCount() != 2 {
		t.Fatalf("beacon after the move = start %v accepted %d", b.GetStartAt().AsTime(), b.GetAcceptedCount())
	}
	for _, p := range []testUser{p1, p2} {
		waitForDoc(t, e.fs, "users/"+p.uid+"/notifications/"+updatedRowID(b))
	}
	// A replay of the same key returns the stored outcome and notifies nobody again.
	if _, err := bc.UpdateBeacon(ctx, authed(org.token, move)); err != nil {
		t.Fatalf("replayed UpdateBeacon: %v", err)
	}
	// A second edit (cost) is a second row.
	cost := beaconsv1.BeaconCost_BEACON_COST_SPLIT_EVENLY
	res2, err := bc.UpdateBeacon(ctx, authed(org.token, &beaconsv1.UpdateBeaconRequest{IdempotencyKey: "bup1-update-key-0002", BeaconId: id, Cost: &cost}))
	if err != nil {
		t.Fatalf("cost UpdateBeacon: %v", err)
	}
	for _, p := range []testUser{p1, p2} {
		waitForDoc(t, e.fs, "users/"+p.uid+"/notifications/"+updatedRowID(res2.Msg.GetView().GetBeacon()))
		if rows := updatedRows(t, e, p.uid, id); len(rows) != 2 {
			t.Fatalf("participant rows after two edits and a replay = %v, want 2", rows)
		}
	}
	for _, u := range []testUser{org, req} {
		if rows := updatedRows(t, e, u.uid, id); len(rows) != 0 {
			t.Errorf("non-accepted user has beacon_updated rows %v", rows)
		}
	}
	// Accepted people stay accepted, and the beacon's participant list is unchanged.
	pl, err := bc.ListParticipants(ctx, authed(org.token, &beaconsv1.ListParticipantsRequest{BeaconId: id}))
	if err != nil || len(pl.Msg.GetParticipants()) != 2 {
		t.Fatalf("participants after the edits = %d, %v", len(pl.Msg.GetParticipants()), err)
	}
	// A start already passed cannot be the target of a move (VALIDATION, before any lookup).
	_, err = bc.UpdateBeacon(ctx, authed(org.token, &beaconsv1.UpdateBeaconRequest{IdempotencyKey: "bup1-update-key-0003", BeaconId: id, StartAt: timestamppb.New(time.Now().Add(-time.Hour))}))
	if connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("past start = %v, want InvalidArgument", err)
	}
}
