package identity

import (
	"regexp"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
)

var handleRe = regexp.MustCompile(`^[A-Za-z0-9_]{3,15}$`)

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
	if !handleRe.MatchString(handle) || reservedDocID(handle) {
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
