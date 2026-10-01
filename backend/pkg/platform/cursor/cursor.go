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
//
// Timelines (ADR-0010 D14) add two things without changing the graph tokens above: Window tokens carrying an
// upper and an optional lower position (window.go), and a caller-chosen TTL on decode (DecodeTTL, DecodeAtTTL,
// DecodeWindow) so persisted `since` and gap tokens can live 30 days while Decode keeps the 24 h default.
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
	plain := strconv.FormatInt(now.UnixMicro(), 10) + "|" + strconv.FormatInt(c.CreatedAt.UnixMicro(), 10) + "|" + c.DocID
	return seal(key, aadLabel+binding, plain)
}

// Decode opens a page token produced by Encode for the same binding. An empty token is a valid "first page"
// request and returns a zero Cursor with no error so callers can branch on IsFirstPage.
func Decode(key []byte, binding, token string) (Cursor, error) {
	return DecodeAt(key, binding, token, time.Now())
}

// DecodeAt is Decode with an explicit current time (tests, fake clocks).
func DecodeAt(key []byte, binding, token string, now time.Time) (Cursor, error) {
	return DecodeAtTTL(key, binding, token, now, TTL)
}

// DecodeTTL is Decode with a caller-chosen token lifetime instead of the 24 h TTL. Timelines persist their
// `since` tokens on the client across days, so they decode with TIMELINE_TOKEN_TTL (30 days, ADR-0010 D14).
// The encoder side is unchanged: the TTL is enforced only here, against the sealed issue time.
func DecodeTTL(key []byte, binding, token string, ttl time.Duration) (Cursor, error) {
	return DecodeAtTTL(key, binding, token, time.Now(), ttl)
}

// DecodeAtTTL is DecodeTTL with an explicit current time (tests, fake clocks). A ttl <= 0 rejects every
// non-empty token.
func DecodeAtTTL(key []byte, binding, token string, now time.Time, ttl time.Duration) (Cursor, error) {
	if token == "" {
		return Cursor{}, nil
	}
	plain, err := open(key, aadLabel+binding, token)
	if err != nil {
		return Cursor{}, err
	}
	parts := strings.SplitN(plain, "|", 3)
	if len(parts) != 3 || parts[2] == "" {
		return Cursor{}, ErrInvalid
	}
	if err := checkIssued(parts[0], now, ttl); err != nil {
		return Cursor{}, err
	}
	micros, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return Cursor{}, ErrInvalid
	}
	return Cursor{CreatedAt: time.UnixMicro(micros).UTC(), DocID: parts[2]}, nil
}

// open base64-decodes and AES-GCM-opens a token with the given additional data.
func open(key []byte, aad, token string) (string, error) {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return "", ErrInvalid
	}
	aead, err := newAEAD(key)
	if err != nil || len(raw) < aead.NonceSize()+aead.Overhead() {
		return "", ErrInvalid
	}
	nonce, ct := raw[:aead.NonceSize()], raw[aead.NonceSize():]
	plain, err := aead.Open(nil, nonce, ct, []byte(aad))
	if err != nil {
		return "", ErrInvalid
	}
	return string(plain), nil
}

// seal encrypts plain with the given additional data. It returns "" if the AEAD or the nonce is unavailable.
func seal(key []byte, aad, plain string) string {
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
	return base64.RawURLEncoding.EncodeToString(aead.Seal(nonce, nonce, []byte(plain), []byte(aad)))
}

// checkIssued rejects an issue time older than ttl or more than clockSkew in the future.
func checkIssued(field string, now time.Time, ttl time.Duration) error {
	issued, err := strconv.ParseInt(field, 10, 64)
	if err != nil {
		return ErrInvalid
	}
	issuedAt := time.UnixMicro(issued)
	if ttl <= 0 || now.Sub(issuedAt) > ttl || issuedAt.Sub(now) > clockSkew {
		return ErrInvalid
	}
	return nil
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
