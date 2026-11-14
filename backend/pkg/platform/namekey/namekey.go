// Package namekey is the one name fold behind search by name (F20, F21): the nameLower field the lists and communities
// modules store on every create and rename, and the folded query SearchLists and SearchCommunities match as a prefix of it.
// Both sides call Fold, so a stored key and a query can never be folded two ways. The cases are
// testdata/fold.json (read by the unit test).
//
// There is no search engine: a match is a Firestore range on the folded name, `nameLower >= lo AND nameLower < hi`
// (Bounds), so only a prefix of the whole name matches ("go" finds "Go devs", not "Learn Go").
package namekey

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

// Field is the stored field name (lists/{id}.nameLower, communities/{id}.nameLower).
const Field = "nameLower"

// MaxQueryRunes is the longest folded query, in code points: the longest name either module allows (communities, 30).
const MaxQueryRunes = 30

// Query errors. The search service maps each to VALIDATION "query".
var (
	ErrEmpty    = errors.New("namekey: query is empty")
	ErrTooLong  = errors.New("namekey: query is too long")
	ErrBadChars = errors.New("namekey: query holds a control or bidi formatting character")
	ErrBadUTF8  = errors.New("namekey: query is not valid UTF-8")
)

// Fold is the stored key of a name and the matched form of a query: NFC, lower-cased (Unicode simple case mapping), NFC
// again (lower-casing can leave a string unnormalised), then trimmed of Unicode white space. Invalid UTF-8 is replaced
// rune by rune with U+FFFD first (a stored name is always valid; this keeps Fold total).
func Fold(s string) string {
	if !utf8.ValidString(s) {
		s = strings.ToValidUTF8(s, "\ufffd")
	}
	return strings.TrimSpace(norm.NFC.String(strings.ToLower(norm.NFC.String(s))))
}

// Query folds a raw query and validates it: valid UTF-8, 1 to MaxQueryRunes code points after the fold, and no control
// (\p{Cc}) or bidi formatting character (U+202A..U+202E, U+2066..U+2069: the post grammar's set) anywhere. Pure.
func Query(raw string) (string, error) {
	if !utf8.ValidString(raw) {
		return "", ErrBadUTF8
	}
	q := Fold(raw)
	for _, r := range q {
		if unicode.Is(unicode.Cc, r) || isBidiControl(r) {
			return "", ErrBadChars
		}
	}
	switch n := utf8.RuneCountInString(q); {
	case n == 0:
		return "", ErrEmpty
	case n > MaxQueryRunes:
		return "", ErrTooLong
	}
	return q, nil
}

func isBidiControl(r rune) bool {
	return (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069)
}

// Bounds is the half-open range [lo, hi) of every folded name that starts with prefix, in Firestore's string order (UTF-8
// bytes). hi is prefix followed by U+10FFFF, the largest code point, whose UTF-8 form (F4 8F BF BF) sorts above every
// other code point's, so a name such as "ab" + an emoji (F0 9F ...) or any other astral-plane character still falls inside;
// the common `prefix + "\uf8ff"` would miss it. The one name outside the range is one whose next code point is U+10FFFF
// itself (a noncharacter).
func Bounds(prefix string) (lo, hi string) {
	return prefix, prefix + string(rune(unicode.MaxRune))
}

// HasPrefix reports whether the folded name key falls in Bounds(prefix): the in-memory twin of the range query (fakes and
// the backfill's dry-run counts use it).
func HasPrefix(key, prefix string) bool {
	lo, hi := Bounds(prefix)
	return key >= lo && key < hi
}

// BackfillPage is one page of a module's nameLower backfill (`opsctl search backfill-name-keys`): the documents scanned in
// document-id order, how many had a missing or stale key, how many of those this page rewrote (0 on a dry run) and how many
// were skipped because the document changed since it was read (a rename writes its own key), and the last id, the resume
// point. Done is true when the page was not full.
type BackfillPage struct {
	Scanned, Stale, Written, Skipped int
	Last                             string
	Done                             bool
}

// Add sums b into p, keeping b's Last and Done (the operator tool's running total).
func (p *BackfillPage) Add(b BackfillPage) {
	p.Scanned += b.Scanned
	p.Stale += b.Stale
	p.Written += b.Written
	p.Skipped += b.Skipped
	p.Last, p.Done = b.Last, b.Done
}

// MaxBackfillPage bounds one backfill page (the Limit of its query).
const MaxBackfillPage = 200

// Stale reports whether a stored key needs a rewrite for name.
func Stale(stored, name string) bool { return stored != Fold(name) }
