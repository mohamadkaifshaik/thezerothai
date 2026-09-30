// Package cursor implements opaque pagination cursors (ADR-0003, rule 5: "pagination: opaque cursors only,
// never offset"). A cursor encodes the last scanned document's (createdAt, docId) pair.
//
// Tokens are sealed with AES-256-GCM (security review M1): confidential, so a token cannot leak the doc id
// of a row the server chose to hide (e.g. a blocked-by follower filtered out of a list page), and
// authenticated, so a hand-edited token fails at 0 Firestore reads. Each token is also
//
//   - bound to a caller-chosen context string (the AEAD additional data), typically "caller|list|target",
//     so a token issued to one user or list is rejected for another; and
//   - time-limited: it carries its issue time and is rejected after TTL.
//
// The AES key is derived with HKDF-SHA256 from the existing CURSOR_HMAC_KEY secret and a fixed label, so no
// new secret is needed. Tokens from the previous (v1, HMAC-signed, plaintext) format simply fail to open and
// come back as ErrInvalid, which callers map to INVALID_ARGUMENT/VALIDATION; clients restart the list.
package cursor

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strconv"
	"strings"
	"time"
)

// ErrInvalid is returned for a malformed, tampered, expired, wrong-key or wrong-binding cursor. Callers
// should map it to INVALID_ARGUMENT, not leak details about why it failed.
var ErrInvalid = errors.New("cursor: invalid page token")

// TTL is how long an issued token stays valid. Paging a list normally takes seconds; a day is generous.
const TTL = 24 * time.Hour

// clockSkew tolerates an issue time slightly in the future (tokens minted on another instance).
const clockSkew = time.Minute

const (
	hkdfInfo = "dzeroth cursor v2 aes-256-gcm"
	aadLabel = "dzeroth-cursor-v2|"
)

// Cursor is the position to resume a createdAt-descending (or ascending) query from.
type Cursor struct {
	CreatedAt time.Time
	DocID     string
}

// Encode seals c into an opaque page token bound to binding, issued now. Empty Cursor{} is not valid input;
// callers with no next page should return "" directly instead of encoding a zero cursor.
func Encode(key []byte, binding string, c Cursor) string {
	return EncodeAt(key, binding, c, time.Now())
}

// EncodeAt is Encode with an explicit issue time (tests, fake clocks).
func EncodeAt(key []byte, binding string, c Cursor, now time.Time) string {
	aead, err := newAEAD(key)
	if err != nil {
		// Unreachable: the derived key is always 32 bytes. Returning "" makes the list look like it has no
		// next page rather than panicking on a request path.
		return ""
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return ""
	}
	plain := strconv.FormatInt(now.UnixMicro(), 10) + "|" + strconv.FormatInt(c.CreatedAt.UnixMicro(), 10) + "|" + c.DocID
	sealed := aead.Seal(nonce, nonce, []byte(plain), []byte(aadLabel+binding))
	return base64.RawURLEncoding.EncodeToString(sealed)
}

// Decode opens a page token produced by Encode for the same binding. An empty token is a valid "first page"
// request and returns a zero Cursor with no error so callers can branch on IsFirstPage.
func Decode(key []byte, binding, token string) (Cursor, error) {
	return DecodeAt(key, binding, token, time.Now())
}

// DecodeAt is Decode with an explicit current time (tests, fake clocks).
func DecodeAt(key []byte, binding, token string, now time.Time) (Cursor, error) {
	if token == "" {
		return Cursor{}, nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return Cursor{}, ErrInvalid
	}
	aead, err := newAEAD(key)
	if err != nil || len(raw) < aead.NonceSize()+aead.Overhead() {
		return Cursor{}, ErrInvalid
	}
	nonce, ct := raw[:aead.NonceSize()], raw[aead.NonceSize():]
	plain, err := aead.Open(nil, nonce, ct, []byte(aadLabel+binding))
	if err != nil {
		return Cursor{}, ErrInvalid
	}
	parts := strings.SplitN(string(plain), "|", 3)
	if len(parts) != 3 || parts[2] == "" {
		return Cursor{}, ErrInvalid
	}
	issued, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return Cursor{}, ErrInvalid
	}
	issuedAt := time.UnixMicro(issued)
	if now.Sub(issuedAt) > TTL || issuedAt.Sub(now) > clockSkew {
		return Cursor{}, ErrInvalid
	}
	micros, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return Cursor{}, ErrInvalid
	}
	return Cursor{CreatedAt: time.UnixMicro(micros).UTC(), DocID: parts[2]}, nil
}

// IsFirstPage reports whether a decoded (zero-value, no error) Cursor represents "start from the top".
func IsFirstPage(c Cursor) bool {
	return c.DocID == "" && c.CreatedAt.IsZero()
}

// newAEAD derives the AES-256-GCM AEAD from the configured secret (HKDF-SHA256, RFC 5869, single output
// block: extract with an empty salt, expand with hkdfInfo). Two HMACs and a key schedule per call is
// microseconds, so no per-key cache is needed.
func newAEAD(secret []byte) (cipher.AEAD, error) {
	extract := hmac.New(sha256.New, nil)
	extract.Write(secret)
	prk := extract.Sum(nil)

	expand := hmac.New(sha256.New, prk)
	expand.Write([]byte(hkdfInfo))
	expand.Write([]byte{1})
	okm := expand.Sum(nil) // 32 bytes

	block, err := aes.NewCipher(okm)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}
