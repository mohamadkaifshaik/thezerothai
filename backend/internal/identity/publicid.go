package identity

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
)

// The public id is the opaque, user-facing identifier of an account (FEATURE_PUBLIC_IDS): "u" followed by 26 characters
// of lowercase Crockford base32 that encode 128 bits from crypto/rand, 27 characters in all. It is not derived from
// the uid, the time or a counter, so it reveals nothing about either; it is immutable, never reissued and never reused
// after erasure. It is stored as users/{uid}.publicId plus the lookup document publicIds/{publicId} -> {uid, createdAt}.
//
// Alphabet: Crockford base32 in lowercase, "0123456789abcdefghjkmnpqrstvwxyz". It leaves out i, l, o and u, so the
// body never contains the prefix letter. The id is meant to be copied, not typed: ValidPublicID is strict (no uppercase,
// no Crockford i/l/o substitution), so a hand-retyped id with any of those is rejected, not corrected. 26
// characters carry 130 bits; the 128-bit value is big-endian, so the first body character holds only the top 3 bits
// and is always one of 0-7. ValidPublicID enforces that, so every valid id decodes to exactly one 128-bit value.
//
// Shape against the other ids on the wire: a Firebase uid is 28 characters of mixed case, a handle 3-15 characters, so
// a well-formed public id is neither. A public id does match the uid character set ([A-Za-z0-9-]), so code that
// accepts both must test ValidPublicID first.
const (
	publicIDPrefix   = "u"
	publicIDBodyLen  = 26
	publicIDLen      = len(publicIDPrefix) + publicIDBodyLen
	publicIDAlphabet = "0123456789abcdefghjkmnpqrstvwxyz"
	// publicIDBytes is the entropy one id consumes: 128 bits.
	publicIDBytes = 16
)

// NewPublicID draws a fresh public id from crypto/rand.
func NewPublicID() (string, error) { return newPublicIDFrom(rand.Reader) }

// newPublicIDFrom draws exactly publicIDBytes bytes from r and encodes them. An error from r is returned wrapped and no
// id is produced (never a weaker one).
func newPublicIDFrom(r io.Reader) (string, error) {
	var b [publicIDBytes]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return "", fmt.Errorf("identity: draw public id: %w", err)
	}
	return encodePublicID(b), nil
}

// encodePublicID writes the 128-bit big-endian value of b as 26 base32 digits, most significant first.
func encodePublicID(b [publicIDBytes]byte) string {
	hi, lo := binary.BigEndian.Uint64(b[:8]), binary.BigEndian.Uint64(b[8:])
	var out [publicIDLen]byte
	out[0] = publicIDPrefix[0]
	for i := publicIDLen - 1; i >= len(publicIDPrefix); i-- {
		out[i] = publicIDAlphabet[lo&31]
		lo = lo>>5 | hi<<59
		hi >>= 5
	}
	return string(out[:])
}

// ValidPublicID reports whether s is a well-formed public id: the prefix, exactly 26 characters of the lowercase
// alphabet, and a first body character of 0-7 (the canonical 128-bit encoding). It does not say the id exists.
func ValidPublicID(s string) bool {
	if len(s) != publicIDLen || s[:len(publicIDPrefix)] != publicIDPrefix {
		return false
	}
	for i := len(publicIDPrefix); i < len(s); i++ {
		if publicIDDigit(s[i]) < 0 {
			return false
		}
	}
	return publicIDDigit(s[len(publicIDPrefix)]) < 8
}

// publicIDDigit is the value of one alphabet character, or -1.
func publicIDDigit(c byte) int {
	for i := range len(publicIDAlphabet) {
		if publicIDAlphabet[i] == c {
			return i
		}
	}
	return -1
}
