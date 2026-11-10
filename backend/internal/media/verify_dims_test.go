package media

import (
	"bytes"
	"context"
	"encoding/base64"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"
)

// B14: verify reads the real pixel size of a JPEG or WebP from its pinned head and refuses an image whose size is not the
// declared one (or breaks MaxDimension, MaxPixels or the purpose geometry) before any Vision unit is charged.

// clientFixture loads a JPEG made by the official client's encoder. The testdata/*.jpg.b64 files are base64 because
// backend/**/testdata/** is checked out as text (eol=lf), which would corrupt raw JPEG bytes. They were produced by
// package:image 4.12.0 the way app/lib/features/media/domain/image_processor.dart does it: exif.clear(), then
// encodeJpg (quality 85 for a full image, 70 for a thumbnail).
func clientFixture(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name+".b64"))
	if err != nil {
		t.Fatal(err)
	}
	b, err := base64.StdEncoding.DecodeString(string(bytes.ReplaceAll(bytes.ReplaceAll(raw, []byte("\r"), nil), []byte("\n"), nil)))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// stdJPEG is a real JPEG of w x h from image/jpeg (no JFIF APP0, so DecodeConfig reads on to the SOS).
func stdJPEG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for i := range img.Pix {
		img.Pix[i] = byte(i)
	}
	img.Set(0, 0, color.White)
	var b bytes.Buffer
	if err := jpeg.Encode(&b, img, nil); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// withAPP inserts APPn segments of the given payload sizes right after the SOI, as a camera's EXIF/ICC block would be.
func withAPP(jpg []byte, sizes ...int) []byte {
	out := append([]byte{}, jpg[:2]...)
	for _, n := range sizes {
		out = append(out, jpegSegment(0xE1, make([]byte, n))...)
	}
	return append(out, jpg[2:]...)
}

func vp8xCanvas(flags byte, w, h int) []byte {
	p := make([]byte, 10)
	p[0] = flags
	cw, ch := w-1, h-1
	p[4], p[5], p[6] = byte(cw), byte(cw>>8), byte(cw>>16)
	p[7], p[8], p[9] = byte(ch), byte(ch>>8), byte(ch>>16)
	return chunk("VP8X", p)
}

func TestB14_JpegDims(t *testing.T) {
	tests := []struct {
		name   string
		in     []byte
		w, h   int
		wantOK bool
	}{
		{"client post", clientFixture(t, "client-post-160x120.jpg"), 160, 120, true},
		{"client thumb", clientFixture(t, "client-thumb-40x30.jpg"), 40, 30, true},
		{"image/jpeg without JFIF", stdJPEG(t, 33, 17), 33, 17, true},
		{"header fixture", jpegSized("x", 1200, 800), 1200, 800, true},
		{"a 60 KiB EXIF before the SOF", withAPP(stdJPEG(t, 20, 10), 60000), 20, 10, true},
		{"magic bytes only", []byte{0xFF, 0xD8, 0xFF, 0xE0}, 0, 0, false},
		{"zero width", jpegSized("x", 0, 800), 0, 0, false},
		{"no SOF before SOS", append([]byte{0xFF, 0xD8}, jpegSegment(0xDA, []byte{0})...), 0, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w, h, ok := jpegDims(tt.in)
			if ok != tt.wantOK || w != tt.w || h != tt.h {
				t.Fatalf("jpegDims = %d x %d, %v; want %d x %d, %v", w, h, ok, tt.w, tt.h, tt.wantOK)
			}
		})
	}
	t.Run("SOF beyond the head read", func(t *testing.T) {
		jpg := withAPP(stdJPEG(t, 20, 10), 65000, 65000) // ~127 KiB of APP1 before the SOF
		head := jpg[:jpegHeadBytes]
		if _, _, ok := jpegDims(head); ok {
			t.Fatal("a SOF past the bound must be refused")
		}
		if w, h, ok := jpegDims(jpg); !ok || w != 20 || h != 10 {
			t.Fatalf("the whole file reads %d x %d, %v (the fixture itself must be valid)", w, h, ok)
		}
	})
}

func TestB14_WebpDims(t *testing.T) {
	big := make([]byte, 5000)
	tests := []struct {
		name   string
		in     []byte
		w, h   int
		wantOK bool
	}{
		{"lossy", webpSized("x", 1200, 800), 1200, 800, true},
		{"lossy max 14-bit", webpSized("x", 16383, 1), 16383, 1, true},
		{"lossless", riff(chunk("VP8L", vp8lHeader(1500, 500))), 1500, 500, true},
		{"lossless 1x1", riff(chunk("VP8L", vp8lHeader(1, 1))), 1, 1, true},
		{"extended, canvas equals the image", riff(vp8xCanvas(0x30, 600, 200), chunk("ICCP", big), chunk("VP8 ", vp8Frame(600, 200))), 600, 200, true},
		{"extended lossless", riff(vp8xCanvas(0x10, 40, 30), chunk("ALPH", []byte("ab")), chunk("VP8L", vp8lHeader(40, 30))), 40, 30, true},
		{"extended, canvas differs from the image", riff(vp8xCanvas(0, 1200, 800), chunk("VP8 ", vp8Frame(10, 10))), 0, 0, false},
		{"lossy interframe", riff(chunk("VP8 ", append([]byte{0x11}, vp8Frame(10, 10)[1:]...))), 0, 0, false},
		{"lossy bad start code", riff(chunk("VP8 ", []byte{0x10, 0, 0, 0x9d, 0x01, 0x2b, 10, 0, 10, 0})), 0, 0, false},
		{"lossy zero width", webpSized("x", 0, 10), 0, 0, false},
		{"lossy header truncated", riff(chunk("VP8 ", vp8Frame(10, 10)[:9])), 0, 0, false},
		{"lossless bad signature", riff(chunk("VP8L", append([]byte{0x2e}, vp8lHeader(10, 10)[1:]...))), 0, 0, false},
		{"lossless version not 0", riff(chunk("VP8L", []byte{0x2f, 0, 0, 0, 0x20})), 0, 0, false},
		{"lossless header truncated", riff(chunk("VP8L", vp8lHeader(10, 10)[:4])), 0, 0, false},
		{"image chunk header cut by the read", riff(chunk("VP8 ", vp8Frame(10, 10)))[:16], 0, 0, false},
		{"animated", animatedWebP(), 0, 0, false},
		{"no image chunk in the read", riff(vp8xCanvas(0, 10, 10), chunk("ICCP", make([]byte, webpHeadBytes))), 0, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			head := tt.in
			if len(head) > webpHeadBytes {
				head = head[:webpHeadBytes]
			}
			w, h, ok := webpDims(head)
			if ok != tt.wantOK || w != tt.w || h != tt.h {
				t.Fatalf("webpDims = %d x %d, %v; want %d x %d, %v", w, h, ok, tt.w, tt.h, tt.wantOK)
			}
		})
	}
}

// createDims runs CreateUpload for one item of the declared size and PUTs full and thumb; ct is both objects' type.
func (e *env) createDims(t *testing.T, purpose Purpose, tag, ct string, w, h int, full, thumb []byte) UploadTarget {
	t.Helper()
	it := item(full, thumb, ct)
	it.Width, it.Height = w, h
	tgs, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: "key-" + tag + "-0123456789", Purpose: purpose, Items: []UploadItem{it},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.put(uidA, tgs[0], full, thumb, ct)
	return tgs[0]
}

func TestB14_FinalizeChecksRealDimensions(t *testing.T) {
	type upload struct {
		purpose     Purpose
		ct          string
		w, h        int
		full, thumb func(t *testing.T) []byte
	}
	fixed := func(b []byte) func(*testing.T) []byte { return func(*testing.T) []byte { return b } }
	fixture := func(name string) func(*testing.T) []byte {
		return func(t *testing.T) []byte { return clientFixture(t, name) }
	}
	tests := []struct {
		name      string
		up        upload
		wantReady bool
	}{
		// The official client declares exactly what it encoded.
		{"client post JPEG", upload{PurposePost, ContentTypeJPEG, 160, 120, fixture("client-post-160x120.jpg"), fixture("client-thumb-40x30.jpg")}, true},
		{"client small post whose thumb is the photo itself", upload{PurposePost, ContentTypeJPEG, 40, 30, fixture("client-thumb-40x30.jpg"), fixture("client-thumb-40x30.jpg")}, true},
		{"client banner JPEG", upload{PurposeBanner, ContentTypeJPEG, 150, 50, fixture("client-banner-150x50.jpg"), fixture("client-banner-thumb-60x20.jpg")}, true},
		{"client avatar JPEG", upload{PurposeAvatar, ContentTypeJPEG, 40, 30, fixture("client-thumb-40x30.jpg"), fixture("client-thumb-40x30.jpg")}, true},
		{"WebP post", upload{PurposePost, ContentTypeWebP, 1200, 800, fixed(webpSized("F", 1200, 800)), fixed(riff(chunk("VP8L", vp8lHeader(400, 267))))}, true},
		{"WebP banner", upload{PurposeBanner, ContentTypeWebP, 1500, 500, fixed(webpSized("F", 1500, 500)), fixed(webpSized("T", 600, 200))}, true},

		// Declared and real size disagree.
		{"JPEG declared larger than it is", upload{PurposePost, ContentTypeJPEG, 1200, 800, fixture("client-post-160x120.jpg"), fixture("client-thumb-40x30.jpg")}, false},
		{"JPEG declared transposed", upload{PurposePost, ContentTypeJPEG, 120, 160, fixture("client-post-160x120.jpg"), fixture("client-thumb-40x30.jpg")}, false},
		{"WebP real size beyond MaxDimension", upload{PurposePost, ContentTypeWebP, 1200, 800, fixed(webpSized("F", 16000, 800)), fixed(webpSized("T", 400, 267))}, false},
		{"lossless WebP declared smaller than it is", upload{PurposePost, ContentTypeWebP, 400, 300, fixed(riff(chunk("VP8L", vp8lHeader(4000, 3000)))), fixed(webpSized("T", 400, 300))}, false},
		{"magic bytes only, no size", upload{PurposePost, ContentTypeJPEG, 1200, 800, fixed([]byte{0xFF, 0xD8, 0xFF, 0xE0, 'x'}), fixed(jpegBytes("T"))}, false},
		{"JPEG whose SOF is past the 64 KiB read", upload{PurposePost, ContentTypeJPEG, 20, 10, func(t *testing.T) []byte { return withAPP(stdJPEG(t, 20, 10), 65000, 65000) }, fixed(jpegSized("T", 20, 10))}, false},

		// The thumbnail: no declared size, but never larger than the full image and, for a banner, 3:1.
		{"thumbnail larger than the full image", upload{PurposePost, ContentTypeJPEG, 160, 120, fixture("client-post-160x120.jpg"), fixed(jpegSized("T", 1200, 800))}, false},
		{"thumbnail beyond MaxDimension", upload{PurposePost, ContentTypeWebP, 1200, 800, fixed(webpSized("F", 1200, 800)), fixed(webpSized("T", 5000, 10))}, false},
		{"banner thumbnail that is not 3:1", upload{PurposeBanner, ContentTypeJPEG, 150, 50, fixture("client-banner-150x50.jpg"), fixture("client-thumb-40x30.jpg")}, false},
		{"banner thumbnail that is unreadable", upload{PurposeBanner, ContentTypeWebP, 1500, 500, fixed(webpSized("F", 1500, 500)), fixed(riff(chunk("VP8 ", []byte("pixels!!"))))}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{screenThumb: true})
			tg := e.createDims(t, tt.up.purpose, "d", tt.up.ct, tt.up.w, tt.up.h, tt.up.full(t), tt.up.thumb(t))
			r, err := e.finalizeErr(t, tg.MediaID)
			if err != nil {
				t.Fatal(err)
			}
			if tt.wantReady {
				if r.Status != StatusReady || r.Ref.Width != tt.up.w || r.Ref.Height != tt.up.h {
					t.Fatalf("result = %+v, want READY %d x %d", r, tt.up.w, tt.up.h)
				}
				return
			}
			if r.Status != StatusRejected || r.RejectionReason != reasonInvalid {
				t.Fatalf("result = %+v, want REJECTED invalid", r)
			}
			if got := e.units(); got != 0 || len(e.mod.calls) != 0 {
				t.Fatalf("vision units = %d calls = %v, want none before a size rejection", got, e.mod.calls)
			}
		})
	}
}

// A GIF's own size is checked by the GIF scan; its client-made still thumbnail is a JPEG or WebP and gets the thumbnail
// rule here: no larger than the GIF.
func TestB14_GIFThumbnailNoLargerThanTheGIF(t *testing.T) {
	e := newEnv(t, envOpts{})
	full, thumb := gifBytes("Fg"), jpegSized("Tg", 1201, 800) // item() declares 1200 x 800
	tgs, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: "key-g-0123456789", Purpose: PurposePost, Items: []UploadItem{gifItem(full, thumb, ContentTypeJPEG)},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.putGIF(uidA, tgs[0], full, thumb, ContentTypeJPEG)
	r, err := e.finalizeErr(t, tgs[0].MediaID)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status != StatusRejected || r.RejectionReason != reasonInvalid {
		t.Fatalf("result = %+v, want REJECTED invalid", r)
	}
	if got := e.units(); got != 0 || len(e.mod.calls) != 0 {
		t.Fatalf("vision units = %d calls = %v, want none", got, e.mod.calls)
	}
}
