// Package cursortest holds test helpers for opaque cursor tokens.
package cursortest

// Tamper returns tok with one character in the middle replaced by a different base64url character. A middle
// character carries six full bits of the payload, so the decoded bytes always change and the seal must fail.
// Replacing the last characters is not enough: in unpadded base64 the final character can carry bits the decoder
// discards, so such a "tampered" token can decode to the original bytes and open (a flaky test).
func Tamper(tok string) string {
	if tok == "" {
		return "A"
	}
	i := len(tok) / 2
	r := byte('A')
	if tok[i] == 'A' {
		r = 'B'
	}
	return tok[:i] + string(r) + tok[i+1:]
}
