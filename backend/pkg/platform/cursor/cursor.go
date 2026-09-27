// Package cursor implements opaque, HMAC-signed pagination cursors (ADR-0003, rule 5: "pagination:
// opaque cursors only, never offset"). Every list RPC's cursor encodes the last returned document's
// (createdAt, docId) pair; signing with a server-only key stops clients from crafting arbitrary,
// unbounded scans by hand-editing the token.
package cursor

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strconv"
	"strings"
	"time"
)

// ErrInvalid is returned for a malformed, tampered, or wrong-key cursor. Callers should map it to
// INVALID_ARGUMENT, not leak details about why it failed.
var ErrInvalid = errors.New("cursor: invalid page token")

// Cursor is the position to resume a createdAt-descending (or ascending) query from.
type Cursor struct {
	CreatedAt time.Time
	DocID     string
}

// Encode signs and serializes c into an opaque page token. Empty Cursor{} is not valid input; callers
// with no next page should return "" directly instead of encoding a zero cursor.
func Encode(key []byte, c Cursor) string {
	payload := strconv.FormatInt(c.CreatedAt.UnixMicro(), 10) + "|" + c.DocID
	sig := sign(key, payload)
	raw := payload + "|" + base64.RawURLEncoding.EncodeToString(sig)
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

// Decode verifies and parses a page token produced by Encode. An empty token is a valid "first page"
// request and returns a zero Cursor with ok=false (no error) so callers can branch on it directly.
func Decode(key []byte, token string) (Cursor, error) {
	if token == "" {
		return Cursor{}, nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return Cursor{}, ErrInvalid
	}
	parts := strings.SplitN(string(raw), "|", 3)
	if len(parts) != 3 {
		return Cursor{}, ErrInvalid
	}
	payload := parts[0] + "|" + parts[1]
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return Cursor{}, ErrInvalid
	}
	if !hmac.Equal(sig, sign(key, payload)) {
		return Cursor{}, ErrInvalid
	}
	micros, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return Cursor{}, ErrInvalid
	}
	if parts[1] == "" {
		return Cursor{}, ErrInvalid
	}
	return Cursor{CreatedAt: time.UnixMicro(micros).UTC(), DocID: parts[1]}, nil
}

// IsFirstPage reports whether a decoded (zero-value, no error) Cursor represents "start from the top".
func IsFirstPage(c Cursor) bool {
	return c.DocID == "" && c.CreatedAt.IsZero()
}

func sign(key []byte, payload string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(payload))
	return mac.Sum(nil)
}
