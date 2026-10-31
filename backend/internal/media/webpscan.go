package media

import "encoding/binary"

// webpHeadBytes is how much of a WebP verify reads (W6-26, security H-2). The magic-number sniff needs 12 bytes, but an
// ANIM chunk can follow a large ICCP chunk, so a WebP gets a wider ranged read. It is still the one pinned UploadHead call
// verify already makes (1 Class B, no extra call); only the bytes of that range grow, and 32 KiB is far under the 256 KiB
// thumbnail cap.
const webpHeadBytes = 32 * 1024

// headBytesFor is the length of the pinned head read for an object of the given declared content type.
func headBytesFor(contentType string) int64 {
	if contentType == ContentTypeWebP {
		return webpHeadBytes
	}
	return 512
}

// webpIsStill reports whether head (the start of a file whose RIFF/WEBP magic is already confirmed) is a single-frame WebP.
// It fails closed: anything it cannot prove still is refused, because an animated WebP would autoplay in feeds and avatars
// and SafeSearch looks at one frame only.
//
// Layout (RFC 9649): "RIFF" size "WEBP", then chunks of FourCC, 32-bit little-endian size, payload padded to even length.
//   - A simple file starts with "VP8 " or "VP8L": always a still.
//   - An extended file starts with "VP8X"; payload byte 0 holds the flags and bit 0x02 is the animation flag.
//   - ANIM and ANMF chunks exist only in animations. They are refused even when the flag is clear, so a hand-built file that
//     lies about the flag is caught as long as the chunk is reachable.
//   - After a VP8X the walk must reach a "VP8 " or "VP8L" image chunk inside head; if it does not (a huge ICCP, a truncated
//     file) the file is refused rather than guessed.
func webpIsStill(head []byte) bool {
	pos := int64(12)
	first := true
	for {
		if pos+4 > int64(len(head)) {
			return false // truncated, or the image data lies beyond the bytes read
		}
		id := string(head[pos : pos+4])
		switch id {
		case "VP8 ", "VP8L":
			return true // the size is not needed: a still image chunk ends the question
		case "ANIM", "ANMF":
			return false
		case "VP8X":
			if !first || pos+8+10 > int64(len(head)) {
				return false
			}
			if head[pos+8]&0x02 != 0 {
				return false
			}
		default:
			if first {
				return false // the first chunk of a WebP is VP8, VP8L or VP8X
			}
		}
		first = false
		if pos+8 > int64(len(head)) {
			return false
		}
		size := int64(binary.LittleEndian.Uint32(head[pos+4 : pos+8]))
		pos += 8 + size + size&1
	}
}
