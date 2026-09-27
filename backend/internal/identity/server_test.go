package identity

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"connectrpc.com/connect"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
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

// authInject stands in for authn.IDTokenInterceptor for server.go tests.
func authInject(uid string, emailVerified bool) connect.UnaryInterceptorFunc {
	return connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			ctx = authn.WithClaims(ctx, authn.Claims{UID: uid, EmailVerified: emailVerified})
			return next(ctx, req)
		}
	})
}

func newTestServerHTTP(t *testing.T, svc Service, uid string) (identityv1connect.IdentityServiceClient, func()) {
	t.Helper()
	mux := http.NewServeMux()
	path, handler := identityv1connect.NewIdentityServiceHandler(NewServer(svc), connect.WithInterceptors(authInject(uid, true)))
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
