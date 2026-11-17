package messaging

import (
	"crypto/sha256"
	"encoding/hex"
)

// plainDigest is the old, unkeyed log hash (hex of the first 8 bytes of SHA-256) that anyone could recompute from an id: the
// value no log line or redacted error may carry. logger.HashUID is keyed now, so it no longer stands in for it.
func plainDigest(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:8])
}
