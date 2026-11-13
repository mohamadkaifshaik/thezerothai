//go:build integration

package apiserver

// Over the real Build chain (Firestore, Auth, Pub/Sub and Storage emulators): a replaced or
// removed avatar publishes a profile_media_retired job after the UpdateProfile commit, the
// job tags the old image and retires its media document, a redelivery does nothing, the resolvers
// refuse a retired image, and a forged message never retires a current image or another user's image.
//
// The Storage emulator does not implement objects.patch (it answers 501), which objstore.SetCustomTime accepts against
// the emulator only, so the customTime patches themselves are checked in the media package with a counting tagger and
// on a real bucket in dev.

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

func retireOn(mode config.ProfileMediaRetire) func(*config.Config) {
	return func(c *config.Config) {
		profileExtrasOn(c)
		c.ProfileMediaRetire = mode
	}
}

// profileImageURL is what UpdateProfile stores for a media id: the public base URL plus the document's object name.
func (e *lifecycleEnv) profileImageURL(id string) string {
	return e.cfg.MediaPublicBaseURL + "/m/" + id + ".jpg"
}

func (e *lifecycleEnv) updateImages(t *testing.T, u testUser, key string, avatar *string) (*identityv1.Profile, map[string]any) {
	t.Helper()
	resp, err := e.identity.UpdateProfile(context.Background(), authed(u.token, &identityv1.UpdateProfileRequest{IdempotencyKey: key, AvatarMediaId: avatar}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	return resp.Msg.GetProfile(), lastRequestLine(t, e, rpcUpdateProfile)
}

// lastRetireLine is the newest `account_job` record of the profile_media_retired kind.
func (e *lifecycleEnv) lastRetireLine(t *testing.T) map[string]any {
	t.Helper()
	var last map[string]any
	for _, l := range e.jobLines() {
		if l["account_job"] == media.JobKindProfileMediaRetired {
			last = l
		}
	}
	if last == nil {
		t.Fatal("no profile_media_retired job line was logged")
	}
	return last
}

func (e *lifecycleEnv) mediaDocFields(t *testing.T, id string) (retiredAt, expireAt time.Time, retired bool) {
	t.Helper()
	snap, err := e.fs.Collection("media").Doc(id).Get(context.Background())
	if err != nil {
		t.Fatalf("media/%s: %v", id, err)
	}
	r, hasR := snap.Data()["retiredAt"].(time.Time)
	x, _ := snap.Data()["expireAt"].(time.Time)
	return r, x, hasR
}

func TestProfileMediaRetire_Chain(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, retireOn(config.ProfileMediaRetireAll))
	a, b := e.newUser(t), e.newUser(t)
	av1, av2, av3 := e.seedMedia(t, a.uid, media.PurposeAvatar), e.seedMedia(t, a.uid, media.PurposeAvatar), e.seedMedia(t, a.uid, media.PurposeAvatar)
	theirs := e.seedMedia(t, b.uid, media.PurposeAvatar)
	str := func(s string) *string { return &s }

	// --- first-time set of an avatar: nothing to retire, no message ---
	e.pull(t) // drain
	got, _ := e.updateImages(t, a, "retire-first-set-00001", &av1)
	if got.GetAvatarUrl() != e.profileImageURL(av1) {
		t.Fatalf("profile = avatar %q", got.GetAvatarUrl())
	}
	if msgs := e.pull(t); len(msgs) != 0 {
		t.Fatalf("a first-time set published %v, want nothing", msgs)
	}

	// --- replace the avatar, then remove it: one message each ---
	var msgs []map[string]any
	got, _ = e.updateImages(t, a, "retire-replace-000001", &av2)
	if got.GetAvatarUrl() != e.profileImageURL(av2) {
		t.Fatalf("profile = avatar %q", got.GetAvatarUrl())
	}
	msgs = append(msgs, e.pull(t)...)
	got, _ = e.updateImages(t, a, "retire-remove-0000001", str(""))
	if got.GetAvatarUrl() != "" {
		t.Fatalf("profile = avatar %q after the removal", got.GetAvatarUrl())
	}
	msgs = append(msgs, e.pull(t)...)
	if len(msgs) != 2 {
		t.Fatalf("messages = %v, want the replaced and the removed avatar", msgs)
	}
	for i, old := range []string{av1, av2} {
		if m := msgs[i]; m["kind"] != media.JobKindProfileMediaRetired || m["uid"] != a.uid || m["purpose"] != "AVATAR" || m["oldUrl"] != e.profileImageURL(old) {
			t.Fatalf("message %d = %v, want the AVATAR %s", i, m, old)
		}
	}

	// --- the handler retires, then the redelivery does nothing ---
	for i, m := range msgs {
		if code := e.deliver(t, m); code != http.StatusNoContent {
			t.Fatalf("delivery %d = %d", i, code)
		}
		jl := e.lastRetireLine(t)
		if jl["outcome"] != "retired" {
			t.Errorf("job line %d outcome = %v, want retired", i, jl["outcome"])
		}
		if strings.Contains(fmt.Sprint(jl), a.uid) {
			t.Errorf("the job line leaks the raw uid: %v", jl)
		}
		if code := e.deliver(t, m); code != http.StatusNoContent {
			t.Fatalf("redelivery %d = %d", i, code)
		}
		jl = e.lastRetireLine(t)
		if jl["outcome"] != "duplicate" {
			t.Errorf("redelivery %d line outcome = %v, want duplicate", i, jl["outcome"])
		}
	}
	for _, id := range []string{av1, av2} {
		r, x, retired := e.mediaDocFields(t, id)
		if !retired || x.Sub(r) != media.RetiredDocTTL || time.Since(r) > time.Minute {
			t.Errorf("media/%s: retiredAt %v expireAt %v retired=%v, want a fresh retiredAt and expireAt = retiredAt + 72 h", id, r, x, retired)
		}
	}
	if got, _ = e.updateImages(t, a, "retire-set-third-0001", &av3); got.GetAvatarUrl() != e.profileImageURL(av3) {
		t.Fatalf("profile = avatar %q", got.GetAvatarUrl())
	}
	if msgs := e.pull(t); len(msgs) != 0 {
		t.Fatalf("setting an avatar on an empty profile published %v", msgs)
	}

	// --- a retired image can never be set again (the one MEDIA_NOT_READY answer) ---
	_, err := e.identity.UpdateProfile(ctx, authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "retire-reuse-000001", AvatarMediaId: &av1}))
	if d := wireError(t, err, connect.CodeFailedPrecondition); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
		t.Errorf("setting a retired avatar: reason = %v, want MEDIA_NOT_READY", d.GetReason())
	}
	// A legacy BANNER document (the removed purpose) is not an avatar either.
	legacy := e.seedMedia(t, a.uid, media.Purpose("BANNER"))
	_, err = e.identity.UpdateProfile(ctx, authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "retire-reuse-000002", AvatarMediaId: &legacy}))
	if d := wireError(t, err, connect.CodeFailedPrecondition); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
		t.Errorf("setting a legacy banner as the avatar: reason = %v, want MEDIA_NOT_READY", d.GetReason())
	}

	// --- forged messages: a message never retires a current image or another user's image ---
	spare := e.seedMedia(t, a.uid, media.PurposeAvatar)
	forged := func(name, outcome string, m map[string]any) {
		t.Helper()
		m["kind"] = media.JobKindProfileMediaRetired
		m["changedAt"] = time.Now().UTC().Format(time.RFC3339Nano)
		if code := e.deliverJSON(t, m); code != http.StatusNoContent {
			t.Fatalf("%s: delivery = %d, want an ack (a poison message must not be retried forever)", name, code)
		}
		if got := e.lastRetireLine(t)["outcome"]; got != outcome {
			t.Errorf("%s: outcome = %v, want %s", name, got, outcome)
		}
	}
	forged("the current avatar", "still_current", map[string]any{"uid": a.uid, "purpose": "AVATAR", "oldUrl": e.profileImageURL(av3)})
	forged("another user's image under my uid", "refused", map[string]any{"uid": a.uid, "purpose": "AVATAR", "oldUrl": e.profileImageURL(theirs)})
	forged("the wrong purpose (a legacy banner named as an avatar)", "refused", map[string]any{"uid": a.uid, "purpose": "AVATAR", "oldUrl": e.profileImageURL(legacy)})
	// A BANNER message still in flight from a revision that had banners is acked and dropped.
	forged("a legacy BANNER message", "dropped:invalid_message", map[string]any{"uid": a.uid, "purpose": "BANNER", "oldUrl": e.profileImageURL(legacy)})
	forged("an url media does not own", "unparseable", map[string]any{"uid": a.uid, "purpose": "AVATAR", "oldUrl": "https://elsewhere.example/avatar.png"})
	forged("an unknown image", "duplicate", map[string]any{"uid": a.uid, "purpose": "AVATAR", "oldUrl": e.profileImageURL("4999999999999999999")})
	for _, id := range []string{av3, theirs, spare, legacy} {
		if _, _, retired := e.mediaDocFields(t, id); retired {
			t.Errorf("media/%s was retired by a forged message", id)
		}
	}
	if code := e.deliverJSON(t, map[string]any{"kind": media.JobKindProfileMediaRetired, "uid": "bad/uid", "purpose": "AVATAR", "oldUrl": "x", "changedAt": time.Now().UTC()}); code != http.StatusNoContent {
		t.Errorf("an invalid message = %d, want an ack", code)
	}
	if got := e.lastRetireLine(t)["outcome"]; got != "dropped:invalid_message" {
		t.Errorf("outcome = %v", got)
	}

	// --- the retired documents stay until their TTL, so the media eraser and the export still cover them (the media
	// package's tests run the eraser over them) ---
	for _, id := range []string{av1, av2} {
		if snap, err := e.fs.Collection("media").Doc(id).Get(ctx); err != nil || !snap.Exists() {
			t.Fatalf("a retired document must stay until its TTL: %v", err)
		}
	}
}

// With the switch off nothing is published and a delivered message is acked without action; all covers the avatar; the
// handler honours the switch even for a message another revision published.
func TestProfileMediaRetire_SwitchModes(t *testing.T) {
	tests := []struct {
		mode              config.ProfileMediaRetire
		wantAvatarMessage bool
	}{
		{config.ProfileMediaRetireOff, false},
		{config.ProfileMediaRetireAll, true},
	}
	for _, tt := range tests {
		t.Run(string(tt.mode), func(t *testing.T) {
			e := newLifecycleEnvCfg(t, nil, retireOn(tt.mode))
			a := e.newUser(t)
			av1, av2 := e.seedMedia(t, a.uid, media.PurposeAvatar), e.seedMedia(t, a.uid, media.PurposeAvatar)
			e.updateImages(t, a, "mode-first-set-0000001", &av1)
			e.pull(t)

			e.updateImages(t, a, "mode-replace-avatar-001", &av2)
			if got := len(e.pull(t)); (got == 1) != tt.wantAvatarMessage || got > 1 {
				t.Errorf("avatar replace published %d messages, want %v", got, tt.wantAvatarMessage)
			}

			// The handler checks the switch too: a message the other revision published is acked and does nothing.
			m := map[string]any{"kind": media.JobKindProfileMediaRetired, "uid": a.uid, "purpose": "AVATAR", "oldUrl": e.profileImageURL(av1), "changedAt": time.Now().UTC().Format(time.RFC3339Nano)}
			if code := e.deliverJSON(t, m); code != http.StatusNoContent {
				t.Fatalf("delivery = %d", code)
			}
			want := "disabled"
			if tt.wantAvatarMessage {
				want = "retired"
			}
			if got := e.lastRetireLine(t)["outcome"]; got != want {
				t.Errorf("outcome = %v, want %s", got, want)
			}
			if _, _, retired := e.mediaDocFields(t, av1); retired != tt.wantAvatarMessage {
				t.Errorf("doc retired = %v, want %v", retired, tt.wantAvatarMessage)
			}
		})
	}
}
