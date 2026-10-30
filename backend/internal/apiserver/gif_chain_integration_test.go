//go:build integration

package apiserver

// W6-9 (ADR-0029 D10) over the real Build chain: a READY GIF media document (seeded the way FinalizeUpload leaves it; a
// signed PUT cannot be minted against the emulators) flows through CreatePost behind FEATURE_GIF, the wire carries
// MediaRef.content_type, the Firestore cost is the same as for a photo, and DeletePost + post_delete remove the document.

import (
	"context"
	"fmt"
	mrand "math/rand"
	"net/http"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func (e *lifecycleEnv) seedGIF(t *testing.T, uid string) string {
	t.Helper()
	id := fmt.Sprintf("%019d", 4_000_000_000_000_000_000+mrand.Int63n(1_000_000_000))
	d := media.Doc{
		OwnerID: uid, Purpose: string(media.PurposePost), Status: string(media.StatusReady),
		ContentType: media.ContentTypeGIF, ThumbContentType: media.ContentTypeJPEG,
		Bytes: 1_500_000, ThumbBytes: 20_000, Width: 480, Height: 270, Blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
		NameSuffix: strings.Repeat("ab", 16), CreatedAt: time.Now().UTC(),
	}
	d.PublicPath, d.ThumbPath = "m/"+id+"-"+d.NameSuffix+".gif", "m/"+id+"-"+d.NameSuffix+"_t.jpg"
	if _, err := e.fs.Collection("media").Doc(id).Set(context.Background(), d); err != nil {
		t.Fatalf("seed gif: %v", err)
	}
	return id
}

func TestGIFChain_CreatePostGateWireAndDelete(t *testing.T) {
	ctx := context.Background()
	off := newLifecycleEnvCfg(t, nil, mediaOn)
	a := off.newUser(t)
	g := off.seedGIF(t, a.uid)
	_, err := off.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "gif-off-key-000000001", Text: "x", MediaIds: []string{g}}))
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if d.GetMetadata()["feature"] != "gif" {
		t.Fatalf("metadata = %v, want feature=gif", d.GetMetadata())
	}
	if c := off.costOf(t, "/dzeroth.posts.v1.PostService/CreatePost"); c[1] != 0 {
		t.Errorf("a refused GIF post wrote %v documents, want 0", c[1])
	}

	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		mediaOn(c)
		c.FeatureGif = flags.Spec{Name: "gif", Mode: flags.On}
	})
	b := e.newUser(t)
	g = e.seedGIF(t, b.uid)
	resp, err := e.posts.CreatePost(ctx, authed(b.token, &postsv1.CreatePostRequest{IdempotencyKey: "gif-on-key-0000000001", Text: "a gif", MediaIds: []string{g}}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	post := resp.Msg.GetPost().GetPost()
	m := post.GetMedia()[0]
	if m.GetContentType() != "image/gif" || !strings.HasSuffix(m.GetUrl(), ".gif") || !strings.HasSuffix(m.GetThumbUrl(), "_t.jpg") {
		t.Fatalf("wire media = %v", m)
	}
	// Same cost as a photo post with one image (media_chain_integration_test.go): reads <= 5, writes 5.
	if c := e.costOf(t, "/dzeroth.posts.v1.PostService/CreatePost"); c[0] > 5 || c[1] != 5 {
		t.Errorf("CreatePost with a GIF = %v, want reads <= 5 and writes 5", c)
	}

	e.pull(t)
	if _, err := e.posts.DeletePost(ctx, authed(b.token, &postsv1.DeletePostRequest{IdempotencyKey: "gif-del-key-0000000001", PostId: post.GetPostId()})); err != nil {
		t.Fatalf("DeletePost: %v", err)
	}
	jobs := e.pull(t)
	if len(jobs) != 1 || jobs[0]["kind"] != "post_delete" {
		t.Fatalf("job messages = %v", jobs)
	}
	if code := e.deliver(t, jobs[0]); code != http.StatusNoContent {
		t.Fatalf("post_delete delivery = %d", code)
	}
	if fsDocExists(t, e.fs, "media/"+g) {
		t.Fatal("post_delete did not remove the GIF's media document")
	}
}
