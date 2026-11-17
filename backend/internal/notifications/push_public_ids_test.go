package notifications

import (
	"bytes"
	"context"
	"log/slog"
	"maps"
	"reflect"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// legacyData is the push data map exactly as buildMessage produced it before public ids: the flag-off contract.
func legacyData(p Push) map[string]string {
	switch {
	case p.Type.pushOnly():
		return map[string]string{"type": string(p.Type), "conversationId": p.ConversationID}
	case p.Type.needsBeacon():
		return map[string]string{"type": string(p.Type), "notificationId": p.NotificationID, "beaconId": p.BeaconID, "actorId": p.ActorID}
	}
	return map[string]string{"type": string(p.Type), "notificationId": p.NotificationID, "postId": p.PostID, "actorId": p.ActorID}
}

// storedPush is the push the fan-out builds for a row of type ty by wireActorUID (stored ids).
func storedPush(ty Type) Push {
	p := Push{Type: ty, ActorID: wireActorUID}
	switch {
	case ty.pushOnly():
		return Push{Type: ty, ConversationID: "0123456789abcdef0123456789abcdef"}
	case ty.needsBeacon():
		p.BeaconID = beaconA
	default:
		p.PostID = postA
	}
	p.NotificationID = notificationID(ty, wireActorUID, subjectFor(ty), t0)
	return p
}

// buildMessage per type in each recipient state: flag off is the legacy payload byte for byte; flag on sends the
// actor's public id as actorId (omitted when there is none) and the wire notification id; the uid never leaves.
func TestBuildMessage_PublicIDsPerRecipient(t *testing.T) {
	t.Parallel()
	for _, ty := range allTypes {
		t.Run(string(ty), func(t *testing.T) {
			t.Parallel()
			base := storedPush(ty)

			off := buildMessage("tok", base)
			if !maps.Equal(off.Data, legacyData(base)) {
				t.Errorf("flag off: data = %v, want the legacy %v", off.Data, legacyData(base))
			}
			// The public id on a flag-off push is ignored (the fan-out never sets it, but the builder must not leak it either).
			stray := base
			stray.ActorPublicID = wirePubID
			if got := buildMessage("tok", stray); !reflect.DeepEqual(got, off) {
				t.Errorf("flag off with a stray public id: %+v, want %+v", got.Data, off.Data)
			}

			on := base
			on.PublicIDs, on.ActorPublicID = true, wirePubID
			got := buildMessage("tok", on).Data
			want := legacyData(base)
			if !ty.pushOnly() {
				want["actorId"] = wirePubID
				want["notificationId"] = WireNotificationID(base.NotificationID, ty, wirePubID)
			}
			if !maps.Equal(got, want) {
				t.Errorf("flag on: data = %v, want %v", got, want)
			}

			none := base
			none.PublicIDs = true
			got = buildMessage("tok", none).Data
			want = legacyData(base)
			if !ty.pushOnly() {
				delete(want, "actorId")
				want["notificationId"] = WireNotificationID(base.NotificationID, ty, "")
			}
			if !maps.Equal(got, want) {
				t.Errorf("flag on, no public id: data = %v, want %v", got, want)
			}

			for _, p := range []Push{on, none} {
				for k, v := range buildMessage("tok", p).Data {
					if strings.Contains(v, wireActorUID) {
						t.Errorf("flag on: data[%s] = %q carries the actor uid", k, v)
					}
				}
			}
			// Everything outside data (collapse key, tag, text, TTL) is the same in every state.
			a, b := buildMessage("tok", base), buildMessage("tok", on)
			a.Data, b.Data = nil, nil
			if !reflect.DeepEqual(a, b) {
				t.Errorf("flag on changed more than data: %+v vs %+v", a, b)
			}
		})
	}
}

// pubFlags turns notifications on for everyone and public_ids on for the uids in on.
type pubFlags struct{ on map[string]bool }

func (f pubFlags) Enabled(uid, name string) bool {
	switch name {
	case FlagName:
		return true
	case identity.PublicIDsFlag:
		return f.on[uid]
	}
	return false
}

// The fan-out decides per recipient: a recipient with public_ids on gets the actor's public id from the profile the
// delivery already loaded (no extra lookup); everyone else gets today's push, field for field.
func TestDeliver_PublicIDsPerRecipient(t *testing.T) {
	tests := []struct {
		name     string
		ty       Type
		actorPub string
	}{
		{"follow, actor has a public id", TypeFollow, wirePubID},
		{"follow, actor has none", TypeFollow, ""},
		{"follow request", TypeFollowRequest, wirePubID},
		{"follow accepted", TypeFollowAccepted, wirePubID},
		{"repost", TypeRepost, wirePubID},
		{"beacon request", TypeBeaconRequest, wirePubID},
		{"like", TypeLike, wirePubID},
		{"mention", TypeMention, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, pubFlags{on: map[string]bool{"bob": true}})
			r.dir.profiles[wireActorUID] = identity.Profile{UserID: wireActorUID, PublicID: tt.actorPub, Handle: "h_actor", Status: identity.AccountStatusActive}
			r.addDevice("bob", "dev-b", "tok-bob")
			r.addDevice("carol", "dev-c", "tok-carol")
			ev := Event{Type: tt.ty, ActorID: wireActorUID, RecipientIDs: []string{"bob", "carol"}, At: t0}
			switch {
			case tt.ty.needsBeacon():
				ev.BeaconID = beaconA
			case tt.ty.needsPost():
				ev.PostID = postA
			}
			out, err := r.f.Deliver(context.Background(), ev)
			mustNoErr(t, err)
			if out.Pushed != 2 {
				t.Fatalf("outcome = %+v, want 2 pushed", out)
			}
			if len(r.dir.lookups) != 1 {
				t.Errorf("directory lookups = %v, want the one profile load (no extra read for the public id)", r.dir.lookups)
			}
			legacy := Push{Type: tt.ty, NotificationID: notificationID(tt.ty, wireActorUID, ev.subject(), t0), PostID: ev.PostID, ActorID: wireActorUID, BeaconID: ev.BeaconID}
			byToken := map[string]Push{}
			for _, s := range r.sender.sent {
				byToken[s.Token] = s.Push
			}
			if got := byToken["tok-carol"]; got != legacy {
				t.Errorf("flag off recipient: push = %+v, want today's %+v", got, legacy)
			}
			wantOn := legacy
			wantOn.PublicIDs, wantOn.ActorPublicID = true, tt.actorPub
			if got := byToken["tok-bob"]; got != wantOn {
				t.Errorf("flag on recipient: push = %+v, want %+v", got, wantOn)
			}
			// The rows are stored exactly as before, whatever the recipient's flag.
			for _, uid := range []string{"bob", "carol"} {
				if _, ok := r.repo.rows[uid][legacy.NotificationID]; !ok {
					t.Errorf("%s: no row under the stored id", uid)
				}
			}
			if logs := r.logs.String(); strings.Contains(logs, wireActorUID) || (tt.actorPub != "" && strings.Contains(logs, tt.actorPub)) {
				t.Errorf("a uid or a public id reached the log: %s", logs)
			}
		})
	}
}

// Globally off (no recipient has the flag, the prod state) and an unwired flag checker: every push is today's.
func TestDeliver_PublicIDsOffIsToday(t *testing.T) {
	for _, fl := range []FlagChecker{pubFlags{}, nil} {
		r := newRig(t, fl)
		r.dir.profiles[wireActorUID] = identity.Profile{UserID: wireActorUID, PublicID: wirePubID, Handle: "h_actor", Status: identity.AccountStatusActive}
		r.addDevice("bob", "dev-b", "tok-bob")
		_, err := r.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: wireActorUID, RecipientIDs: []string{"bob"}, At: t0})
		mustNoErr(t, err)
		want := Push{Type: TypeFollow, NotificationID: "follow_" + wireActorUID, ActorID: wireActorUID}
		if len(r.sender.sent) != 1 || r.sender.sent[0].Push != want {
			t.Fatalf("flags %T: pushes = %+v, want [%+v]", fl, r.sender.sent, want)
		}
		if got := buildMessage("tok", r.sender.sent[0].Push).Data; !maps.Equal(got, legacyData(want)) {
			t.Errorf("flags %T: data = %v", fl, got)
		}
	}
}

// The local sender logs the stored row's hash (the repo's pseudonym) and never the wire id, the public id or the uid.
func TestLogSender_PublicIDPushLogsNoIDs(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	s := LogSender{Log: slog.New(slog.NewJSONHandler(&buf, nil))}
	p := storedPush(TypeFollow)
	p.PublicIDs, p.ActorPublicID = true, wirePubID
	if err := s.Send(context.Background(), "tok-secret", p); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	for _, needle := range []string{wireActorUID, wirePubID, p.NotificationID, WireNotificationID(p.NotificationID, p.Type, wirePubID), "tok-secret"} {
		if strings.Contains(out, needle) {
			t.Errorf("log line carries %q: %s", needle, out)
		}
	}
}
