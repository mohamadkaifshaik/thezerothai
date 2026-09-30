// Package ids holds the one uid-format predicate shared by authn (caller uid), identity and graph
// (target uids). It lives in pkg/platform so authn can use it without importing an internal module.
package ids

import "regexp"

// uidRe is `^[A-Za-z0-9-]{1,128}$`. `_` is deliberately excluded (ADR-0008 A3): it is the composite-key
// separator in follows/likes/reposts doc ids, so a uid containing it would make `a_b_c` ambiguous. Firebase
// Auth issues 28-char alphanumeric uids, and we never mint custom-token uids. `-` stays (test fixtures use
// `uid-*`, and it is not a separator). Excluding `_` also implies the Firestore-reserved `__x__` shape is
// impossible for uids (security review L3).
var uidRe = regexp.MustCompile(`^[A-Za-z0-9-]{1,128}$`)

// ValidUID reports whether uid is an acceptable user id. Pure; never touches Firestore.
func ValidUID(uid string) bool {
	return uidRe.MatchString(uid)
}

// UIDMessage is the user-facing validation text for a bad user_id, shared by every graph RPC so the wording
// lives in one place (graph code review N2).
const UIDMessage = "user_id must be 1-128 characters of [A-Za-z0-9-]"
