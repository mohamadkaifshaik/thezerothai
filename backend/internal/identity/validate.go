package identity

import (
	"net/url"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/handle"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
)

// reservedHandles blocks a small, obvious set of confusable/system handles. Extend via config later if
// abuse shows up (ADR-0006 abuse-spike runbook), not by redeploying this list under pressure.
var reservedHandles = map[string]struct{}{
	"admin": {}, "administrator": {}, "api": {}, "www": {}, "root": {},
	"dzeroth": {}, "support": {}, "help": {}, "about": {}, "settings": {},
	"null": {}, "undefined": {}, "moderator": {}, "official": {},
}

// handleFormatIssue returns "invalid_format", "reserved", or "" (ok). It never reads Firestore — pure
// validation, safe to call before any quota/rate-limit check.
func handleFormatIssue(h string) string {
	if !handle.ValidRun(h) || reservedDocID(h) {
		return "invalid_format"
	}
	if _, reserved := reservedHandles[strings.ToLower(h)]; reserved {
		return "reserved"
	}
	return ""
}

// normalizeDisplayName applies NFC normalization (proto: "1-50 chars after NFC normalization") and
// trims surrounding whitespace.
func normalizeDisplayName(s string) string {
	return norm.NFC.String(strings.TrimSpace(s))
}

func displayNameIssue(s string) bool {
	n := utf8.RuneCountInString(normalizeDisplayName(s))
	return n < 1 || n > 50
}

func bioIssue(s string) bool {
	return utf8.RuneCountInString(s) > 160
}

// userIDIssue reports whether id is not an acceptable uid (see ids.ValidUID).
func userIDIssue(id string) bool {
	return !ValidUserID(id)
}

// ValidUserID reports whether id is an acceptable uid: it delegates to ids.ValidUID (`^[A-Za-z0-9-]{1,128}$`;
// `_` is reserved as the composite-key separator, ADR-0008 A3), which authn also applies to the caller uid. Exported so
// other modules that accept a caller-supplied user id in their own requests (e.g. graph's Follow/Block
// target) can reuse this instead of duplicating the regex (reuse-first) — graph already depends on this
// package for identity.Directory/Counters.
func ValidUserID(id string) bool {
	return ids.ValidUID(id)
}

// reservedDocID reports whether id has the form __x__, which Firestore rejects as a document id (security
// review L3). Handles (handles/{lower}) still need this check; for uids it is implied by ids.ValidUID
// (no `_` at all, ADR-0008 A3).
func reservedDocID(id string) bool {
	return len(id) >= 4 && strings.HasPrefix(id, "__") && strings.HasSuffix(id, "__")
}

// idempotencyKeyIssue mirrors the common.proto convention: 16-64 chars, [A-Za-z0-9_-]. Delegates to the
// shared pkg/platform/idempotency validator (reuse-first: this used to be a local copy of the same regex).
func idempotencyKeyIssue(key string) bool {
	return !idempotency.KeyFormatValid(key)
}

// Profile extras limits (ADR-0024 D2).
const (
	maxLocationRunes = 30
	maxWebsiteRunes  = 100
)

// isBidiControl reports the explicit bidi formatting controls U+202A-U+202E and U+2066-U+2069 (the same set the post
// text rules reject, ADR-0010 D9; kept local because identity cannot import posts).
func isBidiControl(r rune) bool {
	return (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069)
}

// normalizeLocation applies NFC and trims surrounding whitespace.
func normalizeLocation(s string) string {
	return norm.NFC.String(strings.TrimSpace(s))
}

// locationIssue reports whether the already normalised location is unacceptable: invalid UTF-8, more than 30 code
// points, or any control character (a newline included, it is a single line) or bidi formatting control. "" is a
// valid clear.
func locationIssue(normalized string) bool {
	if !utf8.ValidString(normalized) || utf8.RuneCountInString(normalized) > maxLocationRunes {
		return true
	}
	for _, r := range normalized {
		if unicode.IsControl(r) || isBidiControl(r) {
			return true
		}
	}
	return false
}

// normalizeWebsite validates s as a profile website and returns the value to store: the trimmed text with only the
// scheme lower-cased. ok is false for anything that is not an absolute http or https URL with a non-empty host and no
// userinfo, longer than 100 characters, or containing a control, whitespace or bidi character. "" is a valid clear.
// The server never fetches the URL (no SSRF surface), so this is shape validation only.
func normalizeWebsite(s string) (stored string, ok bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", true
	}
	if !utf8.ValidString(s) || utf8.RuneCountInString(s) > maxWebsiteRunes {
		return "", false
	}
	for _, r := range s {
		if unicode.IsControl(r) || unicode.IsSpace(r) || isBidiControl(r) {
			return "", false
		}
	}
	u, err := url.Parse(s)
	if err != nil || u.Opaque != "" || u.User != nil || u.Host == "" || u.Hostname() == "" {
		return "", false
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "https" && scheme != "http" {
		return "", false
	}
	// u.Scheme is the text before the first ":" of s, so its length is the prefix to lower-case.
	return scheme + s[len(u.Scheme):], true
}
