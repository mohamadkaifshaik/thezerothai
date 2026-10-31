package identity

import "unicode/utf8"

// SingleLineText applies the profile text rules (ADR-0024 D2, W3-22 L-2) for a one-line field of another module: trim
// (Unicode White_Space plus U+FEFF), NFC, then at least minRunes and at most maxRunes code points, valid UTF-8, and no
// control character (a newline included), line or paragraph separator, or bidi formatting control. It returns the form to
// store and whether s is acceptable. It is displayNameIssue's rule with the length bounds as parameters, so list names and
// descriptions (ADR-0030 D2) cannot drift from the display name's; the vectors in testdata/profile_text stay authoritative.
// Pure: no Firestore access.
func SingleLineText(s string, minRunes, maxRunes int) (string, bool) {
	if !utf8.ValidString(s) {
		return "", false
	}
	n := normalizeDisplayName(s)
	if c := utf8.RuneCountInString(n); c < minRunes || c > maxRunes {
		return "", false
	}
	if singleLineIssue(n) {
		return "", false
	}
	return n, true
}
