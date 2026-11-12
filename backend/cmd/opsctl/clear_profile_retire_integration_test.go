//go:build integration

package main

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// Through `opsctl clear-profile-fields` on the emulators: the same retire step the Pub/Sub
// handler runs, called in process after the clear committed, over the real identity, media and moderation repos.

type tagLog struct {
	mu    sync.Mutex
	calls []string
}

func (l *tagLog) SetPublicCustomTime(_ context.Context, object string, _ time.Time) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls = append(l.calls, object)
	return nil
}

func TestClearProfileFields_Integration_RetiresClearedImages(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	const uid = "uid-retire"
	const (
		avatarID = "0000000000000000111"
		bannerID = "0000000000000000222" // a legacy banner (the removed feature): never cleared or retired here
		keepID   = "0000000000000000333"
	)
	base := "https://storage.googleapis.com/" + project + "-media/m/"
	if _, err := client.Collection("users").Doc(uid).Set(ctx, map[string]any{
		"handle": "retire", "handleLower": "retire", "displayName": "R", "status": "ACTIVE",
		"avatarUrl": base + avatarID + ".webp", "avatarThumbUrl": base + avatarID + "_t.webp",
		"bannerUrl": base + bannerID + ".webp", "bannerThumbUrl": base + bannerID + "_t.webp",
		"createdAt": time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), "updatedAt": time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC),
	}); err != nil {
		t.Fatal(err)
	}
	seedDoc := func(id string, purpose media.Purpose) {
		t.Helper()
		d := media.Doc{
			OwnerID: uid, Purpose: string(purpose), Status: string(media.StatusReady), ContentType: "image/webp",
			PublicPath: "m/" + id + ".webp", ThumbPath: "m/" + id + "_t.webp", CreatedAt: time.Now().UTC(),
		}
		if _, err := client.Collection("media").Doc(id).Set(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	seedDoc(avatarID, media.PurposeAvatar)
	seedDoc(bannerID, media.Purpose("BANNER"))
	seedDoc(keepID, media.PurposeAvatar) // an image the profile never pointed at: untouched

	tags := &tagLog{}
	identityRepo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	run := func(mode config.ProfileMediaRetire, modeErr error, args ...string) (int, string, string) {
		t.Helper()
		open := func(context.Context, string) (*backends, error) {
			b := &backends{
				reports:    moderation.NewFirestoreRepo(client, quota.New(client)),
				profiles:   identityRepo,
				retireMode: mode,
				retireErr:  modeErr,
				close:      func() {},
			}
			if modeErr == nil {
				b.retire = media.NewJobs(media.NewFirestoreRepo(client, media.WriteDeps{}), nil, nil, nil).
					WithProfileRetire(media.RetireDeps{Mode: mode, Users: identityRepo, Tagger: tags})
			}
			return b, nil
		}
		var out, errOut bytes.Buffer
		code := run(ctx, args, strings.NewReader(""), &out, &errOut, open, time.Now)
		return code, out.String(), errOut.String()
	}
	retiredAt := func(id string) (time.Time, bool) {
		t.Helper()
		s, err := client.Collection("media").Doc(id).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		r, ok := s.Data()["retiredAt"].(time.Time)
		return r, ok
	}
	args := func(fields string, extra ...string) []string {
		return append([]string{"clear-profile-fields", "--project", project, "--uid", uid, "--fields", fields}, extra...)
	}

	// Mode off (an operator shell with the variable unset): the clear applies, nothing is retired, the objects are printed.
	code, stdout, stderr := run(config.ProfileMediaRetireOff, nil, args("avatar", "--dry-run")...)
	if code != 0 || !strings.Contains(stdout, "avatar retire: would not run (PROFILE_MEDIA_RETIRE=off does not cover it)") {
		t.Fatalf("off dry run: code=%d stdout=\n%s\nstderr=%q", code, stdout, stderr)
	}

	// Mode off for real: the avatar is cleared, nothing is retired, the objects are printed for deleting by hand.
	code, stdout, stderr = run(config.ProfileMediaRetireOff, nil, args("avatar")...)
	if code != 0 {
		t.Fatalf("off: code=%d stderr=%q", code, stderr)
	}
	t.Logf("off output:\n%s", stdout)
	for _, want := range []string{
		"avatar retire: not run (PROFILE_MEDIA_RETIRE=off in this shell does not cover it)",
		"avatar object (still public until deleted): m/" + avatarID + ".webp in bucket " + project + "-media",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q", want)
		}
	}
	if _, ok := retiredAt(avatarID); ok {
		t.Error("mode off retired the avatar")
	}
	if len(tags.calls) != 0 {
		t.Errorf("mode off tagged objects: %v", tags.calls)
	}

	// The profile now holds no avatar, so a rerun clears nothing and retires nothing (0 writes).
	code, stdout, stderr = run(config.ProfileMediaRetireAll, nil, args("avatar")...)
	if code != 0 || !strings.Contains(stdout, "nothing to clear: 0 writes") {
		t.Fatalf("rerun: code=%d stdout=\n%s\nstderr=%q", code, stdout, stderr)
	}
	if len(tags.calls) != 0 {
		t.Errorf("a rerun tagged objects: %v", tags.calls)
	}

	// Mode all on a profile that holds the avatar again: it is retired in process; a second delivery would be a duplicate.
	if _, err := client.Collection("users").Doc(uid).Update(ctx, []firestore.Update{
		{Path: "avatarUrl", Value: base + avatarID + ".webp"}, {Path: "avatarThumbUrl", Value: base + avatarID + "_t.webp"},
	}); err != nil {
		t.Fatal(err)
	}
	code, stdout, stderr = run(config.ProfileMediaRetireAll, nil, args("avatar")...)
	if code != 0 || !strings.Contains(stdout, "avatar retire: done.") {
		t.Fatalf("mode all: code=%d stdout=\n%s\nstderr=%q", code, stdout, stderr)
	}
	if _, ok := retiredAt(avatarID); !ok {
		t.Error("the avatar was not retired in mode all")
	}
	if _, ok := retiredAt(keepID); ok {
		t.Error("an image the profile never pointed at was retired")
	}
	if _, ok := retiredAt(bannerID); ok {
		t.Error("the legacy banner was retired")
	}
	if got := strings.Join(tags.calls, ","); got != "m/"+avatarID+".webp,m/"+avatarID+"_t.webp" {
		t.Errorf("tagged objects = %q, want the avatar's two objects only", got)
	}
	if s, _ := client.Collection("users").Doc(uid).Get(ctx); s.Data()["bannerUrl"] != base+bannerID+".webp" {
		t.Error("clear-profile-fields touched the legacy banner fields (purge-banners owns them)")
	}

	// An invalid switch is refused before anything is written, and says which variable.
	if _, err := client.Collection("users").Doc(uid).Update(ctx, []firestore.Update{{Path: "avatarUrl", Value: base + keepID + ".webp"}, {Path: "avatarThumbUrl", Value: base + keepID + "_t.webp"}}); err != nil {
		t.Fatal(err)
	}
	code, _, stderr = run("", fmt.Errorf("config: invalid PROFILE_MEDIA_RETIRE %q (want off|all)", "bogus"), args("avatar")...)
	if code != 2 || !strings.Contains(stderr, "PROFILE_MEDIA_RETIRE") {
		t.Fatalf("invalid switch: code=%d stderr=%q", code, stderr)
	}
	s, _ := client.Collection("users").Doc(uid).Get(ctx)
	if s.Data()["avatarUrl"] != base+keepID+".webp" {
		t.Error("an invalid switch did not stop the clear")
	}
}
