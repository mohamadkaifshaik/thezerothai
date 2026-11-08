package media

import (
	"bytes"
	"image/jpeg"
)

// jpegDims returns the pixel size in a JPEG's SOF marker, read from the first bytes of the file (B14). image/jpeg's
// DecodeConfig skips APPn and COM segments and stops at the SOF (JFIF) or the SOS, so it never decodes pixels. Any
// error, a SOF beyond head included (io.ErrUnexpectedEOF), refuses the file.
func jpegDims(head []byte) (w, h int, ok bool) {
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(head))
	if err != nil || cfg.Width <= 0 || cfg.Height <= 0 {
		return 0, 0, false
	}
	return cfg.Width, cfg.Height, true
}

// gifDims returns a GIF's logical screen size: the two little-endian 16-bit fields after the six-byte signature
// (bytes 6-9). The 512-byte sniff head always holds them, so no further read is made. The frame scan (scanGIF) later
// refuses any frame outside this screen, so the screen bounds every pixel the file draws.
func gifDims(head []byte) (w, h int, ok bool) {
	if len(head) < 10 || (string(head[:6]) != "GIF87a" && string(head[:6]) != "GIF89a") {
		return 0, 0, false
	}
	w, h = le16(head[6:]), le16(head[8:])
	if w == 0 || h == 0 {
		return 0, 0, false
	}
	return w, h, true
}

// imageDims returns the real pixel size of a still JPEG or WebP, or a GIF's logical screen, from head; ok is false for
// any other type or when the header cannot be read inside head.
func imageDims(contentType string, head []byte) (w, h int, ok bool) {
	switch contentType {
	case ContentTypeJPEG:
		return jpegDims(head)
	case ContentTypeWebP:
		return webpDims(head)
	case ContentTypeGIF:
		return gifDims(head)
	}
	return 0, 0, false
}

// geometryOK checks an uploaded image's real pixel size against the document (B14), so what is published and screened is
// the image that was declared:
//   - every image is within MaxDimension on each side and MaxPixels in total;
//   - the full image is exactly the declared width x height (the official client declares what it encoded);
//   - a thumbnail has no declared size, so it is held to no larger than the declared full image on either side (the client
//     never upscales: a small photo's thumbnail is the photo's own size);
//   - a BANNER's full image and thumbnail are both 3:1 within 2% and at most 1500 x 500.
func geometryOK(d *Doc, full bool, w, h int) bool {
	switch {
	case w <= 0 || h <= 0 || w > MaxDimension || h > MaxDimension || int64(w)*int64(h) > MaxPixels:
		return false
	case full && (w != d.Width || h != d.Height):
		return false
	case !full && (w > d.Width || h > d.Height):
		return false
	case d.Purpose == string(PurposeBanner) && !bannerShapeOK(w, h):
		return false
	}
	return true
}
