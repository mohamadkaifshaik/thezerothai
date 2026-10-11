//go:build integration

package apiserver

// P4 over the real Build chain (Firestore, Auth, Pub/Sub emulators): CreatePost with media_ids, UpdateProfile with an
// avatar, DeletePost -> post_delete job -> cleanup, the FEATURE_MEDIA flag and DEGRADED_MODE=nomedia.
//
// A signed PUT URL cannot be minted against the emulators (no signing credentials), so the finished media
// documents are seeded straight into Firestore the way FinalizeUpload leaves them; the signing path is covered by
// the objstore unit test and the dev-project smoke (plan T-P4-8). The upload -> finalize logic itself is covered
// by the media package's own integration tests with the real repo.

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	mediav1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func mediaOn(c *config.Config) {
	c.FeatureMedia = flags.Spec{Name: "media", Mode: flags.On}
}

// seedMedia writes a READY media document owned by uid, like FinalizeUpload leaves it.
func (e *lifecycleEnv) seedMedia(t *testing.T, uid string, purpose media.Purpose) string {
	t.Helper()
	id := fmt.Sprintf("%019d", 4_000_000_000_000_000_000+rand.Int63n(1_000_000_000))
	d := media.Doc{
		OwnerID: uid, Purpose: string(purpose), Status: string(media.StatusReady), ContentType: "image/jpeg",
		Bytes: 1000, ThumbBytes: 100, Width: 1200, Height: 800, Blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
		PublicPath: "m/" + id + ".jpg", ThumbPath: "m/" + id + "_t.jpg", CreatedAt: time.Now().UTC(),
	}
	if _, err := e.fs.Collection("media").Doc(id).Set(context.Background(), d); err != nil {
		t.Fatalf("seed media: %v", err)
	}
	return id
}

func TestMediaChain_PostWithImagesAndDeleteJob(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, mediaOn)
	a, b := e.newUser(t), e.newUser(t)
	m1, m2 := e.seedMedia(t, a.uid, media.PurposePost), e.seedMedia(t, a.uid, media.PurposePost)
	theirs := e.seedMedia(t, b.uid, media.PurposePost)
	avatar := e.seedMedia(t, a.uid, media.PurposeAvatar)

	// Another user's image, an avatar used as a post image, an unknown id: one answer.
	for name, ids := range map[string][]string{"someone else's": {theirs}, "an avatar": {avatar}, "unknown": {"0000000000000000042"}} {
		_, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "media-bad-" + fmt.Sprint(rand.Int63()), Text: "x", MediaIds: ids}))
		d := wireError(t, err, connect.CodeFailedPrecondition)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
			t.Errorf("%s: reason = %v, want MEDIA_NOT_READY", name, d.GetReason())
		}
	}

	resp, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{
		IdempotencyKey: "media-post-key-000001", Text: "two pictures", MediaIds: []string{m1, m2}, MediaAltTexts: []string{"a harbour", ""},
	}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	post := resp.Msg.GetPost().GetPost()
	if len(post.GetMedia()) != 2 || post.GetMedia()[0].GetMediaId() != m1 || post.GetMedia()[1].GetMediaId() != m2 {
		t.Fatalf("media = %v", post.GetMedia())
	}
	for _, m := range post.GetMedia() {
		if m.GetThumbUrl() == "" || m.GetUrl() == "" || m.GetBlurhash() == "" || m.GetWidth() != 1200 {
			t.Fatalf("ref = %v: a list view needs the thumbnail, size and blurhash", m)
		}
	}
	if post.GetMedia()[0].GetAltText() != "a harbour" {
		t.Errorf("alt text = %q", post.GetMedia()[0].GetAltText())
	}
	// The documented worst case (cold interceptor 1 + idempotency 1 + quotas 1 + n media; 4 writes + n updates).
	lines := e.requestLinesFor("/dzeroth.posts.v1.PostService/CreatePost")
	last := lines[len(lines)-1]
	if last["fs_reads"].(float64) > 3+2 || last["fs_writes"].(float64) != 4+2 {
		t.Errorf("CreatePost with 2 images: reads=%v writes=%v, want reads <= 5, writes 6", last["fs_reads"], last["fs_writes"])
	}

	// The post is readable with its images, and the images are attached (a second post cannot reuse them).
	got, err := e.posts.GetPost(ctx, authed(b.token, &postsv1.GetPostRequest{PostId: post.GetPostId()}))
	if err != nil || len(got.Msg.GetPost().GetPost().GetMedia()) != 2 {
		t.Fatalf("GetPost = %v, %v", got, err)
	}
	_, err = e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "media-post-key-000002", Text: "again", MediaIds: []string{m1}}))
	if d := wireError(t, err, connect.CodeFailedPrecondition); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
		t.Fatalf("reuse reason = %v", d.GetReason())
	}
	// A replay of the first request returns the same post and writes nothing.
	replay, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{
		IdempotencyKey: "media-post-key-000001", Text: "two pictures", MediaIds: []string{m1, m2}, MediaAltTexts: []string{"a harbour", ""},
	}))
	if err != nil || replay.Msg.GetPost().GetPost().GetPostId() != post.GetPostId() {
		t.Fatalf("replay = %v, %v", replay, err)
	}
	// An image-only post is valid.
	m3 := e.seedMedia(t, a.uid, media.PurposePost)
	only, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "media-post-key-000003", MediaIds: []string{m3}}))
	if err != nil || only.Msg.GetPost().GetPost().GetText() != "" || len(only.Msg.GetPost().GetPost().GetMedia()) != 1 {
		t.Fatalf("image-only post = %v, %v", only, err)
	}
	// But no text and no image is not.
	_, err = e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "media-post-key-000004", Text: " "}))
	wireError(t, err, connect.CodeInvalidArgument)

	// --- DeletePost publishes exactly one post_delete job; delivering it removes the media documents ---
	e.pull(t) // drain
	if _, err := e.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: "media-del-key-0000001", PostId: post.GetPostId()})); err != nil {
		t.Fatalf("DeletePost: %v", err)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "post_delete" || msgs[0]["postId"] != post.GetPostId() || msgs[0]["uid"] != a.uid {
		t.Fatalf("job messages = %v", msgs)
	}
	if !fsDocExists(t, e.fs, "media/"+m1) || !fsDocExists(t, e.fs, "media/"+m2) {
		t.Fatal("media documents must outlive the delete until the job runs")
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery = %d", code)
	}
	if fsDocExists(t, e.fs, "media/"+m1) || fsDocExists(t, e.fs, "media/"+m2) {
		t.Fatal("post_delete did not remove the media documents")
	}
	if !fsDocExists(t, e.fs, "media/"+m3) || !fsDocExists(t, e.fs, "media/"+theirs) {
		t.Fatal("post_delete removed an image of another post or another user")
	}
	// At-least-once: the redelivery is a harmless duplicate.
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("redelivery = %d", code)
	}

	// --- a forged message for a LIVE post is refused: the job never acts on the message's word alone ---
	if code := e.deliverJSON(t, map[string]any{"kind": "post_delete", "uid": a.uid, "postId": only.Msg.GetPost().GetPost().GetPostId(), "mediaIds": []string{m3}}); code != http.StatusNoContent {
		t.Fatalf("forged delivery = %d (an ack: the message is dropped, not retried forever)", code)
	}
	if !fsDocExists(t, e.fs, "media/"+m3) {
		t.Fatal("a forged post_delete removed the image of a live post")
	}
}

func TestMediaChain_Avatar(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, mediaOn)
	a, b := e.newUser(t), e.newUser(t)
	avatar := e.seedMedia(t, a.uid, media.PurposeAvatar)
	postImage := e.seedMedia(t, a.uid, media.PurposePost)
	theirs := e.seedMedia(t, b.uid, media.PurposeAvatar)

	for name, id := range map[string]string{"another user's avatar": theirs, "a post image": postImage, "unknown": "0000000000000000042", "malformed": "not-an-id"} {
		_, err := e.identity.UpdateProfile(ctx, authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "avatar-bad-" + fmt.Sprint(rand.Int63()), AvatarMediaId: &id}))
		d := wireError(t, err, connect.CodeFailedPrecondition)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
			t.Errorf("%s: reason = %v", name, d.GetReason())
		}
	}
	resp, err := e.identity.UpdateProfile(ctx, authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "avatar-ok-key-000001", AvatarMediaId: &avatar}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	p := resp.Msg.GetProfile()
	if p.GetAvatarUrl() == "" || p.GetAvatarThumbUrl() == "" || p.GetAvatarUrl() == p.GetAvatarThumbUrl() {
		t.Fatalf("profile avatar = %q / %q", p.GetAvatarUrl(), p.GetAvatarThumbUrl())
	}
	lines := e.requestLinesFor("/dzeroth.identity.v1.IdentityService/UpdateProfile")
	if last := lines[len(lines)-1]; last["fs_reads"].(float64) > 3 || last["fs_writes"].(float64) != 1 {
		t.Errorf("UpdateProfile with avatar: reads=%v writes=%v, want reads <= 3 (interceptor, media, profile), writes 1", last["fs_reads"], last["fs_writes"])
	}
	// Removing it still works.
	empty := ""
	resp, err = e.identity.UpdateProfile(ctx, authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "avatar-rm-key-000001", AvatarMediaId: &empty}))
	if err != nil || resp.Msg.GetProfile().GetAvatarUrl() != "" {
		t.Fatalf("remove = %v, %v", resp, err)
	}
}

func TestMediaChain_FlagOffAndNoMedia(t *testing.T) {
	ctx := context.Background()

	t.Run("flag off", func(t *testing.T) {
		e := newLifecycleEnvCfg(t, nil, nil) // FEATURE_MEDIA defaults to off
		a := e.newUser(t)
		id := e.seedMedia(t, a.uid, media.PurposePost)
		mc := mediav1connect.NewMediaServiceClient(http.DefaultClient, e.url)

		_, err := mc.CreateUpload(ctx, authed(a.token, &mediav1.CreateUploadRequest{IdempotencyKey: "flag-off-key-0000001"}))
		if d := wireError(t, err, connect.CodeFailedPrecondition); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
			t.Fatalf("CreateUpload reason = %v", d.GetReason())
		}
		_, err = e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "flag-off-key-0000002", Text: "x", MediaIds: []string{id}}))
		d := wireError(t, err, connect.CodeFailedPrecondition)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || d.GetMetadata()["feature"] != "media" {
			t.Fatalf("CreatePost reason = %v meta=%v", d.GetReason(), d.GetMetadata())
		}
		avatar := e.seedMedia(t, a.uid, media.PurposeAvatar)
		_, err = e.identity.UpdateProfile(ctx, authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "flag-off-key-0000003", AvatarMediaId: &avatar}))
		if d := wireError(t, err, connect.CodeFailedPrecondition); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
			t.Fatalf("UpdateProfile reason = %v", d.GetReason())
		}
		// A text post is unaffected.
		if _, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "flag-off-key-0000004", Text: "plain"})); err != nil {
			t.Fatalf("text post: %v", err)
		}
	})

	t.Run("DEGRADED_MODE=nomedia blocks uploads", func(t *testing.T) {
		e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
			mediaOn(c)
			c.Degraded = config.DegradedNoMedia
		})
		a := e.newUser(t)
		mc := mediav1connect.NewMediaServiceClient(http.DefaultClient, e.url)
		for name, call := range map[string]func() error{
			"CreateUpload": func() error {
				_, err := mc.CreateUpload(ctx, authed(a.token, &mediav1.CreateUploadRequest{IdempotencyKey: "nomedia-key-00000001"}))
				return err
			},
			"FinalizeUpload": func() error {
				_, err := mc.FinalizeUpload(ctx, authed(a.token, &mediav1.FinalizeUploadRequest{IdempotencyKey: "nomedia-key-00000002"}))
				return err
			},
		} {
			d := wireError(t, call(), connect.CodeUnavailable)
			if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE {
				t.Errorf("%s reason = %v", name, d.GetReason())
			}
		}
		// Text posts keep working: nomedia only stops new media (and its Vision and storage cost).
		if _, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "nomedia-key-00000003", Text: "still fine"})); err != nil {
			t.Fatalf("text post under nomedia: %v", err)
		}
	})
}
