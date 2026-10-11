package notifications

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

var t0 = time.Date(2026, 10, 10, 12, 30, 0, 0, time.UTC)

type fanoutRig struct {
	repo   *fakeRepo
	dir    *fakeDirectory
	social *fakeSocial
	sender *fakeSender
	logs   *bytes.Buffer
	f      *Fanout
}

func newRig(t *testing.T, fl FlagChecker) *fanoutRig {
	t.Helper()
	r := &fanoutRig{
		repo: newFakeRepo(), dir: newDirectory("alice", "bob", "carol"),
		social: &fakeSocial{snaps: map[string]graphSnap{}}, sender: &fakeSender{dead: map[string]bool{}, fail: map[string]bool{}},
		logs: &bytes.Buffer{},
	}
	if fl == nil {
		fl = allFlags{}
	}
	r.f = NewFanout(FanoutDeps{
		Repo: r.repo, Directory: r.dir, Social: r.social, Sender: r.sender, Flags: fl,
		Log: slog.New(slog.NewJSONHandler(r.logs, nil)), ProjectID: "demo-test", Now: func() time.Time { return t0 },
	})
	return r
}

type graphSnap = graph.Snapshot

func (r *fanoutRig) addDevice(uid, id, token string) {
	r.repo.devices[uid] = append(r.repo.devices[uid], Device{ID: id, Token: token, Platform: PlatformAndroid})
}

func TestDeliver_FollowCreatesRowAndPushesOnce(t *testing.T) {
	r := newRig(t, nil)
	r.addDevice("bob", "dev-1", "tok-1")
	r.addDevice("bob", "dev-2", "tok-2")
	ev := Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0}

	out, err := r.f.Deliver(context.Background(), ev)
	mustNoErr(t, err)
	if out.Created != 1 || out.Pushed != 2 {
		t.Fatalf("outcome = %+v, want 1 created, 2 pushed", out)
	}
	row, ok := r.repo.rows["bob"]["follow_alice"]
	if !ok {
		t.Fatalf("rows = %+v", r.repo.rows)
	}
	if row.Actor.Handle != "h_alice" || row.CreatedAt != t0 || len(row.ActorIDs) != 1 {
		t.Errorf("row = %+v", row)
	}
	push := r.sender.sent[0].Push
	if push.Type != TypeFollow || push.NotificationID != "follow_alice" || push.ActorID != "alice" {
		t.Errorf("push = %+v", push)
	}

	// Pub/Sub redelivers the same message: no second row and no second push (ADR-0017 D3).
	out, err = r.f.Deliver(context.Background(), ev)
	mustNoErr(t, err)
	if out.Duplicate != 1 || out.Created != 0 || out.Pushed != 0 || len(r.sender.sent) != 2 {
		t.Fatalf("redelivery outcome = %+v, pushes = %d", out, len(r.sender.sent))
	}
	if len(r.repo.rows["bob"]) != 1 {
		t.Errorf("rows after redelivery = %d", len(r.repo.rows["bob"]))
	}
}

func TestDeliver_SuppressionMatrix(t *testing.T) {
	tests := []struct {
		name      string
		ev        Event
		flags     FlagChecker
		snaps     map[string]graphSnap
		drop      []string // uids removed from the directory (suspended / deleting / gone)
		readOnly  bool
		wantRows  int
		wantEvent string // which Outcome counter is 1
	}{
		{name: "delivered", ev: Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}}, wantRows: 1, wantEvent: "created"},
		{name: "recipient blocks actor", ev: Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}},
			snaps: map[string]graphSnap{"bob": {Blocked: map[string]bool{"alice": true}}}, wantEvent: "suppressed"},
		{name: "recipient mutes actor", ev: Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}},
			snaps: map[string]graphSnap{"bob": {Muted: map[string]bool{"alice": true}}}, wantEvent: "suppressed"},
		{name: "actor blocks recipient", ev: Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}},
			snaps: map[string]graphSnap{"bob": {BlockedBy: map[string]bool{"alice": true}}}, wantEvent: "suppressed"},
		{name: "self action", ev: Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"alice"}}},
		{name: "suspended or deleting recipient", ev: Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}}, drop: []string{"bob"}, wantEvent: "dropped"},
		{name: "gone actor", ev: Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}}, drop: []string{"alice"}, wantEvent: "dropped"},
		{name: "flag off for the recipient", ev: Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}}, flags: fakeFlags{"carol": true}},
		{name: "readonly degraded mode", ev: Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}}, readOnly: true, wantEvent: "dropped"},
		{name: "unknown type", ev: Event{Type: "poke", ActorID: "alice", RecipientIDs: []string{"bob"}}, wantEvent: "dropped"},
		{name: "mention without a post", ev: Event{Type: TypeMention, ActorID: "alice", RecipientIDs: []string{"bob"}}, wantEvent: "dropped"},
		{name: "invalid actor id", ev: Event{Type: TypeFollow, ActorID: "a_b", RecipientIDs: []string{"bob"}}, wantEvent: "dropped"},
		{name: "no recipients", ev: Event{Type: TypeFollow, ActorID: "alice"}, wantEvent: "dropped"},
		{name: "too many recipients", ev: Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: strings.Split(strings.Repeat("u,", 11)+"u", ",")}, wantEvent: "dropped"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, tt.flags)
			r.f.d.ReadOnly = tt.readOnly
			for k, v := range tt.snaps {
				r.social.snaps[k] = v
			}
			for _, u := range tt.drop {
				delete(r.dir.profiles, u)
			}
			r.addDevice("bob", "dev-1", "tok-1")
			out, err := r.f.Deliver(context.Background(), tt.ev)
			mustNoErr(t, err)
			rows := 0
			for _, m := range r.repo.rows {
				rows += len(m)
			}
			if rows != tt.wantRows {
				t.Errorf("rows = %d, want %d", rows, tt.wantRows)
			}
			if (tt.wantRows == 0) != (len(r.sender.sent) == 0) {
				t.Errorf("rows = %d but pushes = %d", rows, len(r.sender.sent))
			}
			got := map[string]int{"created": out.Created, "suppressed": out.Suppressed, "dropped": out.Dropped, "duplicate": out.Duplicate}
			for name, n := range got {
				want := 0
				if name == tt.wantEvent {
					want = 1
				}
				if n != want {
					t.Errorf("outcome %s = %d, want %d (outcome %+v)", name, n, want, out)
				}
			}
		})
	}
}

func TestDeliver_MentionFansOutToEveryRecipientAndSuppressesPerRecipient(t *testing.T) {
	r := newRig(t, nil)
	r.social.snaps["carol"] = graphSnap{Muted: map[string]bool{"alice": true}}
	r.addDevice("bob", "d1", "tok-bob")
	r.addDevice("carol", "d2", "tok-carol")
	out, err := r.f.Deliver(context.Background(), Event{Type: TypeMention, ActorID: "alice", RecipientIDs: []string{"bob", "carol", "bob"}, PostID: postA, At: t0})
	mustNoErr(t, err)
	if out.Created != 1 || out.Suppressed != 1 {
		t.Fatalf("outcome = %+v", out)
	}
	if _, ok := r.repo.rows["bob"]["mention_"+postA]; !ok || len(r.repo.rows["carol"]) != 0 {
		t.Errorf("rows = %+v", r.repo.rows)
	}
	if len(r.sender.sent) != 1 || r.sender.sent[0].Token != "tok-bob" || r.sender.sent[0].Push.PostID != postA {
		t.Errorf("pushes = %+v", r.sender.sent)
	}
}

func TestDeliver_LikesCollapsePerPostPerHour(t *testing.T) {
	r := newRig(t, nil)
	r.dir = newDirectory("alice", "bob", "carol", "dave")
	r.f.d.Directory = r.dir
	r.addDevice("bob", "d1", "tok-bob")
	ctx := context.Background()
	like := func(actor string, at time.Time) Outcome {
		out, err := r.f.Deliver(ctx, Event{Type: TypeLike, ActorID: actor, RecipientIDs: []string{"bob"}, PostID: postA, At: at})
		mustNoErr(t, err)
		return out
	}
	if out := like("alice", t0); out.Created != 1 || out.Pushed != 1 {
		t.Fatalf("first like outcome = %+v", out)
	}
	for _, a := range []string{"carol", "dave", "carol"} { // the repeat by carol is idempotent (ArrayUnion)
		if out := like(a, t0.Add(time.Minute)); out.Created != 0 || out.Duplicate != 1 || out.Pushed != 0 {
			t.Fatalf("collapsed like by %s outcome = %+v", a, out)
		}
	}
	row := r.repo.rows["bob"]["like_"+postA+"_2026101012"]
	if len(row.ActorIDs) != 3 || row.Actor.UserID != "carol" {
		t.Fatalf("row = %+v", row)
	}
	if len(r.sender.sent) != 1 {
		t.Errorf("pushes = %d, want exactly 1 for the collapsed row", len(r.sender.sent))
	}
	// A like in the next UTC hour is a new row and a new push.
	if out := like("dave", t0.Add(time.Hour)); out.Created != 1 || len(r.sender.sent) != 2 {
		t.Errorf("next-hour like outcome = %+v, pushes %d", out, len(r.sender.sent))
	}
	if len(r.repo.rows["bob"]) != 2 {
		t.Errorf("rows = %d, want 2", len(r.repo.rows["bob"]))
	}
}

func TestNotificationID(t *testing.T) {
	tests := []struct {
		t      Type
		actor  string
		post   string
		at     time.Time
		want   string
		unique bool
	}{
		{TypeFollow, "u1", "", t0, "follow_u1", true},
		{TypeMention, "u1", postA, t0, "mention_" + postA, true},
		{TypeReply, "u1", postA, t0, "reply_" + postA, true},
		{TypeQuote, "u1", postA, t0, "quote_" + postA, true},
		{TypeRepost, "u1", postA, t0, "repost_" + postA + "_u1", true},
		{TypeLike, "u1", postA, t0, "like_" + postA + "_2026101012", true},
		{TypeLike, "u1", postA, time.Date(2026, 1, 2, 3, 59, 59, 0, time.FixedZone("x", 5*3600+1800)), "like_" + postA + "_2026010122", true},
		{"poke", "u1", postA, t0, "", false},
	}
	for _, tt := range tests {
		if got := notificationID(tt.t, tt.actor, tt.post, tt.at); got != tt.want {
			t.Errorf("notificationID(%s) = %q, want %q", tt.t, got, tt.want)
		}
	}
}

func TestDeliver_PushFailuresNeverFailTheDelivery(t *testing.T) {
	r := newRig(t, nil)
	r.addDevice("bob", "d-dead", "tok-dead")
	r.addDevice("bob", "d-fail", "tok-fail")
	r.addDevice("bob", "d-ok", "tok-ok")
	r.sender.dead["tok-dead"] = true
	r.sender.fail["tok-fail"] = true
	out, err := r.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0})
	mustNoErr(t, err)
	if out.Pushed != 1 || out.Pruned != 1 {
		t.Fatalf("outcome = %+v", out)
	}
	if len(r.repo.removed) != 1 || r.repo.removed[0] != "bob/d-dead/tok-dead" {
		t.Errorf("removed = %v (the prune must be conditional on the token)", r.repo.removed)
	}
	if strings.Contains(r.logs.String(), "tok-") {
		t.Errorf("a device token reached the logs: %s", r.logs.String())
	}
}

func TestDeliver_TransientFailuresAskForRetry(t *testing.T) {
	t.Run("create fails", func(t *testing.T) {
		r := newRig(t, nil)
		r.repo.createErr = errBoom
		if _, err := r.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}}); err == nil {
			t.Fatal("want an error so Pub/Sub redelivers")
		}
	})
	t.Run("profiles fail", func(t *testing.T) {
		r := newRig(t, nil)
		r.dir.err = errBoom
		if _, err := r.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}}); err == nil {
			t.Fatal("want an error")
		}
	})
	t.Run("snapshot fails but the other recipient is delivered", func(t *testing.T) {
		r := newRig(t, nil)
		r.social.err = errBoom
		out, err := r.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}})
		if err == nil || out.Created != 0 {
			t.Fatalf("outcome = %+v, err = %v", out, err)
		}
	})
	t.Run("device lookup fails: the row stands, no retry", func(t *testing.T) {
		r := newRig(t, nil)
		r.repo.devErr = errBoom
		out, err := r.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}})
		if err != nil || out.Created != 1 {
			t.Fatalf("outcome = %+v, err = %v", out, err)
		}
	})
}

func envelope(t *testing.T, data []byte) *http.Request {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"message":         map[string]any{"data": base64.StdEncoding.EncodeToString(data), "messageId": "m-1"},
		"deliveryAttempt": 2,
	})
	mustNoErr(t, err)
	return httptest.NewRequest(http.MethodPost, "/internal/pubsub/notifications-fanout", bytes.NewReader(body))
}

func TestHandler(t *testing.T) {
	good, err := encodeEvent(Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0})
	mustNoErr(t, err)
	tests := []struct {
		name     string
		req      func() *http.Request
		prep     func(*fanoutRig)
		wantCode int
		wantRows int
	}{
		{"delivers", func() *http.Request { return envelope(t, good) }, nil, http.StatusNoContent, 1},
		{"redelivery of the same message is acknowledged", func() *http.Request { return envelope(t, good) }, func(r *fanoutRig) {
			_, _ = r.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0})
		}, http.StatusNoContent, 1},
		{"malformed envelope is acknowledged", func() *http.Request {
			return httptest.NewRequest(http.MethodPost, "/", strings.NewReader("not json"))
		}, nil, http.StatusNoContent, 0},
		{"malformed message is acknowledged", func() *http.Request { return envelope(t, []byte("{")) }, nil, http.StatusNoContent, 0},
		{"unknown version is acknowledged", func() *http.Request { return envelope(t, []byte(`{"v":9,"type":"follow"}`)) }, nil, http.StatusNoContent, 0},
		{"permanently invalid event is acknowledged", func() *http.Request {
			return envelope(t, []byte(`{"v":1,"type":"follow","actorId":"a_b","recipientIds":["bob"]}`))
		}, nil, http.StatusNoContent, 0},
		{"transient failure asks for redelivery", func() *http.Request { return envelope(t, good) }, func(r *fanoutRig) { r.repo.createErr = errBoom }, http.StatusInternalServerError, 0},
		{"GET is rejected", func() *http.Request { return httptest.NewRequest(http.MethodGet, "/", nil) }, nil, http.StatusMethodNotAllowed, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, nil)
			if tt.prep != nil {
				tt.prep(r)
			}
			w := httptest.NewRecorder()
			r.f.Handler().ServeHTTP(w, tt.req())
			if w.Code != tt.wantCode {
				t.Fatalf("code = %d, want %d (body %q)", w.Code, tt.wantCode, w.Body.String())
			}
			if got := len(r.repo.rows["bob"]); got != tt.wantRows {
				t.Errorf("rows = %d, want %d", got, tt.wantRows)
			}
			if w.Code == http.StatusNoContent && tt.wantRows == 1 {
				var line map[string]any
				for _, l := range strings.Split(strings.TrimSpace(r.logs.String()), "\n") {
					if strings.Contains(l, `"notification_delivery"`) {
						mustNoErr(t, json.Unmarshal([]byte(l), &line))
					}
				}
				if line == nil || line["message_id"] != "m-1" || line["fs_reads"] == nil || line["fs_writes"] == nil {
					t.Errorf("delivery log line = %v (needs message_id, fs_reads, fs_writes)", line)
				}
			}
		})
	}
}

func TestHandler_BodyIsBounded(t *testing.T) {
	r := newRig(t, nil)
	w := httptest.NewRecorder()
	big := io.NopCloser(strings.NewReader(`{"message":{"data":"` + strings.Repeat("A", 1<<20) + `"}}`))
	req := httptest.NewRequest(http.MethodPost, "/", big)
	r.f.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusNoContent {
		t.Errorf("oversized body: code = %d, want an acknowledgement", w.Code)
	}
	if len(r.repo.rows) != 0 {
		t.Errorf("rows = %v", r.repo.rows)
	}
}
