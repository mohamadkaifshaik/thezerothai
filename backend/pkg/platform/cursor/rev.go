package cursor

import (
	"strconv"
	"strings"
	"time"
)

// revAADLabel puts revision-carrying tokens in their own AEAD domain: a token from EncodeRevAt never opens through
// DecodeAtTTL (or the reverse) even with the same binding string, so a plain token cannot be replayed as one that
// claims a revision, and a revision token cannot be mistaken for a position-only one.
const revAADLabel = aadLabel + "rev|"

// EncodeRevAt seals c plus an integer revision into a token bound to binding, issued at now. The revision is the one the
// issuer saw on the thing the token pages (messaging: conversations/{id}.rev, ADR-0027 note 2026-10-29); the verifier
// compares it after its own read, so the binding stays free of data that must be read to compute it.
func EncodeRevAt(key []byte, binding string, c Cursor, rev int64, now time.Time) string {
	plain := strconv.FormatInt(now.UnixMicro(), 10) + "|" + strconv.FormatInt(c.CreatedAt.UnixMicro(), 10) + "|" +
		strconv.FormatInt(rev, 10) + "|" + c.DocID
	return seal(key, revAADLabel+binding, plain)
}

// DecodeRevAtTTL opens a token produced by EncodeRevAt for the same binding and returns its cursor and revision. A token
// of the position-only format (EncodeAt, issued before revisions existed) still opens and has revision 0, so nothing is
// invalidated at deploy. A token that opens in the revision domain but is expired, from the future or malformed fails
// with ErrInvalid; it does not fall back. An empty token is a valid "first page" request (zero Cursor, revision 0).
func DecodeRevAtTTL(key []byte, binding, token string, now time.Time, ttl time.Duration) (Cursor, int64, error) {
	if token == "" {
		return Cursor{}, 0, nil
	}
	plain, err := open(key, revAADLabel+binding, token)
	if err != nil {
		c, derr := DecodeAtTTL(key, binding, token, now, ttl)
		return c, 0, derr
	}
	parts := strings.SplitN(plain, "|", 4)
	if len(parts) != 4 || parts[3] == "" {
		return Cursor{}, 0, ErrInvalid
	}
	if _, err := checkIssued(parts[0], now, ttl); err != nil {
		return Cursor{}, 0, err
	}
	micros, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return Cursor{}, 0, ErrInvalid
	}
	rev, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil || rev < 0 {
		return Cursor{}, 0, ErrInvalid
	}
	return Cursor{CreatedAt: time.UnixMicro(micros).UTC(), DocID: parts[3]}, rev, nil
}
