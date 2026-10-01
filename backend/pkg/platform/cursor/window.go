package cursor

import (
	"strconv"
	"strings"
	"time"
)

// windowAADLabel keeps Window tokens and single-position Cursor tokens in separate AEAD domains: a Cursor
// token never opens as a Window (or the reverse) even when the caller passes the same binding string.
const windowAADLabel = "dzeroth-cursor-v2w|"

// noLower is the plaintext marker for "this Window has no lower bound".
const noLower = "-"

// Window is a two-bound page position for a createdAt-descending query (ADR-0010 D14): Upper is the position to
// resume strictly below (the oldest item already returned) and Lower, when set, is the position the scan must
// stop at (a timeline gap's old `since`). A nil Lower is an ordinary scroll. The codec never interprets the
// two bounds; ordering and "lower bound reached" rules belong to the timeline service.
type Window struct {
	Upper Cursor
	Lower *Cursor
}

// IsZero reports whether w is the zero value a first-page request (empty token) decodes to.
func (w Window) IsZero() bool {
	return w.Lower == nil && IsFirstPage(w.Upper)
}

// EncodeWindow seals w into an opaque page token bound to binding, issued now. It returns "" when w is not
// encodable (empty Upper.DocID, a set Lower with an empty DocID, or a doc id containing the "|" separator;
// real doc ids are decimal ids and uids, which never contain it), so callers treat "" as "no next page".
func EncodeWindow(key []byte, binding string, w Window) string {
	return EncodeWindowAt(key, binding, w, time.Now())
}

// EncodeWindowAt is EncodeWindow with an explicit issue time (tests, fake clocks).
func EncodeWindowAt(key []byte, binding string, w Window, now time.Time) string {
	if w.Upper.DocID == "" || strings.Contains(w.Upper.DocID, "|") {
		return ""
	}
	lowerMicros, lowerDoc := noLower, ""
	if w.Lower != nil {
		if w.Lower.DocID == "" || strings.Contains(w.Lower.DocID, "|") {
			return ""
		}
		lowerMicros, lowerDoc = strconv.FormatInt(w.Lower.CreatedAt.UnixMicro(), 10), w.Lower.DocID
	}
	plain := strings.Join([]string{
		strconv.FormatInt(now.UnixMicro(), 10),
		strconv.FormatInt(w.Upper.CreatedAt.UnixMicro(), 10),
		w.Upper.DocID,
		lowerMicros,
		lowerDoc,
	}, "|")
	return seal(key, windowAADLabel+binding, plain)
}

// DecodeWindow opens a Window token produced by EncodeWindow for the same binding, rejecting tokens older
// than ttl (TIMELINE_TOKEN_TTL, 30 days) or issued in the future. An empty token is a valid "first page"
// request and returns a zero Window with no error. Anything else that fails (malformed, tampered, expired,
// wrong key, wrong binding, or a plain Cursor token) is ErrInvalid.
func DecodeWindow(key []byte, binding, token string, ttl time.Duration) (Window, error) {
	return DecodeWindowAt(key, binding, token, time.Now(), ttl)
}

// DecodeWindowAt is DecodeWindow with an explicit current time (tests, fake clocks).
func DecodeWindowAt(key []byte, binding, token string, now time.Time, ttl time.Duration) (Window, error) {
	if token == "" {
		return Window{}, nil
	}
	plain, err := open(key, windowAADLabel+binding, token)
	if err != nil {
		return Window{}, err
	}
	parts := strings.Split(plain, "|")
	if len(parts) != 5 || parts[2] == "" {
		return Window{}, ErrInvalid
	}
	if err := checkIssued(parts[0], now, ttl); err != nil {
		return Window{}, err
	}
	upperMicros, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return Window{}, ErrInvalid
	}
	w := Window{Upper: Cursor{CreatedAt: time.UnixMicro(upperMicros).UTC(), DocID: parts[2]}}
	if parts[3] == noLower {
		if parts[4] != "" {
			return Window{}, ErrInvalid
		}
		return w, nil
	}
	lowerMicros, err := strconv.ParseInt(parts[3], 10, 64)
	if err != nil || parts[4] == "" {
		return Window{}, ErrInvalid
	}
	w.Lower = &Cursor{CreatedAt: time.UnixMicro(lowerMicros).UTC(), DocID: parts[4]}
	return w, nil
}
