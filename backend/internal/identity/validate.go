package identity

import (
	"math"
	"strconv"
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

// Profile text rules (ADR-0024 D2, W3-22 L-2). One family for display name, bio, location and website; the Dart
// client mirrors them and both sides run the vectors in testdata/profile_text/ (see its README.md). They apply to new
// writes only: nothing re-validates a stored value on read, and no migration rewrites one.
//
// Every field is trimmed first (Unicode White_Space plus U+FEFF, which is what Dart's String.trim removes), then
// NFC-normalized (website excepted: it is stored as typed), and every rule below is applied to that result.

// isProfileSpace is the trim set: unicode.IsSpace (Unicode White_Space) plus the byte order mark U+FEFF, which Dart's
// String.trim and RegExp \s treat as whitespace and Go's unicode.IsSpace does not.
func isProfileSpace(r rune) bool { return unicode.IsSpace(r) || r == '\uFEFF' }

// trimProfileText removes isProfileSpace runes at both ends.
func trimProfileText(s string) string { return strings.TrimFunc(s, isProfileSpace) }

// isLineSeparator reports the Unicode line and paragraph separators (categories Zl and Zp: U+2028, U+2029). The other
// line breaks (LF, VT, FF, CR, NEL) are Cc and are caught by unicode.IsControl.
func isLineSeparator(r rune) bool { return unicode.In(r, unicode.Zl, unicode.Zp) }

// singleLineIssue reports a rune that must never appear in a one-line field (display name, location): any control
// character (Cc, a newline included), a line or paragraph separator, or a bidi formatting control.
func singleLineIssue(s string) bool {
	for _, r := range s {
		if unicode.IsControl(r) || isLineSeparator(r) || isBidiControl(r) {
			return true
		}
	}
	return false
}

// normalizeDisplayName applies NFC normalization (proto: "1-50 chars after NFC normalization") and
// trims surrounding whitespace.
func normalizeDisplayName(s string) string {
	return norm.NFC.String(trimProfileText(s))
}

// displayNameIssue reports whether s is not an acceptable display name: invalid UTF-8; fewer than 1 or more than 50
// code points after trim and NFC; or a control character, line separator or bidi formatting control (a display name
// is one line; an RLO would reorder the header and every post row's author snapshot, W3-22 L-2c).
func displayNameIssue(s string) bool {
	if !utf8.ValidString(s) {
		return true
	}
	n := normalizeDisplayName(s)
	if c := utf8.RuneCountInString(n); c < 1 || c > 50 {
		return true
	}
	return singleLineIssue(n)
}

// normalizeBio applies trim and NFC. It is what is stored, and what bioIssue counts.
func normalizeBio(s string) string {
	return norm.NFC.String(trimProfileText(s))
}

// bioIssue reports whether s is not an acceptable bio: invalid UTF-8; more than 160 code points after trim and NFC; or
// a control character other than "\n", a line or paragraph separator, or a bidi formatting control. "\n" is the one
// line break a bio keeps ("\r" is rejected, not folded: the clients send "\n").
func bioIssue(s string) bool {
	if !utf8.ValidString(s) {
		return true
	}
	n := normalizeBio(s)
	if utf8.RuneCountInString(n) > 160 {
		return true
	}
	for _, r := range n {
		if r != '\n' && (unicode.IsControl(r) || isLineSeparator(r) || isBidiControl(r)) {
			return true
		}
	}
	return false
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

// normalizeLocation applies trim and NFC.
func normalizeLocation(s string) string {
	return norm.NFC.String(trimProfileText(s))
}

// locationIssue reports whether the already normalised location is unacceptable: invalid UTF-8, more than 30 code
// points, or any control character (a newline included, it is a single line), line or paragraph separator (U+2028,
// U+2029: the header draws a location with no line limit, so one would paint a fake second line, W3-22 L-2a) or bidi
// formatting control. "" is a valid clear.
func locationIssue(normalized string) bool {
	if !utf8.ValidString(normalized) || utf8.RuneCountInString(normalized) > maxLocationRunes {
		return true
	}
	return singleLineIssue(normalized)
}

// websiteForbidden is the set of code points a website may not contain anywhere: exactly the client's
// (app/lib/shared/format/profile_website.dart `_forbidden`): whitespace (\s, which includes U+FEFF), C0 and C1
// controls, and the bidi controls U+061C, U+200E, U+200F, U+202A-U+202E and U+2066-U+2069.
func websiteForbidden(r rune) bool {
	return unicode.IsControl(r) || isProfileSpace(r) || isBidiControl(r) || r == '\u061C' || r == '\u200E' || r == '\u200F'
}

// normalizeWebsite validates s as a profile website and returns the value to store: the trimmed text with only the
// scheme lower-cased. ok is false unless s is one the client can render and open (parseWebsite); "" is a valid clear.
// The server never fetches the URL (no SSRF surface), so this is shape validation only.
func normalizeWebsite(s string) (stored string, ok bool) {
	stored, _, ok = parseWebsite(s)
	return stored, ok
}

// parseWebsite is the server twin of the client's parseProfileWebsite (ADR-0024 D2, W3-22 L-2b/L-3): it accepts a
// website only if the client would show and open it, so a saved website never silently disappears, and it adds the
// host-class rules of L-3 (the client adopts them too; both run testdata/profile_text/website.json).
//
//   - trimmed, at most 100 code points, valid UTF-8, no code point of websiteForbidden;
//   - scheme "http" or "https" in any case, then "://"; the authority is everything up to the first "/", "?" or "#";
//     the path, query and fragment after it are not inspected (beyond the forbidden set);
//   - the authority has no "@" (userinfo) and no "[" (IPv6 literal); an optional ":port" after its LAST colon, digits
//     only, 1..65535, may be empty ("host:" is accepted);
//   - the host is lower-cased, loses ONE trailing dot, and every label is non-empty; a label with a non-ASCII code
//     point is encoded as "xn--" + RFC 3492 punycode (raw: no NFKC mapping), so a look-alike host is judged by the
//     name it really resolves to; each (encoded) label is at most 63 bytes of [a-z0-9_-];
//   - L-3: at least two labels; the last label is TLD-shaped, "[a-z]{2,63}" or "xn--[a-z0-9-]+"; the host is not
//     localhost, local, internal or home.arpa nor a subdomain of one. A TLD-shaped last label is also what rules out
//     IPv4 literals in dotted, decimal ("3232235777") and hex ("0x7f.1") forms.
//
// host is the lower-case ASCII host the client displays (no port, no trailing dot).
func parseWebsite(s string) (stored, host string, ok bool) {
	s = trimProfileText(s)
	if s == "" {
		return "", "", true
	}
	if !utf8.ValidString(s) || utf8.RuneCountInString(s) > maxWebsiteRunes {
		return "", "", false
	}
	for _, r := range s {
		if websiteForbidden(r) {
			return "", "", false
		}
	}
	scheme, rest, found := strings.Cut(s, "://")
	if lower := strings.ToLower(scheme); !found || (lower != "http" && lower != "https") {
		return "", "", false
	}
	authority := rest
	if i := strings.IndexAny(rest, "/?#"); i >= 0 {
		authority = rest[:i]
	}
	if strings.ContainsAny(authority, "@[") {
		return "", "", false
	}
	hostPart := authority
	if colon := strings.LastIndex(authority, ":"); colon >= 0 {
		if digits := authority[colon+1:]; digits != "" && !validPort(digits) {
			return "", "", false
		}
		hostPart = authority[:colon]
	}
	host, ok = websiteHost(hostPart)
	if !ok {
		return "", "", false
	}
	// scheme is the text before the first "://", so its length is the prefix to lower-case.
	return strings.ToLower(scheme) + s[len(scheme):], host, true
}

// validPort reports whether digits is a TCP port: ASCII digits only (leading zeros allowed), value 1..65535.
func validPort(digits string) bool {
	for i := 0; i < len(digits); i++ {
		if digits[i] < '0' || digits[i] > '9' {
			return false
		}
	}
	n, err := strconv.ParseUint(digits, 10, 32)
	return err == nil && n >= 1 && n <= 65535
}

// internalHostSuffixes are the names that only mean something on the viewer's own machine or network (RFC 6761
// localhost, RFC 6762 local, the ICANN-reserved private-use internal, RFC 8375 home.arpa): a profile link to one is a tap-to-hit-my-LAN
// link (W3-22 L-3). A host is refused if it equals one or is a subdomain of one.
var internalHostSuffixes = []string{"localhost", "local", "internal", "home.arpa"}

// websiteHost normalises one host the way the client does (lower-case, one trailing dot dropped, per-label punycode)
// and applies the L-3 host-class rules. It returns the ASCII host.
func websiteHost(raw string) (string, bool) {
	host := strings.TrimSuffix(strings.ToLower(raw), ".")
	if host == "" {
		return "", false
	}
	labels := strings.Split(host, ".")
	for i, label := range labels {
		if label == "" {
			return "", false
		}
		if !isASCII(label) {
			label = "xn--" + punycodeEncode(label)
		}
		if len(label) > 63 || !asciiHostLabel(label) {
			return "", false
		}
		labels[i] = label
	}
	if len(labels) < 2 || !tldShaped(labels[len(labels)-1]) {
		return "", false
	}
	host = strings.Join(labels, ".")
	for _, suffix := range internalHostSuffixes {
		if host == suffix || strings.HasSuffix(host, "."+suffix) {
			return "", false
		}
	}
	return host, true
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

// asciiHostLabel is the client's label alphabet: [a-z0-9_-]+ (the caller has lower-cased and encoded the label).
func asciiHostLabel(label string) bool {
	if label == "" {
		return false
	}
	for i := 0; i < len(label); i++ {
		c := label[i]
		allowed := c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-'
		if !allowed {
			return false
		}
	}
	return true
}

// tldShaped reports whether the last host label looks like a top-level domain: "[a-z]{2,63}" or an internationalised
// "xn--[a-z0-9-]+" (the label has already been checked as at most 63 bytes of [a-z0-9_-]). A label with a digit
// (the last part of "127.0.0.1", "0x7f.0x1", a decimal IPv4) is not.
func tldShaped(label string) bool {
	if rest, ok := strings.CutPrefix(label, "xn--"); ok {
		return rest != "" && !strings.Contains(rest, "_")
	}
	if len(label) < 2 {
		return false
	}
	for i := 0; i < len(label); i++ {
		if label[i] < 'a' || label[i] > 'z' {
			return false
		}
	}
	return true
}

// RFC 3492 Punycode constants.
const (
	pcBase        = 36
	pcTMin        = 1
	pcTMax        = 26
	pcSkew        = 38
	pcDamp        = 700
	pcInitialBias = 72
	pcInitialN    = 128
)

// punycodeEncode is the RFC 3492 encoding of one label, without the "xn--" prefix: a line-for-line port of the
// client's punycodeEncode (profile_website.dart), so the 63-byte length check agrees on both sides. The basic (ASCII)
// code points are copied first, then the others are encoded as deltas. The label must be valid UTF-8.
func punycodeEncode(label string) string {
	cps := []rune(label)
	out := make([]byte, 0, len(label)+8)
	for _, cp := range cps {
		if cp < 0x80 {
			out = append(out, byte(cp))
		}
	}
	basic := len(out)
	handled := basic
	if basic > 0 {
		out = append(out, '-')
	}
	n, delta, bias := pcInitialN, 0, pcInitialBias
	for handled < len(cps) {
		m := math.MaxInt32
		for _, cp := range cps {
			if int(cp) >= n && int(cp) < m {
				m = int(cp)
			}
		}
		delta += (m - n) * (handled + 1)
		n = m
		for _, cp := range cps {
			if int(cp) < n {
				delta++
			}
			if int(cp) == n {
				q := delta
				for k := pcBase; ; k += pcBase {
					t := pcTMin
					if k >= bias+pcTMax {
						t = pcTMax
					} else if k > bias {
						t = k - bias
					}
					if q < t {
						break
					}
					out = append(out, pcDigit(t+(q-t)%(pcBase-t)))
					q = (q - t) / (pcBase - t)
				}
				out = append(out, pcDigit(q))
				bias = pcAdapt(delta, handled+1, handled == basic)
				delta = 0
				handled++
			}
		}
		delta++
		n++
	}
	return string(out)
}

// pcDigits are the 36 punycode digit characters; the encoder only ever asks for 0..35.
const pcDigits = "abcdefghijklmnopqrstuvwxyz0123456789"

func pcDigit(d int) byte {
	if d < 0 || d >= len(pcDigits) {
		return '-' // unreachable by construction; never panics on a request path
	}
	return pcDigits[d]
}

func pcAdapt(delta, points int, first bool) int {
	if first {
		delta /= pcDamp
	} else {
		delta /= 2
	}
	delta += delta / points
	k := 0
	for delta > ((pcBase-pcTMin)*pcTMax)/2 {
		delta /= pcBase - pcTMin
		k += pcBase
	}
	return k + (pcBase-pcTMin+1)*delta/(delta+pcSkew)
}
