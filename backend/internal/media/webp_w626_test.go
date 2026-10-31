package media

import (
	"context"
	"encoding/binary"
	"testing"
)

// W6-26 (security H-2): an animated WebP is refused for photos, avatars, banners and GIF thumbnails, with no Vision unit.

func chunk(id string, payload []byte) []byte {
	b := append([]byte(id), 0, 0, 0, 0)
	binary.LittleEndian.PutUint32(b[4:], uint32(len(payload)))
	b = append(b, payload...)
	if len(payload)%2 == 1 {
		b = append(b, 0)
	}
	return b
}

func riff(chunks ...[]byte) []byte {
	b := []byte("RIFF\x00\x00\x00\x00WEBP")
	for _, c := range chunks {
		b = append(b, c...)
	}
	return b
}

func vp8x(flags byte) []byte {
	p := make([]byte, 10)
	p[0] = flags
	return chunk("VP8X", p)
}

func TestW626_WebpIsStill(t *testing.T) {
	big := make([]byte, 5000)
	tests := []struct {
		name string
		in   []byte
		want bool
	}{
		{"lossy simple", riff(chunk("VP8 ", []byte("data1234"))), true},
		{"lossless simple", riff(chunk("VP8L", []byte("data1234"))), true},
		{"extended still with ICCP and ALPH", riff(vp8x(0x30), chunk("ICCP", big), chunk("ALPH", []byte("ab")), chunk("VP8 ", []byte("d"))), true},
		{"animation flag set", riff(vp8x(0x02), chunk("ANIM", make([]byte, 6)), chunk("ANMF", make([]byte, 16))), false},
		{"animation flag set, nothing after", riff(vp8x(0x02)), false},
		{"ANIM without the flag", riff(vp8x(0x00), chunk("ANIM", make([]byte, 6))), false},
		{"ANMF without the flag", riff(vp8x(0x00), chunk("ANMF", make([]byte, 16))), false},
		{"ANIM after a large EXIF chunk, flag clear", riff(vp8x(0x00), chunk("EXIF", big), chunk("ANIM", make([]byte, 6))), false},
		{"ANIM after a large ICCP chunk, flag set", riff(vp8x(0x22), chunk("ICCP", big), chunk("ANIM", make([]byte, 6))), false},
		{"VP8X still whose image data is beyond the read", riff(vp8x(0x00), chunk("ICCP", make([]byte, webpHeadBytes))), false},
		{"truncated after the RIFF header", []byte("RIFF\x00\x00\x00\x00WEBP"), false},
		{"truncated inside VP8X", riff(vp8x(0x00))[:20], false},
		{"unknown first chunk", riff(chunk("JUNK", []byte("xx"))), false},
		{"oversized chunk length", riff(vp8x(0), append([]byte("EXIF"), 0xff, 0xff, 0xff, 0xff)), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := webpIsStill(tt.in); got != tt.want {
				t.Fatalf("webpIsStill = %v, want %v", got, tt.want)
			}
		})
	}
}

func animatedWebP() []byte {
	return riff(vp8x(0x02), chunk("ANIM", make([]byte, 6)), chunk("ANMF", make([]byte, 16)))
}

func stillWebP(kind string) []byte {
	if kind == "lossless" {
		return riff(chunk("VP8L", []byte("pixels!!")))
	}
	return riff(chunk("VP8 ", []byte("pixels!!")))
}

func (e *env) createWebP(t *testing.T, purpose Purpose, tag string, full, thumb []byte) UploadTarget {
	t.Helper()
	it := item(full, thumb, ContentTypeWebP)
	if purpose == PurposeBanner {
		it.Width, it.Height = 1500, 500
	}
	if purpose == PurposeAvatar {
		it.Width, it.Height = 400, 400
	}
	tgs, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: "key-" + tag + "-0123456789", Purpose: purpose, Items: []UploadItem{it},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.put(uidA, tgs[0], full, thumb, ContentTypeWebP)
	return tgs[0]
}

func TestW626_FinalizeRefusesAnimatedWebP(t *testing.T) {
	for _, purpose := range []Purpose{PurposePost, PurposeAvatar, PurposeBanner} {
		for _, side := range []string{"full", "thumb"} {
			t.Run(string(purpose)+"/"+side, func(t *testing.T) {
				e := newEnv(t, envOpts{screenThumb: true})
				full, thumb := stillWebP("lossy"), stillWebP("lossless")
				if side == "full" {
					full = animatedWebP()
				} else {
					thumb = animatedWebP()
				}
				tg := e.createWebP(t, purpose, "a"+side, full, thumb)
				r, err := e.finalizeErr(t, tg.MediaID)
				if err != nil {
					t.Fatal(err)
				}
				if r.Status != StatusRejected || r.RejectionReason != reasonInvalid {
					t.Fatalf("result = %+v, want REJECTED invalid", r)
				}
				if got := e.units(); got != 0 {
					t.Fatalf("vision units = %d, want 0", got)
				}
				if len(e.mod.calls) != 0 {
					t.Fatalf("vision calls = %v, want none", e.mod.calls)
				}
			})
		}
	}
}

func TestW626_FinalizeRefusesAnimatedGIFThumbnail(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.createGIF(t, uidA, "g", ContentTypeWebP)
	d := e.repo.docs[tg.MediaID]
	th := e.obj.upload[d.ThumbUploadPath]
	th.data = animatedWebP()
	e.obj.upload[d.ThumbUploadPath] = th
	r, err := e.finalizeErr(t, tg.MediaID)
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

func TestW626_StillWebPStillPasses(t *testing.T) {
	for _, kind := range []string{"lossy", "lossless"} {
		for _, purpose := range []Purpose{PurposePost, PurposeAvatar, PurposeBanner} {
			t.Run(kind+"/"+string(purpose), func(t *testing.T) {
				e := newEnv(t, envOpts{})
				tg := e.createWebP(t, purpose, "s", stillWebP(kind), stillWebP(kind))
				r, err := e.finalizeErr(t, tg.MediaID)
				if err != nil {
					t.Fatal(err)
				}
				if r.Status != StatusReady {
					t.Fatalf("result = %+v, want READY", r)
				}
			})
		}
	}
}
