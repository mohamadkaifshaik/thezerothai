package media

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"image"
	"image/color"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	mediav1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// W6-18: the gaps of the GIF backend tests that W6-9 and W6-10 left (ADR-0029 F11, D11, D12). Fixtures and fakes are the
// W6-9/W6-10 ones (encodeTestGIF, rawGIF, redIsExplicit, gateObjects, the env).

// timedGIF is a 32 x 32 GIF with one full-screen frame per index and its own delay in centiseconds.
func timedGIF(idxs []uint8, delays []int) []byte {
	var fr []testFrame
	for i, ix := range idxs {
		fr = append(fr, testFrame{rect: image.Rect(0, 0, 32, 32), idx: ix, delay: delays[i]})
	}
	return encodeTestGIF(32, 32, testPalette, fr)
}

func repeatIdx(n int, v uint8) []uint8 {
	s := make([]uint8, n)
	for i := range s {
		s[i] = v
	}
	return s
}

func repeatInt(n, v int) []int {
	s := make([]int, n)
	for i := range s {
		s[i] = v
	}
	return s
}

// TestW618_ExplicitFrameVerdictMatrix: a harmless first frame never hides an explicit frame that the sampler visits, and
// the accepted F11 residual (a frame strictly between two samples) is pinned as READY. Eight equal delays sample frames
// 0, 2, 4, 6; a GIF of up to four frames samples every frame.
func TestW618_ExplicitFrameVerdictMatrix(t *testing.T) {
	eight := func(explicitAt int) []uint8 {
		s := repeatIdx(8, pxGreen)
		s[0] = pxWhite
		s[explicitAt] = pxRed
		return s
	}
	tests := []struct {
		name   string
		idxs   []uint8
		delays []int
		want   Status
	}{
		{"explicit first frame", eight(0), repeatInt(8, 10), StatusRejected},
		{"explicit is the 2nd sample", eight(2), repeatInt(8, 10), StatusRejected},
		{"explicit is the 3rd sample", eight(4), repeatInt(8, 10), StatusRejected},
		{"explicit is the 4th sample", eight(6), repeatInt(8, 10), StatusRejected},
		{"RESIDUAL F11: explicit at frame 1, between samples 0 and 2", eight(1), repeatInt(8, 10), StatusReady},
		{"RESIDUAL F11: explicit at frame 3", eight(3), repeatInt(8, 10), StatusReady},
		{"RESIDUAL F11: explicit at frame 5", eight(5), repeatInt(8, 10), StatusReady},
		{"RESIDUAL F11: explicit at the last frame, after the last sample", eight(7), repeatInt(8, 10), StatusReady},
		{"two frames: explicit second", []uint8{pxWhite, pxRed}, []int{10, 10}, StatusRejected},
		{"three frames: explicit third", []uint8{pxWhite, pxGreen, pxRed}, []int{10, 10, 10}, StatusRejected},
		{"four frames: explicit fourth", []uint8{pxWhite, pxGreen, pxGreen, pxRed}, []int{10, 10, 10, 10}, StatusRejected},
		{"one long explicit frame at the end covers the 3T/4 point", append(repeatIdx(5, pxWhite), pxRed), []int{1, 1, 1, 1, 1, 400}, StatusRejected},
		{"a long harmless first frame covers every point, the short explicit tail is not seen (residual)", append([]uint8{pxWhite}, repeatIdx(5, pxRed)...), []int{400, 1, 1, 1, 1, 1}, StatusReady},
		{"harmless everywhere", repeatIdx(8, pxGreen), repeatInt(8, 10), StatusReady},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			e.mod.bytesBy = redIsExplicit(t)
			r := e.finalizeGIF(t, e.createGIFWith(t, uidA, "a", timedGIF(tt.idxs, tt.delays)))
			if r.Status != tt.want {
				t.Fatalf("result = %+v, want %s", r, tt.want)
			}
			if tt.want == StatusRejected && r.RejectionReason != reasonPolicy {
				t.Fatalf("reason = %q, want %q", r.RejectionReason, reasonPolicy)
			}
			if got := e.repo.vision[monthKey(testNow)]; got != 2 {
				t.Fatalf("vision units = %d, want 2 either way (the sheet and the thumbnail were both screened)", got)
			}
			if tt.want == StatusRejected && (len(e.obj.public) != 0 || len(e.obj.upload) != 0) {
				t.Fatalf("a rejected GIF left objects: %v / %v", e.obj.public, e.obj.upload)
			}
		})
	}
}

// TestW618_BrowserDelayClampIsModelled closes W6-18 D-1 (see the test report). Browsers (and the Flutter image codec) play
// a delay of 0 or 1 cs as 10 cs, so sampleIndices does too. A GIF whose explicit frames use delay 1 is long on screen:
// here the explicit tail is 170 of the 233 cs a browser plays (73 % of the display time). Before the fix the sampler saw
// it as 17 of 80 cs, after the 3T/4 sample, and published the GIF unscreened; now the samples reach it and it is REJECTED.
func TestW618_BrowserDelayClampIsModelled(t *testing.T) {
	idxs := append(repeatIdx(21, pxGreen), repeatIdx(17, pxRed)...)
	delays := append(repeatInt(21, 3), repeatInt(17, 1)...)
	data := timedGIF(idxs, delays)

	sc, err := scanGIF(data, s0Limits)
	if err != nil {
		t.Fatal(err)
	}
	explicitSampled := false
	for _, i := range sampleIndices(sc.frames) {
		if i >= 21 {
			explicitSampled = true
		}
	}
	if !explicitSampled {
		t.Fatalf("samples %v never reach the explicit tail that fills 73 %% of a browser's playback", sampleIndices(sc.frames))
	}

	e := newEnv(t, envOpts{})
	e.mod.bytesBy = redIsExplicit(t)
	r := e.finalizeGIF(t, e.createGIFWith(t, uidA, "a", data))
	if r.Status != StatusRejected {
		t.Fatalf("result = %+v, want REJECTED (the explicit tail is 73 %% of the display time in a browser)", r)
	}
}

// TestW618_BombsFinalizeAllocatesLittle: the whole FinalizeUpload of a bomb (read, pre-scan, reject, cleanup) allocates
// a bounded amount, not memory proportional to what the header claims. The same sizes as the pre-scan test, measured end
// to end through the service with the fakes.
func TestW618_BombsFinalizeAllocatesLittle(t *testing.T) {
	many := make([][4]int, 10_000)
	for i := range many {
		many[i] = [4]int{0, 0, 1, 1}
	}
	big := make([][4]int, 40)
	for i := range big {
		big[i] = [4]int{0, 0, 1280, 1280}
	}
	for name, data := range map[string][]byte{
		"10,000 frames":        rawGIF(100, 100, many, true),
		"65535 x 65535 screen": rawGIF(65535, 65535, [][4]int{{0, 0, 1, 1}}, true),
		"1281 x 1281 screen":   rawGIF(1281, 1281, [][4]int{{0, 0, 1, 1}}, true),
		"40 full screens":      rawGIF(1280, 1280, big, true),
		"301 frames":           rawGIF(100, 100, many[:301], true),
	} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			tg := e.createGIFWith(t, uidA, "b", data)
			runtime.GC()
			var before, after runtime.MemStats
			runtime.ReadMemStats(&before)
			r := e.finalizeGIF(t, tg)
			runtime.ReadMemStats(&after)
			if r.Status != StatusRejected || r.RejectionReason != reasonGifLarge {
				t.Fatalf("result = %+v, want REJECTED %q", r, reasonGifLarge)
			}
			if got := after.TotalAlloc - before.TotalAlloc; got > 16<<20 {
				t.Fatalf("finalizing a bomb allocated %d bytes, want under 16 MiB (a canvas alone is 6.3 MiB)", got)
			}
			if len(e.mod.byteCalls) != 0 || len(e.mod.calls) != 0 || e.repo.vision[monthKey(testNow)] != 0 {
				t.Fatalf("Vision calls: %d bytes, %v uri, units %d", len(e.mod.byteCalls), e.mod.calls, e.repo.vision[monthKey(testNow)])
			}
		})
	}
}

// TestW618_AcceptedWorstCaseStaysInsideTheMemoryBudget: a GIF just inside every limit finalizes READY and allocates a
// bounded amount, the runbook's "about 26 MiB live at the limits". TotalAlloc is an upper bound of the live size; the
// bound is generous (the race detector inflates allocations in CI, never above 2x) and the test also fails if the
// fixture stops being at the limit.
func TestW618_AcceptedWorstCaseStaysInsideTheMemoryBudget(t *testing.T) {
	pal := color.Palette{color.White, color.RGBA{R: 255, A: 255}}
	tests := []struct {
		name    string
		w, h    int
		frames  int
		fw      int
		wantMax int // bytes the finalize may allocate in total
	}{
		// 300 frames (GIF_MAX_FRAMES) of 400 x 400 = 48,000,000 of the 50,000,000 pixel budget, on a 1,280 x 1,280 screen.
		{"300 frames, 1280 x 1280 screen, area near the cap", 1280, 1280, 300, 400, 80 << 20},
		// the edge limit alone: one frame filling the largest allowed screen.
		{"one 1280 x 1280 frame", 1280, 1280, 1, 1280, 80 << 20},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var fr []testFrame
			for i := 0; i < tt.frames; i++ {
				fr = append(fr, testFrame{rect: image.Rect(0, 0, tt.fw, tt.fw), idx: uint8(i % 2), delay: 5})
			}
			data := encodeTestGIF(tt.w, tt.h, pal, fr)
			if int64(len(data)) > MaxFullBytes {
				t.Skipf("fixture is %d bytes, above the %d upload limit", len(data), MaxFullBytes)
			}
			sc, err := scanGIF(data, s0Limits)
			if err != nil || len(sc.frames) != tt.frames {
				t.Fatalf("fixture must pass the pre-scan at the limits: %v", err)
			}
			// The deadline is lifted far above production's 2 s: this test measures memory, and CI runs it under -race, which
			// slows decoding several times (the worst case took about 30 s there with a 20 s limit and was REJECTED).
			e := newEnv(t, envOpts{gifDecode: 5 * time.Minute})
			tg := e.createGIFWith(t, uidA, "w", data)
			runtime.GC()
			var before, after runtime.MemStats
			runtime.ReadMemStats(&before)
			r := e.finalizeGIF(t, tg)
			runtime.ReadMemStats(&after)
			if r.Status != StatusReady {
				t.Fatalf("result = %+v, want READY", r)
			}
			got := after.TotalAlloc - before.TotalAlloc
			t.Logf("%s: file %d bytes, finalize allocated %.1f MiB in total", tt.name, len(data), float64(got)/(1<<20))
			if got > uint64(tt.wantMax) {
				t.Fatalf("finalize allocated %d bytes, want under %d", got, tt.wantMax)
			}
			if len(e.mod.byteCalls) != 1 {
				t.Fatalf("sheet calls = %d", len(e.mod.byteCalls))
			}
		})
	}
}

// TestW618_SlotIsReleasedAfterARefusalAndDoesNotBlockPhotos: a bomb refused inside the slot frees it for the next GIF at
// once, and a photo finalize never waits for the GIF slot (it is held by a GIF read in flight).
func TestW618_SlotIsReleasedAfterARefusalAndDoesNotBlockPhotos(t *testing.T) {
	e := newEnv(t, envOpts{gifWait: 20 * time.Millisecond})
	bomb := e.createGIFWith(t, uidA, "x", rawGIF(65535, 65535, [][4]int{{0, 0, 1, 1}}, true))
	if r := e.finalizeGIF(t, bomb); r.Status != StatusRejected {
		t.Fatalf("bomb = %+v", r)
	}
	if r := e.finalizeGIF(t, e.createGIFWith(t, uidA, "y", colourGIF(pxWhite, pxGreen))); r.Status != StatusReady {
		t.Fatalf("a GIF after a refused one = %+v, want READY (the slot must be free)", r)
	}

	gate := &gateObjects{entered: make(chan struct{}), release: make(chan struct{})}
	e2 := newEnv(t, envOpts{gifWait: 20 * time.Millisecond, objects: func(f *fakeObjects) Objects { gate.fakeObjects = f; return gate }})
	g := e2.createGIFWith(t, uidA, "g", colourGIF(pxWhite, pxGreen))
	photo := e2.upload(t, uidA, PurposePost, "p")
	done := make(chan Result, 1)
	go func() { done <- e2.finalizeGIF(t, g) }()
	<-gate.entered // the GIF holds the slot
	res, err := e2.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: photo.MediaID}})
	if err != nil || res[0].Status != StatusReady {
		t.Fatalf("photo while a GIF holds the slot = %+v err=%v", res, err)
	}
	gate.release <- struct{}{}
	if r := <-done; r.Status != StatusReady {
		t.Fatalf("GIF = %+v", r)
	}
}

// TestW618_VisionCapBoundary: a GIF needs 2 units. One unit left is "at the cap" for it (REJECTED, nothing spent, the
// counter unchanged), two units left is READY and lands exactly on the cap; a photo needing 1 unit still fits.
func TestW618_VisionCapBoundary(t *testing.T) {
	t.Run("one unit left rejects a GIF without partial spend", func(t *testing.T) {
		e := newEnv(t, envOpts{cap: 10, policy: config.VisionPolicyReject})
		e.repo.vision[monthKey(testNow)] = 9
		r := e.finalizeGIF(t, e.createGIF(t, uidA, "a", ContentTypeJPEG))
		if r.Status != StatusRejected || r.RejectionReason != reasonCapacity {
			t.Fatalf("result = %+v, want REJECTED %q", r, reasonCapacity)
		}
		if got := e.repo.vision[monthKey(testNow)]; got != 9 {
			t.Fatalf("vision units = %d, want 9 (no partial reservation)", got)
		}
		if len(e.mod.calls) != 0 || len(e.mod.byteCalls) != 0 || len(e.obj.public) != 0 {
			t.Fatalf("calls %v / %d, public %v", e.mod.calls, len(e.mod.byteCalls), e.obj.public)
		}
		// the same account's photo (1 unit, thumbnail not screened) still fits the last unit.
		p := e.upload(t, uidA, PurposePost, "p")
		res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: p.MediaID}})
		if err != nil || res[0].Status != StatusReady {
			t.Fatalf("photo on the last unit = %+v err=%v", res, err)
		}
		if got := e.repo.vision[monthKey(testNow)]; got != 10 {
			t.Fatalf("vision units = %d, want 10", got)
		}
	})
	t.Run("two units left is READY and lands on the cap", func(t *testing.T) {
		e := newEnv(t, envOpts{cap: 10, policy: config.VisionPolicyReject})
		e.repo.vision[monthKey(testNow)] = 8
		r := e.finalizeGIF(t, e.createGIF(t, uidA, "a", ContentTypeJPEG))
		if r.Status != StatusReady {
			t.Fatalf("result = %+v", r)
		}
		if got := e.repo.vision[monthKey(testNow)]; got != 10 {
			t.Fatalf("vision units = %d, want 10", got)
		}
	})
}

// TestW618_VisionFailureSpendsNothingAndKeepsTheGIFRetryable: Vision failing on the sheet is a retryable UNAVAILABLE with
// the reservation returned and the claim released (not a rejection, not a charge).
func TestW618_VisionFailureSpendsNothingAndKeepsTheGIFRetryable(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.createGIF(t, uidA, "a", ContentTypeJPEG)
	e.mod.bytesErr = errors.New("vision 503")
	_, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeUnavailable {
		t.Fatalf("err = %v, want UNAVAILABLE", err)
	}
	if got := e.repo.vision[monthKey(testNow)]; got != 0 {
		t.Fatalf("vision units = %d, want 0", got)
	}
	if d := e.repo.docs[tg.MediaID]; d.Status != string(StatusPending) || d.ScreeningUntil != nil {
		t.Fatalf("doc = %+v, want PENDING with the claim released", d)
	}
	e.mod.bytesErr = nil
	if r := e.finalizeGIF(t, tg); r.Status != StatusReady {
		t.Fatalf("retry = %+v", r)
	}
}

// TestW618_PurgeAndPostDeleteRemoveGIFObjects: the account purge and the post_delete job remove the GIF's own names
// (".gif" and the thumbnail's "_t.jpg" or "_t.webp", never a "_t.gif"), published, pending and rejected alike.
func TestW618_PurgeAndPostDeleteRemoveGIFObjects(t *testing.T) {
	for _, thumb := range []struct{ ct, ext string }{{ContentTypeJPEG, "jpg"}, {ContentTypeWebP, "webp"}} {
		t.Run("purge/"+thumb.ext, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			published := e.createGIF(t, uidA, "a", thumb.ct)
			if r := e.finalizeGIF(t, published); r.Status != StatusReady {
				t.Fatalf("published = %+v", r)
			}
			pending := e.createGIF(t, uidA, "b", thumb.ct) // objects sit in the private bucket
			rejected := e.createGIFWith(t, uidA, "c", rawGIF(65535, 65535, [][4]int{{0, 0, 1, 1}}, true))
			e.finalizeGIF(t, rejected)
			// an unrecorded public object of a REJECTED document: the deterministic names must go too.
			rd := e.repo.docs[rejected.MediaID]
			rd.NameSuffix = strings.Repeat("cd", 16)
			stray := []string{publicObject(rd.ID, rd.NameSuffix, "gif"), publicThumbObject(rd.ID, rd.NameSuffix, "jpg")} // createGIFWith uses a jpeg thumbnail
			for _, s := range stray {
				e.obj.public[s] = "image/gif"
			}
			// Bob's published GIF must survive.
			bob := e.createGIF(t, uidB, "d", thumb.ct)
			if r, err := e.svc.FinalizeUpload(context.Background(), uidB, []FinalizeItem{{MediaID: bob.MediaID}}); err != nil || r[0].Status != StatusReady {
				t.Fatalf("bob = %+v err=%v", r, err)
			}
			if got := e.repo.docs[pending.MediaID].ThumbUploadPath; got != uploadThumbObject(uidA, pending.MediaID, thumb.ext) {
				t.Fatalf("pending thumb upload path = %q", got)
			}
			bobPublic := len(e.obj.public) - len(stray) - 2 // Alice's published pair, the stray pair
			if bobPublic != 2 {
				t.Fatalf("test setup: Bob has %d public objects", bobPublic)
			}

			_, done, err := NewPurger(e.repo, e.obj, "https://cdn.test/media").PurgeUser(context.Background(), uidA, Checkpoint{})
			if err != nil || !done {
				t.Fatalf("done=%v err=%v", done, err)
			}
			for o := range e.obj.upload {
				if strings.Contains(o, "/"+uidA+"/") {
					t.Errorf("private object left: %s", o)
				}
			}
			bobDoc := e.repo.docs[bob.MediaID]
			if len(e.obj.public) != 2 || e.obj.public[bobDoc.PublicPath] == "" || e.obj.public[bobDoc.ThumbPath] == "" {
				t.Errorf("public objects = %v, want only Bob's two", e.obj.public)
			}
			for _, d := range e.obj.deleted {
				if strings.Contains(d, "_t.gif") {
					t.Errorf("deleted a name that is never written: %s", d)
				}
			}
		})
	}

	t.Run("post_delete", func(t *testing.T) {
		e := newEnv(t, envOpts{})
		tg := e.createGIF(t, uidA, "a", ContentTypeWebP)
		if r := e.finalizeGIF(t, tg); r.Status != StatusReady {
			t.Fatalf("finalize = %+v", r)
		}
		e.repo.docs[tg.MediaID].PostID = postP
		if len(e.obj.public) != 2 {
			t.Fatalf("public = %v", e.obj.public)
		}
		j := NewJobs(e.repo, e.obj, fakePosts{live: map[string]bool{postP: false}}, nil)
		got, err := j.Handle(context.Background(), msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{tg.MediaID}}))
		if err != nil || got != "done" {
			t.Fatalf("outcome=%q err=%v", got, err)
		}
		if len(e.obj.public) != 0 || len(e.repo.docs) != 0 {
			t.Fatalf("left: public %v docs %d", e.obj.public, len(e.repo.docs))
		}
		for _, d := range e.obj.deleted {
			if strings.Contains(d, "_t.gif") {
				t.Errorf("deleted a name that is never written: %s", d)
			}
		}
	})
}

// readCountObjects wraps the fake store and counts the full-object reads (the publish hook (fakeObjects.publishHook) models
// a client that re-PUTs the signed URL after screening.
type readCountObjects struct {
	*fakeObjects
	reads atomic.Int32
}

func (s *readCountObjects) UploadHead(ctx context.Context, object string, n int64) ([]byte, error) {
	if n != 512 {
		s.reads.Add(1)
	}
	return s.fakeObjects.UploadHead(ctx, object, n)
}

// TestW618_KnownResidual_PublishSwapAfterScreening documents the pre-existing risk handed to W6-20 (security): the signed
// PUT URL pins no object generation, so a client that overwrites the private object after the sheet was sampled (and
// before Publish copies it) gets different bytes published than the ones that were screened. The same window exists for
// the thumbnail, which Vision reads by URI. This test pins today's outcome; it is NOT the desired behaviour. If W6-20 adds a
// generation precondition to Publish, this test must flip to a rejection.
func TestW618_KnownResidual_PublishSwapAfterScreening(t *testing.T) {
	so := &readCountObjects{}
	e := newEnv(t, envOpts{objects: func(f *fakeObjects) Objects { so.fakeObjects = f; return so }})
	e.mod.bytesBy = redIsExplicit(t)
	tg := e.createGIFWith(t, uidA, "a", colourGIF(pxWhite, pxGreen, pxGreen, pxGreen))
	up := uploadObject(uidA, tg.MediaID, "gif")
	explicit := colourGIF(pxRed, pxRed, pxRed, pxRed)
	e.obj.publishHook, e.obj.publishOn = func() {
		e.obj.mu.Lock()
		e.obj.upload[up] = fakeObject{data: explicit, contentType: ContentTypeGIF}
		e.obj.mu.Unlock()
	}, up

	r := e.finalizeGIF(t, tg)
	if so.reads.Load() != 1 {
		t.Fatalf("full-object reads = %d, want 1", so.reads.Load())
	}
	if r.Status != StatusReady {
		t.Fatalf("result = %+v: Publish now refuses the swapped object, so flip this test and close the W6-20 residual", r)
	}
	if got := e.repo.vision[monthKey(testNow)]; got != 2 {
		t.Fatalf("vision units = %d", got)
	}
}

// TestW618_RequestHashGolden pins the literal pre-W6 request hash of a photo upload (a stored idempotency record from before
// the deploy must still match a retry), next to the reconstruction test in gif_test.go.
func TestW618_RequestHashGolden(t *testing.T) {
	it := UploadItem{ContentType: ContentTypeJPEG, FullBytes: 1000, ThumbBytes: 100, Width: 1200, Height: 800, FullMD5: "AAAAAAAAAAAAAAAAAAAAAA==", ThumbMD5: "BBBBBBBBBBBBBBBBBBBBBA=="}
	want := idempotency.HashRequest("v1|purpose=POST|image/jpeg,1000,100,1200,800,AAAAAAAAAAAAAAAAAAAAAA==,BBBBBBBBBBBBBBBBBBBBBA==")
	if got := requestHash(PurposePost, []UploadItem{it}); got != want {
		t.Fatalf("photo request hash = %s, want %s (the pre-W6 format)", got, want)
	}
	it.ThumbContentType = ContentTypeJPEG
	if got := requestHash(PurposePost, []UploadItem{it}); got != want {
		t.Fatalf("an equal thumb type must hash like none: %s", got)
	}
	if _, err := base64.StdEncoding.DecodeString(it.FullMD5); err != nil {
		t.Fatalf("golden md5 is not base64: %v", err)
	}
	// A GIF is a different request from the same-sized photo.
	g := it
	g.ContentType = ContentTypeGIF
	if requestHash(PurposePost, []UploadItem{g}) == want {
		t.Fatal("a GIF must not hash like a photo")
	}
}

// TestW618_PercentModeIsPerUserAndTheSameForMediaAndPosts: a mid percentage splits users deterministically, and the media
// server's decision for each uid equals the registry's decision for the flag name posts uses.
func TestW618_PercentModeIsPerUserAndTheSameForMediaAndPosts(t *testing.T) {
	reg := flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.On},
		flags.Spec{Name: GifFlagName, Mode: flags.Percent, Percent: 50})
	var on, off int
	e := newEnv(t, envOpts{perDay: 1000, newPerDay: 1000})
	s := NewServer(e.svc, reg)
	full, thumb := gifBytes("F"), jpegBytes("T")
	for i := 0; i < 40; i++ {
		uid := fmt.Sprintf("uid-%d", i)
		want := reg.Enabled(uid, "gif") // "gif" is posts.GifFlagName (a test in posts keeps the names equal)
		_, err := s.CreateUpload(authedCtx(uid), connect.NewRequest(&mediav1.CreateUploadRequest{
			IdempotencyKey: fmt.Sprintf("percent-key-%02d-abcdef", i), Purpose: mediav1.MediaPurpose_MEDIA_PURPOSE_POST,
			Items: []*mediav1.UploadItem{{ContentType: ContentTypeGIF, ThumbContentType: ContentTypeJPEG, FullSizeBytes: int64(len(full)), ThumbSizeBytes: int64(len(thumb)),
				Width: 400, Height: 300, FullMd5: md5b64(full), ThumbMd5: md5b64(thumb)}},
		}))
		if want {
			on++
			if err != nil {
				t.Fatalf("%s: allowed by the registry but media answered %v", uid, err)
			}
			continue
		}
		off++
		_ = wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	}
	if on == 0 || off == 0 {
		t.Fatalf("50 %% of 40 uids: %d on, %d off, want both populated", on, off)
	}
	// determinism: the same uid always lands on the same side.
	first := reg.Enabled("uid-3", "gif")
	for i := 0; i < 5; i++ {
		if reg.Enabled("uid-3", "gif") != first {
			t.Fatal("bucket is not deterministic")
		}
	}
}

// TestW618_CreateUploadFlagOffIsRefusedBeforeAnyRead: with FEATURE_GIF off, a GIF CreateUpload does no Firestore work at
// all (the fake repo records nothing, nothing is signed), for a GIF item mixed with a photo too.
func TestW618_CreateUploadFlagOffIsRefusedBeforeAnyRead(t *testing.T) {
	e := newEnv(t, envOpts{})
	s := NewServer(e.svc, flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.On},
		flags.Spec{Name: GifFlagName, Mode: flags.Off}))
	g, p := gifBytes("F"), jpegBytes("T")
	gi := &mediav1.UploadItem{ContentType: ContentTypeGIF, ThumbContentType: ContentTypeJPEG, FullSizeBytes: int64(len(g)), ThumbSizeBytes: int64(len(p)), Width: 400, Height: 300, FullMd5: md5b64(g), ThumbMd5: md5b64(p)}
	pi := &mediav1.UploadItem{ContentType: ContentTypeJPEG, FullSizeBytes: int64(len(p)), ThumbSizeBytes: int64(len(p)), Width: 400, Height: 300, FullMd5: md5b64(p), ThumbMd5: md5b64(p)}
	for name, items := range map[string][]*mediav1.UploadItem{"gif": {gi}, "gif and photo": {gi, pi}} {
		_, err := s.CreateUpload(authedCtx(uidA), connect.NewRequest(&mediav1.CreateUploadRequest{IdempotencyKey: key1, Purpose: mediav1.MediaPurpose_MEDIA_PURPOSE_POST, Items: items}))
		ae := wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
		if ae.Metadata["feature"] != "gif" || e.sign.calls != 0 || len(e.repo.docs) != 0 || len(e.repo.vision) != 0 {
			t.Fatalf("%s: feature=%q signs=%d docs=%d: a disabled flag must do no work", name, ae.Metadata["feature"], e.sign.calls, len(e.repo.docs))
		}
	}
}

// TestW618_FinalizeIgnoresTheGifFlag: a GIF uploaded before the flag was lowered still finalizes (runbook: FinalizeUpload
// ignores FEATURE_GIF; only the post gate refuses it).
func TestW618_FinalizeIgnoresTheGifFlag(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.createGIF(t, uidA, "a", ContentTypeJPEG)
	s := NewServer(e.svc, flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.On},
		flags.Spec{Name: GifFlagName, Mode: flags.Off}))
	resp, err := s.FinalizeUpload(authedCtx(uidA), connect.NewRequest(&mediav1.FinalizeUploadRequest{IdempotencyKey: "finalize-key-000000001", Items: []*mediav1.FinalizeItem{{MediaId: tg.MediaID}}}))
	if err != nil {
		t.Fatal(err)
	}
	if got := resp.Msg.GetResults()[0].GetStatus(); got != mediav1.MediaStatus_MEDIA_STATUS_READY {
		t.Fatalf("status = %v, want READY", got)
	}
}

// TestW618_ExportCoversAGIF: the account export lists a published GIF with its content type, its .gif URL and the
// thumbnail's own URL, and never an internal path or hash (W6-9: "the purge and export of media cover the gif extension").
func TestW618_ExportCoversAGIF(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.createGIF(t, uidA, "a", ContentTypeWebP)
	if r := e.finalizeGIF(t, tg); r.Status != StatusReady {
		t.Fatalf("finalize = %+v", r)
	}
	var buf strings.Builder
	if err := NewPurger(e.repo, e.obj, "https://cdn.test/media").WriteSection(context.Background(), uidA, &buf); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	d := e.repo.docs[tg.MediaID]
	for _, want := range []string{`"contentType":"image/gif"`, `"url":"https://cdn.test/media/` + d.PublicPath + `"`, `"thumbUrl":"https://cdn.test/media/` + d.ThumbPath + `"`} {
		if !strings.Contains(out, want) {
			t.Errorf("export %s lacks %s", out, want)
		}
	}
	if !strings.HasSuffix(d.PublicPath, ".gif") || !strings.HasSuffix(d.ThumbPath, "_t.webp") {
		t.Errorf("paths = %q %q", d.PublicPath, d.ThumbPath)
	}
	for _, leak := range []string{"u/" + uidA, "md5", "MD5", "UploadPath", "uploadPath"} {
		if strings.Contains(out, leak) {
			t.Errorf("export leaks %q: %s", leak, out)
		}
	}
}
