package identity

import (
	"regexp"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

var handleRe = regexp.MustCompile(`^[A-Za-z0-9_]{3,15}$`)

// userIDRe is a conservative Firebase UID charset check: Firebase Auth itself only requires a non-empty
// string of at most 128 characters, but every uid it actually issues (and every provider uid we accept)
// is alphanumeric plus '_'/'-'. Rejecting anything else here is a validation-layer defense (GetProfile
// accepts a caller-supplied user_id) that costs nothing and never rejects a real uid.
var userIDRe = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// reservedHandles blocks a small, obvious set of confusable/system handles. Extend via config later if
// abuse shows up (ADR-0006 abuse-spike runbook), not by redeploying this list under pressure.
var reservedHandles = map[string]struct{}{
	"admin": {}, "administrator": {}, "api": {}, "www": {}, "root": {},
	"dzeroth": {}, "support": {}, "help": {}, "about": {}, "settings": {},
	"null": {}, "undefined": {}, "moderator": {}, "official": {},
}

// handleFormatIssue returns "invalid_format", "reserved", or "" (ok). It never reads Firestore — pure
// validation, safe to call before any quota/rate-limit check.
func handleFormatIssue(handle string) string {
	if !handleRe.MatchString(handle) {
		return "invalid_format"
	}
	if _, reserved := reservedHandles[strings.ToLower(handle)]; reserved {
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

// userIDIssue reports whether id is not a plausible Firebase UID (length/charset; see userIDRe).
func userIDIssue(id string) bool {
	return !ValidUserID(id)
}

// ValidUserID reports whether id is a plausible Firebase UID (length/charset; see userIDRe). Exported so
// other modules that accept a caller-supplied user id in their own requests (e.g. graph's Follow/Block
// target) can reuse this instead of duplicating the regex (reuse-first) — graph already depends on this
// package for identity.Directory/Counters.
func ValidUserID(id string) bool {
	return userIDRe.MatchString(id)
}

// idempotencyKeyIssue mirrors the common.proto convention: 16-64 chars, [A-Za-z0-9_-]. Delegates to the
// shared pkg/platform/idempotency validator (reuse-first: this used to be a local copy of the same regex).
func idempotencyKeyIssue(key string) bool {
	return !idempotency.KeyFormatValid(key)
}
