package clientinfo_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/clientinfo"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// TestParse is the parse table of plan 6 section 3.1: lenient, never an error. A value that is not exactly
// "<word>/<level>" after trimming (over 32 bytes, no slash, extra slashes), or whose ASCII-lowercased word is empty or
// has a byte outside [a-z], is an unknown platform at level 0; a known platform with a bad level keeps the platform at level 0;
// an unknown [a-z] word (other, desktop, ...) keeps its level but is held to the highest floor
// (TestFloors_UnknownPlatformUsesTheHighestFloor).
func TestParse(t *testing.T) {
	unknown0 := clientinfo.Client{Platform: clientinfo.PlatformUnknown, Level: 0}
	for _, tc := range []struct {
		name  string
		value string
		want  clientinfo.Client
	}{
		// Good values, exactly what app/lib/core/app_build.dart sends.
		{"web/1", "web/1", clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 1}},
		{"android/1", "android/1", clientinfo.Client{Platform: clientinfo.PlatformAndroid, Level: 1}},
		{"ios/0", "ios/0", clientinfo.Client{Platform: clientinfo.PlatformIOS, Level: 0}},
		{"other/0 is an unknown platform", "other/0", unknown0},
		{"other with a level keeps the level", "other/3", clientinfo.Client{Platform: clientinfo.PlatformUnknown, Level: 3}},
		{"the highest level", "android/1000", clientinfo.Client{Platform: clientinfo.PlatformAndroid, Level: 1000}},
		{"leading zeros", "web/007", clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 7}},
		// Missing: an old build sends no header.
		{"missing header", "", unknown0},
		{"only spaces", "   ", unknown0},
		// Case and spaces are forgiven.
		{"mixed case", "Android/1", clientinfo.Client{Platform: clientinfo.PlatformAndroid, Level: 1}},
		{"upper case", "WEB/2", clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 2}},
		{"surrounding spaces", "  web/1\t", clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 1}},
		// The case fold is ASCII only (A-Z to a-z): upper case known words are known, with spaces trimmed as above
		// (strings.TrimSpace, so Unicode spaces around the value are trimmed too, as before the ASCII fold).
		{"all upper web", "WEB/1", clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 1}},
		{"upper ios", "IOS/0", clientinfo.Client{Platform: clientinfo.PlatformIOS, Level: 0}},
		{"upper case with surrounding spaces", "\t WEB/1 \n", clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 1}},
		{"mixed case with surrounding spaces", " Android/1 ", clientinfo.Client{Platform: clientinfo.PlatformAndroid, Level: 1}},
		{"no-break space around is trimmed", " web/1 ", clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 1}},
		// A non-ASCII lookalike never folds into a word. U+212A KELVIN SIGN lowercases to ASCII 'k' under Unicode
		// folding (strings.ToLower), which would make "des<K>top/1" the word "desktop" with level 1.
		{"kelvin sign lookalike", "desKtop/1", unknown0},
		{"kelvin sign upper lookalike", "DESKTOP/1", unknown0},
		{"cyrillic a lookalike", "аndroid/1", unknown0},
		{"cyrillic capital lookalike", "WЕB/1", unknown0},
		{"dotted capital i lookalike", "İOS/0", unknown0},
		{"invalid utf-8 byte", "web\xff/1", unknown0},
		// Bad levels: the platform is kept, the level is 0.
		{"negative", "android/-1", clientinfo.Client{Platform: clientinfo.PlatformAndroid, Level: 0}},
		{"plus sign", "android/+1", clientinfo.Client{Platform: clientinfo.PlatformAndroid, Level: 0}},
		{"one past the highest", "web/1001", clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 0}},
		{"huge number", "web/99999999999999999999999", clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 0}},
		{"empty level", "ios/", clientinfo.Client{Platform: clientinfo.PlatformIOS, Level: 0}},
		{"letters", "android/one", clientinfo.Client{Platform: clientinfo.PlatformAndroid, Level: 0}},
		{"decimal", "android/1.5", clientinfo.Client{Platform: clientinfo.PlatformAndroid, Level: 0}},
		{"inner space", "web/ 1", clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 0}},
		// Garbage: unknown platform, level 0.
		{"no slash", "android1", unknown0},
		{"extra slashes", "web/1/2", unknown0},
		{"two slashes", "web//1", unknown0},
		{"slash only", "/", unknown0},
		// A platform word that is empty or has a byte outside [a-z] (after lowercasing) is garbage too.
		{"empty platform", "/1", unknown0},
		{"control bytes", "web\x00/1", unknown0},
		{"digit in the word", "web2/1", unknown0},
		{"underscore in the word", "my_os/1", unknown0},
		{"non-ascii word", "wéb/1", unknown0},
		{"unknown word", "desktop/1", clientinfo.Client{Platform: clientinfo.PlatformUnknown, Level: 1}},
		{"over-long value", "android/" + strings.Repeat("1", 64), unknown0},
		{"over-long platform", strings.Repeat("a", 40) + "/1", unknown0},
		{"over-long after trimming only", "  " + strings.Repeat("A", 31) + "/1  ", unknown0},
		{"at the cap after trimming", "  " + strings.Repeat("q", 28) + "/123  ", clientinfo.Client{Platform: clientinfo.PlatformUnknown, Level: 123}},
		{"comma list", "web/1, android/1", unknown0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := clientinfo.Parse(tc.value); got != tc.want {
				t.Errorf("Parse(%q) = %+v, want %+v", tc.value, got, tc.want)
			}
		})
	}
}

// TestFloors_UnknownPlatformUsesTheHighestFloor: a request whose platform is missing or not one of the three uses the
// highest of the three floors (plan 6 section 3.1).
func TestFloors_UnknownPlatformUsesTheHighestFloor(t *testing.T) {
	f := clientinfo.Floors{Android: 1, Web: 3, IOS: 2}
	for _, tc := range []struct {
		p    clientinfo.Platform
		want int
	}{
		{clientinfo.PlatformAndroid, 1},
		{clientinfo.PlatformWeb, 3},
		{clientinfo.PlatformIOS, 2},
		{clientinfo.PlatformUnknown, 3},
		{clientinfo.Platform("other"), 3},
	} {
		if got := f.For(tc.p); got != tc.want {
			t.Errorf("For(%q) = %d, want %d", tc.p, got, tc.want)
		}
	}
	if !f.Below(clientinfo.Parse("other/2")) {
		t.Error("other/2 must be below the highest floor 3")
	}
	if f.Below(clientinfo.Parse("other/3")) {
		t.Error("other/3 meets the highest floor 3")
	}
	if !f.Below(clientinfo.Parse("")) {
		t.Error("a missing header must be below a raised floor")
	}
}

// TestFloors_Below: the floor is inclusive (a build AT the floor passes), per platform.
func TestFloors_Below(t *testing.T) {
	f := clientinfo.Floors{Android: 1, Web: 1, IOS: 1}
	for _, tc := range []struct {
		value string
		below bool
	}{
		{"android/1", false},
		{"web/1", false},
		{"web/2", false},
		{"ios/0", true},
		{"android/0", true},
		{"", true},
		{"other/0", true},
		{"android/-1", true},
	} {
		if got := f.Below(clientinfo.Parse(tc.value)); got != tc.below {
			t.Errorf("Below(%q) = %v, want %v", tc.value, got, tc.below)
		}
	}
}

// TestFloors_Floor0ChangesNothing: with every floor 0 (the default) no client is ever below, header or not.
func TestFloors_Floor0ChangesNothing(t *testing.T) {
	var f clientinfo.Floors
	if f.Raised() {
		t.Error("the zero Floors must not be raised")
	}
	for _, v := range []string{"", "garbage", "other/0", "ios/0", "android/0", "web/1", "android/-5", "web/1/2"} {
		if f.Below(clientinfo.Parse(v)) {
			t.Errorf("floor 0: Below(%q) = true, want false", v)
		}
		if f.BelowFloor(clientinfo.WithClient(context.Background(), clientinfo.Parse(v))) {
			t.Errorf("floor 0: BelowFloor(%q) = true, want false", v)
		}
	}
	if f.BelowFloor(context.Background()) {
		t.Error("floor 0: an unstamped context must not be below")
	}
	if !(clientinfo.Floors{IOS: 1}).Raised() {
		t.Error("a floor of 1 is raised")
	}
}

// TestContext: an unstamped context reads as a missing header (unknown platform, level 0), so a raised floor holds it
// (fails closed for the update prompt, never for authorisation: the header is not a security control).
func TestContext(t *testing.T) {
	if got := clientinfo.FromContext(context.Background()); got != (clientinfo.Client{}) {
		t.Errorf("unstamped = %+v, want the zero client", got)
	}
	c := clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 1}
	ctx := clientinfo.WithClient(context.Background(), c)
	if got := clientinfo.FromContext(ctx); got != c {
		t.Errorf("stamped = %+v, want %+v", got, c)
	}
	f := clientinfo.Floors{Web: 2, Android: 1}
	if !f.BelowFloor(ctx) {
		t.Error("web/1 is below a web floor of 2")
	}
	if !f.BelowFloor(context.Background()) {
		t.Error("an unstamped context is below a raised floor")
	}
}

// TestInterceptor_StampsUnary: the unary handler side reads the header into the context before next runs; the client
// side is untouched.
func TestInterceptor_StampsUnary(t *testing.T) {
	ic := clientinfo.Interceptor()
	for _, tc := range []struct {
		header string
		want   clientinfo.Client
	}{
		{"android/1", clientinfo.Client{Platform: clientinfo.PlatformAndroid, Level: 1}},
		{"", clientinfo.Client{}},
		{"junk", clientinfo.Client{}},
	} {
		var got clientinfo.Client
		var ran bool
		next := connect.UnaryFunc(func(ctx context.Context, _ connect.AnyRequest) (connect.AnyResponse, error) {
			ran = true
			got = clientinfo.FromContext(ctx)
			return nil, nil
		})
		req := connect.NewRequest(&commonv1.ErrorDetail{})
		if tc.header != "" {
			req.Header().Set(clientinfo.Header, tc.header)
		}
		if _, err := ic.WrapUnary(next)(context.Background(), req); err != nil {
			t.Fatalf("WrapUnary(%q) error = %v", tc.header, err)
		}
		if !ran || got != tc.want {
			t.Errorf("header %q: stamped %+v (ran %v), want %+v", tc.header, got, ran, tc.want)
		}
	}
}

// TestInterceptor_LogsPlatformAndLevel: the request log line (mw.Logging, outermost) carries the parsed platform word
// and level as client_platform and client_level. A missing, garbage or unknown-word header logs platform "unknown".
// The raw header value never reaches the log.
func TestInterceptor_LogsPlatformAndLevel(t *testing.T) {
	for _, tc := range []struct {
		name         string
		header       string
		wantPlatform string
		wantLevel    float64
	}{
		{"android", "android/1", "android", 1},
		{"web upper case", "WEB/1", "web", 1},
		{"ios", "ios/0", "ios", 0},
		{"other", "other/0", "unknown", 0},
		{"unknown word keeps its level", "desktop/7", "unknown", 7},
		{"missing header", "", "unknown", 0},
		{"garbage", "zz<script>secret-token-9f3a", "unknown", 0},
		{"non-ascii lookalike", "desKtop/5", "unknown", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var buf bytes.Buffer
			log := slog.New(slog.NewJSONHandler(&buf, nil))
			handler := connect.UnaryFunc(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
				return connect.NewResponse(&commonv1.ErrorDetail{}), nil
			})
			chain := mw.Logging(log, "demo-project").WrapUnary(clientinfo.Interceptor().WrapUnary(handler))
			req := connect.NewRequest(&commonv1.ErrorDetail{})
			if tc.header != "" {
				req.Header().Set(clientinfo.Header, tc.header)
			}
			if _, err := chain(context.Background(), req); err != nil {
				t.Fatalf("chain error = %v", err)
			}
			var line map[string]any
			if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &line); err != nil {
				t.Fatalf("log output is not one JSON line: %v; got %s", err, buf.String())
			}
			if line["msg"] != "request" {
				t.Fatalf("msg = %v, want the request line; got %s", line["msg"], buf.String())
			}
			if got := line["client_platform"]; got != tc.wantPlatform {
				t.Errorf("client_platform = %v, want %q", got, tc.wantPlatform)
			}
			if got := line["client_level"]; got != tc.wantLevel {
				t.Errorf("client_level = %v, want %v", got, tc.wantLevel)
			}
			if tc.header != "" && strings.Contains(buf.String(), tc.header) {
				t.Errorf("the raw header value %q reached the log: %s", tc.header, buf.String())
			}
		})
	}
}

// TestInterceptor_NoRequestInfoIsFine: without a request log above it (no logger.RequestInfo) the stamp still stamps.
func TestInterceptor_NoRequestInfoIsFine(t *testing.T) {
	var got clientinfo.Client
	next := connect.UnaryFunc(func(ctx context.Context, _ connect.AnyRequest) (connect.AnyResponse, error) {
		got = clientinfo.FromContext(ctx)
		if _, ok := logger.RequestField(ctx, "client_platform"); ok {
			t.Error("client_platform set without a RequestInfo")
		}
		return nil, nil
	})
	req := connect.NewRequest(&commonv1.ErrorDetail{})
	req.Header().Set(clientinfo.Header, "web/1")
	if _, err := clientinfo.Interceptor().WrapUnary(next)(context.Background(), req); err != nil {
		t.Fatalf("WrapUnary error = %v", err)
	}
	if want := (clientinfo.Client{Platform: clientinfo.PlatformWeb, Level: 1}); got != want {
		t.Errorf("stamped %+v, want %+v", got, want)
	}
}

// TestInterceptor_StreamingSetsLogFields: a streaming handler records the same two fields on a RequestInfo above it.
func TestInterceptor_StreamingSetsLogFields(t *testing.T) {
	ctx, _ := logger.WithRequestInfo(context.Background())
	var platform, level any
	h := clientinfo.Interceptor().WrapStreamingHandler(func(ctx context.Context, _ connect.StreamingHandlerConn) error {
		platform, _ = logger.RequestField(ctx, "client_platform")
		level, _ = logger.RequestField(ctx, "client_level")
		return nil
	})
	conn := &fakeStreamConn{header: http.Header{}}
	conn.header.Set(clientinfo.Header, "garbage")
	if err := h(ctx, conn); err != nil {
		t.Fatalf("streaming handler error = %v", err)
	}
	if platform != "unknown" || fmt.Sprint(level) != "0" {
		t.Errorf("fields = %v/%v, want unknown/0", platform, level)
	}
}

// TestInterceptor_StampsStreamingAndPassesClients: a streaming handler is stamped the same way; a streaming client is
// passed through unchanged.
func TestInterceptor_StampsStreamingAndPassesClients(t *testing.T) {
	ic := clientinfo.Interceptor()
	var got clientinfo.Client
	h := ic.WrapStreamingHandler(func(ctx context.Context, _ connect.StreamingHandlerConn) error {
		got = clientinfo.FromContext(ctx)
		return nil
	})
	conn := &fakeStreamConn{header: http.Header{}}
	conn.header.Set(clientinfo.Header, "ios/0")
	if err := h(context.Background(), conn); err != nil {
		t.Fatalf("streaming handler error = %v", err)
	}
	if want := (clientinfo.Client{Platform: clientinfo.PlatformIOS, Level: 0}); got != want {
		t.Errorf("streaming stamped %+v, want %+v", got, want)
	}
	called := false
	client := ic.WrapStreamingClient(func(context.Context, connect.Spec) connect.StreamingClientConn {
		called = true
		return nil
	})
	_ = client(context.Background(), connect.Spec{})
	if !called {
		t.Error("the streaming client func was not passed through")
	}
	// A unary client call (no handler context: a client request) is passed through without a stamp.
	creq := connect.NewRequest(&commonv1.ErrorDetail{})
	creq.Header().Set(clientinfo.Header, "web/1")
	clientUnary := ic.WrapUnary(func(ctx context.Context, _ connect.AnyRequest) (connect.AnyResponse, error) {
		got = clientinfo.FromContext(ctx)
		return nil, nil
	})
	if _, err := clientUnary(context.Background(), clientRequest{creq}); err != nil {
		t.Fatalf("client unary error = %v", err)
	}
	if got != (clientinfo.Client{}) {
		t.Errorf("a client-side call was stamped %+v, want nothing", got)
	}
}

// TestUpdateRequired: the answer of every messaging and key RPC below the floor (plan 6 section 3.1): FAILED_PRECONDITION
// + FEATURE_DISABLED, feature=<name>, update_required=true, the shared "not available" message, nothing else.
func TestUpdateRequired(t *testing.T) {
	err := clientinfo.UpdateRequired(context.Background(), clientinfo.FeatureMessaging)
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("UpdateRequired = %T, want *apierr.Error", err)
	}
	if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		t.Errorf("code/reason = %v/%v, want FAILED_PRECONDITION/FEATURE_DISABLED", ae.Code, ae.Reason)
	}
	want := map[string]string{"feature": "messaging", "update_required": "true"}
	if len(ae.Metadata) != len(want) {
		t.Errorf("metadata = %v, want %v", ae.Metadata, want)
	}
	for k, v := range want {
		if ae.Metadata[k] != v {
			t.Errorf("metadata[%q] = %q, want %q", k, ae.Metadata[k], v)
		}
	}
	if ae.Message != "this feature is not available yet" {
		t.Errorf("message = %q, want the shared FEATURE_DISABLED message", ae.Message)
	}
	if ae.RetryAfter != 0 {
		t.Errorf("retry_after = %v, want none", ae.RetryAfter)
	}
}

type fakeStreamConn struct {
	connect.StreamingHandlerConn
	header http.Header
}

func (c *fakeStreamConn) RequestHeader() http.Header { return c.header }

// clientRequest is a request whose Spec says it is a client call (IsClient true).
type clientRequest struct {
	*connect.Request[commonv1.ErrorDetail]
}

func (clientRequest) Spec() connect.Spec { return connect.Spec{IsClient: true} }
