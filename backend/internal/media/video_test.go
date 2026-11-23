package media

import (
	"bytes"
	"context"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"
)

// blue-clip.mp4 is one second of synthetic blue H.264 video, 64x48 at 8 fps.
func TestVideoScreeningFrames(t *testing.T) {
	clip, err := os.ReadFile("testdata/blue-clip.mp4")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "clip.mp4")
	if err = os.WriteFile(path, clip, 0600); err != nil {
		t.Fatal(err)
	}
	sheet, err := videoSheet(context.Background(), dir, &Doc{Width: 64, Height: 48})
	if err != nil {
		t.Fatal(err)
	}
	img, err := jpeg.Decode(bytes.NewReader(sheet))
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range []int{160, 480} {
		for _, y := range []int{120, 360} {
			r, g, b, _ := img.At(x, y).RGBA()
			if b < 50000 || r > 10000 || g > 10000 {
				t.Fatalf("no blue sample at %d,%d", x, y)
			}
		}
	}
	if _, err = videoSheet(context.Background(), dir, &Doc{Width: 48, Height: 64}); err == nil {
		t.Fatal("accepted incorrect declared dimensions")
	}
	if err = os.WriteFile(path, clip[:24], 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = videoSheet(context.Background(), dir, &Doc{Width: 64, Height: 48}); err == nil {
		t.Fatal("accepted truncated MP4")
	}
}

func TestPostVideoPublication(t *testing.T) {
	clip, err := os.ReadFile("testdata/blue-clip.mp4")
	if err != nil {
		t.Fatal(err)
	}
	for _, blocked := range []bool{false, true} {
		e := newEnv(t, envOpts{})
		poster := jpegSized("poster", 32, 24)
		it := item(clip, poster, ContentTypeMP4)
		it.Width, it.Height, it.ThumbContentType = 64, 48, ContentTypeJPEG
		ctx := context.Background()
		targets, err := e.svc.CreateUpload(ctx, uidA, CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{it}})
		if err != nil {
			t.Fatal(err)
		}
		id := targets[0].MediaID
		fullPath, thumbPath := uploadObject(uidA, id, "mp4"), uploadThumbObject(uidA, id, "jpg")
		e.obj.upload[fullPath] = fakeObject{data: clip, contentType: ContentTypeMP4}
		e.obj.upload[thumbPath] = fakeObject{data: poster, contentType: ContentTypeJPEG}
		if blocked {
			e.mod.by[thumbPath] = SafeSearch{Adult: LikelihoodVeryLikely}
		}
		results, err := e.svc.FinalizeUpload(ctx, uidA, []FinalizeItem{{MediaID: id}})
		if err != nil {
			t.Fatal(err)
		}
		if len(e.mod.byteCalls) != 1 {
			t.Fatal("missing frame screening")
		}
		if blocked {
			if results[0].Status != StatusRejected || len(e.obj.public) != 0 {
				t.Fatalf("blocked clip published: %+v", results)
			}
		} else if results[0].Status != StatusReady || results[0].Ref.ContentType != ContentTypeMP4 || len(e.obj.public) != 2 {
			t.Fatalf("clip publication: %+v", results)
		}
	}
}

// The generated clip is five minutes of synthetic H.264 video at one frame per second.
func TestFiveMinuteVideo(t *testing.T) {
	dir := t.TempDir()
	clip, err := os.ReadFile("testdata/five-minute-clip.mp4")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(dir, "clip.mp4"), clip, 0600); err != nil {
		t.Fatal(err)
	}
	sheet, err := videoSheet(context.Background(), dir, &Doc{Width: 64, Height: 48})
	if err != nil {
		t.Fatal(err)
	}
	img, err := jpeg.Decode(bytes.NewReader(sheet))
	if err != nil {
		t.Fatal(err)
	}
	for i := range 15 {
		r, g, b, _ := img.At(i%4*320+160, i/4*240+120).RGBA()
		if b < 50000 || r > 10000 || g > 10000 {
			t.Fatalf("missing sample %d", i)
		}
	}
}

func TestPostVideoDurationLimits(t *testing.T) {
	for _, tc := range []struct {
		seconds float64
		want    int
	}{{0, 0}, {0.1, 4}, {120, 6}, {300, 15}, {300.001, 0}} {
		if got := videoSampleCount(tc.seconds); got != tc.want {
			t.Errorf("%g seconds: got %d samples, want %d", tc.seconds, got, tc.want)
		}
	}
}
