package media

import (
	"context"
	"errors"
	"image"
	"image/color"
	"testing"
	"time"
)

// W6-28 (security M-2): the last frame is always one of the sampled frames. A GIF without a loop block, or with a finite
// loop count, plays once and then rests on its last frame, so an animation must not be able to hide its payload there.

// TestW628_OnlyTheLastFrameIsExplicit: whatever the length, a GIF whose only unsafe content is its final frame (even with
// a 2 cs delay, no clamp) is REJECTED, the last frame is the final tile of the sheet, and the Vision spend is unchanged
// at 2 units (the sheet and the thumbnail).
func TestW628_OnlyTheLastFrameIsExplicit(t *testing.T) {
	for _, n := range []int{1, 2, 3, 4, 5, 8, 41, 120} {
		t.Run(itoa(n)+" frames", func(t *testing.T) {
			idxs := repeatIdx(n, pxGreen)
			delays := repeatInt(n, 10)
			idxs[n-1], delays[n-1] = pxRed, 2
			e := newEnv(t, envOpts{})
			e.mod.bytesBy = redIsExplicit(t)
			r := e.finalizeGIF(t, e.createGIFWith(t, uidA, "a", timedGIF(idxs, delays)))
			if r.Status != StatusRejected || r.RejectionReason != reasonPolicy {
				t.Fatalf("result = %+v, want REJECTED %q", r, reasonPolicy)
			}
			if len(e.mod.byteCalls) != 1 {
				t.Fatalf("sheet calls = %d", len(e.mod.byteCalls))
			}
			cells := sheetCells(t, e.mod.byteCalls[0]) // a 3-tile sheet has a black 4th cell
			tiles := min(n, 4)
			if len(cells) < tiles || !isRed(cells[tiles-1]) {
				t.Fatalf("cells = %v, want %d tiles with the last one red", cells, tiles)
			}
			for _, c := range cells[:tiles-1] {
				if isRed(c) {
					t.Fatalf("a frame before the last is red: %v", cells)
				}
			}
			if got := e.repo.vision[monthKey(testNow)]; got != 2 {
				t.Fatalf("vision units = %d, want 2 (unchanged by W6-28)", got)
			}
		})
	}
}

// TestW628_HarmlessLongGIFStaysReady: the extra last-frame sample does not reject harmless animations, and the sheet never
// grows beyond 4 tiles.
func TestW628_HarmlessLongGIFStaysReady(t *testing.T) {
	e := newEnv(t, envOpts{})
	e.mod.bytesBy = redIsExplicit(t)
	r := e.finalizeGIF(t, e.createGIFWith(t, uidA, "a", timedGIF(repeatIdx(250, pxGreen), repeatInt(250, 4))))
	if r.Status != StatusReady {
		t.Fatalf("result = %+v, want READY", r)
	}
	if cells := sheetCells(t, e.mod.byteCalls[0]); len(cells) != 4 {
		t.Fatalf("cells = %d, want 4", len(cells))
	}
	if got := e.repo.vision[monthKey(testNow)]; got != 2 {
		t.Fatalf("vision units = %d, want 2", got)
	}
}

// worstCaseGIF is the W6-18 accepted worst case: 300 frames (GIF_MAX_FRAMES) of 400 x 400 on a 1,280 x 1,280 screen.
func worstCaseGIF() []byte {
	var fr []testFrame
	for i := 0; i < 300; i++ {
		fr = append(fr, testFrame{rect: image.Rect(0, 0, 400, 400), idx: uint8(i % 2), delay: 5})
	}
	return encodeTestGIF(1280, 1280, color.Palette{color.White, color.RGBA{R: 255, A: 255}}, fr)
}

// TestW628_WorstCaseDecodeTime: decoding up to the last frame now means decoding EVERY frame. This logs the time for the
// worst accepted GIF (the number the PR reports against the 2 s deadline) and pins that all 300 frames were visited and
// the last one sampled. It asserts no wall-clock bound (CI runs under -race); the deadline behaviour is tested below.
func TestW628_WorstCaseDecodeTime(t *testing.T) {
	data := worstCaseGIF()
	sc, err := scanGIF(data, s0Limits)
	if err != nil {
		t.Fatal(err)
	}
	if got := sampleIndices(sc.frames); got[len(got)-1] != 299 {
		t.Fatalf("samples %v do not end at the last frame", got)
	}
	began := time.Now()
	_, sampled, err := sampleGIF(context.Background(), data, sc)
	if err != nil || sampled != 4 {
		t.Fatalf("sampled = %d, err = %v", sampled, err)
	}
	t.Logf("worst case (300 frames of 400 x 400, 1280 x 1280 screen, %d bytes): all 300 frames decoded in %v", len(data), time.Since(began))
}

// TestW628_DeadlineStillEnforced: the decode deadline refuses the worst case as "too long" (reasonGifLarge, 0 Vision
// units) now that it must reach the last frame; and the area cap still refuses before any decode.
func TestW628_DeadlineStillEnforced(t *testing.T) {
	data := worstCaseGIF()
	sc, err := scanGIF(data, s0Limits)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancel()
	time.Sleep(time.Millisecond)
	_, _, err = sampleGIF(ctx, data, sc)
	var ref *gifRefusal
	if !errors.As(err, &ref) || ref.why != "deadline" {
		t.Fatalf("err = %v, want a deadline refusal", err)
	}

	e := newEnv(t, envOpts{gifDecode: time.Nanosecond})
	r := e.finalizeGIF(t, e.createGIFWith(t, uidA, "d", data))
	if r.Status != StatusRejected || r.RejectionReason != reasonGifLarge || len(e.mod.byteCalls) != 0 || e.repo.vision[monthKey(testNow)] != 0 {
		t.Fatalf("result = %+v, units %d", r, e.repo.vision[monthKey(testNow)])
	}

	tight := s0Limits
	tight.maxAreaSum = 47_000_000 // below the fixture's 48,000,000
	if _, err := scanGIF(data, tight); err == nil {
		t.Fatal("area cap not enforced")
	}
}

func itoa(n int) string {
	s := ""
	for ; n > 0; n /= 10 {
		s = string(rune('0'+n%10)) + s
	}
	return s
}
