package media

import "encoding/binary"

// webpHeadBytes is how much of a WebP verify reads (security H-2, B14). The magic-number sniff needs 12 bytes, but an
// ANIM chunk can follow a large ICCP chunk, and the pixel size sits in the image chunk after it, so a WebP gets a wider
// ranged read. It is still the one pinned UploadHead call verify already makes (1 Class B, no extra call); only the
// bytes of that range grow, and 64 KiB is far under the 256 KiB thumbnail cap.
const webpHeadBytes = 64 * 1024

// jpegHeadBytes is how much of a JPEG verify reads (B14): enough to pass a large EXIF/ICC APPn block and reach the
// SOF marker that carries the pixel size. A JPEG whose SOF lies beyond it is refused, not guessed.
const jpegHeadBytes = 64 * 1024

// headBytesFor is the length of the pinned head read for an object of the given declared content type.
func headBytesFor(contentType string) int64 {
	switch contentType {
	case ContentTypeWebP:
		return webpHeadBytes
	case ContentTypeJPEG:
		return jpegHeadBytes
	}
	return 512
}

// webpIsStill reports whether head (the start of a file whose RIFF/WEBP magic is already confirmed) is a single-frame WebP.
// It fails closed: anything it cannot prove still is refused, because an animated WebP would autoplay in feeds and avatars
// and SafeSearch looks at one frame only.
func webpIsStill(head []byte) bool {
	_, ok := webpStillImage(head)
	return ok
}

// webpImage is what the chunk walk of a still WebP found.
type webpImage struct {
	// vp8x is the 10-byte VP8X payload of an extended file, nil for a simple one.
	vp8x []byte
	// id is the image chunk's FourCC ("VP8 " or "VP8L") and data the part of its payload that lies inside head.
	id   string
	data []byte
}

// webpStillImage walks the chunks of head and returns the image chunk of a single-frame WebP; ok is false for anything
// it cannot prove still.
//
// Layout (RFC 9649): "RIFF" size "WEBP", then chunks of FourCC, 32-bit little-endian size, payload padded to even length.
//   - A simple file starts with "VP8 " or "VP8L": always a still.
//   - An extended file starts with "VP8X"; payload byte 0 holds the flags and bit 0x02 is the animation flag.
//   - ANIM and ANMF chunks exist only in animations. They are refused even when the flag is clear, so a hand-built file that
//     lies about the flag is caught as long as the chunk is reachable.
//   - After a VP8X the walk must reach a "VP8 " or "VP8L" image chunk inside head; if it does not (a huge ICCP, a truncated
//     file) the file is refused rather than guessed.
func webpStillImage(head []byte) (img webpImage, ok bool) {
	pos := int64(12)
	first := true
	for {
		if pos+4 > int64(len(head)) {
			return webpImage{}, false // truncated, or the image data lies beyond the bytes read
		}
		id := string(head[pos : pos+4])
		switch id {
		case "VP8 ", "VP8L":
			// A still image chunk ends the question; its data is clipped to head (the size check is the caller's).
			img.id = id
			if start := pos + 8; start <= int64(len(head)) {
				end := min(start+int64(binary.LittleEndian.Uint32(head[pos+4:start])), int64(len(head)))
				img.data = head[start:end]
			}
			return img, true
		case "ANIM", "ANMF":
			return webpImage{}, false
		case "VP8X":
			if !first || pos+8+10 > int64(len(head)) {
				return webpImage{}, false
			}
			if head[pos+8]&0x02 != 0 {
				return webpImage{}, false
			}
			img.vp8x = head[pos+8 : pos+18]
		default:
			if first {
				return webpImage{}, false // the first chunk of a WebP is VP8, VP8L or VP8X
			}
		}
		first = false
		if pos+8 > int64(len(head)) {
			return webpImage{}, false
		}
		size := int64(binary.LittleEndian.Uint32(head[pos+4 : pos+8]))
		pos += 8 + size + size&1
	}
}

// webpDims returns the pixel size of a still WebP from its first bytes (B14). It parses the headers by hand (no codec
// dependency) and fails closed:
//   - "VP8 " (lossy): a key frame (frame tag bit 0 clear), the start code 9d 01 2a, then 14-bit width and height.
//   - "VP8L" (lossless): the signature byte 0x2f, then 14-bit width-1 and height-1 and a 3-bit version that must be 0.
//   - "VP8X" (extended): a 24-bit canvas width-1 and height-1, which must equal the image chunk's own size (a still's
//     bitstream is the whole canvas).
func webpDims(head []byte) (w, h int, ok bool) {
	img, still := webpStillImage(head)
	if !still {
		return 0, 0, false
	}
	p := img.data
	switch img.id {
	case "VP8 ":
		if len(p) < 10 || p[0]&0x01 != 0 || p[3] != 0x9d || p[4] != 0x01 || p[5] != 0x2a {
			return 0, 0, false
		}
		w = int(binary.LittleEndian.Uint16(p[6:8]) & 0x3fff)
		h = int(binary.LittleEndian.Uint16(p[8:10]) & 0x3fff)
	case "VP8L":
		if len(p) < 5 || p[0] != 0x2f {
			return 0, 0, false
		}
		bits := binary.LittleEndian.Uint32(p[1:5])
		if bits>>29 != 0 {
			return 0, 0, false
		}
		w = int(bits&0x3fff) + 1
		h = int((bits>>14)&0x3fff) + 1
	default:
		return 0, 0, false
	}
	if w <= 0 || h <= 0 {
		return 0, 0, false
	}
	if c := img.vp8x; c != nil {
		cw := 1 + (int(c[4]) | int(c[5])<<8 | int(c[6])<<16)
		ch := 1 + (int(c[7]) | int(c[8])<<8 | int(c[9])<<16)
		if cw != w || ch != h {
			return 0, 0, false
		}
	}
	return w, h, true
}
