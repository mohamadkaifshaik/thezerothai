package identity

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// fakeLifecycle is an AccountLifecycle that records the uid and key it was called with.
type fakeLifecycle struct {
	calls   int
	lastUID string
	lastKey string
	lastID  string
	at      time.Time
	view    ExportView
	err     error
}

func (f *fakeLifecycle) DeleteAccount(_ context.Context, uid, key string) (time.Time, error) {
	f.calls++
	f.lastUID, f.lastKey = uid, key
	return f.at, f.err
}

func (f *fakeLifecycle) RequestAccountExport(_ context.Context, uid, key string) (ExportView, error) {
	f.calls++
	f.lastUID, f.lastKey = uid, key
	return f.view, f.err
}

func (f *fakeLifecycle) GetAccountExport(_ context.Context, uid, id string) (ExportView, error) {
	f.calls++
	f.lastUID, f.lastID = uid, id
	return f.view, f.err
}

var serverNow = time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)

func lifecycleServer(t *testing.T, claims authn.Claims, lc AccountLifecycle, maxAge time.Duration) (*Server, context.Context) {
	t.Helper()
	fc := fakeFlagChecker{claims.UID + "/" + AccountLifecycleFlag: true}
	s := NewServer(&fakeService{}, WithFlagChecker(fc), WithLifecycle(lc), WithReauthMaxAge(maxAge), WithClock(func() time.Time { return serverNow }))
	return s, authn.WithClaims(context.Background(), claims)
}

// TestServer_DeleteAccount_RecentSignIn: the window is the configured one (ACCOUNT_DELETE_REAUTH_MAX_AGE), not a
// hard-coded 5 minutes; a missing or stale auth_time is REAUTH_REQUIRED before the service is reached, on a replay too.
func TestServer_DeleteAccount_RecentSignIn(t *testing.T) {
	tests := []struct {
		name     string
		authTime time.Time
		maxAge   time.Duration
		wantOK   bool
	}{
		{"fresh sign-in", serverNow.Add(-time.Minute), 5 * time.Minute, true},
		{"4m59s with the 5m default", serverNow.Add(-4*time.Minute - 59*time.Second), 5 * time.Minute, true},
		{"5m01s with the 5m default", serverNow.Add(-5*time.Minute - time.Second), 5 * time.Minute, false},
		{"6 minutes passes when the config says 10m", serverNow.Add(-6 * time.Minute), 10 * time.Minute, true},
		{"6 minutes fails when the config says 2m", serverNow.Add(-6 * time.Minute), 2 * time.Minute, false},
		{"missing auth_time", time.Time{}, 5 * time.Minute, false},
		{"auth_time in the future beyond skew", serverNow.Add(time.Hour), 5 * time.Minute, false},
		{"max age left unset fails closed", serverNow.Add(-time.Second), 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			lc := &fakeLifecycle{at: serverNow}
			s, ctx := lifecycleServer(t, authn.Claims{UID: "uid-1", AuthTime: tt.authTime}, lc, tt.maxAge)
			resp, err := s.DeleteAccount(ctx, connect.NewRequest(&identityv1.DeleteAccountRequest{IdempotencyKey: "k-0123456789abcdef"}))
			if tt.wantOK {
				if err != nil || !resp.Msg.GetDeletionRequestedAt().AsTime().Equal(serverNow) {
					t.Fatalf("resp = %v, err = %v", resp, err)
				}
				if lc.calls != 1 || lc.lastUID != "uid-1" || lc.lastKey != "k-0123456789abcdef" {
					t.Errorf("lifecycle call = %+v", lc)
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED {
				t.Fatalf("err = %v, want FAILED_PRECONDITION + REAUTH_REQUIRED", err)
			}
			if lc.calls != 0 {
				t.Error("the service was reached with a stale sign-in")
			}
		})
	}
}

func TestServer_DeleteAccount_ServiceError(t *testing.T) {
	lc := &fakeLifecycle{err: errors.New("boom")}
	s, ctx := lifecycleServer(t, authn.Claims{UID: "uid-1", AuthTime: serverNow}, lc, 5*time.Minute)
	if _, err := s.DeleteAccount(ctx, connect.NewRequest(&identityv1.DeleteAccountRequest{})); err == nil {
		t.Fatal("service error swallowed")
	}
}

// TestServer_DeleteAccount_UsesTheTokenUID (IAM control C1): there is no uid in the request, and whatever the
// handler does is for the token's own uid.
func TestServer_DeleteAccount_UsesTheTokenUID(t *testing.T) {
	var req identityv1.DeleteAccountRequest
	fields := req.ProtoReflect().Descriptor().Fields()
	if fields.Len() != 1 || fields.Get(0).Name() != "idempotency_key" {
		t.Fatalf("DeleteAccountRequest has fields %v; it must never carry a uid (ADR-0011 C1)", fields)
	}
	lc := &fakeLifecycle{at: serverNow}
	s, ctx := lifecycleServer(t, authn.Claims{UID: "token-uid", AuthTime: serverNow}, lc, 5*time.Minute)
	if _, err := s.DeleteAccount(ctx, connect.NewRequest(&identityv1.DeleteAccountRequest{IdempotencyKey: "k-0123456789abcdef"})); err != nil {
		t.Fatal(err)
	}
	if lc.lastUID != "token-uid" {
		t.Errorf("deleted %q", lc.lastUID)
	}
}

func TestServer_Exports(t *testing.T) {
	exp := serverNow.Add(7 * 24 * time.Hour)
	urlExp := serverNow.Add(15 * time.Minute)
	lc := &fakeLifecycle{view: ExportView{ID: "exp-1", Status: ExportReady, DownloadURL: "https://signed", URLExpiresAt: urlExp, ExpiresAt: exp}}
	s, ctx := lifecycleServer(t, authn.Claims{UID: "uid-1"}, lc, 5*time.Minute)

	r1, err := s.RequestAccountExport(ctx, connect.NewRequest(&identityv1.RequestAccountExportRequest{IdempotencyKey: "k-0123456789abcdef"}))
	if err != nil || r1.Msg.GetExportId() != "exp-1" || r1.Msg.GetStatus() != identityv1.ExportStatus_EXPORT_STATUS_READY || lc.lastUID != "uid-1" {
		t.Fatalf("RequestAccountExport = %v, %v (%+v)", r1, err, lc)
	}
	r2, err := s.GetAccountExport(ctx, connect.NewRequest(&identityv1.GetAccountExportRequest{ExportId: "exp-1"}))
	if err != nil {
		t.Fatal(err)
	}
	m := r2.Msg
	if m.GetDownloadUrl() != "https://signed" || !m.GetDownloadUrlExpiresAt().AsTime().Equal(urlExp) || !m.GetExpiresAt().AsTime().Equal(exp) || lc.lastID != "exp-1" || lc.lastUID != "uid-1" {
		t.Errorf("GetAccountExport = %v (%+v)", m, lc)
	}

	// PENDING carries no URL expiry.
	lc.view = ExportView{ID: "exp-1", Status: ExportPending, ExpiresAt: exp}
	r3, _ := s.GetAccountExport(ctx, connect.NewRequest(&identityv1.GetAccountExportRequest{ExportId: "exp-1"}))
	if r3.Msg.GetDownloadUrlExpiresAt() != nil || r3.Msg.GetDownloadUrl() != "" {
		t.Errorf("PENDING response = %v", r3.Msg)
	}

	lc.err = errors.New("boom")
	if _, err := s.RequestAccountExport(ctx, connect.NewRequest(&identityv1.RequestAccountExportRequest{})); err == nil {
		t.Error("RequestAccountExport swallowed the error")
	}
	if _, err := s.GetAccountExport(ctx, connect.NewRequest(&identityv1.GetAccountExportRequest{})); err == nil {
		t.Error("GetAccountExport swallowed the error")
	}
}

func TestServer_Lifecycle_FlagOffNeverReachesTheService(t *testing.T) {
	lc := &fakeLifecycle{}
	s := NewServer(&fakeService{}, WithFlagChecker(fakeFlagChecker{}), WithLifecycle(lc), WithReauthMaxAge(5*time.Minute))
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-1", AuthTime: time.Now()})
	if _, err := s.DeleteAccount(ctx, connect.NewRequest(&identityv1.DeleteAccountRequest{})); err == nil {
		t.Error("DeleteAccount ran with the flag off")
	}
	if _, err := s.RequestAccountExport(ctx, connect.NewRequest(&identityv1.RequestAccountExportRequest{})); err == nil {
		t.Error("RequestAccountExport ran with the flag off")
	}
	if _, err := s.GetAccountExport(ctx, connect.NewRequest(&identityv1.GetAccountExportRequest{})); err == nil {
		t.Error("GetAccountExport ran with the flag off")
	}
	if lc.calls != 0 {
		t.Errorf("the service was called %d times with the flag off", lc.calls)
	}
}

func TestToProtoExportStatus(t *testing.T) {
	tests := map[ExportStatus]identityv1.ExportStatus{
		ExportPending: identityv1.ExportStatus_EXPORT_STATUS_PENDING,
		ExportReady:   identityv1.ExportStatus_EXPORT_STATUS_READY,
		ExportFailed:  identityv1.ExportStatus_EXPORT_STATUS_FAILED,
		"":            identityv1.ExportStatus_EXPORT_STATUS_UNSPECIFIED,
	}
	for in, want := range tests {
		if got := toProtoExportStatus(in); got != want {
			t.Errorf("toProtoExportStatus(%q) = %v, want %v", in, got, want)
		}
	}
}
