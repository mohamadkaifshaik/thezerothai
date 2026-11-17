//go:build integration

package notifications

import (
	"context"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// Against the emulator: a recipient with public_ids on gets the wire form in the push while the row is stored under the
// same id as for everyone else (the dedupe key), and a redelivery pushes nothing a second time.
func TestIntegration_PublicIDsPushKeepsTheStoredRowID(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	rig := newRig(t, pubFlags{on: map[string]bool{"bob": true}})
	rig.f.d.Repo = repo
	rig.dir.profiles[wireActorUID] = identity.Profile{UserID: wireActorUID, PublicID: wirePubID, Handle: "h_actor", Status: identity.AccountStatusActive}
	register(t, repo, "bob", "device-bbbbbbbbbbbb", "tok-b1", t0)
	register(t, repo, "carol", "device-cccccccccccc", "tok-c1", t0)
	ev := Event{Type: TypeFollow, ActorID: wireActorUID, RecipientIDs: []string{"bob", "carol"}, At: t0}

	out, err := rig.f.Deliver(context.Background(), ev)
	mustNoErr(t, err)
	if out.Created != 2 || out.Pushed != 2 {
		t.Fatalf("outcome = %+v", out)
	}
	stored := "follow_" + wireActorUID
	for _, uid := range []string{"bob", "carol"} {
		if !docExists(t, client, "users/"+uid+"/notifications/"+stored) {
			t.Errorf("%s: the row is not stored under %s", uid, stored)
		}
	}
	data := map[string]map[string]string{}
	for _, s := range rig.sender.sent {
		data[s.Token] = buildMessage(s.Token, s.Push).Data
	}
	if d := data["tok-b1"]; d["actorId"] != wirePubID || d["notificationId"] != "follow_"+wirePubID {
		t.Errorf("flag-on push data = %v", d)
	}
	if d := data["tok-c1"]; d["actorId"] != wireActorUID || d["notificationId"] != stored {
		t.Errorf("flag-off push data = %v, want today's", d)
	}

	out, err = rig.f.Deliver(context.Background(), ev)
	mustNoErr(t, err)
	if out.Duplicate != 2 || out.Pushed != 0 || len(rig.sender.sent) != 2 {
		t.Fatalf("redelivery outcome = %+v, pushes = %d", out, len(rig.sender.sent))
	}
}
