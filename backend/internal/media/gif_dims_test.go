package media

import (
	"context"
	"testing"
)

// Task 13: verify reads a GIF's logical screen size (header bytes 6-9, little-endian) from the same pinned 512-byte head
// read and refuses a GIF whose size is not the declared one, before any Vision unit is charged. The still thumbnail
// (JPEG or WebP) keeps the B14 thumbnail rule.

// gifHeader is the first bytes of a GIF of sig ("GIF87a" / "GIF89a") whose logical screen is w x h.
func gifHeader(sig string, w, h int) []byte {
	return append([]byte(sig), byte(w), byte(w>>8), byte(h), byte(h>>8), 0, 0, 0)
}

func TestGIFDims(t *testing.T) {
	tests := []struct {
		name   string
		in     []byte
		w, h   int
		wantOK bool
	}{
		{"encoded GIF", gifSized("x", 320, 240), 320, 240, true},
		{"one-pixel GIF", gifSized("x", 1, 1), 1, 1, true},
		{"GIF87a header", gifHeader("GIF87a", 1200, 800), 1200, 800, true},
		{"little-endian high bytes", gifHeader("GIF89a", 0x0102, 0x0304), 0x0102, 0x0304, true},
		{"largest 16-bit edge (geometryOK bounds it)", gifHeader("GIF89a", 65535, 1), 65535, 1, true},
		{"zero width", gifHeader("GIF89a", 0, 10), 0, 0, false},
		{"zero height", gifHeader("GIF89a", 10, 0), 0, 0, false},
		{"header cut before the height", gifHeader("GIF89a", 10, 10)[:9], 0, 0, false},
		{"signature only", []byte("GIF89a"), 0, 0, false},
		{"not a GIF", jpegBytes("x"), 0, 0, false},
		{"bad version", gifHeader("GIF88a", 10, 10), 0, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w, h, ok := gifDims(tt.in)
			if ok != tt.wantOK || w != tt.w || h != tt.h {
				t.Fatalf("gifDims = %d x %d, %v; want %d x %d, %v", w, h, ok, tt.w, tt.h, tt.wantOK)
			}
			if gw, gh, gok := imageDims(ContentTypeGIF, tt.in); gw != w || gh != h || gok != ok {
				t.Fatalf("imageDims(gif) = %d x %d, %v; want gifDims' answer", gw, gh, gok)
			}
		})
	}
}

// The GIF read for the size is the bounded head verify already makes; the logical screen lies in its first 10 bytes.
func TestGIFDims_BoundedHead(t *testing.T) {
	if n := headBytesFor(ContentTypeGIF); n != 512 {
		t.Fatalf("GIF head read = %d bytes, want the 512-byte sniff read", n)
	}
}

// The full GIF's real size is held to MaxDimension on each side (CreateUpload's GIF_MAX_EDGE keeps a declaration far
// below it, so geometryOK's bound is tested directly).
func TestGIFGeometry_MaxDimension(t *testing.T) {
	tests := []struct {
		name string
		w, h int
		want bool
	}{
		{"declared size", 1200, 800, true},
		{"wider than MaxDimension", MaxDimension + 1, 800, false},
		{"taller than MaxDimension", 1200, MaxDimension + 1, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			d := &Doc{Purpose: string(PurposePost), ContentType: ContentTypeGIF, Width: tt.w, Height: tt.h}
			if got := geometryOK(d, true, tt.w, tt.h); got != tt.want {
				t.Fatalf("geometryOK(%d x %d) = %v, want %v", tt.w, tt.h, got, tt.want)
			}
		})
	}
}

func TestGIF_FinalizeChecksLogicalScreen(t *testing.T) {
	tests := []struct {
		name      string
		dw, dh    int // declared
		full      []byte
		thumb     []byte
		wantReady bool
	}{
		{"declared equals the logical screen", 320, 240, gifSized("F", 320, 240), jpegSized("T", 320, 240), true},
		{"small GIF, thumbnail smaller still", 40, 30, gifSized("F", 40, 30), jpegSized("T", 20, 15), true},
		{"8x8 GIF declared 1200 x 800", 1200, 800, gifSized("F", 8, 8), jpegSized("T", 8, 8), false},
		{"width differs only", 320, 240, gifSized("F", 321, 240), jpegSized("T", 320, 240), false},
		{"height differs only", 320, 240, gifSized("F", 320, 239), jpegSized("T", 320, 240), false},
		{"transposed", 240, 320, gifSized("F", 320, 240), jpegSized("T", 240, 320), false},
		{"thumbnail larger than the GIF", 320, 240, gifSized("F", 320, 240), jpegSized("T", 321, 240), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			it := gifItem(tt.full, tt.thumb, ContentTypeJPEG)
			it.Width, it.Height = tt.dw, tt.dh
			tgs, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
				IdempotencyKey: "key-gd-0123456789", Purpose: PurposePost, Items: []UploadItem{it},
			})
			if err != nil {
				t.Fatal(err)
			}
			e.putGIF(uidA, tgs[0], tt.full, tt.thumb, ContentTypeJPEG)
			r, err := e.finalizeErr(t, tgs[0].MediaID)
			if err != nil {
				t.Fatal(err)
			}
			if tt.wantReady {
				if r.Status != StatusReady || r.Ref.Width != tt.dw || r.Ref.Height != tt.dh {
					t.Fatalf("result = %+v, want READY %d x %d", r, tt.dw, tt.dh)
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
