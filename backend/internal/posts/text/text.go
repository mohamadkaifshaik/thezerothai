// Package text is the pure post-text parser (ADR-0010 D7, D8, D9): normalisation, validation, and extraction of
// @mention and #hashtag candidates. It does no I/O. Resolving mention candidates to users, dropping blocked
// ones and storing the result belong to the posts service.
package text

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// Limits (ADR-0010 D7-D9). The proto and the client use the same numbers.
const (
	MaxRunes    = 280 // code points of the NFC text
	MaxLines    = 10  // at most MaxLines-1 newlines
	MaxMentions = 10
	MaxHashtags = 10

	maxMentionRun = 15 // identity's handle grammar, [A-Za-z0-9_]{3,15}
	maxHashtagLen = 50 // code points of the hashtag body
)

// Parsed is the result of Parse: the normalised text (what is stored) and the extracted candidates.
type Parsed struct {
	// Text is the normalised string (D9). It is what gets stored and what Mentions/Hashtags were taken from.
	Text string
	// Mentions are lower-cased handles, deduplicated in first-occurrence order, at most MaxMentions. They are
	// candidates: the caller resolves them against `handles/*`.
	Mentions []string
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
	return Parsed{Text: t, Mentions: Mentions(t), Hashtags: Hashtags(t)}, nil
}

// Normalize applies ADR-0010 D9 in order: UTF-8 check; CRLF and CR to LF and tab to one space; NFC; trim;
// non-empty; control and bidi-control rejection; at most 280 code points; at most 10 lines.
func Normalize(raw string) (string, error) {
	if !utf8.ValidString(raw) {
		return "", bad("text must be valid UTF-8")
	}
	s := strings.ReplaceAll(raw, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	s = strings.ReplaceAll(s, "\t", " ")
	s = norm.NFC.String(s)
	s = strings.TrimFunc(s, unicode.IsSpace)
	if s == "" {
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

// isBidiControl reports the explicit bidi formatting controls U+202A-U+202E and U+2066-U+2069 (display
// spoofing). LRM/RLM (U+200E/U+200F) and ZWJ/ZWNJ are allowed.
func isBidiControl(r rune) bool {
	return (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069)
}

func bad(msg string) error { return apierr.Validation("text", msg) }

// Mentions extracts @mention candidates from already-normalised text (D7).
func Mentions(s string) []string {
	rs := []rune(s)
	var out []string
	seen := map[string]struct{}{}
	for i, r := range rs {
		if r != '@' || !mentionStartOK(rs, i) {
			continue
		}
		j := i + 1
		for j < len(rs) && isHandleRune(rs[j]) {
			j++
		}
		// The run must be followed by the end or a rune that is not [A-Za-z0-9_@]. The run is maximal, so
		// only '@' can still disqualify it.
		if j < len(rs) && rs[j] == '@' {
			continue
		}
		run := string(rs[i+1 : j])
		if j-(i+1) > maxMentionRun || !identity.ValidHandleRun(run) {
			continue // too short, or too long: never truncated
		}
		out = appendUnique(out, seen, strings.ToLower(run), MaxMentions)
	}
	return out
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

func isHandleRune(r rune) bool {
	return r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
}

// Hashtags extracts hashtags from already-normalised text (D8, Indic-safe grammar).
func Hashtags(s string) []string {
	rs := []rune(s)
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
