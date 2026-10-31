package media

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"log/slog"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// W6-10 (ADR-0029 D11, F11): frame-sampled GIF screening. Fixtures are built in the test (image/gif encoder, hand-made
// bomb headers) instead of checked-in files, so the frames' colours and delays are visible next to the assertion.

// Palette indices of the test GIFs.
const (
	pxWhite = iota
	pxRed   // the "explicit" frame: the sheet classifier below reads it as adult VERY_LIKELY
	pxGreen
	pxBlue
)

var testPalette = color.Palette{color.White, color.RGBA{R: 255, A: 255}, color.RGBA{G: 255, A: 255}, color.RGBA{B: 255, A: 255}}

// testFrame is one solid rectangle of palette index idx.
type testFrame struct {
	rect     image.Rectangle
	idx      uint8
	delay    int
	disposal byte
}

func encodeTestGIF(w, h int, pal color.Palette, frames []testFrame) []byte {
	g := &gif.GIF{Config: image.Config{ColorModel: pal, Width: w, Height: h}}
	for _, f := range frames {
		p := image.NewPaletted(f.rect, pal)
		for i := range p.Pix {
			p.Pix[i] = f.idx
		}
		g.Image = append(g.Image, p)
		g.Delay = append(g.Delay, f.delay)
		g.Disposal = append(g.Disposal, f.disposal)
	}
	var b bytes.Buffer
	if err := gif.EncodeAll(&b, g); err != nil {
		panic(err)
	}
	return b.Bytes()
}

// colourGIF is a 32 x 32 GIF with one full-screen frame per index, each shown for 10 cs.
func colourGIF(idxs ...uint8) []byte {
	var fr []testFrame
	for _, i := range idxs {
		fr = append(fr, testFrame{rect: image.Rect(0, 0, 32, 32), idx: i, delay: 10})
	}
	return encodeTestGIF(32, 32, testPalette, fr)
}

// sheetCells returns the centre pixel of each of the (up to four) 640 x 480 cells of a sheet.
func sheetCells(t *testing.T, sheet []byte) []color.RGBA {
	t.Helper()
	img, err := jpeg.Decode(bytes.NewReader(sheet))
	if err != nil {
		t.Fatal(err)
	}
	var out []color.RGBA
	for k := range 4 {
		x, y := (k%2)*gifTileW+gifTileW/2, (k/2)*gifTileH+gifTileH/2
		if !image.Pt(x, y).In(img.Bounds()) {
			break
		}
		r, g, b, _ := img.At(x, y).RGBA()
		out = append(out, color.RGBA{R: uint8(r >> 8), G: uint8(g >> 8), B: uint8(b >> 8), A: 255})
	}
	return out
}

func isRed(c color.RGBA) bool { return c.R > 200 && c.G < 80 && c.B < 80 }

// redIsExplicit scripts the fake Moderator: a sheet with a red cell is adult VERY_LIKELY.
func redIsExplicit(t *testing.T) func([]byte) SafeSearch {
	return func(sheet []byte) SafeSearch {
		for _, c := range sheetCells(t, sheet) {
			if isRed(c) {
				return SafeSearch{Adult: LikelihoodVeryLikely}
			}
		}
		return SafeSearch{Adult: LikelihoodVeryUnlikely}
	}
}

// createGIFWith runs CreateUpload and the client's PUTs for a GIF with the given bytes.
func (e *env) createGIFWith(t *testing.T, uid, tag string, full []byte) UploadTarget {
	t.Helper()
	thumb := jpegBytes("T" + tag)
	tgs, err := e.svc.CreateUpload(context.Background(), uid, CreateUploadInput{
		IdempotencyKey: "key-" + tag + "-0123456789", Purpose: PurposePost, Items: []UploadItem{gifItem(full, thumb, ContentTypeJPEG)},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.putGIF(uid, tgs[0], full, thumb, ContentTypeJPEG)
	return tgs[0]
}

func (e *env) finalizeGIF(t *testing.T, tg UploadTarget) Result {
	t.Helper()
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err != nil {
		t.Fatal(err)
	}
	return res[0]
}

func TestGIFScreen_ThirdSampledFrameExplicitIsRejected(t *testing.T) {
	// 8 frames of equal delay: the samples are frames 0, 2, 5, 7. The first frame is harmless and the explicit one is
	// the 3rd sample (frame 5), which Vision's first-frame-only reading of the file would never have seen.
	e := newEnv(t, envOpts{})
	e.mod.bytesBy = redIsExplicit(t)
	tg := e.createGIFWith(t, uidA, "a", colourGIF(pxWhite, pxGreen, pxGreen, pxGreen, pxGreen, pxRed, pxGreen, pxGreen))
	r := e.finalizeGIF(t, tg)
	if r.Status != StatusRejected || r.RejectionReason != reasonPolicy {
		t.Fatalf("result = %+v, want REJECTED %q", r, reasonPolicy)
	}
	if len(e.mod.byteCalls) != 1 {
		t.Fatalf("sheet calls = %d", len(e.mod.byteCalls))
	}
	cells := sheetCells(t, e.mod.byteCalls[0])
	if len(cells) != 4 || isRed(cells[0]) || isRed(cells[1]) || !isRed(cells[2]) || isRed(cells[3]) {
		t.Fatalf("sheet cells = %v, want the 3rd sample red", cells)
	}
	if got := e.repo.vision[monthKey(testNow)]; got != 2 {
		t.Fatalf("vision units = %d, want 2 (a blocked screen still spent both calls)", got)
	}
	if len(e.obj.upload) != 0 || len(e.obj.public) != 0 {
		t.Fatalf("objects left: %v / %v", e.obj.upload, e.obj.public)
	}
}

// TestGIFScreen_FrameBetweenTheSamplesIsNotScreened pins the residual risk the founder accepted in F11 point 2: content
// shown only between two sample points is not seen. If a future change starts screening more frames, this test changes
// deliberately.
func TestGIFScreen_FrameBetweenTheSamplesIsNotScreened(t *testing.T) {
	e := newEnv(t, envOpts{})
	e.mod.bytesBy = redIsExplicit(t)
	tg := e.createGIFWith(t, uidA, "a", colourGIF(pxWhite, pxRed, pxGreen, pxGreen, pxGreen, pxGreen, pxGreen, pxGreen))
	if r := e.finalizeGIF(t, tg); r.Status != StatusReady {
		t.Fatalf("result = %+v, want READY (frame 1 is not a sample)", r)
	}
	if got := e.repo.vision[monthKey(testNow)]; got != 2 {
		t.Fatalf("vision units = %d, want 2", got)
	}
}

func TestSampleIndices(t *testing.T) {
	frames := func(delays ...int) []gifFrame {
		out := make([]gifFrame, len(delays))
		for i, d := range delays {
			out[i].delayCS = d
		}
		return out
	}
	rep := func(n, v int) []int {
		s := make([]int, n)
		for i := range s {
			s[i] = v
		}
		return s
	}
	tests := []struct {
		name string
		in   []gifFrame
		want []int
	}{
		{"one frame", frames(10), []int{0}},
		{"three frames are each sampled once", frames(10, 10, 10), []int{0, 1, 2}},
		{"four frames", frames(10, 10, 10, 10), []int{0, 1, 2, 3}},
		{"eight equal delays: 0, T/3, 2T/3 and the last", frames(rep(8, 10)...), []int{0, 2, 5, 7}},
		{"zero delay counts as 10 ms", frames(rep(8, 0)...), []int{0, 2, 5, 7}},
		{"five frames: the last is the fourth sample", frames(rep(5, 10)...), []int{0, 1, 3, 4}},
		{"two frames", frames(10, 10), []int{0, 1}},
		{"a long GIF of 300 frames", frames(rep(300, 5)...), []int{0, 100, 200, 299}},
		{"a 2 cs last frame after a long GIF is sampled (M-2)", frames(append(rep(40, 10), 2)...), []int{0, 13, 26, 40}},
		{"a long first frame covers every point, the last frame is still sampled", frames(append([]int{400}, rep(5, 1)...)...), []int{0, 5}},
		{"a long last frame is sampled once", frames(append(rep(5, 1), 400)...), []int{0, 5}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := sampleIndices(tt.in)
			if len(got) != len(tt.want) {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Fatalf("got %v, want %v", got, tt.want)
				}
			}
		})
	}
}

func TestSampleGIF_CompositesWithDisposal(t *testing.T) {
	// Cells hold a 32 x 32 tile centred in 640 x 480: tile pixel (x, y) is sheet pixel (304+x, 224+y).
	at := func(t *testing.T, sheet []byte, cell, x, y int) color.RGBA {
		t.Helper()
		img, err := jpeg.Decode(bytes.NewReader(sheet))
		if err != nil {
			t.Fatal(err)
		}
		r, g, b, _ := img.At((cell%2)*gifTileW+304+x, (cell/2)*gifTileH+224+y).RGBA()
		return color.RGBA{R: uint8(r >> 8), G: uint8(g >> 8), B: uint8(b >> 8), A: 255}
	}
	near := func(c color.RGBA, want color.RGBA) bool {
		d := func(a, b uint8) int { return max(int(a)-int(b), int(b)-int(a)) }
		return d(c.R, want.R) < 40 && d(c.G, want.G) < 40 && d(c.B, want.B) < 40
	}
	red, green, white := color.RGBA{R: 255, A: 255}, color.RGBA{G: 255, A: 255}, color.RGBA{R: 255, G: 255, B: 255, A: 255}
	run := func(t *testing.T, data []byte) []byte {
		t.Helper()
		sc, err := scanGIF(data, s0Limits)
		if err != nil {
			t.Fatal(err)
		}
		sheet, n, err := sampleGIF(context.Background(), data, sc)
		if err != nil || n != len(sc.frames) {
			t.Fatalf("sampled %d of %d, err=%v", n, len(sc.frames), err)
		}
		return sheet
	}
	t.Run("a later frame is drawn over the earlier one", func(t *testing.T) {
		sheet := run(t, encodeTestGIF(32, 32, testPalette, []testFrame{
			{rect: image.Rect(0, 0, 32, 32), idx: pxRed, delay: 10},
			{rect: image.Rect(0, 0, 8, 8), idx: pxGreen, delay: 10},
		}))
		if c := at(t, sheet, 0, 20, 20); !near(c, red) {
			t.Fatalf("tile 0 = %v", c)
		}
		if c := at(t, sheet, 1, 2, 2); !near(c, green) {
			t.Fatalf("tile 1 corner = %v, want green", c)
		}
		if c := at(t, sheet, 1, 20, 20); !near(c, red) {
			t.Fatalf("tile 1 body = %v, want the earlier red kept", c)
		}
	})
	t.Run("restore to background clears the frame's rectangle", func(t *testing.T) {
		sheet := run(t, encodeTestGIF(32, 32, testPalette, []testFrame{
			{rect: image.Rect(0, 0, 16, 16), idx: pxRed, delay: 10, disposal: gif.DisposalBackground},
			{rect: image.Rect(16, 16, 24, 24), idx: pxGreen, delay: 10},
		}))
		if c := at(t, sheet, 1, 2, 2); !near(c, white) {
			t.Fatalf("tile 1 = %v, want the cleared (white) background, not red", c)
		}
	})
	t.Run("restore to previous undoes the frame", func(t *testing.T) {
		sheet := run(t, encodeTestGIF(32, 32, testPalette, []testFrame{
			{rect: image.Rect(0, 0, 32, 32), idx: pxRed, delay: 10},
			{rect: image.Rect(0, 0, 16, 16), idx: pxGreen, delay: 10, disposal: gif.DisposalPrevious},
			{rect: image.Rect(28, 28, 32, 32), idx: pxBlue, delay: 10},
		}))
		if c := at(t, sheet, 1, 2, 2); !near(c, green) {
			t.Fatalf("tile 1 = %v, want green while shown", c)
		}
		if c := at(t, sheet, 2, 2, 2); !near(c, red) {
			t.Fatalf("tile 2 = %v, want red restored", c)
		}
	})
}

var s0Limits = gifLimits{maxFrames: 300, maxEdge: 1280, maxAreaSum: 50_000_000}

// rawGIF assembles a GIF container by hand: a 2-colour global table and one descriptor per frame with a stub data run.
func rawGIF(w, h int, frames [][4]int, trailer bool) []byte {
	b := []byte("GIF89a")
	b = append(b, byte(w), byte(w>>8), byte(h), byte(h>>8), 0x80, 0, 0, 0, 0, 0, 255, 255, 255)
	for _, f := range frames { // left, top, w, h
		b = append(b, 0x2C, byte(f[0]), byte(f[0]>>8), byte(f[1]), byte(f[1]>>8), byte(f[2]), byte(f[2]>>8), byte(f[3]), byte(f[3]>>8), 0, 2, 2, 0x4C, 0x01, 0)
	}
	if trailer {
		b = append(b, 0x3B)
	}
	return b
}

func TestScanGIF_Refusals(t *testing.T) {
	lim := gifLimits{maxFrames: 5, maxEdge: 100, maxAreaSum: 1000}
	one := [][4]int{{0, 0, 10, 10}}
	tests := []struct {
		name string
		data []byte
		why  string // "" = accepted
	}{
		{"valid", rawGIF(100, 100, one, true), ""},
		{"valid, exactly the frame limit", rawGIF(100, 100, [][4]int{{0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1}}, true), ""},
		{"one frame over the limit", rawGIF(100, 100, [][4]int{{0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1}}, true), "frames"},
		{"screen wider than the edge limit", rawGIF(101, 10, one, true), "edge"},
		{"screen 65535 x 65535", rawGIF(65535, 65535, one, true), "edge"},
		{"zero-width screen", rawGIF(0, 10, one, true), "screen_size"},
		{"frame past the right edge", rawGIF(100, 100, [][4]int{{95, 0, 10, 10}}, true), "frame_outside"},
		{"frame past the bottom edge", rawGIF(100, 100, [][4]int{{0, 95, 10, 10}}, true), "frame_outside"},
		{"area sum above the limit", rawGIF(100, 100, [][4]int{{0, 0, 25, 25}, {0, 0, 25, 25}}, true), "area"},
		{"zero-size frame", rawGIF(100, 100, [][4]int{{0, 0, 0, 10}}, true), "frame_size"},
		{"no frames", rawGIF(100, 100, nil, true), "no_frames"},
		{"missing trailer", rawGIF(100, 100, one, false), "no_trailer"},
		{"truncated mid descriptor", rawGIF(100, 100, one, true)[:20], "image_descriptor"},
		{"truncated mid sub-block", rawGIF(100, 100, one, true)[:len(rawGIF(100, 100, one, true))-5], "sub_blocks"},
		{"not a gif", []byte("PNG not gif at all..."), "header"},
		{"unknown block", append(rawGIF(100, 100, one, false), 0x99), "block"},
		{"short", []byte("GIF89a"), "header"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sc, err := scanGIF(tt.data, lim)
			if tt.why == "" {
				if err != nil || sc == nil || len(sc.frames) == 0 {
					t.Fatalf("scan = %v, %v", sc, err)
				}
				return
			}
			var ref *gifRefusal
			if !errors.As(err, &ref) || ref.why != tt.why {
				t.Fatalf("err = %v, want refusal %q", err, tt.why)
			}
			wantReason := reasonInvalid
			if tt.why == "frames" || tt.why == "edge" || tt.why == "area" || tt.why == "frame_outside" {
				wantReason = reasonGifLarge
			}
			if ref.reason != wantReason {
				t.Fatalf("reason = %q, want %q", ref.reason, wantReason)
			}
		})
	}
}

func FuzzScanGIF(f *testing.F) {
	f.Add(rawGIF(100, 100, [][4]int{{0, 0, 10, 10}}, true))
	f.Add(colourGIF(pxRed, pxGreen))
	f.Add([]byte("GIF89a\x01\x00\x01\x00\x00\x00\x00\x21\xf9\x04\x00\x00\x00\x00\x00\x3b"))
	lim := gifLimits{maxFrames: 20, maxEdge: 200, maxAreaSum: 100_000}
	f.Fuzz(func(t *testing.T, data []byte) {
		sc, err := scanGIF(data, lim)
		if err != nil {
			var ref *gifRefusal
			if !errors.As(err, &ref) {
				t.Fatalf("non-refusal error %v", err)
			}
			return
		}
		var area int64
		for _, fr := range sc.frames {
			area += int64(fr.w) * int64(fr.h)
			if fr.start < 0 || fr.start > fr.end || fr.end > len(data) || fr.left+fr.w > sc.width || fr.top+fr.h > sc.height {
				t.Fatalf("frame out of range: %+v in %d bytes, screen %dx%d", fr, len(data), sc.width, sc.height)
			}
		}
		if len(sc.frames) == 0 || len(sc.frames) > lim.maxFrames || area > lim.maxAreaSum || sc.width > lim.maxEdge || sc.height > lim.maxEdge {
			t.Fatalf("accepted over the limits: %d frames, area %d, %dx%d", len(sc.frames), area, sc.width, sc.height)
		}
		// The sampler must not panic on anything the scan accepts (it may refuse).
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_, _, _ = sampleGIF(ctx, data, sc)
	})
}

// TestGIFScreen_BombsAreRefusedBeforeAnyDecode: a header with 10,000 frame descriptors and a 65,535 x 65,535 logical screen
// are REJECTED with the "too large or too long" reason, spend nothing, and the pre-scan stays far under 20 MB. Not
// parallel: it reads the process-wide allocation counter.
func TestGIFScreen_BombsAreRefusedBeforeAnyDecode(t *testing.T) {
	many := make([][4]int, 10_000)
	for i := range many {
		many[i] = [4]int{0, 0, 1, 1}
	}
	for name, data := range map[string][]byte{
		"10,000 frames":       rawGIF(100, 100, many, true),
		"65535 x 65535 sheet": rawGIF(65535, 65535, [][4]int{{0, 0, 1, 1}}, true),
		"area sum":            rawGIF(1280, 1280, [][4]int{{0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}, {0, 0, 1280, 1280}}, true),
	} {
		t.Run(name, func(t *testing.T) {
			var before, after runtime.MemStats
			runtime.ReadMemStats(&before)
			_, err := scanGIF(data, s0Limits)
			runtime.ReadMemStats(&after)
			var ref *gifRefusal
			if !errors.As(err, &ref) || ref.reason != reasonGifLarge {
				t.Fatalf("err = %v", err)
			}
			if got := after.TotalAlloc - before.TotalAlloc; got > 20<<20 {
				t.Fatalf("pre-scan allocated %d bytes, want under 20 MB", got)
			}

			e := newEnv(t, envOpts{})
			tg := e.createGIFWith(t, uidA, "b", data)
			r := e.finalizeGIF(t, tg)
			if r.Status != StatusRejected || r.RejectionReason != reasonGifLarge {
				t.Fatalf("result = %+v, want REJECTED %q", r, reasonGifLarge)
			}
			if len(e.mod.byteCalls) != 0 || len(e.mod.calls) != 0 || e.repo.vision[monthKey(testNow)] != 0 {
				t.Fatalf("a refused GIF must spend no Vision units: %v %v %d", e.mod.byteCalls, e.mod.calls, e.repo.vision[monthKey(testNow)])
			}
			if len(e.obj.upload) != 0 || len(e.obj.public) != 0 {
				t.Fatalf("objects left: %v / %v", e.obj.upload, e.obj.public)
			}
		})
	}
}

func TestGIFScreen_ConfiguredLimitsApply(t *testing.T) {
	e := newEnv(t, envOpts{gifMaxFrames: 3})
	tg := e.createGIFWith(t, uidA, "a", colourGIF(pxWhite, pxGreen, pxGreen, pxGreen))
	if r := e.finalizeGIF(t, tg); r.Status != StatusRejected || r.RejectionReason != reasonGifLarge {
		t.Fatalf("result = %+v", r)
	}
	e = newEnv(t, envOpts{gifMaxArea: 1000})
	tg = e.createGIFWith(t, uidA, "a", colourGIF(pxWhite, pxGreen)) // 2 x 1,024 pixels
	if r := e.finalizeGIF(t, tg); r.Status != StatusRejected || r.RejectionReason != reasonGifLarge {
		t.Fatalf("result = %+v", r)
	}
}

func TestSampleGIF_DeadlineIsRefusedAsTooLong(t *testing.T) {
	data := colourGIF(pxWhite, pxGreen)
	sc, err := scanGIF(data, s0Limits)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, _, err = sampleGIF(ctx, data, sc)
	var ref *gifRefusal
	if !errors.As(err, &ref) || ref.why != "deadline" || ref.reason != reasonGifLarge {
		t.Fatalf("err = %v, want a deadline refusal", err)
	}
}

func TestGIFScreen_CorruptFrameDataIsRejectedAsInvalid(t *testing.T) {
	// The container scans fine (stub LZW data) but the frame does not decode to its pixels.
	e := newEnv(t, envOpts{})
	tg := e.createGIFWith(t, uidA, "a", rawGIF(100, 100, [][4]int{{0, 0, 50, 50}}, true))
	r := e.finalizeGIF(t, tg)
	if r.Status != StatusRejected || r.RejectionReason != reasonInvalid || len(e.mod.byteCalls) != 0 {
		t.Fatalf("result = %+v", r)
	}
}

// gateObjects wraps the object store: the full-object read of a GIF (n other than the 512-byte magic read) can block on a
// gate, count its concurrency, or panic.
type gateObjects struct {
	*fakeObjects
	entered  chan struct{}
	release  chan struct{}
	inFlight atomic.Int32
	maxSeen  atomic.Int32
	panicRun bool
}

func (g *gateObjects) UploadHead(ctx context.Context, object string, n, generation int64) ([]byte, error) {
	if n != 512 {
		if g.panicRun {
			panic("boom")
		}
		cur := g.inFlight.Add(1)
		defer g.inFlight.Add(-1)
		for {
			m := g.maxSeen.Load()
			if cur <= m || g.maxSeen.CompareAndSwap(m, cur) {
				break
			}
		}
		if g.entered != nil {
			g.entered <- struct{}{}
			<-g.release
		}
		for range 50 {
			runtime.Gosched()
		}
	}
	return g.fakeObjects.UploadHead(ctx, object, n, generation)
}

func TestGIFScreen_BusySlotAnswersMediaNotReadyWithoutSpend(t *testing.T) {
	gate := &gateObjects{entered: make(chan struct{}), release: make(chan struct{})}
	e := newEnv(t, envOpts{gifWait: 30 * time.Millisecond, objects: func(f *fakeObjects) Objects { gate.fakeObjects = f; return gate }})
	a := e.createGIFWith(t, uidA, "a", colourGIF(pxWhite, pxGreen))
	b := e.createGIFWith(t, uidA, "b", colourGIF(pxGreen, pxWhite))

	var wg sync.WaitGroup
	wg.Add(1)
	var resA Result
	go func() {
		defer wg.Done()
		resA = e.finalizeGIF(t, a)
	}()
	<-gate.entered // A holds the slot

	_, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: b.MediaID}})
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
		t.Fatalf("err = %v, want MEDIA_NOT_READY", err)
	}
	if len(e.mod.byteCalls) != 0 || len(e.mod.calls) != 0 {
		t.Fatal("the waiter must not call Vision")
	}
	if d := e.repo.docs[b.MediaID]; d.Status != string(StatusPending) || d.ScreeningUntil != nil {
		t.Fatalf("B = %+v, want PENDING with its screening claim released", d)
	}
	gate.release <- struct{}{}
	wg.Wait()
	if resA.Status != StatusReady {
		t.Fatalf("A = %+v", resA)
	}
	// Only A was counted: B's reservation was returned.
	if got := e.repo.vision[monthKey(testNow)]; got != 2 {
		t.Fatalf("vision units = %d, want 2", got)
	}
	// The client's retry now succeeds (A is done, so the gate is no longer needed).
	gate.entered = nil
	if r := e.finalizeGIF(t, b); r.Status != StatusReady {
		t.Fatalf("B retry = %+v", r)
	}
}

func TestGIFScreen_TwoGIFsRunOneAfterAnotherAndBothFinish(t *testing.T) {
	gate := &gateObjects{}
	e := newEnv(t, envOpts{objects: func(f *fakeObjects) Objects { gate.fakeObjects = f; return gate }})
	var targets []UploadTarget
	for _, tag := range []string{"a", "b", "c", "d"} {
		targets = append(targets, e.createGIFWith(t, uidA, tag, colourGIF(pxWhite, uint8(len(targets)%3+1))))
	}
	// The Cloud Run request timeout (30 s, cloud-run-api request_timeout_seconds) is the deadline all four must meet.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var wg sync.WaitGroup
	results := make([]Result, len(targets))
	for i, tg := range targets {
		wg.Add(1)
		go func() {
			defer wg.Done()
			res, err := e.svc.FinalizeUpload(ctx, uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil {
				t.Error(err)
				return
			}
			results[i] = res[0]
		}()
	}
	wg.Wait()
	for i, r := range results {
		if r.Status != StatusReady {
			t.Fatalf("GIF %d = %+v", i, r)
		}
	}
	if gate.maxSeen.Load() != 1 {
		t.Fatalf("up to %d GIFs were read and sampled at once, want 1", gate.maxSeen.Load())
	}
	if got := e.repo.vision[monthKey(testNow)]; got != 8 {
		t.Fatalf("vision units = %d, want 2 per GIF", got)
	}
}

func TestGIFScreen_SamplerPanicIsRejectedAndReported(t *testing.T) {
	var logs bytes.Buffer
	gate := &gateObjects{panicRun: true}
	e := newEnv(t, envOpts{
		objects: func(f *fakeObjects) Objects { gate.fakeObjects = f; return gate },
		log:     slog.New(slog.NewJSONHandler(&logs, nil)),
	})
	tg := e.createGIFWith(t, uidA, "a", colourGIF(pxWhite, pxGreen))
	r := e.finalizeGIF(t, tg)
	if r.Status != StatusRejected || r.RejectionReason != reasonInvalid || e.repo.vision[monthKey(testNow)] != 0 {
		t.Fatalf("result = %+v", r)
	}
	// An Error-Reporting-shaped ERROR entry (mw.ReportError) naming the operation, with a stack, and no uid.
	var found bool
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) != nil || rec["level"] != "ERROR" {
			continue
		}
		found = true
		if rec["rpc"] != gifSheetOp || !strings.Contains(fmt.Sprint(rec["@type"]), "ReportedErrorEvent") || rec["stack_trace"] == "" {
			t.Fatalf("error record = %v", rec)
		}
	}
	if !found {
		t.Fatalf("no ERROR record in %q", logs.String())
	}
	if strings.Contains(logs.String(), uidA) {
		t.Fatalf("the report must not carry the uid: %s", logs.String())
	}
}

func TestGIFScreen_ObjectChangedAfterVerifyIsRejected(t *testing.T) {
	// The full object is read again for the sheet; bytes that differ from the MD5 verify approved are not sampled.
	swap := &swapObjects{swap: colourGIF(pxRed, pxRed)}
	e := newEnv(t, envOpts{objects: func(f *fakeObjects) Objects { swap.fakeObjects = f; return swap }})
	tg := e.createGIFWith(t, uidA, "a", colourGIF(pxWhite, pxGreen))
	swap.name = uploadObject(uidA, tg.MediaID, "gif")
	if r := e.finalizeGIF(t, tg); r.Status != StatusRejected || r.RejectionReason != reasonInvalid || len(e.mod.byteCalls) != 0 {
		t.Fatalf("result = %+v", r)
	}
}

// swapObjects answers the full-object read of name with different bytes than the ones verify approved.
type swapObjects struct {
	*fakeObjects
	name string
	swap []byte
}

func (s *swapObjects) UploadHead(ctx context.Context, object string, n, generation int64) ([]byte, error) {
	if n != 512 && object == s.name {
		return s.swap, nil
	}
	return s.fakeObjects.UploadHead(ctx, object, n, generation)
}

func TestGIFScreen_MissingObjectIsNotARejection(t *testing.T) {
	// A read error is an infrastructure failure: the client retries (UNAVAILABLE), nothing is spent or rejected.
	e := newEnv(t, envOpts{objects: func(f *fakeObjects) Objects { return failingRead{f} }})
	tg := e.createGIFWith(t, uidA, "a", colourGIF(pxWhite, pxGreen))
	_, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err == nil || e.repo.vision[monthKey(testNow)] != 0 {
		t.Fatalf("err = %v", err)
	}
	if d := e.repo.docs[tg.MediaID]; d.Status != string(StatusPending) {
		t.Fatalf("doc = %+v", d)
	}
}

// failingRead removes the GIF just before the pinned full read, the real path of a vanished object: the store answers 404
// (ErrObjectNotFound, not ErrGenerationChanged), which is a retryable infrastructure error, not a rejection.
type failingRead struct{ *fakeObjects }

func (f failingRead) UploadHead(ctx context.Context, object string, n, generation int64) ([]byte, error) {
	if n != 512 {
		f.mu.Lock()
		delete(f.upload, object)
		f.mu.Unlock()
	}
	return f.fakeObjects.UploadHead(ctx, object, n, generation)
}
