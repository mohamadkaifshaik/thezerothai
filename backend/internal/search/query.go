package search

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// Query kinds for the request line (ADR-0028 D10: the raw query is never logged, only its kind and length).
const (
	queryKindHashtag     = "hashtag"
	queryKindUnsupported = "unsupported"
)

// query is a search string after ADR-0028 D1 steps 1 to 3: normalised, with at most one leading sigil split off.
// It is valid (non-empty body, at most 50 code points, no control or bidi character); what the body means is decided
// by the RPC (hashtag for SearchPosts, handle prefix for SearchPeople).
type query struct {
	sigil rune   // 0, '@' or '#'
	body  string // the normalised text after the sigil
}

// parseQuery applies D1 steps 1 to 3 in order and returns a VALIDATION error on field "query" (0 reads) when the
// query is empty after the sigil, longer than 50 code points after it (the sigil does not count), holds invalid
// UTF-8, a control character (\p{Cc}) or a bidi formatting control (ADR-0010 D9) anywhere. Pure.
func parseQuery(raw string) (query, error) {
	if !utf8.ValidString(raw) {
		return query{}, apierr.Validation("query", "query must be valid UTF-8")
	}
	s := strings.ToLower(strings.TrimSpace(norm.NFC.String(raw)))
	// Step 3: a control or bidi character anywhere after the trim (a leading or trailing tab or newline is trimmed away,
	// exactly as the client parser does).
	for _, r := range s {
		if unicode.Is(unicode.Cc, r) || text.IsBidiControl(r) {
			return query{}, apierr.Validation("query", "query contains a disallowed control character")
		}
	}
	var q query
	if s != "" && (s[0] == '@' || s[0] == '#') {
		q.sigil = rune(s[0])
		s = s[1:]
	}
	if s == "" {
		return query{}, apierr.Validation("query", "query must not be empty")
	}
	if utf8.RuneCountInString(s) > text.MaxHashtagLen {
		return query{}, apierr.Validation("query", "query must be at most 50 characters")
	}
	q.body = s
	return q, nil
}

// hashtag reports the tag a SearchPosts query searches (D1 step 5): not an '@' query, and the body is exactly one
// ADR-0010 D8 hashtag, decided by the same extractor posts store tags with. A one-code-point body is a tag. ok is false
// for the "unsupported query" answer (several words, "#123" with no letter, "#go!", a handle).
func (q query) hashtag() (tag string, ok bool) {
	if q.sigil == '@' {
		return "", false
	}
	tags := text.Hashtags("#" + q.body)
	if len(tags) != 1 || tags[0] != q.body {
		return "", false
	}
	return q.body, true
}
