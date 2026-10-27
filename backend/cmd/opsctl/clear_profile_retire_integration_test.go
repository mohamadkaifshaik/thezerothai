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

// ADR-0024 Amendment 1 A4 through `opsctl clear-profile-fields` on the emulators: the same retire step the Pub/Sub
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
		bannerID = "0000000000000000222"
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
	seedDoc(bannerID, media.PurposeBanner)
	seedDoc(keepID, media.PurposeBanner) // an image the profile never pointed at: untouched

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

	// Mode banner: the banner is retired, the avatar is not.
	code, stdout, stderr = run(config.ProfileMediaRetireBanner, nil, args("banner,avatar")...)
	if code != 0 {
		t.Fatalf("banner mode: code=%d stderr=%q", code, stderr)
	}
	t.Logf("banner mode output:\n%s", stdout)
	for _, want := range []string{
		"banner retire: done.",
		"avatar retire: not run (PROFILE_MEDIA_RETIRE=banner in this shell does not cover it)",
		"banner object (public until the lifecycle rule deletes it): m/" + bannerID + ".webp in bucket " + project + "-media",
		"avatar object (still public until deleted): m/" + avatarID + ".webp in bucket " + project + "-media",
		// The clear (1 read, 1 write) plus one retire (users read, media doc read, 1 write).
		"cost: reads=3 writes=2",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q", want)
		}
	}
	if _, ok := retiredAt(bannerID); !ok {
		t.Error("the cleared banner's document was not retired")
	}
	if _, ok := retiredAt(avatarID); ok {
		t.Error("mode banner retired an avatar")
	}
	if got := strings.Join(tags.calls, ","); got != "m/"+bannerID+".webp,m/"+bannerID+"_t.webp" {
		t.Errorf("tagged objects = %q, want the banner's two objects only", got)
	}

	// The avatar was cleared above without a retire; the profile now holds nothing, so the operator can still retire it
	// by hand through a message, and a rerun of the command clears nothing and retires nothing (0 writes).
	code, stdout, stderr = run(config.ProfileMediaRetireAll, nil, args("banner,avatar")...)
	if code != 0 || !strings.Contains(stdout, "nothing to clear: 0 writes") || !strings.Contains(stdout, "cost: reads=1 writes=0") {
		t.Fatalf("rerun: code=%d stdout=\n%s\nstderr=%q", code, stdout, stderr)
	}
	if len(tags.calls) != 2 {
		t.Errorf("a rerun tagged objects: %v", tags.calls)
	}

	// Mode all on a profile that holds images again: both are retired in process; a second delivery would be a duplicate.
	if _, err := client.Collection("users").Doc(uid).Update(ctx, []firestore.Update{
		{Path: "avatarUrl", Value: base + avatarID + ".webp"}, {Path: "avatarThumbUrl", Value: base + avatarID + "_t.webp"},
	}); err != nil {
		t.Fatal(err)
	}
	code, stdout, stderr = run(config.ProfileMediaRetireAll, nil, args("avatar")...)
	if code != 0 || !strings.Contains(stdout, "avatar retire: done.") || !strings.Contains(stdout, "cost: reads=3 writes=2") {
		t.Fatalf("mode all: code=%d stdout=\n%s\nstderr=%q", code, stdout, stderr)
	}
	if _, ok := retiredAt(avatarID); !ok {
		t.Error("the avatar was not retired in mode all")
	}
	if _, ok := retiredAt(keepID); ok {
		t.Error("an image the profile never pointed at was retired")
	}
	if len(tags.calls) != 4 {
		t.Errorf("tagged objects = %v, want 4 in total", tags.calls)
	}

	// An invalid switch is refused before anything is written, and says which variable.
	if _, err := client.Collection("users").Doc(uid).Update(ctx, []firestore.Update{{Path: "bannerUrl", Value: base + keepID + ".webp"}, {Path: "bannerThumbUrl", Value: base + keepID + "_t.webp"}}); err != nil {
		t.Fatal(err)
	}
	code, _, stderr = run("", fmt.Errorf("config: invalid PROFILE_MEDIA_RETIRE %q (want off|banner|all)", "avatar"), args("banner")...)
	if code != 2 || !strings.Contains(stderr, "PROFILE_MEDIA_RETIRE") {
		t.Fatalf("invalid switch: code=%d stderr=%q", code, stderr)
	}
	s, _ := client.Collection("users").Doc(uid).Get(ctx)
	if s.Data()["bannerUrl"] != base+keepID+".webp" {
		t.Error("an invalid switch did not stop the clear")
	}
}
