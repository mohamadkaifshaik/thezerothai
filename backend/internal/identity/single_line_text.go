package identity

import (
	"unicode/utf8"
)

// SingleLineText applies the profile text rules (ADR-0024 D2, L-2) for a one-line field of another module: trim
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

// BioText applies the profile bio rules (ADR-0010 D9) for a multi-line text field of another module, with the length bound as a
// parameter: trim, NFC, at most maxRunes code points, valid UTF-8, and no control character other than "\n", line or paragraph
// separator, bidi formatting control, invisible format character (Cf) or filler, with the single-line rule's ZWJ/ZWNJ and subdivision-flag
// exceptions (one scanner: invisibleTextIssue). Unlike SingleLineText it does not require a visible rune. It returns the form to store and whether s is acceptable. An empty result is
// acceptable. bioIssue is this rule at 160, so community descriptions and rule texts (ADR-0031 D2) cannot drift from the bio's.
// Pure: no Firestore access.
func BioText(s string, maxRunes int) (string, bool) {
	if !utf8.ValidString(s) {
		return "", false
	}
	n := normalizeBio(s)
	if utf8.RuneCountInString(n) > maxRunes {
		return "", false
	}
	if invisibleTextIssue(n, true, false) {
		return "", false
	}
	return n, true
}
