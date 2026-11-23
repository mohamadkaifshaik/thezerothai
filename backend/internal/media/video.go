package media

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/draw"
	"image/jpeg"
	"math"

	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"codeberg.org/gruf/go-ffmpreg/embed"
	"codeberg.org/gruf/go-ffmpreg/wasm"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
	"github.com/tetratelabs/wazero"
)

// Compile once, only when video is used. Each invocation gets fresh bounded
// linear memory, a cancellation deadline, and one read-only input directory.
type videoDecoder struct {
	runtime wazero.Runtime
	module  wazero.CompiledModule
}

var loadVideoDecoder = sync.OnceValues(func() (*videoDecoder, error) {
	ctx := context.Background()
	rt, err := wasm.NewRuntime(ctx, wazero.NewRuntimeConfig().WithMemoryLimitPages(2048).WithCloseOnContextDone(true))
	if err != nil {
		return nil, err
	}
	module, err := rt.CompileModule(ctx, embed.B())
	if err != nil {
		_ = rt.Close(ctx)
		return nil, err
	}
	embed.Free()
	return &videoDecoder{rt, module}, nil
})

func (v *videoDecoder) run(ctx context.Context, dir, name string, args ...string) ([]byte, error) {
	var out bytes.Buffer
	rc, err := wasm.Run(ctx, v.runtime, v.module, wasm.Args{Name: name, Args: args, Stdout: &out, Config: func(cfg wazero.ModuleConfig) wazero.ModuleConfig {
		return cfg.WithFSConfig(wazero.NewFSConfig().WithReadOnlyDirMount(dir, "/"))
	}})
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil || rc != 0 {
		return nil, refuseInvalid("video_decode")
	}
	return out.Bytes(), nil
}

// videoSampleCount returns zero for durations outside the post limits.
func videoSampleCount(seconds float64) int {
	if !(seconds > 0 && seconds <= (5*time.Minute).Seconds()) {
		return 0
	}
	return max(4, int(math.Ceil(seconds/20)))
}

func videoSheet(ctx context.Context, dir string, d *Doc) ([]byte, error) {
	decoder, err := loadVideoDecoder()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	raw, err := decoder.run(ctx, dir, "ffprobe", "-v", "error", "-f", "mov", "-show_entries", "stream=codec_name,codec_type,width,height:stream_side_data=rotation:format=duration", "-of", "json", "/clip.mp4")
	if err != nil {
		return nil, err
	}
	var probe struct {
		Streams []struct {
			Codec         string `json:"codec_name"`
			Kind          string `json:"codec_type"`
			Width, Height int
			Side          []struct{ Rotation int } `json:"side_data_list"`
		}
		Format struct{ Duration string }
	}
	if json.Unmarshal(raw, &probe) != nil {
		return nil, refuseInvalid("video_metadata")
	}
	duration, err := strconv.ParseFloat(probe.Format.Duration, 64)
	samples := videoSampleCount(duration)
	if err != nil || samples == 0 {
		return nil, refuseInvalid("video_duration")
	}
	videos, audios := 0, 0
	for _, s := range probe.Streams {
		switch s.Kind {
		case "video":
			videos++
			w, h := s.Width, s.Height
			for _, side := range s.Side {
				if side.Rotation%180 != 0 {
					w, h = h, w
					break
				}
			}
			if s.Codec != "h264" || !geometryOK(d, true, w, h) {
				return nil, refuseInvalid("video_format")
			}
		case "audio":
			audios++
			if s.Codec != "aac" {
				return nil, refuseInvalid("audio_format")
			}
		default:
			return nil, refuseInvalid("video_tracks")
		}
	}
	if videos != 1 || audios > 1 {
		return nil, refuseInvalid("video_tracks")
	}
	// Scale the number of sampled frames with clip length, retaining one bounded contact sheet.
	cols := int(math.Ceil(math.Sqrt(float64(samples))))
	rows := (samples + cols - 1) / cols
	sheet := image.NewRGBA(image.Rect(0, 0, cols*320, rows*240))
	for i := 0; i < samples; i++ {
		pos := fmt.Sprintf("%.6f", duration*float64(i)/float64(samples))
		frame, err := decoder.run(ctx, dir, "ffmpeg", "-v", "error", "-ss", pos, "-f", "mov", "-i", "/clip.mp4", "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=320:240:force_original_aspect_ratio=decrease", "-f", "image2pipe", "-c:v", "mjpeg", "pipe:1")
		if err != nil {
			return nil, err
		}
		img, err := jpeg.Decode(bytes.NewReader(frame))
		if err != nil {
			return nil, refuseInvalid("video_frame")
		}
		start := image.Pt(i%cols*320, i/cols*240)
		draw.Draw(sheet, img.Bounds().Add(start), img, image.Point{}, draw.Src)
	}
	var out bytes.Buffer
	err = jpeg.Encode(&out, sheet, nil)
	return out.Bytes(), err
}

func (s *service) screenVideo(ctx context.Context, d *Doc, gens verifiedGens, release func()) (screenResult, error) {
	dir, err := os.MkdirTemp("", "clip-")
	if err != nil {
		return screenResult{refundable: 2}, err
	}
	defer os.RemoveAll(dir)
	f, err := os.OpenFile(filepath.Join(dir, "clip.mp4"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return screenResult{refundable: 2}, err
	}
	written, err := s.Objects.WriteUploadTo(ctx, d.UploadPath, d.Bytes, gens.full, f)
	closeErr := f.Close()
	if errors.Is(err, objstore.ErrGenerationChanged) {
		err = refuseInvalid("video_changed")
	}
	if err != nil {
		return screenResult{refundable: 2}, err
	}
	if closeErr != nil {
		return screenResult{refundable: 2}, closeErr
	}
	if written != d.Bytes {
		return screenResult{refundable: 2}, refuseInvalid("video_size")
	}
	sheet, err := videoSheet(ctx, dir, d)
	release()
	if err != nil {
		return screenResult{refundable: 2}, err
	}
	return s.screenAll(ctx, d, []func(context.Context) (SafeSearch, error){
		func(c context.Context) (SafeSearch, error) { return s.Moderator.SafeSearchBytes(c, sheet) },
		func(c context.Context) (SafeSearch, error) { return s.Moderator.SafeSearch(c, d.ThumbUploadPath) },
	})
}
