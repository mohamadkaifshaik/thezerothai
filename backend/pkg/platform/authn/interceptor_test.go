package authn_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// seedRequestInfo mimics the one thing mw.Logging does that these interceptors depend on: attaching a
// mutable logger.RequestInfo to ctx before calling next (M2). Kept local to this test file instead of
// importing mw, which would create a needless pkg/platform/mw <-> pkg/platform/authn test dependency.
func seedRequestInfo(captured **logger.RequestInfo) connect.UnaryInterceptorFunc {
	return connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			ctx, info := logger.WithRequestInfo(ctx)
			*captured = info
			return next(ctx, req)
		}
	})
}

const procedure = "/test.Service/Method"

type fakeAppCheckVerifier struct {
	valid map[string]bool
}

func (f fakeAppCheckVerifier) VerifyToken(_ context.Context, token string) error {
	if f.valid[token] {
		return nil
	}
	return errors.New("invalid app check token")
}

type fakeIDTokenVerifier struct {
	tokens map[string]authn.Claims
}

func (f fakeIDTokenVerifier) VerifyIDToken(_ context.Context, idToken string) (authn.Claims, error) {
	c, ok := f.tokens[idToken]
	if !ok {
		return authn.Claims{}, errors.New("invalid id token")
	}
	return c, nil
}

type fakeAccountStatusProvider struct {
	byUID map[string]struct {
		exists bool
		status authn.AccountStatus
	}
}

func (f fakeAccountStatusProvider) AccountStatus(_ context.Context, uid string) (bool, authn.AccountStatus, error) {
	v, ok := f.byUID[uid]
	if !ok {
		return false, authn.AccountStatusUnknown, nil
	}
	return v.exists, v.status, nil
}

func okHandler(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
	return connect.NewResponse(&commonv1.ErrorDetail{}), nil
}

func newServer(t *testing.T, interceptors ...connect.Interceptor) *httptest.Server {
	t.Helper()
	opts := make([]connect.HandlerOption, 0, len(interceptors))
	for _, ic := range interceptors {
		opts = append(opts, connect.WithInterceptors(ic))
	}
	h := connect.NewUnaryHandler(procedure, okHandler, opts...)
	mux := http.NewServeMux()
	mux.Handle(procedure, h)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func call(t *testing.T, srv *httptest.Server, headers map[string]string) error {
	t.Helper()
	client := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+procedure)
	req := connect.NewRequest(&commonv1.ErrorDetail{})
	for k, v := range headers {
		req.Header().Set(k, v)
	}
	_, err := client.CallUnary(context.Background(), req)
	return err
}

func codeOf(t *testing.T, err error) connect.Code {
	t.Helper()
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	return cerr.Code()
}

func TestAppCheckInterceptor_EnforceRejectsMissing(t *testing.T) {
	v := fakeAppCheckVerifier{valid: map[string]bool{"good": true}}
	srv := newServer(t, authn.AppCheckInterceptor(v, authn.ModeEnforce))
	err := call(t, srv, nil)
	if err == nil {
		t.Fatal("expected missing App Check token to be rejected")
	}
	if got := codeOf(t, err); got != connect.CodeUnauthenticated {
		t.Fatalf("Code() = %v, want Unauthenticated", got)
	}
}

func TestAppCheckInterceptor_EnforceAllowsValid(t *testing.T) {
	v := fakeAppCheckVerifier{valid: map[string]bool{"good": true}}
	srv := newServer(t, authn.AppCheckInterceptor(v, authn.ModeEnforce))
	if err := call(t, srv, map[string]string{authn.AppCheckHeader: "good"}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestAppCheckInterceptor_MonitorAllowsInvalid(t *testing.T) {
	v := fakeAppCheckVerifier{}
	srv := newServer(t, authn.AppCheckInterceptor(v, authn.ModeMonitor))
	if err := call(t, srv, nil); err != nil {
		t.Fatalf("monitor mode should not block on invalid App Check: %v", err)
	}
}

func TestIDTokenInterceptor_RejectsMissingBearer(t *testing.T) {
	v := fakeIDTokenVerifier{}
	srv := newServer(t, authn.IDTokenInterceptor(v))
	err := call(t, srv, nil)
	if err == nil {
		t.Fatal("expected missing bearer token to be rejected")
	}
	if got := codeOf(t, err); got != connect.CodeUnauthenticated {
		t.Fatalf("Code() = %v, want Unauthenticated", got)
	}
}

func TestIDTokenInterceptor_RejectsInvalidToken(t *testing.T) {
	v := fakeIDTokenVerifier{}
	srv := newServer(t, authn.IDTokenInterceptor(v))
	err := call(t, srv, map[string]string{"Authorization": "Bearer garbage"})
	if err == nil {
		t.Fatal("expected invalid token to be rejected")
	}
}

func TestIDTokenInterceptor_AllowsValidToken(t *testing.T) {
	v := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"good": {UID: "uid-1", EmailVerified: true}}}
	srv := newServer(t, authn.IDTokenInterceptor(v))
	if err := call(t, srv, map[string]string{"Authorization": "Bearer good"}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestIDTokenInterceptor_RejectsMalformedUID(t *testing.T) {
	for _, uid := range []string{"x_y", "__x__", "", "a/b"} {
		t.Run(uid, func(t *testing.T) {
			reached := false
			v := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"good": {UID: uid}}}
			srv := newServer(t, authn.IDTokenInterceptor(v), connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
				return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
					reached = true
					return next(ctx, req)
				}
			}))
			err := call(t, srv, map[string]string{"Authorization": "Bearer good"})
			if err == nil {
				t.Fatal("expected malformed uid to be rejected")
			}
			if got := codeOf(t, err); got != connect.CodeUnauthenticated {
				t.Fatalf("Code() = %v, want Unauthenticated", got)
			}
			if reached {
				t.Fatal("downstream handler ran for a rejected uid")
			}
		})
	}
}

func TestIDTokenInterceptor_RecordsUIDOnRequestInfo(t *testing.T) {
	var info *logger.RequestInfo
	v := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"good": {UID: "uid-42"}}}
	srv := newServer(t, seedRequestInfo(&info), authn.IDTokenInterceptor(v))

	if err := call(t, srv, map[string]string{"Authorization": "Bearer good"}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if info == nil || info.UID != "uid-42" {
		t.Fatalf("RequestInfo = %+v, want UID = uid-42", info)
	}
}

func TestAppCheckInterceptor_MonitorRecordsFailureOnRequestInfo(t *testing.T) {
	var info *logger.RequestInfo
	v := fakeAppCheckVerifier{}
	srv := newServer(t, seedRequestInfo(&info), authn.AppCheckInterceptor(v, authn.ModeMonitor))

	if err := call(t, srv, nil); err != nil {
		t.Fatalf("monitor mode should not block on invalid App Check: %v", err)
	}
	if info == nil || !info.AppCheckFailed {
		t.Fatalf("RequestInfo = %+v, want AppCheckFailed = true", info)
	}
}

func TestAppCheckInterceptor_EnforceDoesNotNeedRequestInfo(t *testing.T) {
	// AppCheckInterceptor must not panic when no logger.RequestInfo is attached (e.g. a test exercising it
	// standalone, as every other test in this file does).
	v := fakeAppCheckVerifier{valid: map[string]bool{"good": true}}
	srv := newServer(t, authn.AppCheckInterceptor(v, authn.ModeMonitor))
	if err := call(t, srv, map[string]string{authn.AppCheckHeader: "good"}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestAccountStatusInterceptor_ProfileRequired(t *testing.T) {
	provider := fakeAccountStatusProvider{byUID: map[string]struct {
		exists bool
		status authn.AccountStatus
	}{}}
	idVerifier := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"good": {UID: "new-uid"}}}
	srv := newServer(t, authn.IDTokenInterceptor(idVerifier), authn.AccountStatusInterceptor(provider, authn.ProfileExemptProcedures()))

	err := call(t, srv, map[string]string{"Authorization": "Bearer good"})
	if err == nil {
		t.Fatal("expected PROFILE_REQUIRED for a uid with no profile")
	}
	if got := codeOf(t, err); got != connect.CodeFailedPrecondition {
		t.Fatalf("Code() = %v, want FailedPrecondition", got)
	}
}

func TestAccountStatusInterceptor_ExemptProcedureBypassesCheck(t *testing.T) {
	provider := fakeAccountStatusProvider{}
	idVerifier := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"good": {UID: "new-uid"}}}
	srv := newServer(t, authn.IDTokenInterceptor(idVerifier), authn.AccountStatusInterceptor(provider, authn.ProfileExemptProcedures(procedure)))

	if err := call(t, srv, map[string]string{"Authorization": "Bearer good"}); err != nil {
		t.Fatalf("exempt procedure should bypass the profile-required check: %v", err)
	}
}

func TestAccountStatusInterceptor_RestrictedAccountBlocked(t *testing.T) {
	provider := fakeAccountStatusProvider{byUID: map[string]struct {
		exists bool
		status authn.AccountStatus
	}{
		"suspended-uid": {exists: true, status: authn.AccountStatusSuspended},
	}}
	idVerifier := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"good": {UID: "suspended-uid"}}}
	srv := newServer(t, authn.IDTokenInterceptor(idVerifier), authn.AccountStatusInterceptor(provider, authn.ProfileExemptProcedures()))

	err := call(t, srv, map[string]string{"Authorization": "Bearer good"})
	if err == nil {
		t.Fatal("expected suspended account to be blocked")
	}
	if got := codeOf(t, err); got != connect.CodePermissionDenied {
		t.Fatalf("Code() = %v, want PermissionDenied", got)
	}
}

func TestAccountStatusInterceptor_ActiveAccountAllowed(t *testing.T) {
	provider := fakeAccountStatusProvider{byUID: map[string]struct {
		exists bool
		status authn.AccountStatus
	}{
		"active-uid": {exists: true, status: authn.AccountStatusActive},
	}}
	idVerifier := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"good": {UID: "active-uid"}}}
	srv := newServer(t, authn.IDTokenInterceptor(idVerifier), authn.AccountStatusInterceptor(provider, authn.ProfileExemptProcedures()))

	if err := call(t, srv, map[string]string{"Authorization": "Bearer good"}); err != nil {
		t.Fatalf("unexpected error for an active account: %v", err)
	}
}
