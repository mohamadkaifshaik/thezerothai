package search

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

// The query grammar of ADR-0028 D1, steps 1 to 4 (the people half; the posts half is SearchPosts' own, W4-7). The client
// parser (app/lib/features/search/domain/search_query.dart) applies the same rules in the same order, and both are checked
// against testdata/search_query_grammar.json. Nothing here reads Firestore: a rejected or unsupported query costs 0 reads.

const (
	// maxQueryCodePoints is the longest query body, not counting the sigil (D1 step 3), so a tag tap-through of a
	// 50-code-point tag (`#` + body) is always searchable.
	maxQueryCodePoints = 50
	// minPrefixLen and maxHandleLen bound a people prefix (D1 step 4): handles are 3 to 15 characters, a prefix 2 to 15.
	minPrefixLen = 2
	maxHandleLen = 15
)

// normalizedQuery is a query after D1 steps 1 to 3: NFC, trimmed, lower-cased, one leading sigil split off.
type normalizedQuery struct {
	// sigil is '@', '#' or 0 (none). Only the first character is a sigil: `##a` has sigil '#' and body `#a`.
	sigil rune
	// body is the rest, 1 to maxQueryCodePoints code points, free of control and bidi formatting characters.
	body string
}

// normalizeQuery applies D1 steps 1 to 3. ok is false for an invalid query: nothing left after the sigil, more than
// maxQueryCodePoints code points after it, or a control or bidi formatting character anywhere.
func normalizeQuery(raw string) (q normalizedQuery, ok bool) {
	text := strings.ToLower(strings.TrimSpace(norm.NFC.String(raw)))
	if strings.IndexFunc(text, isForbiddenRune) >= 0 {
		return normalizedQuery{}, false
	}
	body := text
	if text != "" && (text[0] == '@' || text[0] == '#') {
		q.sigil = rune(text[0])
		body = text[1:]
	}
	if body == "" || utf8.RuneCountInString(body) > maxQueryCodePoints {
		return normalizedQuery{}, false
	}
	q.body = body
	return q, true
}

// isForbiddenRune is a control character (\p{Cc}) or a bidi formatting control (ADR-0010 D9). It matches the client's
// list, which also refuses U+061C, U+200E and U+200F (a post allows LRM and RLM; a search box has no use for them).
// ZWJ and ZWNJ stay: tag bodies may hold them.
func isForbiddenRune(r rune) bool {
	return unicode.Is(unicode.Cc, r) || r == 0x061C || r == 0x200E || r == 0x200F ||
		(r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069)
}

// peopleResult is how SearchPeople reads a query (D1 step 4); the fixture spells them invalid, too_short, unsupported
// and prefix.
type peopleResult int

const (
	// peopleInvalid: VALIDATION `query`.
	peopleInvalid peopleResult = iota
	// peopleTooShort: VALIDATION `query` ("too short"), a handle-class rest of one character; `a` and `@a` alike.
	peopleTooShort
	// peopleUnsupported: an empty answer with unsupported_query = true, 0 reads (a `#` sigil, or a rest that is not
	// [a-z0-9_]{1,15}).
	peopleUnsupported
	// peoplePrefix: a handle prefix of 2 to 15 characters; nothing else is searched.
	peoplePrefix
)

// parsePeopleQuery classifies raw for SearchPeople and returns the prefix when the result is peoplePrefix.
func parsePeopleQuery(raw string) (peopleResult, string) {
	q, ok := normalizeQuery(raw)
	if !ok {
		return peopleInvalid, ""
	}
	if q.sigil == '#' || len(q.body) > maxHandleLen || !isHandleClass(q.body) {
		return peopleUnsupported, ""
	}
	if len(q.body) < minPrefixLen {
		return peopleTooShort, ""
	}
	return peoplePrefix, q.body
}

// isHandleClass reports whether s is non-empty and made only of [a-z0-9_] (pkg/platform/handle's alphabet).
func isHandleClass(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '_' {
			return false
		}
	}
	return true
}
