package media

import (
	"context"
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
		name   string
		swap   func(tg UploadTarget) string // which private object the attacker overwrites
		public int                          // public objects left behind (0: a copied full image is dropped again)
	}{
		{"full photo", func(tg UploadTarget) string { return uploadObject(uidA, tg.MediaID, "jpg") }, 0},
		{"thumbnail", func(tg UploadTarget) string { return uploadThumbObject(uidA, tg.MediaID, "jpg") }, 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			tg := e.upload(t, uidA, PurposePost, "sw")
			up := tc.swap(tg)
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
		r.fakeObjects.rePut(object, r.data, ContentTypeGIF)
	}
	return r.fakeObjects.UploadHead(ctx, object, n, generation)
}

func TestW625_GIFReadIsPinnedToTheVerifiedGeneration(t *testing.T) {
	r := &replaceBeforeRead{data: colourGIF(pxRed, pxRed)}
	e := newEnv(t, envOpts{objects: func(f *fakeObjects) Objects { r.fakeObjects = f; return r }})
	tg := e.createGIFWith(t, uidA, "a", colourGIF(pxWhite, pxGreen))
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
	if err := e.obj.Publish(context.Background(), d.UploadPath, 1, "p/x.jpg", "image/jpeg"); err != objstore.ErrGenerationChanged {
		t.Fatalf("a stale generation must be refused, got %v", err)
	}
}
