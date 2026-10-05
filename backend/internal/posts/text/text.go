// Package text is the pure post-text parser (ADR-0010 D7, D8, D9): normalisation, validation, and extraction of
// @mention and #hashtag candidates. It does no I/O. Resolving mention candidates to users, dropping blocked
// ones and storing the result belong to the posts service.
package text

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/handle"
)

// Limits (ADR-0010 D7-D9). The proto and the client use the same numbers.
const (
	MaxRunes    = 280 // code points of the NFC text
	MaxLines    = 10  // at most MaxLines-1 newlines
	MaxMentions = 10
	MaxHashtags = 10

	maxHashtagLen = 50 // code points of the hashtag body
)

// Parsed is the result of Parse: the normalised text (what is stored) and the extracted candidates.
type Parsed struct {
	// Text is the normalised string (D9). It is what gets stored and what Mentions/Hashtags were taken from.
	Text string
	// Mentions are lower-cased handles, deduplicated in first-occurrence order, at most MaxMentions. They are
	// candidates: the caller resolves them against `handles/*`.
	Mentions []string
	// MentionsInURL counts well-formed @mention candidates dropped because they sit inside a URL span (D21 G1),
	// for the mentions_in_url request-log field. A count only: never the handles.
	MentionsInURL int
	// Hashtags are lower-cased NFC bodies, deduplicated in first-occurrence order, at most MaxHashtags.
	Hashtags []string
}

// Parse normalises and validates raw, then extracts mentions and hashtags. Every failure is a VALIDATION error
// with field "text" (an *apierr.Error), so the service can return it unchanged.
func Parse(raw string) (Parsed, error) {
	t, err := Normalize(raw)
	if err != nil {
		return Parsed{}, err
	}
	m, inURL := scanMentions(t)
	return Parsed{Text: t, Mentions: m, MentionsInURL: inURL, Hashtags: Hashtags(t)}, nil
}

// Normalize applies ADR-0010 D9 (with D21 G2 and G4) in order: UTF-8 check; CRLF, CR, U+2028 and U+2029 to LF
// and tab to one space; NFC; trim of whitespace and the invisible set; non-empty (visible content); control and
// bidi-control rejection; at most 280 code points; at most 10 lines.
func Normalize(raw string) (string, error) {
	if !utf8.ValidString(raw) {
		return "", bad("text must be valid UTF-8")
	}
	s := strings.ReplaceAll(raw, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	s = strings.ReplaceAll(s, "\u2028", "\n")
	s = strings.ReplaceAll(s, "\u2029", "\n")
	s = strings.ReplaceAll(s, "\t", " ")
	s = norm.NFC.String(s)
	s = strings.TrimFunc(s, isTrimmable)
	if !hasVisible(s) {
		return "", bad("text must not be empty")
	}
	for _, r := range s {
		if r != '\n' && (unicode.Is(unicode.Cc, r) || isBidiControl(r)) {
			return "", bad("text contains a disallowed control character")
		}
	}
	if utf8.RuneCountInString(s) > MaxRunes {
		return "", bad("text must be at most 280 characters")
	}
	if strings.Count(s, "\n") > MaxLines-1 {
		return "", bad("text must be at most 10 lines")
	}
	return s, nil
}

// isTrimmable is the step-4 trim set: whitespace plus the explicit invisible list U+00AD, U+180E, U+200B,
// U+2060-U+2064, U+FEFF (D21 G4). It is deliberately not all of \p{Cf}: that would trim a flag emoji's tag
// characters and the bidi controls step 6 must reject.
func isTrimmable(r rune) bool {
	switch {
	case unicode.IsSpace(r):
		return true
	case r == 0x00AD, r == 0x180E, r == 0x200B, r == 0xFEFF:
		return true
	default:
		return r >= 0x2060 && r <= 0x2064
	}
}

// hasVisible reports whether s has a rune outside unicode.IsSpace, \p{Cf}, the variation selectors U+FE00-U+FE0F
// and U+E0100-U+E01EF, and the blank-looking set in isBlankLooking (D21 G4 step 5, amended 2026-10-05 for L5).
// Only this emptiness check uses the wide set; it never trims or changes stored text.
func hasVisible(s string) bool {
	for _, r := range s {
		if unicode.IsSpace(r) || unicode.Is(unicode.Cf, r) || (r >= 0xFE00 && r <= 0xFE0F) || (r >= 0xE0100 && r <= 0xE01EF) || isBlankLooking(r) {
			continue
		}
		return true
	}
	return false
}

// isBlankLooking is the explicit list of non-Cf code points that render as blank space: the Hangul fillers
// U+115F, U+1160, U+3164 and U+FFA0, the Braille blank U+2800, the combining grapheme joiner U+034F and the Khmer
// inherent vowels U+17B4 and U+17B5. A post made only of these (and of whitespace and \p{Cf}) has no visible
// content. Spelled out, like isTrimmable, so it is stable across Go's and Dart's Unicode versions.
func isBlankLooking(r rune) bool {
	switch r {
	case 0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0:
		return true
	}
	return false
}

// isBidiControl reports the explicit bidi formatting controls U+202A-U+202E and U+2066-U+2069 (display
// spoofing). LRM/RLM (U+200E/U+200F) and ZWJ/ZWNJ are allowed.
func isBidiControl(r rune) bool {
	return (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069)
}

func bad(msg string) error { return apierr.Validation("text", msg) }

// Mentions extracts @mention candidates from already-normalised text (D7).
func Mentions(s string) []string {
	m, _ := scanMentions(s)
	return m
}

// scanMentions is Mentions plus the number of well-formed candidates excluded by a URL span.
func scanMentions(s string) ([]string, int) {
	rs := []rune(s)
	inURL := 0
	spans := urlSpans(rs)
	var out []string
	seen := map[string]struct{}{}
	for i, r := range rs {
		if r != '@' || !mentionStartOK(rs, i) {
			continue
		}
		j := i + 1
		for j < len(rs) && handle.IsRune(rs[j]) {
			j++
		}
		// The run must be followed by the end or a rune that is not [A-Za-z0-9_@]. The run is maximal, so
		// only '@' can still disqualify it.
		if j < len(rs) && rs[j] == '@' {
			continue
		}
		run := string(rs[i+1 : j])
		if j-(i+1) > handle.MaxLen || !handle.ValidRun(run) {
			continue // too short, or too long: never truncated
		}
		if overlaps(spans, i, j) {
			inURL++
			continue // inside a URL span (D21 G1): not addressed to a person
		}
		out = appendUnique(out, seen, strings.ToLower(run), MaxMentions)
	}
	return out, inURL
}

// mentionStartOK: the '@' is at the start or after a rune that is not \p{L}\p{M}\p{N} and not one of
// `_ @ # / . : & $ + -`.
func mentionStartOK(rs []rune, i int) bool {
	if i == 0 {
		return true
	}
	p := rs[i-1]
	return !isLMN(p) && !strings.ContainsRune("_@#/.:&$+-", p)
}

// Hashtags extracts hashtags from already-normalised text (D8, Indic-safe grammar).
func Hashtags(s string) []string {
	rs := []rune(s)
	spans := urlSpans(rs)
	var out []string
	seen := map[string]struct{}{}
	for i, r := range rs {
		if r != '#' || !hashtagStartOK(rs, i) {
			continue
		}
		j := i + 1
		if j >= len(rs) || !isHashtagFirst(rs[j]) {
			continue
		}
		hasLetter := false
		for j < len(rs) && (j == i+1 || isHashtagRest(rs[j])) {
			hasLetter = hasLetter || unicode.IsLetter(rs[j])
			j++
		}
		if !hasLetter || j-(i+1) > maxHashtagLen {
			continue // no letter (pinned: #123), or longer than 50: never truncated
		}
		if overlaps(spans, i, j) {
			continue // inside a URL span (D21 G1)
		}
		out = appendUnique(out, seen, strings.ToLower(string(rs[i+1:j])), MaxHashtags)
	}
	return out
}

// hashtagStartOK: the '#' is at the start or after a rune that is not \p{L}\p{M}\p{N} and not one of `_ @ # / &`
// (keeps URL fragments and HTML entities such as &#39; out).
func hashtagStartOK(rs []rune, i int) bool {
	if i == 0 {
		return true
	}
	p := rs[i-1]
	return !isLMN(p) && !strings.ContainsRune("_@#/&", p)
}

// isHashtagFirst is [\p{L}\p{N}_]: the first rune is not a mark or joiner.
func isHashtagFirst(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsNumber(r) }

// isHashtagRest is [\p{L}\p{M}\p{N}_\x{200C}\x{200D}].
func isHashtagRest(r rune) bool {
	return isHashtagFirst(r) || unicode.IsMark(r) || r == 0x200C || r == 0x200D
}

func isLMN(r rune) bool { return unicode.IsLetter(r) || unicode.IsMark(r) || unicode.IsNumber(r) }

// appendUnique appends v unless seen already or limit is reached, preserving first-occurrence order.
func appendUnique(out []string, seen map[string]struct{}, v string, limit int) []string {
	if len(out) >= limit {
		return out
	}
	if _, dup := seen[v]; dup {
		return out
	}
	seen[v] = struct{}{}
	return append(out, v)
}

// span is a half-open rune range [start, end) of the text.
type span struct{ start, end int }

// overlaps reports whether [start, end) intersects any span.
func overlaps(spans []span, start, end int) bool {
	for _, sp := range spans {
		if start < sp.end && sp.start < end {
			return true
		}
	}
	return false
}

// isURLTerminator is the ADR-0010 D7 "URL spans" terminator set: < > " and the ECMAScript \s set. It is spelled
// out because unicode.IsSpace adds U+0085 and lacks U+FEFF.
func isURLTerminator(r rune) bool {
	switch r {
	case '<', '>', '"', 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		return true
	}
	return r >= 0x2000 && r <= 0x200A
}

// urlSpans returns the syntactic URL spans of rs per ADR-0010 D7 (D21 G1): case-insensitive http(s)://, then a
// maximal run of non-terminators; a non-overlapping left-to-right scan that resumes at a candidate's end whether
// it was accepted or not; a candidate preceded by \p{L}\p{M}\p{N} is rejected; trailing punctuation and
// unbalanced closing brackets are trimmed. The span is syntactic, never a "safe link" judgement.
func urlSpans(rs []rune) []span {
	var out []span
	for i := 0; i < len(rs); {
		n := schemeLen(rs, i)
		if n == 0 {
			i++
			continue
		}
		end := i + n
		for end < len(rs) && !isURLTerminator(rs[end]) {
			end++
		}
		if end == i+n { // nothing after the scheme: not a candidate
			i++
			continue
		}
		if i == 0 || !isLMN(rs[i-1]) {
			out = append(out, span{i, trimURL(rs, i, end)})
		}
		i = end
	}
	return out
}

// schemeLen returns the length of an "http://" or "https://" (any case) at rs[i:], or 0.
func schemeLen(rs []rune, i int) int {
	for _, sch := range [...]string{"https://", "http://"} {
		if i+len(sch) > len(rs) {
			continue
		}
		ok := true
		for k := 0; k < len(sch); k++ {
			if unicode.ToLower(rs[i+k]) != rune(sch[k]) || rs[i+k] > unicode.MaxASCII {
				ok = false
				break
			}
		}
		if ok {
			return len(sch)
		}
	}
	return 0
}

// trimURL applies the D7 trailing trim to the candidate rs[start:end] and returns the span's end.
func trimURL(rs []rune, start, end int) int {
	for end-start > 1 {
		last := rs[end-1]
		if strings.ContainsRune(".,;:!?'\"", last) {
			end--
			continue
		}
		var open rune
		switch last {
		case ')':
			open = '('
		case ']':
			open = '['
		case '}':
			open = '{'
		}
		if open != 0 && countRune(rs[start:end], last) > countRune(rs[start:end], open) {
			end--
			continue
		}
		break
	}
	return end
}

func countRune(rs []rune, r rune) int {
	n := 0
	for _, x := range rs {
		if x == r {
			n++
		}
	}
	return n
}
