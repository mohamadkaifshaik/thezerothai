//go:build integration

package apiserver

// W6-18 (ADR-0029 D10, D11) over the real Build chain with the real Storage emulator: FinalizeUpload of a GIF (read, pre-scan,
// sampled sheet, publish, delete), then CreatePost, the wire shape, the cost against a photo's, SchedulePost's refusal and
// DeletePost -> post_delete removing the public objects.
//
// A signed PUT URL cannot be minted against the emulators (no signing credentials), so the PENDING document that CreateUpload
// leaves is made by a media.Service over the SAME Firestore with a stub signer, and the client's two PUTs are written straight
// into the emulator's upload bucket. Everything after that (FinalizeUpload, CreatePost, DeletePost, the job) is the wired
// chain. Build uses media.AllowAll as the Moderator when ENV=local, so the verdict cases (explicit later frame) live in the
// media package's unit tests; here the sheet is built and "screened" by AllowAll and the Vision counter is asserted.

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/base64"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"io"
	"math/rand"
	"net/http"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/storage"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	mediav1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

type stubSigner struct{}

func (stubSigner) SignPut(_ context.Context, object, contentType, _ string, _ int64, _ time.Duration, _ time.Time) (string, map[string]string, error) {
	return "https://upload.test/" + object, map[string]string{"Content-Type": contentType}, nil
}

type randIDs struct{}

func (randIDs) Generate() string {
	return fmt.Sprintf("%019d", 4_100_000_000_000_000_000+rand.Int63n(1_000_000_000))
}

type oldAccount struct{}

func (oldAccount) AccountCreatedAt(context.Context, string) (time.Time, error) {
	return time.Now().Add(-60 * 24 * time.Hour), nil
}

func gifFixture(frames int) []byte {
	pal := color.Palette{color.White, color.RGBA{G: 200, A: 255}, color.RGBA{B: 200, A: 255}}
	g := &gif.GIF{Config: image.Config{ColorModel: pal, Width: 64, Height: 48}}
	for i := 0; i < frames; i++ {
		p := image.NewPaletted(image.Rect(0, 0, 64, 48), pal)
		for j := range p.Pix {
			p.Pix[j] = uint8(i % 3)
		}
		g.Image, g.Delay = append(g.Image, p), append(g.Delay, 10)
	}
	var b bytes.Buffer
	if err := gif.EncodeAll(&b, g); err != nil {
		panic(err)
	}
	return b.Bytes()
}

func jpegFixture(seed int) []byte {
	img := image.NewRGBA(image.Rect(0, 0, 32, 24))
	for i := range img.Pix {
		img.Pix[i] = byte(seed + i)
	}
	var b bytes.Buffer
	if err := jpeg.Encode(&b, img, nil); err != nil {
		panic(err)
	}
	return b.Bytes()
}

func md5of(b []byte) string { s := md5.Sum(b); return base64.StdEncoding.EncodeToString(s[:]) }

type gifChain struct {
	*lifecycleEnv
	sc           *storage.Client
	upBkt, pubBk string
	svc          media.Service
}

func newGifChain(t *testing.T, mutate func(*config.Config)) *gifChain {
	t.Helper()
	sfx := rand.Int63()
	up, pub := fmt.Sprintf("demo-gif-up-%d", sfx), fmt.Sprintf("demo-gif-pub-%d", sfx)
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		mediaOn(c)
		c.FeatureGif = flags.Spec{Name: "gif", Mode: flags.On}
		c.FeatureScheduledPosts = flags.Spec{Name: "scheduled_posts", Mode: flags.On}
		c.MediaUploadBucket, c.MediaBucket = up, pub
		if mutate != nil {
			mutate(c)
		}
	})
	sc, err := storage.NewClient(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sc.Close() })
	buckets, err := media.NewBuckets(up, pub)
	if err != nil {
		t.Fatal(err)
	}
	svc, err := media.New(media.Deps{
		Repo:   media.NewFirestoreRepo(e.fs, media.WriteDeps{Idempotency: idempotency.New(e.fs), Quotas: quota.New(e.fs)}),
		Signer: stubSigner{}, Objects: buckets, Moderator: media.AllowAll{}, Directory: oldAccount{}, IDs: randIDs{},
		PublicBaseURL: "https://cdn.test", MediaPerDay: 100, NewAccountMediaPerDay: 100, NewAccountWindow: time.Hour, VisionMonthlyCap: 1000,
	})
	if err != nil {
		t.Fatal(err)
	}
	return &gifChain{lifecycleEnv: e, sc: sc, upBkt: up, pubBk: pub, svc: svc}
}

func (g *gifChain) put(t *testing.T, bucket, object, ct string, data []byte) {
	t.Helper()
	w := g.sc.Bucket(bucket).Object(object).NewWriter(context.Background())
	w.ContentType = ct
	if _, err := w.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("put %s: %v", object, err)
	}
}

func (g *gifChain) exists(bucket, object string) bool {
	_, err := g.sc.Bucket(bucket).Object(object).Attrs(context.Background())
	return err == nil
}

// uploadGIF makes the PENDING document (CreateUpload) and the client's two PUTs; it returns the media id.
func (g *gifChain) uploadGIF(t *testing.T, u testUser, tag string) string {
	t.Helper()
	full, thumb := gifFixture(6), jpegFixture(1)
	tgs, err := g.svc.CreateUpload(context.Background(), u.uid, media.CreateUploadInput{
		IdempotencyKey: "gif-up-" + tag + "-0000000", Purpose: media.PurposePost,
		Items: []media.UploadItem{{ContentType: media.ContentTypeGIF, ThumbContentType: media.ContentTypeJPEG, FullBytes: int64(len(full)), ThumbBytes: int64(len(thumb)),
			Width: 64, Height: 48, FullMD5: md5of(full), ThumbMD5: md5of(thumb)}},
	})
	if err != nil {
		t.Fatalf("CreateUpload: %v", err)
	}
	id := tgs[0].MediaID
	g.put(t, g.upBkt, "u/"+u.uid+"/"+id+".gif", media.ContentTypeGIF, full)
	g.put(t, g.upBkt, "u/"+u.uid+"/"+id+"_t.jpg", media.ContentTypeJPEG, thumb)
	return id
}

func (g *gifChain) uploadPhoto(t *testing.T, u testUser, tag string) string {
	t.Helper()
	full, thumb := jpegFixture(7), jpegFixture(9)
	tgs, err := g.svc.CreateUpload(context.Background(), u.uid, media.CreateUploadInput{
		IdempotencyKey: "photo-up-" + tag + "-00000", Purpose: media.PurposePost,
		Items: []media.UploadItem{{ContentType: media.ContentTypeJPEG, FullBytes: int64(len(full)), ThumbBytes: int64(len(thumb)), Width: 32, Height: 24, FullMD5: md5of(full), ThumbMD5: md5of(thumb)}},
	})
	if err != nil {
		t.Fatalf("CreateUpload photo: %v", err)
	}
	id := tgs[0].MediaID
	g.put(t, g.upBkt, "u/"+u.uid+"/"+id+".jpg", media.ContentTypeJPEG, full)
	g.put(t, g.upBkt, "u/"+u.uid+"/"+id+"_t.jpg", media.ContentTypeJPEG, thumb)
	return id
}

func (g *gifChain) visionUnits(t *testing.T) int64 {
	t.Helper()
	snap, err := g.fs.Collection("admin").Doc("vision-" + time.Now().UTC().Format("200601")).Get(context.Background())
	if err != nil {
		return 0
	}
	v, _ := snap.DataAt("units")
	n, _ := v.(int64)
	return n
}

func TestGIFChain_FinalizePostScheduleAndDelete(t *testing.T) {
	ctx := context.Background()
	g := newGifChain(t, nil)
	a := g.newUser(t)
	mc := mediav1connect.NewMediaServiceClient(http.DefaultClient, g.url)
	finalize := func(key string, ids ...string) (*mediav1.FinalizeUploadResponse, error) {
		var items []*mediav1.FinalizeItem
		for _, id := range ids {
			items = append(items, &mediav1.FinalizeItem{MediaId: id})
		}
		resp, err := mc.FinalizeUpload(ctx, authed(a.token, &mediav1.FinalizeUploadRequest{IdempotencyKey: key, Items: items}))
		if err != nil {
			return nil, err
		}
		return resp.Msg, nil
	}

	photo := g.uploadPhoto(t, a, "p1")
	if _, err := finalize("gif-fin-photo-00000001", photo); err != nil {
		t.Fatalf("finalize photo: %v", err)
	}
	photoCost := g.costOf(t, "/dzeroth.media.v1.MediaService/FinalizeUpload")
	photoUnits := g.visionUnits(t)

	gid := g.uploadGIF(t, a, "g1")
	resp, err := finalize("gif-fin-gif-0000000001", gid)
	if err != nil {
		t.Fatalf("FinalizeUpload gif: %v", err)
	}
	res := resp.GetResults()[0]
	if res.GetStatus() != mediav1.MediaStatus_MEDIA_STATUS_READY {
		t.Fatalf("result = %v (reason %q), want READY", res.GetStatus(), res.GetRejectionReason())
	}
	ref := res.GetMedia()
	if ref.GetContentType() != "image/gif" || !strings.HasSuffix(ref.GetUrl(), ".gif") || !strings.HasSuffix(ref.GetThumbUrl(), "_t.jpg") {
		t.Fatalf("wire media = %v", ref)
	}
	// Vision: 2 units for the GIF (sheet + thumbnail); a photo is 1 (the thumbnail is not screened by default).
	if got := g.visionUnits(t) - photoUnits; got != 2 {
		t.Errorf("GIF vision units = %d, want 2 (photo spent %d)", got, photoUnits)
	}
	// Firestore cost: unchanged against a photo's finalize ("Firestore unchanged", runbook).
	if gifCost := g.costOf(t, "/dzeroth.media.v1.MediaService/FinalizeUpload"); gifCost[1] != photoCost[1] || gifCost[0] > photoCost[0] { // reads: the photo run also loaded the Vision counter into the instance cache
		t.Errorf("FinalizeUpload cost gif %v, photo %v: the GIF path must write the same documents and read no more", gifCost, photoCost)
	}
	// Storage: the private pair is gone, the public pair is there with the right types.
	for _, o := range []string{"u/" + a.uid + "/" + gid + ".gif", "u/" + a.uid + "/" + gid + "_t.jpg"} {
		if g.exists(g.upBkt, o) {
			t.Errorf("private object %s still exists", o)
		}
	}
	pubObj, pubThumb := g.docPath(t, gid, "publicPath"), g.docPath(t, gid, "thumbPath")
	if !strings.HasSuffix(ref.GetUrl(), "/"+pubObj) || !strings.HasSuffix(ref.GetThumbUrl(), "/"+pubThumb) {
		t.Fatalf("urls %s %s do not end in the stored paths %s %s", ref.GetUrl(), ref.GetThumbUrl(), pubObj, pubThumb)
	}
	for obj, wantCT := range map[string]string{pubObj: "image/gif", pubThumb: "image/jpeg"} {
		attrs, err := g.sc.Bucket(g.pubBk).Object(obj).Attrs(ctx)
		if err != nil {
			t.Errorf("public object %q: %v (urls %s %s)", obj, err, ref.GetUrl(), ref.GetThumbUrl())
			continue
		}
		if attrs.ContentType != wantCT {
			t.Errorf("public %s content type = %q, want %q", obj, attrs.ContentType, wantCT)
		}
	}
	// The published bytes are the uploaded bytes, unchanged.
	if rd, err := g.sc.Bucket(g.pubBk).Object(pubObj).NewReader(ctx); err != nil {
		t.Errorf("read public gif: %v", err)
	} else {
		b, _ := io.ReadAll(rd)
		_ = rd.Close()
		if !bytes.Equal(b, gifFixture(6)) {
			t.Errorf("published bytes differ from the uploaded GIF (%d vs %d bytes)", len(b), len(gifFixture(6)))
		}
	}

	// CreatePost: a GIF next to a photo is VALIDATION media_ids, nothing written.
	_, err = g.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "gif-mix-key-000000001", Text: "x", MediaIds: []string{gid, photo}}))
	d := wireError(t, err, connect.CodeInvalidArgument)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION || d.GetMetadata()["field"] != "media_ids" {
		t.Fatalf("gif+photo: reason %v metadata %v, want VALIDATION media_ids", d.GetReason(), d.GetMetadata())
	}
	if c := g.costOf(t, "/dzeroth.posts.v1.PostService/CreatePost"); c[1] != 0 {
		t.Errorf("refused GIF+photo wrote %v documents, want 0", c[1])
	}
	// SchedulePost with the GIF: refused the same way.
	_, err = g.posts.SchedulePost(ctx, authed(a.token, &postsv1.SchedulePostRequest{
		IdempotencyKey: "gif-sched-key-00000001", Text: "later", MediaIds: []string{gid}, PublishAt: timestamppb.New(time.Now().Add(2 * time.Hour)),
	}))
	d = wireError(t, err, connect.CodeInvalidArgument)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION || d.GetMetadata()["field"] != "media_ids" {
		t.Fatalf("schedule gif: reason %v metadata %v, want VALIDATION media_ids", d.GetReason(), d.GetMetadata())
	}

	// CreatePost with the GIF alone.
	pr, err := g.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "gif-post-key-00000001", Text: "a gif", MediaIds: []string{gid}}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	post := pr.Msg.GetPost().GetPost()
	if m := post.GetMedia(); len(m) != 1 || m[0].GetContentType() != "image/gif" || m[0].GetUrl() != ref.GetUrl() {
		t.Fatalf("post media = %v", m)
	}
	if c := g.costOf(t, "/dzeroth.posts.v1.PostService/CreatePost"); c[0] > 5 || c[1] != 5 {
		t.Errorf("CreatePost with a GIF = %v, want reads <= 5 and writes 5 (the photo budget)", c)
	}

	// DeletePost -> post_delete removes the public objects, not just the document.
	g.pull(t)
	if _, err := g.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: "gif-del-key-00000001", PostId: post.GetPostId()})); err != nil {
		t.Fatalf("DeletePost: %v", err)
	}
	jobs := g.pull(t)
	if len(jobs) != 1 || jobs[0]["kind"] != "post_delete" {
		t.Fatalf("job messages = %v", jobs)
	}
	if code := g.deliver(t, jobs[0]); code != http.StatusNoContent {
		t.Fatalf("post_delete delivery = %d", code)
	}
	for _, o := range []string{pubObj, pubThumb} {
		if g.exists(g.pubBk, o) {
			t.Errorf("public object %s survived post_delete", o)
		}
	}
	if fsDocExists(t, g.fs, "media/"+gid) {
		t.Error("the GIF's media document survived post_delete")
	}
}

// TestGIFChain_CreateUploadGatesOverTheWire: the flag, the shape rules and the nomedia mode, through Build. A valid GIF
// request would reach the V4 signer, which needs credentials the emulators do not have, so only refusals are asserted.
func TestGIFChain_CreateUploadGatesOverTheWire(t *testing.T) {
	ctx := context.Background()
	full, thumb := gifFixture(2), jpegFixture(1)
	item := func(ct, thumbCT string) *mediav1.UploadItem {
		return &mediav1.UploadItem{ContentType: ct, ThumbContentType: thumbCT, FullSizeBytes: int64(len(full)), ThumbSizeBytes: int64(len(thumb)), Width: 64, Height: 48, FullMd5: md5of(full), ThumbMd5: md5of(thumb)}
	}
	req := func(purpose mediav1.MediaPurpose, key string, items ...*mediav1.UploadItem) *mediav1.CreateUploadRequest {
		return &mediav1.CreateUploadRequest{IdempotencyKey: key, Purpose: purpose, Items: items}
	}
	post := mediav1.MediaPurpose_MEDIA_PURPOSE_POST

	t.Run("flag off: FEATURE_DISABLED with 0 reads and 0 writes", func(t *testing.T) {
		e := newLifecycleEnvCfg(t, nil, mediaOn)
		a := e.newUser(t)
		mc := mediav1connect.NewMediaServiceClient(http.DefaultClient, e.url)
		_, err := mc.CreateUpload(ctx, authed(a.token, req(post, "gif-off-up-00000001", item("image/gif", "image/jpeg"))))
		d := wireError(t, err, connect.CodeFailedPrecondition)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || d.GetMetadata()["feature"] != "gif" {
			t.Fatalf("reason %v metadata %v", d.GetReason(), d.GetMetadata())
		}
		if c := e.costOf(t, "/dzeroth.media.v1.MediaService/CreateUpload"); c[0] != 0 || c[1] != 0 {
			t.Errorf("a disabled GIF CreateUpload cost %v, want 0 reads and 0 writes", c)
		}
	})

	on := func(c *config.Config) {
		mediaOn(c)
		c.FeatureProfileExtras = flags.Spec{Name: "profile_extras", Mode: flags.On} // BANNER is gated by it
		c.FeatureGif = flags.Spec{Name: "gif", Mode: flags.On}
	}
	t.Run("flag on: shape rules", func(t *testing.T) {
		e := newLifecycleEnvCfg(t, nil, on)
		a := e.newUser(t)
		mc := mediav1connect.NewMediaServiceClient(http.DefaultClient, e.url)
		photo := item("image/jpeg", "")
		cases := map[string]*mediav1.CreateUploadRequest{
			"gif and photo":     req(post, "gif-shape-key-0000001", item("image/gif", "image/jpeg"), photo),
			"two gifs":          req(post, "gif-shape-key-0000002", item("image/gif", "image/jpeg"), item("image/gif", "image/jpeg")),
			"avatar gif":        req(mediav1.MediaPurpose_MEDIA_PURPOSE_AVATAR, "gif-shape-key-0000003", item("image/gif", "image/jpeg")),
			"banner gif":        req(mediav1.MediaPurpose_MEDIA_PURPOSE_BANNER, "gif-shape-key-0000004", item("image/gif", "image/jpeg")),
			"gif png thumbnail": req(post, "gif-shape-key-0000005", item("image/gif", "image/png")),
			"gif no thumb type": req(post, "gif-shape-key-0000006", item("image/gif", "")),
			"gif gif thumbnail": req(post, "gif-shape-key-0000007", item("image/gif", "image/gif")),
		}
		for name, r := range cases {
			t.Run(name, func(t *testing.T) {
				_, err := mc.CreateUpload(ctx, authed(a.token, r))
				d := wireError(t, err, connect.CodeInvalidArgument)
				if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION {
					t.Errorf("reason %v", d.GetReason())
				}
			})
		}
	})

	t.Run("nomedia blocks a GIF CreateUpload", func(t *testing.T) {
		e := newLifecycleEnvCfg(t, nil, func(c *config.Config) { on(c); c.Degraded = config.DegradedNoMedia })
		a := e.newUser(t)
		mc := mediav1connect.NewMediaServiceClient(http.DefaultClient, e.url)
		_, err := mc.CreateUpload(ctx, authed(a.token, req(post, "gif-nomedia-key-00001", item("image/gif", "image/jpeg"))))
		if d := wireError(t, err, connect.CodeUnavailable); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE {
			t.Errorf("reason = %v", d.GetReason())
		}
	})
}

// docPath reads a stored object path of a media document.
func (g *gifChain) docPath(t *testing.T, id, field string) string {
	t.Helper()
	snap, err := g.fs.Collection("media").Doc(id).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	v, _ := snap.DataAt(field)
	s, _ := v.(string)
	if s == "" {
		t.Fatalf("media/%s.%s is empty", id, field)
	}
	return s
}
