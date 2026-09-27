package identity

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// fakeService is a fake Service for server.go (Connect handler) unit tests, isolating proto<->domain
// conversion from business logic (which is covered by service_test.go).
type fakeService struct {
	profile Profile
	err     error

	lastAvailable bool
	lastReason    string

	meResult   MeResult
	lastTarget ProfileTarget
	lastParams UpdateProfileParams
}

func (f *fakeService) CreateProfile(context.Context, string, string, string, string) (Profile, error) {
	return f.profile, f.err
}
func (f *fakeService) CheckHandleAvailability(context.Context, string) (bool, string, error) {
	return f.lastAvailable, f.lastReason, f.err
}
func (f *fakeService) GetMe(context.Context, string) (MeResult, error) {
	return f.meResult, f.err
}
func (f *fakeService) GetProfile(_ context.Context, _ string, target ProfileTarget) (Profile, error) {
	f.lastTarget = target
	return f.profile, f.err
}
func (f *fakeService) UpdateProfile(_ context.Context, _ string, params UpdateProfileParams) (Profile, error) {
	f.lastParams = params
	return f.profile, f.err
}
func (f *fakeService) ChangeHandle(context.Context, string, string, string) (Profile, error) {
	return f.profile, f.err
}
func (f *fakeService) AccountStatus(context.Context, string) (bool, AccountStatus, error) {
	return true, AccountStatusActive, f.err
}

// authInjectClaims stands in for authn.IDTokenInterceptor for server.go tests, giving full control over
// every claim a handler might read (uid, email_verified, sign-in provider — the last needed by H1's
// requireVerifiedEmailForPassword).
func authInjectClaims(claims authn.Claims) connect.UnaryInterceptorFunc {
	return connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, claims), req)
		}
	})
}

func newTestServerHTTP(t *testing.T, svc Service, uid string) (identityv1connect.IdentityServiceClient, func()) {
	t.Helper()
	return newTestServerHTTPWithClaims(t, svc, authn.Claims{UID: uid, EmailVerified: true})
}

// discardLogger is a no-op *slog.Logger for tests that need mw.ErrorMapping wired but don't assert on
// its output (see mw's own package tests for that).
func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func newTestServerHTTPWithClaims(t *testing.T, svc Service, claims authn.Claims) (identityv1connect.IdentityServiceClient, func()) {
	t.Helper()
	mux := http.NewServeMux()
	// mw.ErrorMapping is wired here to match the real chain (apiserver.Build, innermost before the
	// handler): a handler is free to return a raw *apierr.Error (CLAUDE.md: "handlers just return the
	// service error as-is"; see server.go's requireVerifiedEmailForPassword) and rely on ErrorMapping to
	// shape it into a proper *connect.Error — without it here, connect-go has no idea how to encode an
	// unrecognized error type and falls back to CodeUnknown, which every real deployment never sees.
	path, handler := identityv1connect.NewIdentityServiceHandler(NewServer(svc), connect.WithInterceptors(authInjectClaims(claims), mw.ErrorMapping(discardLogger())))
	mux.Handle(path, handler)
	srv := httptest.NewServer(mux)
	client := identityv1connect.NewIdentityServiceClient(srv.Client(), srv.URL)
	return client, srv.Close
}

func TestServer_CreateProfile(t *testing.T) {
	svc := &fakeService{profile: Profile{UserID: "uid-1", Handle: "Alice", FollowersCount: 5}}
	client, closeFn := newTestServerHTTP(t, svc, "uid-1")
	defer closeFn()

	resp, err := client.CreateProfile(context.Background(), connect.NewRequest(&identityv1.CreateProfileRequest{
		IdempotencyKey: validKey, Handle: "Alice", DisplayName: "Alice A.",
	}))
	if err != nil {
		t.Fatalf("CreateProfile() error = %v", err)
	}
	if resp.Msg.GetProfile().GetUserId() != "uid-1" || resp.Msg.GetProfile().GetFollowersCount() != 5 {
		t.Fatalf("unexpected response: %+v", resp.Msg)
	}
}

func TestServer_CreateProfile_ErrorPropagates(t *testing.T) {
	svc := &fakeService{err: connect.NewError(connect.CodeAlreadyExists, errors.New("taken"))}
	client, closeFn := newTestServerHTTP(t, svc, "uid-1")
	defer closeFn()

	_, err := client.CreateProfile(context.Background(), connect.NewRequest(&identityv1.CreateProfileRequest{
		IdempotencyKey: validKey, Handle: "Alice", DisplayName: "Alice A.",
	}))
	var cerr *connect.Error
	if !errors.As(err, &cerr) || cerr.Code() != connect.CodeAlreadyExists {
		t.Fatalf("expected AlreadyExists, got %v", err)
	}
}

// TestServer_CreateProfile_PasswordProviderUnverified_Blocked (H1, 2026-09-27 security audit): a
// password-provider account with an unverified email must never reach the service layer.
func TestServer_CreateProfile_PasswordProviderUnverified_Blocked(t *testing.T) {
	svc := &fakeService{profile: Profile{UserID: "uid-1"}}
	client, closeFn := newTestServerHTTPWithClaims(t, svc, authn.Claims{UID: "uid-1", EmailVerified: false, SignInProvider: "password"})
	defer closeFn()

	_, err := client.CreateProfile(context.Background(), connect.NewRequest(&identityv1.CreateProfileRequest{
		IdempotencyKey: validKey, Handle: "alice", DisplayName: "Alice A.",
	}))
	assertErrorReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED)
}

// assertErrorReason checks both the Connect code and the dzeroth.common.v1.ErrorDetail.Reason carried in
// the error's details (apierr.ToConnect's shape — see pkg/platform/apierr).
func assertErrorReason(t *testing.T, err error, wantCode connect.Code, wantReason commonv1.ErrorReason) {
	t.Helper()
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	if cerr.Code() != wantCode {
		t.Fatalf("Code() = %v, want %v", cerr.Code(), wantCode)
	}
	for _, d := range cerr.Details() {
		msg, derr := d.Value()
		if derr != nil {
			continue
		}
		if detail, ok := msg.(*commonv1.ErrorDetail); ok && detail.GetReason() == wantReason {
			return
		}
	}
	t.Fatalf("expected ErrorReason %v in details, got none matching (err: %v)", wantReason, err)
}

// TestServer_CreateProfile_PasswordProviderVerified_OK (H1): a verified password-provider account is
// never blocked.
func TestServer_CreateProfile_PasswordProviderVerified_OK(t *testing.T) {
	svc := &fakeService{profile: Profile{UserID: "uid-1", Handle: "alice"}}
	client, closeFn := newTestServerHTTPWithClaims(t, svc, authn.Claims{UID: "uid-1", EmailVerified: true, SignInProvider: "password"})
	defer closeFn()

	resp, err := client.CreateProfile(context.Background(), connect.NewRequest(&identityv1.CreateProfileRequest{
		IdempotencyKey: validKey, Handle: "alice", DisplayName: "Alice A.",
	}))
	if err != nil {
		t.Fatalf("CreateProfile() error = %v", err)
	}
	if resp.Msg.GetProfile().GetHandle() != "alice" {
		t.Fatalf("unexpected response: %+v", resp.Msg)
	}
}

// TestServer_CreateProfile_GoogleOrAppleUnverified_OK (H1): "Google/Apple are inherently verified — don't
// block them" — even an (unusual) unverified email_verified claim must not block these providers.
func TestServer_CreateProfile_GoogleOrAppleUnverified_OK(t *testing.T) {
	for _, provider := range []string{"google.com", "apple.com"} {
		t.Run(provider, func(t *testing.T) {
			svc := &fakeService{profile: Profile{UserID: "uid-1", Handle: "alice"}}
			client, closeFn := newTestServerHTTPWithClaims(t, svc, authn.Claims{UID: "uid-1", EmailVerified: false, SignInProvider: provider})
			defer closeFn()

			if _, err := client.CreateProfile(context.Background(), connect.NewRequest(&identityv1.CreateProfileRequest{
				IdempotencyKey: validKey, Handle: "alice", DisplayName: "Alice A.",
			})); err != nil {
				t.Fatalf("CreateProfile() error = %v, want nil for provider %q even when unverified", err, provider)
			}
		})
	}
}

func TestServer_GetMe_UsesTokenClaimsForEmailVerified(t *testing.T) {
	svc := &fakeService{meResult: MeResult{Profile: Profile{UserID: "uid-1"}, UnreadNotificationCount: 7}}
	client, closeFn := newTestServerHTTP(t, svc, "uid-1")
	defer closeFn()

	resp, err := client.GetMe(context.Background(), connect.NewRequest(&identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe() error = %v", err)
	}
	if !resp.Msg.GetEmailVerified() {
		t.Error("expected EmailVerified from token claims")
	}
	if resp.Msg.GetUnreadNotificationCount() != 7 {
		t.Errorf("UnreadNotificationCount = %d, want 7", resp.Msg.GetUnreadNotificationCount())
	}
}

func TestServer_GetProfile_PassesOneofTarget(t *testing.T) {
	svc := &fakeService{profile: Profile{UserID: "uid-2"}}
	client, closeFn := newTestServerHTTP(t, svc, "uid-1")
	defer closeFn()

	_, err := client.GetProfile(context.Background(), connect.NewRequest(&identityv1.GetProfileRequest{
		Target: &identityv1.GetProfileRequest_Handle{Handle: "bob"},
	}))
	if err != nil {
		t.Fatalf("GetProfile() error = %v", err)
	}
	if svc.lastTarget.Handle != "bob" || svc.lastTarget.UserID != "" {
		t.Fatalf("unexpected target passed to service: %+v", svc.lastTarget)
	}
}

func TestServer_UpdateProfile_PassesOptionalFields(t *testing.T) {
	svc := &fakeService{profile: Profile{UserID: "uid-1"}}
	client, closeFn := newTestServerHTTP(t, svc, "uid-1")
	defer closeFn()

	newBio := "hi"
	_, err := client.UpdateProfile(context.Background(), connect.NewRequest(&identityv1.UpdateProfileRequest{
		IdempotencyKey: validKey, Bio: &newBio,
	}))
	if err != nil {
		t.Fatalf("UpdateProfile() error = %v", err)
	}
	if svc.lastParams.Bio == nil || *svc.lastParams.Bio != "hi" {
		t.Fatalf("unexpected params passed to service: %+v", svc.lastParams)
	}
	if svc.lastParams.DisplayName != nil {
		t.Error("expected DisplayName to remain nil (not set in request)")
	}
}

func TestServer_ChangeHandle(t *testing.T) {
	svc := &fakeService{profile: Profile{UserID: "uid-1", Handle: "newname"}}
	client, closeFn := newTestServerHTTP(t, svc, "uid-1")
	defer closeFn()

	resp, err := client.ChangeHandle(context.Background(), connect.NewRequest(&identityv1.ChangeHandleRequest{
		IdempotencyKey: validKey, NewHandle: "newname",
	}))
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v", err)
	}
	if resp.Msg.GetProfile().GetHandle() != "newname" {
		t.Fatalf("unexpected response: %+v", resp.Msg)
	}
}

func TestServer_CheckHandleAvailability(t *testing.T) {
	svc := &fakeService{lastAvailable: true}
	client, closeFn := newTestServerHTTP(t, svc, "uid-1")
	defer closeFn()

	resp, err := client.CheckHandleAvailability(context.Background(), connect.NewRequest(&identityv1.CheckHandleAvailabilityRequest{Handle: "bob"}))
	if err != nil {
		t.Fatalf("CheckHandleAvailability() error = %v", err)
	}
	if !resp.Msg.GetAvailable() {
		t.Error("expected Available = true")
	}
}

func TestServer_Phase1Stubs_ReturnUnimplemented(t *testing.T) {
	svc := &fakeService{}
	client, closeFn := newTestServerHTTP(t, svc, "uid-1")
	defer closeFn()

	assertUnimplemented := func(t *testing.T, err error) {
		t.Helper()
		var cerr *connect.Error
		if !errors.As(err, &cerr) || cerr.Code() != connect.CodeUnimplemented {
			t.Fatalf("expected Unimplemented, got %v", err)
		}
	}

	_, err := client.DeleteAccount(context.Background(), connect.NewRequest(&identityv1.DeleteAccountRequest{}))
	assertUnimplemented(t, err)

	_, err = client.RequestAccountExport(context.Background(), connect.NewRequest(&identityv1.RequestAccountExportRequest{}))
	assertUnimplemented(t, err)

	_, err = client.GetAccountExport(context.Background(), connect.NewRequest(&identityv1.GetAccountExportRequest{}))
	assertUnimplemented(t, err)
}

// TestServer_Phase1Stubs_DoNotLeakInternalRoadmap (L10, 2026-09-27 security audit): the Unimplemented
// message must be generic — the previous text named the exact modules (graph/posts/engagement/media/
// notifications) and ADR needed to finish the feature, disclosing internal roadmap details to any
// authenticated caller.
func TestServer_Phase1Stubs_DoNotLeakInternalRoadmap(t *testing.T) {
	svc := &fakeService{}
	client, closeFn := newTestServerHTTP(t, svc, "uid-1")
	defer closeFn()

	leaky := []string{"graph", "posts", "engagement", "media", "notifications", "ADR", "Phase 1", "Phase0", "Phase 0"}
	assertGeneric := func(t *testing.T, err error) {
		t.Helper()
		var cerr *connect.Error
		if !errors.As(err, &cerr) {
			t.Fatalf("error is %T, want *connect.Error", err)
		}
		msg := cerr.Message()
		if msg != "not available yet" {
			t.Errorf("Unimplemented message = %q, want the generic \"not available yet\"", msg)
		}
		for _, term := range leaky {
			if strings.Contains(cerr.Error(), term) {
				t.Errorf("Unimplemented error leaks internal roadmap term %q: %v", term, cerr)
			}
		}
	}

	_, err := client.DeleteAccount(context.Background(), connect.NewRequest(&identityv1.DeleteAccountRequest{}))
	assertGeneric(t, err)
	_, err = client.RequestAccountExport(context.Background(), connect.NewRequest(&identityv1.RequestAccountExportRequest{}))
	assertGeneric(t, err)
	_, err = client.GetAccountExport(context.Background(), connect.NewRequest(&identityv1.GetAccountExportRequest{}))
	assertGeneric(t, err)
}

func TestToProtoStatus(t *testing.T) {
	tests := map[AccountStatus]identityv1.AccountStatus{
		AccountStatusActive:      identityv1.AccountStatus_ACCOUNT_STATUS_ACTIVE,
		AccountStatusSuspended:   identityv1.AccountStatus_ACCOUNT_STATUS_SUSPENDED,
		AccountStatusDeleting:    identityv1.AccountStatus_ACCOUNT_STATUS_DELETING,
		AccountStatusUnspecified: identityv1.AccountStatus_ACCOUNT_STATUS_UNSPECIFIED,
	}
	for in, want := range tests {
		if got := toProtoStatus(in); got != want {
			t.Errorf("toProtoStatus(%v) = %v, want %v", in, got, want)
		}
	}
}
