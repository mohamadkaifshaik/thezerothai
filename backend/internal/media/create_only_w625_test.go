package media

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

// W6-25 (security finding H-1): the signed PUT is create-only, and the generation verify read is pinned on the GIF read
// and on Publish, so bytes that replace a screened object are never published.

// rePut models the attacker's re-PUT of the signed URL: the object gets new bytes and a higher generation (what GCS does
// when a write succeeds; the create-only header makes GCS refuse it, and these tests are the second line).
func (o *fakeObjects) rePut(object string, data []byte, contentType string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.upload[object] = fakeObject{data: data, contentType: contentType, gen: o.upload[object].genOf() + 1}
}

func TestW625_SignedPutHeadersAreCreateOnly(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "co")
	for name, h := range map[string]map[string]string{"full": tg.Full.Headers, "thumb": tg.Thumb.Headers} {
		if got := h["x-goog-if-generation-match"]; got != "0" {
			t.Fatalf("%s headers = %v: want x-goog-if-generation-match: 0 so a second PUT gets 412", name, h)
		}
	}
}

func TestW625_PublishRefusesAReplacedObject(t *testing.T) {
	tests := []struct {
		name    string
		purpose Purpose
		thumb   bool // which private object the attacker overwrites
		public  int  // public objects left behind (0: a copied full image is dropped again)
	}{
		{"full photo", PurposePost, false, 0},
		{"thumbnail", PurposePost, true, 0},
		{"avatar full", PurposeAvatar, false, 0},
		{"avatar thumbnail", PurposeAvatar, true, 0},
		{"banner full", PurposeBanner, false, 0},
		{"banner thumbnail", PurposeBanner, true, 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			ext := "jpg"
			var tg UploadTarget
			if tc.purpose == PurposeBanner {
				ext = "webp"
				tg = e.bannerUpload(t, uidA, "sw")
			} else {
				tg = e.upload(t, uidA, tc.purpose, "sw")
			}
			up := uploadObject(uidA, tg.MediaID, ext)
			if tc.thumb {
				up = uploadThumbObject(uidA, tg.MediaID, ext)
			}
			e.obj.publishHook, e.obj.publishOn = func() { e.obj.rePut(up, jpegBytes("EVIL"), "image/jpeg") }, up

			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil {
				t.Fatal(err)
			}
			if r := res[0]; r.Status != StatusRejected || r.RejectionReason != reasonInvalid || r.Ref != nil {
				t.Fatalf("result = %+v, want REJECTED %q", r, reasonInvalid)
			}
			if len(e.obj.public) != tc.public {
				t.Fatalf("public objects = %v: the swapped bytes must not stay public", e.obj.public)
			}
			if d := e.repo.docs[tg.MediaID]; d.Status != string(StatusRejected) || d.PublicPath != "" {
				t.Fatalf("doc = %+v", d)
			}
		})
	}
}

// replaceBeforeRead overwrites name (higher generation) just before the GIF sampler reads it.
type replaceBeforeRead struct {
	*fakeObjects
	name string
	data []byte
	done atomic.Bool
}

func (r *replaceBeforeRead) UploadHead(ctx context.Context, object string, n, generation int64) ([]byte, error) {
	if n != 512 && object == r.name && r.done.CompareAndSwap(false, true) {
		r.rePut(object, r.data, ContentTypeGIF)
	}
	return r.fakeObjects.UploadHead(ctx, object, n, generation)
}

// The attacker re-PUTs the SAME bytes as a new generation. The MD5 re-check cannot see that, so only the generation pin on the
// sampler read can: without it the GIF would be sampled and Vision units spent for an object verify never approved.
func TestW625_GIFReadIsPinnedToTheVerifiedGeneration(t *testing.T) {
	original := colourGIF(pxWhite, pxGreen)
	r := &replaceBeforeRead{data: original}
	e := newEnv(t, envOpts{objects: func(f *fakeObjects) Objects { r.fakeObjects = f; return r }})
	tg := e.createGIFWith(t, uidA, "a", original)
	r.name = uploadObject(uidA, tg.MediaID, "gif")
	if res := e.finalizeGIF(t, tg); res.Status != StatusRejected || res.RejectionReason != reasonInvalid {
		t.Fatalf("result = %+v", res)
	}
	if len(e.mod.byteCalls) != 0 || e.repo.vision[monthKey(testNow)] != 0 {
		t.Fatalf("a swapped GIF must not reach Vision: sheets %d, units %d", len(e.mod.byteCalls), e.repo.vision[monthKey(testNow)])
	}
}

func TestW625_VerifyRecordsTheGenerationItRead(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "gn")
	e.obj.rePut(uploadObject(uidA, tg.MediaID, "jpg"), jpegBytes("Fgn"), "image/jpeg") // same bytes, generation 2
	d := e.repo.docs[tg.MediaID]
	reason, gens, err := e.svc.(*service).verify(context.Background(), d)
	if err != nil || reason != "" {
		t.Fatalf("verify = %q, %v", reason, err)
	}
	if gens.full != 2 || gens.thumb != 1 {
		t.Fatalf("generations = %+v, want full 2 thumb 1", gens)
	}
	if err := e.obj.Publish(context.Background(), d.UploadPath, 1, "p/x.jpg", "image/jpeg"); !errors.Is(err, objstore.ErrGenerationChanged) {
		t.Fatalf("a stale generation must be refused, got %v", err)
	}
}

// noGenObjects reports attributes without a generation (what a store that dropped the field would do); the plain fake turns
// 0 into 1, which would hide the missing pin.
type noGenObjects struct{ *fakeObjects }

func (n noGenObjects) UploadAttrs(ctx context.Context, object string) (objstore.Attrs, error) {
	a, err := n.fakeObjects.UploadAttrs(ctx, object)
	a.Generation = 0
	return a, err
}

// W6-25 M-4: no generation means no pin, so verify fails closed (an internal error, the client retries) and nothing is published.
func TestW625_VerifyFailsClosedWithoutAGeneration(t *testing.T) {
	e := newEnv(t, envOpts{objects: func(f *fakeObjects) Objects { return noGenObjects{f} }})
	tg := e.upload(t, uidA, PurposePost, "ng")
	d := e.repo.docs[tg.MediaID]
	if _, _, err := e.svc.(*service).verify(context.Background(), d); err == nil {
		t.Fatal("verify accepted attributes without a generation")
	}
	if _, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}}); err == nil {
		t.Fatal("FinalizeUpload succeeded without a generation")
	}
	if e.obj.publishes != 0 || len(e.obj.public) != 0 {
		t.Fatalf("published without a pin: %d, %v", e.obj.publishes, e.obj.public)
	}
	if d := e.repo.docs[tg.MediaID]; d.Status != string(StatusPending) {
		t.Fatalf("doc = %+v, want it left PENDING for a retry", d)
	}
}

// The real Buckets refuse an unpinned publish too, whatever the caller passes.
func TestW625_BucketsPublishRefusesAZeroGeneration(t *testing.T) {
	b, err := NewBuckets("up", "pub")
	if err != nil {
		t.Fatal(err)
	}
	if err := b.Publish(context.Background(), "u/x", 0, "p/x", "image/jpeg"); err == nil {
		t.Fatal("Publish with generation 0 was attempted")
	}
}
