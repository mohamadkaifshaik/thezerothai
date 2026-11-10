//go:build integration

package apiserver

// The media orphan sweep over the real Build chain: it runs as the last step of /internal/cron/daily-maintenance, sees
// the real holders (a PENDING scheduled post, an unpublished article draft, the profile's avatar), and every attach path
// (CreatePost, the scheduled publish sweep) removes orphanCheckAt. The emulator project is shared with other tests, so
// every assertion is per document, never a count of the run.

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// seedDueMedia is seedMedia with orphanCheckAt a minute in the past: an orphan-sweep candidate now.
func (e *lifecycleEnv) seedDueMedia(t *testing.T, uid string, purpose media.Purpose) string {
	t.Helper()
	id := e.seedMedia(t, uid, purpose)
	if _, err := e.fs.Collection("media").Doc(id).Update(context.Background(), []firestore.Update{
		{Path: "orphanCheckAt", Value: time.Now().Add(-time.Minute).UTC()},
	}); err != nil {
		t.Fatal(err)
	}
	return id
}

func (e *lifecycleEnv) mediaDoc(t *testing.T, id string) *media.Doc {
	t.Helper()
	snap, err := e.fs.Collection("media").Doc(id).Get(context.Background())
	switch {
	case status.Code(err) == codes.NotFound:
		return nil
	case err != nil:
		t.Fatal(err)
	}
	var d media.Doc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	return &d
}

func (e *lifecycleEnv) runDailyMaintenance(t *testing.T) {
	t.Helper()
	if got := postRoute(t, e.url+"/internal/cron/daily-maintenance", http.MethodPost); got != http.StatusNoContent {
		t.Fatalf("daily-maintenance = %d, want 204", got)
	}
}

func TestMediaOrphanChain_DailyStepHoldersAndAttachPaths(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		mediaOn(c)
		c.FeatureScheduledPosts = flags.Spec{Name: "scheduled_posts", Mode: flags.On}
	})
	a := e.newUser(t)
	scheduled := e.seedDueMedia(t, a.uid, media.PurposePost)
	cover := e.seedDueMedia(t, a.uid, media.PurposePost)
	free := e.seedDueMedia(t, a.uid, media.PurposePost)
	posted := e.seedDueMedia(t, a.uid, media.PurposePost)
	shownAvatar := e.seedDueMedia(t, a.uid, media.PurposeAvatar)
	unshownAvatar := e.seedDueMedia(t, a.uid, media.PurposeAvatar)

	// CreatePost attaches `posted`: the same transaction removes orphanCheckAt.
	if _, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("orphan-post"), Text: "x", MediaIds: []string{posted}})); err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	if d := e.mediaDoc(t, posted); d.PostID == "" || d.OrphanCheckAt != nil {
		t.Fatalf("posted image = postId %q orphanCheckAt %v, want attached and no check", d.PostID, d.OrphanCheckAt)
	}
	// A PENDING scheduled post holds `scheduled` (validated, not attached).
	sresp, err := e.posts.SchedulePost(ctx, authed(a.token, &postsv1.SchedulePostRequest{
		IdempotencyKey: contractKey("orphan-sched"), Text: "later", MediaIds: []string{scheduled}, PublishAt: timestamppb.New(time.Now().Add(10 * time.Minute)),
	}))
	if err != nil {
		t.Fatalf("SchedulePost: %v", err)
	}
	// An unpublished article draft names `cover`.
	articleID := fmt.Sprintf("orphan-article-%d", rand.Int63())
	if _, err := e.fs.Collection("articles").Doc(articleID).Set(ctx, map[string]any{
		"authorId": a.uid, "published": false, "coverMediaId": cover, "revision": int64(1), "title": "T", "body": "[]",
	}); err != nil {
		t.Fatal(err)
	}
	// The profile shows `shownAvatar`.
	if _, err := e.identity.UpdateProfile(ctx, authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: contractKey("orphan-avatar"), AvatarMediaId: &shownAvatar})); err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}

	start := time.Now()
	e.runDailyMaintenance(t)
	if lines := e.logs.messageLines("media_orphan_sweep"); len(lines) == 0 || lines[len(lines)-1]["outcome"] != "ok" {
		t.Fatalf("media_orphan_sweep lines = %v, want an ok line", lines)
	}
	later := func(d *media.Doc) bool {
		return d.OrphanCheckAt != nil && d.OrphanCheckAt.After(start.Add(media.OrphanAfter-time.Hour))
	}
	for name, id := range map[string]string{"scheduled": scheduled, "article cover": cover} {
		if d := e.mediaDoc(t, id); d == nil || d.OrphanedAt != nil || !later(d) {
			t.Errorf("%s image = %+v, want held: unmarked and checked again in N", name, d)
		}
	}
	if d := e.mediaDoc(t, unshownAvatar); d == nil || d.OrphanedAt != nil || d.OrphanCheckAt != nil {
		t.Errorf("unshown avatar = %+v, want kept (PROFILE_MEDIA_RETIRE off): out of the queue, not deleted", d)
	}
	if d := e.mediaDoc(t, shownAvatar); d == nil || d.OrphanedAt != nil || d.OrphanCheckAt != nil {
		t.Errorf("shown avatar = %+v, want attached: no sweep fields", d)
	}
	d := e.mediaDoc(t, free)
	if d == nil || d.OrphanedAt == nil {
		t.Fatalf("free image = %+v, want marked", d)
	}

	// Phase 2, a day later: backdate the mark past the grace, run again: the free image is gone, the others are not.
	past := time.Now().Add(-media.OrphanGrace - time.Minute).UTC()
	if _, err := e.fs.Collection("media").Doc(free).Update(ctx, []firestore.Update{{Path: "orphanedAt", Value: past}, {Path: "orphanCheckAt", Value: past}}); err != nil {
		t.Fatal(err)
	}
	e.runDailyMaintenance(t)
	if e.mediaDoc(t, free) != nil {
		t.Fatal("the free image survived phase 2")
	}
	for _, id := range []string{scheduled, cover, shownAvatar, unshownAvatar, posted} {
		if e.mediaDoc(t, id) == nil {
			t.Errorf("media/%s was deleted", id)
		}
	}

	// The scheduled publish attaches `scheduled` and removes orphanCheckAt.
	sid := sresp.Msg.GetScheduledPost().GetScheduledId()
	if _, err := e.fs.Collection("users").Doc(a.uid).Collection("scheduled").Doc(sid).Update(ctx, []firestore.Update{
		{Path: "publishAt", Value: time.Now().Add(-10 * time.Minute).UTC()},
	}); err != nil {
		t.Fatal(err)
	}
	if got := postRoute(t, e.url+"/internal/cron/publish-scheduled", http.MethodPost); got != http.StatusNoContent {
		t.Fatalf("publish-scheduled = %d", got)
	}
	if d := e.mediaDoc(t, scheduled); d == nil || d.PostID == "" || d.OrphanCheckAt != nil {
		t.Fatalf("scheduled image after publish = %+v, want attached and no check", d)
	}
}
