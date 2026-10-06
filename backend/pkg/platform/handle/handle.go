// Package handle holds the one @handle grammar shared by identity (profile handles) and posts/text (mention
// candidates), ADR-0010 D21 G3. Dependency-free on purpose (the precedent is pkg/platform/ids), so a pure parser
// can use it without importing a domain module. Policy (reserved names, lower-casing, error messages) stays in
// identity.
package handle

// Handle length bounds, in bytes (the class is ASCII).
const (
	MinLen = 3
	MaxLen = 15
)

// IsRune reports whether r is in the handle class [A-Za-z0-9_].
func IsRune(r rune) bool {
	return r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
}

// ValidRun reports whether s matches ^[A-Za-z0-9_]{3,15}$. It does not apply the reserved list or the Firestore
// doc-id shape check.
func ValidRun(s string) bool {
	if len(s) < MinLen || len(s) > MaxLen {
		return false
	}
	for _, r := range s {
		if !IsRune(r) {
			return false
		}
	}
	return true
}
