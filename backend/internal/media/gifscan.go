package media

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/gif"
	"image/jpeg"
	"time"
)

// Frame-sampled GIF screening (ADR-0029 D11, F11 a, plan W6-10). Cloud Vision looks at the first frame of an animated
// GIF only, so FinalizeUpload builds a contact sheet of up to four sampled frames and sends it by bytes.
//
// The code here is pure (bytes in, JPEG out, no I/O, no globals) so it can move to a separate job unchanged. It has
// two stages. scanGIF walks the container without decoding a pixel and refuses anything above the limits. sampleGIF
// then decodes ONE frame at a time (each frame is cut out of the file as a one-frame GIF and handed to image/gif), so
// the live memory is the file, two canvases and one frame, whatever the frame count. See gifscreen.go for the
// semaphore, the deadlines and the worst-case memory.

// Sheet geometry: Google recommends 640 x 480 for SAFE_SEARCH_DETECTION (ADR-0029 F11 point 3).
const (
	gifTileW     = 640
	gifTileH     = 480
	gifSamples   = 4
	gifJPEGScore = 85
)

// gifLimits are the pre-scan limits (GIF_MAX_FRAMES, GIF_MAX_EDGE, GIF_MAX_FRAME_AREA_SUM).
type gifLimits struct {
	maxFrames  int
	maxEdge    int
	maxAreaSum int64
}

// gifRefusal is a GIF the screen declines to look at. reason is the user-facing rejection text; why is a short enum
// for the gif_screen log line (never file content).
type gifRefusal struct {
	reason string
	why    string
}

func (e *gifRefusal) Error() string { return "media: gif refused: " + e.why }

func refuseLarge(why string) error   { return &gifRefusal{reason: reasonGifLarge, why: why} }
func refuseInvalid(why string) error { return &gifRefusal{reason: reasonInvalid, why: why} }

// gifFrame is one image of the file: the byte range from the end of the previous image (so it carries the graphic
// control extension that precedes it) to the end of its data, its rectangle, delay and disposal.
type gifFrame struct {
	start, end      int
	left, top, w, h int
	delayCS         int // centiseconds, as stored
	disposal        byte
}

// gifScan is the result of scanGIF.
type gifScan struct {
	width, height int
	header        []byte // signature, logical screen descriptor and global colour table
	frames        []gifFrame
}

func le16(b []byte) int { return int(b[0]) | int(b[1])<<8 }

// scanGIF parses the container of data without decoding pixels. It refuses (a *gifRefusal) above lim, a frame
// outside the logical screen, and anything it cannot parse to the trailer. The work is linear in len(data) (at most
// 2 MiB) and allocates one gifFrame per frame, at most lim.maxFrames.
func scanGIF(data []byte, lim gifLimits) (*gifScan, error) {
	if len(data) < 13 || (string(data[:6]) != "GIF87a" && string(data[:6]) != "GIF89a") {
		return nil, refuseInvalid("header")
	}
	sc := &gifScan{width: le16(data[6:]), height: le16(data[8:])}
	if sc.width == 0 || sc.height == 0 {
		return nil, refuseInvalid("screen_size")
	}
	if sc.width > lim.maxEdge || sc.height > lim.maxEdge {
		return nil, refuseLarge("edge")
	}
	pos := 13
	if data[10]&0x80 != 0 {
		pos += 3 << ((data[10] & 7) + 1)
	}
	if pos > len(data) {
		return nil, refuseInvalid("global_table")
	}
	sc.header = data[:pos]

	var (
		areaSum int64
		cur     = gifFrame{start: pos}
	)
	for {
		if pos >= len(data) {
			return nil, refuseInvalid("no_trailer")
		}
		switch data[pos] {
		case 0x3B: // trailer
			if len(sc.frames) == 0 {
				return nil, refuseInvalid("no_frames")
			}
			return sc, nil
		case 0x21: // extension
			if pos+2 > len(data) {
				return nil, refuseInvalid("extension")
			}
			label := data[pos+1]
			pos += 2
			if label == 0xF9 { // graphic control: block size 4, packed, delay (2), transparent index
				if pos+6 > len(data) || data[pos] != 4 {
					return nil, refuseInvalid("graphic_control")
				}
				cur.disposal = (data[pos+1] >> 2) & 7
				cur.delayCS = le16(data[pos+2:])
			}
			var err error
			if pos, err = skipSubBlocks(data, pos); err != nil {
				return nil, err
			}
		case 0x2C: // image descriptor
			if len(sc.frames) >= lim.maxFrames {
				return nil, refuseLarge("frames")
			}
			if pos+10 > len(data) {
				return nil, refuseInvalid("image_descriptor")
			}
			cur.left, cur.top = le16(data[pos+1:]), le16(data[pos+3:])
			cur.w, cur.h = le16(data[pos+5:]), le16(data[pos+7:])
			packed := data[pos+9]
			pos += 10
			if cur.w == 0 || cur.h == 0 {
				return nil, refuseInvalid("frame_size")
			}
			if cur.left+cur.w > sc.width || cur.top+cur.h > sc.height {
				return nil, refuseLarge("frame_outside")
			}
			if areaSum += int64(cur.w) * int64(cur.h); areaSum > lim.maxAreaSum {
				return nil, refuseLarge("area")
			}
			if packed&0x80 != 0 {
				pos += 3 << ((packed & 7) + 1)
			}
			pos++ // LZW minimum code size
			if pos > len(data) {
				return nil, refuseInvalid("image_data")
			}
			var err error
			if pos, err = skipSubBlocks(data, pos); err != nil {
				return nil, err
			}
			cur.end = pos
			sc.frames = append(sc.frames, cur)
			cur = gifFrame{start: pos}
		default:
			return nil, refuseInvalid("block")
		}
	}
}

// skipSubBlocks returns the position after the sub-block run starting at pos (up to and including the zero terminator).
func skipSubBlocks(data []byte, pos int) (int, error) {
	for {
		if pos >= len(data) {
			return 0, refuseInvalid("sub_blocks")
		}
		n := int(data[pos])
		pos++
		if n == 0 {
			return pos, nil
		}
		pos += n
	}
}

// sampleIndices picks the frames to screen: the frame visible at t = 0, T/4, T/2 and 3T/4 of the display time T (the
// sum of the delays, a delay under 2 cs counted as 10 cs = 100 ms, as browsers and the Flutter codec play it), sorted
// and without repeats. A GIF with up to four frames samples each frame once.
func sampleIndices(frames []gifFrame) []int {
	n := len(frames)
	if n <= gifSamples {
		out := make([]int, n)
		for i := range out {
			out[i] = i
		}
		return out
	}
	delay := func(f gifFrame) int64 {
		if f.delayCS < 2 { // W6-18 D-1: browsers play 0 and 1 cs as 10 cs, so the sampler must see the time a viewer sees
			return 10
		}
		return int64(f.delayCS)
	}
	var total int64
	for _, f := range frames {
		total += delay(f)
	}
	var out []int
	idx, start := 0, int64(0)
	for k := int64(0); k < gifSamples; k++ {
		t := total * k / gifSamples
		for idx < n-1 && start+delay(frames[idx]) <= t {
			start += delay(frames[idx])
			idx++
		}
		if len(out) == 0 || out[len(out)-1] != idx {
			out = append(out, idx)
		}
	}
	return out
}

// sampleGIF decodes the frames named by sampleIndices one at a time, composites them onto the logical screen with
// the GIF disposal rules, and returns the 2 x 2 contact sheet as a JPEG. ctx bounds the work.
func sampleGIF(ctx context.Context, data []byte, sc *gifScan) (sheet []byte, sampled int, err error) {
	want := sampleIndices(sc.frames)
	isSample := make(map[int]bool, len(want))
	for _, i := range want {
		isSample[i] = true
	}
	last := want[len(want)-1]

	bounds := image.Rect(0, 0, sc.width, sc.height)
	canvas := image.NewRGBA(bounds)
	var saved *image.RGBA // the canvas before a "restore to previous" frame, allocated on first use
	tiles := make([]*image.RGBA, 0, len(want))

	for i := 0; i <= last; i++ {
		if dl, ok := ctx.Deadline(); ctx.Err() != nil || (ok && !time.Now().Before(dl)) {
			return nil, 0, refuseLarge("deadline")
		}
		f := sc.frames[i]
		img, err := decodeOneFrame(data, sc, f)
		if err != nil {
			return nil, 0, refuseInvalid("decode")
		}
		if f.disposal == 3 {
			if saved == nil {
				saved = image.NewRGBA(bounds)
			}
			copy(saved.Pix, canvas.Pix)
		}
		drawPaletted(canvas, img)
		if isSample[i] {
			tiles = append(tiles, fitTile(canvas))
		}
		switch f.disposal {
		case 2:
			draw.Draw(canvas, image.Rect(f.left, f.top, f.left+f.w, f.top+f.h), image.Transparent, image.Point{}, draw.Src)
		case 3:
			copy(canvas.Pix, saved.Pix)
		}
	}
	jpg, err := encodeSheet(tiles)
	if err != nil {
		return nil, 0, fmt.Errorf("media: encode gif sheet: %w", err)
	}
	return jpg, len(tiles), nil
}

// decodeOneFrame decodes one frame cut out of data as a stand-alone one-frame GIF (header + the frame's blocks +
// trailer). image/gif reads at most w x h pixels of LZW output, so a data stream that expands far beyond the frame is
// cut off at the frame's size.
func decodeOneFrame(data []byte, sc *gifScan, f gifFrame) (*image.Paletted, error) {
	var b bytes.Buffer
	b.Grow(len(sc.header) + f.end - f.start + 1)
	b.Write(sc.header)
	b.Write(data[f.start:f.end])
	b.WriteByte(0x3B)
	g, err := gif.DecodeAll(&b)
	if err != nil {
		return nil, err
	}
	if len(g.Image) != 1 {
		return nil, errors.New("media: gif frame did not decode to one image")
	}
	return g.Image[0], nil
}

// u8 narrows a channel value that is at most 255 by construction (a clamp keeps the conversion provably safe).
func u8(v uint32) uint8 { return uint8(min(v, 255)) }

// drawPaletted composites a decoded frame onto the canvas ("over"). It is draw.Draw's result for a paletted source
// without the per-pixel colour-model conversions, which dominated the sampler's CPU (about 75 ms per 1,280 x 1,280 frame).
func drawPaletted(dst *image.RGBA, src *image.Paletted) {
	pal := make([]color.RGBA, len(src.Palette))
	for i, c := range src.Palette {
		r, g, b, a := c.RGBA() // premultiplied, 16-bit
		pal[i] = color.RGBA{R: u8(r >> 8), G: u8(g >> 8), B: u8(b >> 8), A: u8(a >> 8)}
	}
	r := src.Rect.Intersect(dst.Bounds())
	for y := r.Min.Y; y < r.Max.Y; y++ {
		in := src.Pix[src.PixOffset(r.Min.X, y):]
		out := dst.Pix[dst.PixOffset(r.Min.X, y):]
		for x := 0; x < r.Dx(); x++ {
			if int(in[x]) >= len(pal) {
				continue
			}
			c, o := pal[in[x]], out[x*4:x*4+4]
			switch c.A {
			case 0:
			case 255:
				o[0], o[1], o[2], o[3] = c.R, c.G, c.B, 255
			default: // source over premultiplied destination
				na := 255 - uint32(c.A)
				o[0] = u8(uint32(c.R) + uint32(o[0])*na/255)
				o[1] = u8(uint32(c.G) + uint32(o[1])*na/255)
				o[2] = u8(uint32(c.B) + uint32(o[2])*na/255)
				o[3] = u8(uint32(c.A) + uint32(o[3])*na/255)
			}
		}
	}
}

// fitTile flattens src onto white and scales it down (box filter, never up) to fit 640 x 480.
func fitTile(src *image.RGBA) *image.RGBA {
	sw, sh := src.Bounds().Dx(), src.Bounds().Dy()
	dw, dh := sw, sh
	if dw > gifTileW || dh > gifTileH {
		// Same ratio on both sides: scale by the tighter of the two limits.
		if int64(gifTileW)*int64(sh) <= int64(gifTileH)*int64(sw) {
			dw, dh = gifTileW, max(1, sh*gifTileW/sw)
		} else {
			dw, dh = max(1, sw*gifTileH/sh), gifTileH
		}
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := range dh {
		y0, y1 := y*sh/dh, max(y*sh/dh+1, (y+1)*sh/dh)
		for x := range dw {
			x0, x1 := x*sw/dw, max(x*sw/dw+1, (x+1)*sw/dw)
			var r, g, b, n uint32
			for sy := y0; sy < y1; sy++ {
				row := src.Pix[sy*src.Stride:]
				for sx := x0; sx < x1; sx++ {
					p := row[sx*4 : sx*4+4]
					// Premultiplied: composite over white by adding the missing alpha to each channel.
					na := 255 - uint32(p[3])
					r += uint32(p[0]) + na
					g += uint32(p[1]) + na
					b += uint32(p[2]) + na
					n++
				}
			}
			o := dst.PixOffset(x, y)
			dst.Pix[o], dst.Pix[o+1], dst.Pix[o+2], dst.Pix[o+3] = u8(r/n), u8(g/n), u8(b/n), 255
		}
	}
	return dst
}

// encodeSheet lays the tiles out two per row in 640 x 480 cells (each centred on black) and encodes the sheet as a JPEG.
func encodeSheet(tiles []*image.RGBA) ([]byte, error) {
	cols := min(len(tiles), 2)
	rows := (len(tiles) + 1) / 2
	sheet := image.NewRGBA(image.Rect(0, 0, cols*gifTileW, rows*gifTileH))
	draw.Draw(sheet, sheet.Bounds(), image.NewUniform(color.Black), image.Point{}, draw.Src)
	for i, t := range tiles {
		cx, cy := (i%2)*gifTileW, (i/2)*gifTileH
		ox, oy := cx+(gifTileW-t.Bounds().Dx())/2, cy+(gifTileH-t.Bounds().Dy())/2
		draw.Draw(sheet, image.Rect(ox, oy, ox+t.Bounds().Dx(), oy+t.Bounds().Dy()), t, image.Point{}, draw.Src)
	}
	var out bytes.Buffer
	if err := jpeg.Encode(&out, sheet, &jpeg.Options{Quality: gifJPEGScore}); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}
