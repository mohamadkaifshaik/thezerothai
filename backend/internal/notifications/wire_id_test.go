package notifications

import (
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// Shapes used by the public-id tests: a Firebase-shaped uid (28 mixed-case characters, no "_") and a well-formed public id.
const (
	wireActorUID = "ActorUidAbCdEfGhIjKlMnOpQr12"
	wirePubID    = "u0123456789abcdefghjkmnpqrs"
)

// The tombstone is the one literal shared with the edge (pkg/platform/publicid.Tombstone, PR 4a): it can never be minted,
// so it never names a real account.
func TestTombstonePublicID(t *testing.T) {
	t.Parallel()
	if TombstonePublicID != "uzzzzzzzzzzzzzzzzzzzzzzzzzz" || len(TombstonePublicID) != len(wirePubID) {
		t.Fatalf("TombstonePublicID = %q", TombstonePublicID)
	}
	if identity.ValidPublicID(TombstonePublicID) {
		t.Fatal("the tombstone is a mintable public id")
	}
	if !identity.ValidPublicID(wirePubID) {
		t.Fatal("test fixture is not a valid public id")
	}
}

// subjectFor is a well-formed subject for t (a beacon id for the beacon types, else a post id).
func subjectFor(t Type) string {
	if t.needsBeacon() {
		return beaconA
	}
	return postA
}

// The guard over every type the real id builder knows: a type whose stored id embeds the actor's uid must be
// classified actor-keyed (and then rewritten), and no wire id ever carries the uid. A new type that embeds the actor
// fails here until someone decides how its id goes on the wire.
func TestWireNotificationID_EveryTypeOfTheRealBuilder(t *testing.T) {
	t.Parallel()
	if len(allTypes) != 13 {
		t.Fatalf("allTypes has %d types: review WireNotificationID for the new one", len(allTypes))
	}
	for _, ty := range allTypes {
		if !ty.Valid() {
			t.Fatalf("%s is in allTypes but not Valid", ty)
		}
		if ty.pushOnly() {
			continue // no row, no notification id (the message push carries a conversation id only)
		}
		stored := notificationID(ty, wireActorUID, subjectFor(ty), t0)
		if stored == "" {
			t.Fatalf("%s: the builder made no id", ty)
		}
		embeds := strings.Contains(stored, wireActorUID)
		if embeds != ty.ActorKeyedID() {
			t.Errorf("%s: stored id %q embeds the actor = %v, ActorKeyedID = %v", ty, stored, embeds, ty.ActorKeyedID())
		}
		for _, pub := range []string{wirePubID, ""} {
			wire := WireNotificationID(stored, ty, pub)
			if strings.Contains(wire, wireActorUID) {
				t.Errorf("%s (pub %q): wire id %q carries the actor uid", ty, pub, wire)
			}
			switch {
			case !ty.ActorKeyedID():
				if wire != stored {
					t.Errorf("%s: wire id %q, want the stored id %q unchanged", ty, wire, stored)
				}
			case pub == "":
				if want := strings.TrimSuffix(stored, wireActorUID) + TombstonePublicID; wire != want {
					t.Errorf("%s: wire id %q, want %q (tombstone)", ty, wire, want)
				}
			default:
				if want := strings.TrimSuffix(stored, wireActorUID) + pub; wire != want {
					t.Errorf("%s: wire id %q, want %q", ty, wire, want)
				}
			}
		}
		uid, ok := NotificationIDActor(stored, ty)
		if ok != ty.ActorKeyedID() || (ok && uid != wireActorUID) {
			t.Errorf("%s: NotificationIDActor = %q, %v", ty, uid, ok)
		}
	}
}

func TestWireNotificationID(t *testing.T) {
	t.Parallel()
	const u = wireActorUID
	tests := []struct {
		name, stored string
		typ          Type
		pub, want    string
	}{
		{"follow", "follow_" + u, TypeFollow, wirePubID, "follow_" + wirePubID},
		{"follow request", "follow_request_" + u, TypeFollowRequest, wirePubID, "follow_request_" + wirePubID},
		{"follow accepted", "follow_accepted_" + u, TypeFollowAccepted, wirePubID, "follow_accepted_" + wirePubID},
		{"repost", "repost_" + postA + "_" + u, TypeRepost, wirePubID, "repost_" + postA + "_" + wirePubID},
		{"beacon request", "beacon_request_" + beaconA + "_" + u, TypeBeaconRequest, wirePubID, "beacon_request_" + beaconA + "_" + wirePubID},
		{"no public id: tombstone", "follow_" + u, TypeFollow, "", "follow_" + TombstonePublicID},
		{"a uid passed as the public id: tombstone", "follow_" + u, TypeFollow, u, "follow_" + TombstonePublicID},
		{"the tombstone passed in stays the tombstone", "repost_" + postA + "_" + u, TypeRepost, TombstonePublicID, "repost_" + postA + "_" + TombstonePublicID},
		{"a corrupt id without a segment is replaced whole", u, TypeFollow, wirePubID, wirePubID},
		{"like is unchanged", "like_" + postA + "_2026101012", TypeLike, wirePubID, "like_" + postA + "_2026101012"},
		{"mention is unchanged", "mention_" + postA, TypeMention, "", "mention_" + postA},
		{"beacon updated is unchanged", "beacon_updated_" + beaconA + "_1760099400000", TypeBeaconUpdated, wirePubID, "beacon_updated_" + beaconA + "_1760099400000"},
		{"unknown type is unchanged", "poke_x", Type("poke"), wirePubID, "poke_x"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := WireNotificationID(tt.stored, tt.typ, tt.pub); got != tt.want {
				t.Errorf("WireNotificationID(%q, %s, %q) = %q, want %q", tt.stored, tt.typ, tt.pub, got, tt.want)
			}
		})
	}
}

func TestNotificationIDActor(t *testing.T) {
	t.Parallel()
	tests := []struct {
		stored string
		typ    Type
		want   string
		ok     bool
	}{
		{"follow_" + wireActorUID, TypeFollow, wireActorUID, true},
		{"repost_" + postA + "_" + wireActorUID, TypeRepost, wireActorUID, true},
		{"follow_", TypeFollow, "", false},
		{wireActorUID, TypeFollow, "", false},
		{"like_" + postA + "_2026101012", TypeLike, "", false},
	}
	for _, tt := range tests {
		got, ok := NotificationIDActor(tt.stored, tt.typ)
		if got != tt.want || ok != tt.ok {
			t.Errorf("NotificationIDActor(%q, %s) = %q, %v; want %q, %v", tt.stored, tt.typ, got, ok, tt.want, tt.ok)
		}
	}
}
