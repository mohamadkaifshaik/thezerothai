// Package clientinfo reads the app's capability header (plan 6 section 3.1, "Too-old apps") into the request context and
// holds the per-platform floors an operator can raise to switch messaging off for builds that are too old for it.
//
// The app sends `x-dz-client: <platform>/<level>` on every request (app/lib/core/app_build.dart): the platform word is
// web, android or ios (any other target sends "other"), and the level is the app's hand-kept E2EE capability level, not
// the store build number. Builds made before the header existed send nothing.
//
// NOT A SECURITY CONTROL. A modified app can send any header. The floor only spares honest old apps blank bubbles and
// generic errors; it must never be used for authorisation, rate limits or anything a caller gains by lying. The security
// backstop for messaging stays the server's own rules (ENCRYPTION_REQUIRED).
//
// Parsing is lenient and never fails a request: a missing header is an unknown platform at level 0; a value that is not
// exactly "<word>/<level>" after trimming (over 32 bytes, no slash, extra slashes, a list) is an unknown platform at
// level 0; so is a word that, ASCII-lowercased (A-Z only, no Unicode folding), is empty or has a byte outside [a-z]
// ("/1", "web2/1", a control byte, any non-ASCII byte such as a lookalike letter); a known platform with a bad level
// (negative, signed, not decimal, above MaxLevel) keeps the platform at level 0; any other [a-z] word ("other",
// "desktop") is an unknown platform with its level. An unknown platform is held to the highest of the three floors
// (Floors.For).
//
// The request log line (mw.Logging) gets client_platform (android, web, ios or "unknown") and client_level (the parsed
// integer); the raw header value is never logged.
//
// Cost: the stamp reads one header and does no I/O, so it adds no Firestore read or write to any request.
package clientinfo

import (
	"context"
	"strconv"
	"strings"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Header is the request header carrying "<platform>/<level>" (the app sends it lowercase; HTTP headers are
// case-insensitive).
const Header = "X-Dz-Client"

// MaxLevel is the highest capability level and the highest floor (config validates CLIENT_FLOOR_* to 0..MaxLevel). A
// level above it is a bad value and reads as 0.
const MaxLevel = 1000

// maxValueLen bounds the header value considered at all ("android/1000" is 12 bytes); a longer value is garbage.
const maxValueLen = 32

// FeatureMessaging is the feature name a floor switches off (GetMeResponse.features_needing_update and the
// FEATURE_DISABLED metadata["feature"]): direct messages and the key directory.
const FeatureMessaging = "messaging"

// Platform is the platform word of the header. Only the three named values are known.
type Platform string

const (
	// PlatformUnknown is a missing header, garbage, or a word other than the three below ("other").
	PlatformUnknown Platform = ""
	PlatformAndroid Platform = "android"
	PlatformWeb     Platform = "web"
	PlatformIOS     Platform = "ios"
)

// Client is one request's parsed header. The zero value is a missing header (unknown platform, level 0).
type Client struct {
	Platform Platform
	Level    int
}

// Parse reads a header value; it never fails (see the package doc for the rules).
func Parse(v string) Client {
	v = strings.TrimSpace(v)
	// The cap is checked before any lowercasing, so an over-long value costs nothing more.
	if v == "" || len(v) > maxValueLen {
		return Client{}
	}
	word, level, ok := strings.Cut(v, "/")
	if !ok || strings.Contains(level, "/") {
		return Client{}
	}
	word, ok = asciiWord(word)
	if !ok {
		return Client{}
	}
	c := Client{Level: parseLevel(level)}
	switch p := Platform(word); p {
	case PlatformAndroid, PlatformWeb, PlatformIOS:
		c.Platform = p
	}
	return c
}

// asciiWord lowercases w byte by byte, ASCII only (A-Z to a-z), and reports whether the result is a non-empty run of
// [a-z]. It deliberately does not use strings.ToLower: Unicode folding maps some non-ASCII letters onto ASCII ones
// (U+0130 to 'i', U+212A KELVIN SIGN to 'k'), which would let "İOS/0" read as ios. Any byte outside [A-Za-z],
// including every byte of a multi-byte character, makes the word garbage.
func asciiWord(w string) (string, bool) {
	if w == "" {
		return "", false
	}
	b := make([]byte, len(w))
	for i := 0; i < len(w); i++ {
		switch c := w[i]; {
		case c >= 'a' && c <= 'z':
			b[i] = c
		case c >= 'A' && c <= 'Z':
			b[i] = c + ('a' - 'A')
		default:
			return "", false
		}
	}
	return string(b), true
}

// unknownLogName is the request-log word for PlatformUnknown (a missing header, garbage or a word other than the three).
const unknownLogName = "unknown"

// logName is the platform word written on the request log line: one of the three known words or "unknown". It is
// never the raw header value.
func (p Platform) logName() string {
	if p == PlatformUnknown {
		return unknownLogName
	}
	return string(p)
}

// stampCtx stamps the parsed header into ctx and records it on the request log line (mw.Logging) as client_platform
// (the enum word, "unknown" for anything else) and client_level (the parsed integer). The raw header is never logged.
// Without a logger.RequestInfo in ctx (no request log above) the log fields are a no-op.
func stampCtx(ctx context.Context, header string) context.Context {
	c := Parse(header)
	logger.SetRequestField(ctx, "client_platform", c.Platform.logName())
	logger.SetRequestField(ctx, "client_level", c.Level)
	return WithClient(ctx, c)
}

// parseLevel is a plain decimal in 0..MaxLevel, else 0 (no sign, no spaces, no fraction).
func parseLevel(s string) int {
	if s == "" {
		return 0
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0
		}
	}
	n, err := strconv.Atoi(s)
	if err != nil || n > MaxLevel {
		return 0 // out of range: a bad value, never an error
	}
	return n
}

type ctxKey struct{}

// WithClient stamps c into ctx.
func WithClient(ctx context.Context, c Client) context.Context {
	return context.WithValue(ctx, ctxKey{}, c)
}

// FromContext is the stamped client; an unstamped context reads as a missing header (the zero Client).
func FromContext(ctx context.Context) Client {
	c, _ := ctx.Value(ctxKey{}).(Client)
	return c
}

// Interceptor stamps every handler call (unary and streaming) with the parsed header before the next interceptor and the
// handler run. Client-side calls pass through untouched. No I/O.
func Interceptor() connect.Interceptor { return stamp{} }

type stamp struct{}

func (stamp) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
		if !req.Spec().IsClient {
			ctx = stampCtx(ctx, req.Header().Get(Header))
		}
		return next(ctx, req)
	}
}

func (stamp) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (stamp) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return func(ctx context.Context, conn connect.StreamingHandlerConn) error {
		return next(stampCtx(ctx, conn.RequestHeader().Get(Header)), conn)
	}
}

// Floors is the lowest capability level each platform must report to use messaging (CLIENT_FLOOR_ANDROID, _WEB, _IOS;
// 0..MaxLevel). The zero value is no floor at all: nothing is ever below it.
type Floors struct {
	Android int
	Web     int
	IOS     int
}

// Raised reports whether any floor is above 0.
func (f Floors) Raised() bool { return f.Android > 0 || f.Web > 0 || f.IOS > 0 }

// For is the floor of platform p; an unknown platform uses the highest of the three.
func (f Floors) For(p Platform) int {
	switch p {
	case PlatformAndroid:
		return f.Android
	case PlatformWeb:
		return f.Web
	case PlatformIOS:
		return f.IOS
	}
	return max(f.Android, f.Web, f.IOS)
}

// Below reports whether c is older than its platform's floor (a build at the floor passes).
func (f Floors) Below(c Client) bool { return c.Level < f.For(c.Platform) }

// BelowFloor is Below for the client stamped in ctx (an unstamped context is a missing header). It is the seam the
// identity, messaging and keys modules read (their consumer-side ClientFloor interfaces).
func (f Floors) BelowFloor(ctx context.Context) bool { return f.Below(FromContext(ctx)) }

// UpdateRequired is the refusal of a feature to a build below the floor: FAILED_PRECONDITION + FEATURE_DISABLED (the
// shared message), metadata["feature"] = feature and metadata["update_required"] = "true". Old builds treat it as any
// FEATURE_DISABLED (hide the feature, refresh GetMe); new builds show the update prompt. It carries nothing about any
// other user. The request log line gets feature, update_required and outcome rejected:update_required.
func UpdateRequired(ctx context.Context, feature string) error {
	logger.SetRequestField(ctx, "feature_disabled", true)
	logger.SetRequestField(ctx, "feature", feature)
	logger.SetRequestField(ctx, "update_required", true)
	logger.SetRequestField(ctx, "outcome", "rejected:update_required")
	return flags.DisabledError().WithMeta("feature", feature).WithMeta("update_required", "true")
}
