package identity

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// UpdateProfile hands a replaced or removed avatar to the media retire step after
// the commit, without re-reading the profile. The Firestore side is in media_retire_integration_test.go;
// the step itself (the switch, the object names, the refusals) is the media module's.

type retireCall struct {
	uid, oldURL, oldThumbURL string
	image                    ProfileImage
	at                       time.Time
	ctxErr                   error
	hasDeadline              bool
}

type fakeRetirer struct {
	calls []retireCall
	// failFor makes the call for that image fail.
	failFor map[ProfileImage]error
}

func (f *fakeRetirer) RetireProfileImage(ctx context.Context, uid string, image ProfileImage, oldURL, oldThumbURL string, changedAt time.Time) error {
	_, dl := ctx.Deadline()
	f.calls = append(f.calls, retireCall{uid: uid, image: image, oldURL: oldURL, oldThumbURL: oldThumbURL, at: changedAt, ctxErr: ctx.Err(), hasDeadline: dl})
	return f.failFor[image]
}

type retireEnv struct {
	*extrasEnv
	avatars *fakeAvatars
	retirer *fakeRetirer
	logs    *bytes.Buffer
	now     time.Time
}

func newRetireEnv(t *testing.T, withRetirer bool) *retireEnv {
	t.Helper()
	avatars := &fakeAvatars{ref: AvatarRef{URL: "https://m/m/0000000000000000201.webp", ThumbURL: "https://m/m/0000000000000000201_t.webp"}}
	retirer := &fakeRetirer{failFor: map[ProfileImage]error{}}
	logs := &bytes.Buffer{}
	opts := []Option{WithAvatarResolver(avatars)}
	if withRetirer {
		opts = append(opts, WithMediaRetirer(retirer, slog.New(slog.NewJSONHandler(logs, nil))))
	}
	e := &retireEnv{extrasEnv: newExtrasEnv(t, extrasRegistry(flags.On), opts...), avatars: avatars, retirer: retirer, logs: logs}
	e.now = time.Date(2026, 10, 27, 9, 0, 0, 0, time.UTC)
	e.svc.now = func() time.Time { return e.now }
	return e
}

func (e *retireEnv) setAvatar(id string) {
	e.avatars.ref = AvatarRef{URL: "https://m/m/" + id + ".webp", ThumbURL: "https://m/m/" + id + "_t.webp"}
}

const (
	avA = "0000000000000000201"
	avB = "0000000000000000203"
)

// seedImages gives the profile avatar avA, then forgets the calls the seeding made.
func (e *retireEnv) seedImages(t *testing.T) {
	t.Helper()
	e.setAvatar(avA)
	if _, err := e.update(context.Background(), UpdateProfileParams{AvatarMediaID: strp(avA)}); err != nil {
		t.Fatal(err)
	}
	e.retirer.calls = nil
	e.now = e.now.Add(time.Hour)
}

func TestUpdateProfile_RetiresReplacedAndRemovedImages(t *testing.T) {
	avatarA := [2]string{"https://m/m/" + avA + ".webp", "https://m/m/" + avA + "_t.webp"}
	tests := []struct {
		name   string
		seed   bool
		params UpdateProfileParams
		before func(e *retireEnv) // prepare the resolvers for the request
		want   []retireCall       // image + old urls (uid and time are checked separately)
	}{
		{
			name: "avatar replaced", seed: true,
			params: UpdateProfileParams{AvatarMediaID: strp(avB)},
			before: func(e *retireEnv) { e.setAvatar(avB) },
			want:   []retireCall{{image: ProfileImageAvatar, oldURL: avatarA[0], oldThumbURL: avatarA[1]}},
		},
		{
			name: "avatar removed", seed: true,
			params: UpdateProfileParams{AvatarMediaID: strp("")},
			want:   []retireCall{{image: ProfileImageAvatar, oldURL: avatarA[0], oldThumbURL: avatarA[1]}},
		},
		{name: "first avatar: nothing before, nothing to retire", params: UpdateProfileParams{AvatarMediaID: strp(avA)}},
		{name: "removing an avatar that was never set", params: UpdateProfileParams{AvatarMediaID: strp("")}},
		{name: "the same avatar again is a no-op", seed: true, params: UpdateProfileParams{AvatarMediaID: strp(avA)}},
		{name: "an empty request", seed: true, params: UpdateProfileParams{}},
		{name: "a bio edit leaves the images alone", seed: true, params: UpdateProfileParams{Bio: strp("new bio")}},
		{name: "a display-name edit leaves the images alone", seed: true, params: UpdateProfileParams{DisplayName: strp("Alice B.")}},
		{name: "location, website and pin edits leave the images alone", seed: true,
			params: UpdateProfileParams{Location: strp("Pune"), Website: strp("https://example.com"), PinnedPostID: strp(pinID)}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newRetireEnv(t, true)
			if tt.seed {
				e.seedImages(t)
			}
			if tt.before != nil {
				tt.before(e)
			}
			readsBefore, writesBefore := e.repo.getProfileCalls, e.repo.updateWrites
			if _, err := e.update(context.Background(), tt.params); err != nil {
				t.Fatalf("UpdateProfile: %v", err)
			}
			if e.repo.getProfileCalls != readsBefore {
				t.Errorf("the retire hand-over read the profile (%d extra reads); the old URLs must come from the transaction's own read", e.repo.getProfileCalls-readsBefore)
			}
			if len(e.retirer.calls) != len(tt.want) {
				t.Fatalf("retire calls = %+v, want %d", e.retirer.calls, len(tt.want))
			}
			for i, w := range tt.want {
				g := e.retirer.calls[i]
				if g.image != w.image || g.oldURL != w.oldURL || g.oldThumbURL != w.oldThumbURL {
					t.Errorf("call %d = %s %q %q, want %s %q %q", i, g.image, g.oldURL, g.oldThumbURL, w.image, w.oldURL, w.oldThumbURL)
				}
				if g.uid != extrasUID || !g.at.Equal(e.now) {
					t.Errorf("call %d: uid %q at %v, want %q at %v (the commit time)", i, g.uid, g.at, extrasUID, e.now)
				}
			}
			if len(tt.want) == 0 && e.repo.updateWrites != writesBefore && !tt.seed {
				t.Logf("(a first-time set wrote the profile, as expected)")
			}
		})
	}
}

// TestUpdateProfile_RetireFailureNeverFailsTheRequest: the hand-over is best effort. The profile change is committed and
// returned; the failure is an ERROR-severity log line without the raw uid.
func TestUpdateProfile_RetireFailureNeverFailsTheRequest(t *testing.T) {
	e := newRetireEnv(t, true)
	e.seedImages(t)
	e.setAvatar(avB)
	e.retirer.failFor[ProfileImageAvatar] = errors.New("pubsub unavailable for " + extrasUID)

	got, err := e.update(context.Background(), UpdateProfileParams{AvatarMediaID: strp(avB)})
	if err != nil {
		t.Fatalf("a failed hand-over failed the request: %v", err)
	}
	if !strings.Contains(got.AvatarURL, avB) {
		t.Errorf("the response must carry the committed change: %+v", got)
	}
	if stored := e.repo.profiles[extrasUID]; !strings.Contains(stored.AvatarURL, avB) {
		t.Errorf("the change was not committed: %+v", stored)
	}
	if len(e.retirer.calls) != 1 {
		t.Errorf("calls = %d, want the one avatar hand-over", len(e.retirer.calls))
	}
	logs := e.logs.String()
	if n := strings.Count(logs, "profile_media_retire_enqueue_failed:"); n != 1 {
		t.Fatalf("failure lines = %d, want exactly 1 (only the avatar hand-over failed):\n%s", n, logs)
	}
	// The platform logger maps the slog level to Cloud Logging severity; an ERROR entry of the Error Reporting event type
	// is what makes the failure visible there.
	if !strings.Contains(logs, `"level":"ERROR"`) || !strings.Contains(logs, "ReportedErrorEvent") {
		t.Errorf("the failure must be an Error-Reporting-shaped ERROR entry:\n%s", logs)
	}
	if !strings.Contains(logs, `"image":"AVATAR"`) {
		t.Errorf("the entry must name the failed image:\n%s", logs)
	}
	if strings.Contains(logs, extrasUID) {
		t.Errorf("the log line leaks the raw uid:\n%s", logs)
	}
}

// TestUpdateProfile_RetireIsDetachedFromTheRequestContext: the hand-over runs after the commit under its own short
// deadline, so a client that hung up right after the commit does not turn delete-after-grace into delete-with-account.
func TestUpdateProfile_RetireIsDetachedFromTheRequestContext(t *testing.T) {
	e := newRetireEnv(t, true)
	e.seedImages(t)
	e.setAvatar(avB)
	ctx, cancel := context.WithCancel(context.Background())
	e.svc.repo = cancelAfterUpdate{Repo: e.repo, cancel: cancel}

	if _, err := e.update(ctx, UpdateProfileParams{AvatarMediaID: strp(avB)}); err != nil {
		t.Fatal(err)
	}
	if ctx.Err() == nil {
		t.Fatal("test setup: the request context should be cancelled by now")
	}
	if len(e.retirer.calls) != 1 {
		t.Fatalf("calls = %d", len(e.retirer.calls))
	}
	if c := e.retirer.calls[0]; c.ctxErr != nil || !c.hasDeadline {
		t.Errorf("the hand-over context: err=%v deadline=%v; want a live context with its own deadline", c.ctxErr, c.hasDeadline)
	}
}

// cancelAfterUpdate cancels the request context once the transaction committed, like a client that disconnects.
type cancelAfterUpdate struct {
	Repo
	cancel context.CancelFunc
}

func (c cancelAfterUpdate) UpdateProfile(ctx context.Context, uid string, mutate func(*Profile)) (Profile, error) {
	p, err := c.Repo.UpdateProfile(ctx, uid, mutate)
	c.cancel()
	return p, err
}

// retryingRepo runs the mutation twice, the way a Firestore transaction that was aborted and retried does: only the
// last attempt's view may produce a hand-over, and it must produce exactly one.
type retryingRepo struct{ Repo }

func (r retryingRepo) UpdateProfile(ctx context.Context, uid string, mutate func(*Profile)) (Profile, error) {
	cur, err := r.GetProfile(ctx, uid)
	if err != nil {
		return Profile{}, err
	}
	mutate(&cur) // attempt 1 runs against a copy and is discarded: an aborted transaction writes nothing
	return r.Repo.UpdateProfile(ctx, uid, mutate)
}

func TestUpdateProfile_RetryOfTheTransactionHandsOverOnce(t *testing.T) {
	e := newRetireEnv(t, true)
	e.seedImages(t)
	e.setAvatar(avB)
	e.svc.repo = retryingRepo{Repo: e.repo}
	if _, err := e.update(context.Background(), UpdateProfileParams{AvatarMediaID: strp(avB)}); err != nil {
		t.Fatal(err)
	}
	if len(e.retirer.calls) != 1 || e.retirer.calls[0].image != ProfileImageAvatar {
		t.Fatalf("calls = %+v, want exactly one avatar hand-over", e.retirer.calls)
	}
}

// TestUpdateProfile_WithoutARetirerNothingHappens: apiserver always wires one, but the service must not depend on it
// (the pre-A4 behaviour is the default).
func TestUpdateProfile_WithoutARetirerNothingHappens(t *testing.T) {
	e := newRetireEnv(t, false)
	e.seedImages(t)
	e.setAvatar(avB)
	if _, err := e.update(context.Background(), UpdateProfileParams{AvatarMediaID: strp(avB)}); err != nil {
		t.Fatal(err)
	}
	if len(e.retirer.calls) != 0 {
		t.Errorf("an unwired retirer was called: %+v", e.retirer.calls)
	}
	var none MediaRetirer
	if opt := WithMediaRetirer(none, nil); opt == nil {
		t.Error("WithMediaRetirer(nil) must still be a valid Option")
	}
	s := New(newFakeRepo(), NewCache(time.Minute), time.Hour, WithMediaRetirer(none, nil)).(*service)
	if s.retire != nil {
		t.Error("a nil retirer must leave the step unwired")
	}
}

// TestRetiredImages is the pure comparison behind the hand-over.
func TestRetiredImages(t *testing.T) {
	t.Parallel()
	mk := func(av, avT string) Profile {
		return Profile{AvatarURL: av, AvatarThumbURL: avT}
	}
	tests := []struct {
		name          string
		before, after Profile
		want          []retiredImage
	}{
		{"nothing set", mk("", ""), mk("", ""), nil},
		{"unchanged", mk("a", "at"), mk("a", "at"), nil},
		{"first set", mk("", ""), mk("a", "at"), nil},
		{"avatar replaced", mk("a", "at"), mk("a2", "at2"), []retiredImage{{ProfileImageAvatar, "a", "at"}}},
		{"avatar removed", mk("a", "at"), mk("", ""), []retiredImage{{ProfileImageAvatar, "a", "at"}}},
		{"only the thumbnail differs", mk("a", "at"), mk("a", "at2"), []retiredImage{{ProfileImageAvatar, "a", "at"}}},
		{"an old image with only a thumbnail", mk("", "at"), mk("", ""), []retiredImage{{ProfileImageAvatar, "", "at"}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := retiredImages(tt.before, tt.after)
			if len(got) != len(tt.want) {
				t.Fatalf("got %+v, want %+v", got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("got[%d] = %+v, want %+v", i, got[i], tt.want[i])
				}
			}
		})
	}
}
