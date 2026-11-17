package notifications

// The uid scan, push half (public id PR 7). Every notification type is delivered through the real Fanout to two
// recipients with devices, one with FEATURE_PUBLIC_IDS on and one without, and the WHOLE FCM message each device would
// receive (buildMessage of the captured Push, marshalled: data map, notification title and body, Android collapse key
// and tag, apns headers) is scanned for every uid in the scenario. The captured Push struct itself is not scanned: its
// ActorID and NotificationID hold stored uids by design (the row and the log pseudonym) and never reach the device when
// the recipient is flagged.
//
// This is the unit-level counterpart of the apiserver uid scan (backend/internal/apiserver/public_ids_uid_scan_*): the
// chain cannot capture pushes because apiserver wires LogSender unless delivery is pubsub (no buildOpts seam for the
// sender; see the PR 7 report).

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

const (
	scanFlaggedUID   = "FlaggedRecipientUid0123456789"
	scanUnflaggedUID = "UnflaggedRecipientUid012345678"
)

// scanFlags: every feature on, public_ids on for the listed recipients only.
type scanFlags struct{ pub map[string]bool }

func (f scanFlags) Enabled(uid, name string) bool {
	if name == identity.PublicIDsFlag {
		return f.pub[uid]
	}
	return true
}

func scanEvent(ty Type) Event {
	ev := Event{Type: ty, ActorID: wireActorUID, RecipientIDs: []string{scanFlaggedUID, scanUnflaggedUID}, At: t0}
	switch {
	case ty.pushOnly():
		ev.ConversationID = "0123456789abcdef0123456789abcdef"
	case ty.needsBeacon():
		ev.BeaconID = beaconA
	case ty.needsPost():
		ev.PostID = postA
	}
	return ev
}

func TestUIDScan_PushPayloadsPerRecipient(t *testing.T) {
	uids := map[string]string{wireActorUID: "the actor", scanFlaggedUID: "the flagged recipient", scanUnflaggedUID: "the unflagged recipient"}
	for _, ty := range allTypes {
		t.Run(string(ty), func(t *testing.T) {
			r := newRig(t, scanFlags{pub: map[string]bool{scanFlaggedUID: true}})
			for _, u := range []string{scanFlaggedUID, scanUnflaggedUID} {
				r.dir.profiles[u] = identity.Profile{UserID: u, Handle: "h_" + u[:4], Status: identity.AccountStatusActive}
			}
			r.dir.profiles[wireActorUID] = identity.Profile{UserID: wireActorUID, PublicID: wirePubID, Handle: "h_actor", Status: identity.AccountStatusActive}
			r.addDevice(scanFlaggedUID, "dev-f", "tok-flagged")
			r.addDevice(scanUnflaggedUID, "dev-u", "tok-unflagged")

			out, err := r.f.Deliver(context.Background(), scanEvent(ty))
			mustNoErr(t, err)
			if out.Pushed != 2 {
				t.Fatalf("outcome = %+v, want 2 pushed (one per recipient)", out)
			}
			byToken := map[string]Push{}
			for _, s := range r.sender.sent {
				byToken[s.Token] = s.Push
			}

			// Flagged recipient: no uid anywhere in the message that reaches the device.
			flagged := buildMessage("tok-flagged", byToken["tok-flagged"])
			raw, err := json.Marshal(flagged)
			if err != nil {
				t.Fatal(err)
			}
			for uid, who := range uids {
				if strings.Contains(string(raw), uid) {
					t.Errorf("flagged recipient: the FCM message carries the uid of %s: %s", who, raw)
				}
			}
			if strings.Contains(string(raw), TombstonePublicID) {
				t.Errorf("flagged recipient: the actor has a public id, so the tombstone must not appear: %s", raw)
			}
			if !ty.pushOnly() {
				if got := flagged.Data["actorId"]; got != wirePubID {
					t.Errorf("flagged recipient: actorId = %q, want the actor's public id", got)
				}
				stored := notificationID(ty, wireActorUID, scanEvent(ty).subject(), t0)
				if ty.ActorKeyedID() {
					if got := flagged.Data["notificationId"]; got != strings.TrimSuffix(stored, wireActorUID)+wirePubID {
						t.Errorf("flagged recipient: notificationId = %q, want the actor segment to be the public id", got)
					}
				} else if got := flagged.Data["notificationId"]; got != stored {
					t.Errorf("flagged recipient: notificationId = %q, want the stored id %q (no actor segment)", got, stored)
				}
			}

			// Unflagged recipient on the same delivery: the stored (uid) forms, and never a public id.
			unflagged := buildMessage("tok-unflagged", byToken["tok-unflagged"])
			raw, err = json.Marshal(unflagged)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(raw), wirePubID) {
				t.Errorf("unflagged recipient: the FCM message carries a public id: %s", raw)
			}
			if !ty.pushOnly() {
				if got := unflagged.Data["actorId"]; got != wireActorUID {
					t.Errorf("unflagged recipient: actorId = %q, want the stored uid", got)
				}
				if ty.ActorKeyedID() && !strings.HasSuffix(unflagged.Data["notificationId"], wireActorUID) {
					t.Errorf("unflagged recipient: notificationId = %q, want the stored id", unflagged.Data["notificationId"])
				}
			}
		})
	}
}
