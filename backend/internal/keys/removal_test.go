package keys

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The removed marks (security audit H1; removal-server design 2026-11-23, section 2): a REMOTE removal remembers the id
// for RemovalMarkTTL, Register and Upload refuse it with DEVICE_REMOVED, a sign-out removal remembers nothing, and a
// REMOTE removal of an id not yet marked needs a recent sign-in.

const testReauthMaxAge = 5 * time.Minute

// newRemovalService is newTestService with the reauth window wired, as the composition root does.
func newRemovalService(t *testing.T) (Service, *fakeRepo, *fakeClock) {
	t.Helper()
	repo, clk := newFakeRepo(), &fakeClock{t: t0}
	return New(Deps{Repo: repo, Now: clk.now, ReauthMaxAge: testReauthMaxAge}), repo, clk
}

// signedIn is a request context whose ID token says the user signed in at authTime (zero = no auth_time claim), with a
// request line to read fields from.
func signedIn(authTime time.Time) (context.Context, *logger.RequestInfo) {
	ctx, info := logger.WithRequestInfo(context.Background())
	return authn.WithClaims(ctx, authn.Claims{UID: uidA, AuthTime: authTime}), info
}

// errUnavailableForTest is a contention error (mapErr answers UNAVAILABLE with a retry hint).
func errUnavailableForTest() error { return status.Error(codes.Aborted, "contention") }

func wantDeviceRemoved(t *testing.T, err error) {
	t.Helper()
	wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_DEVICE_REMOVED)
	ae := err.(*apierr.Error)
	if len(ae.Metadata) != 0 || ae.RetryAfter != 0 {
		t.Fatalf("DEVICE_REMOVED carries metadata %v / retry %v, want none", ae.Metadata, ae.RetryAfter)
	}
	if ae.Message != "this device was removed from your account" {
		t.Fatalf("message = %q", ae.Message)
	}
	if strings.Contains(err.Error(), devID) || strings.Contains(err.Error(), devID2) {
		t.Fatalf("the error names a device id: %v", err)
	}
}

func TestRemove_Reasons(t *testing.T) {
	recent := t0.Add(-time.Minute)
	stale := t0.Add(-testReauthMaxAge - time.Second)
	cases := []struct {
		name     string
		reason   RemoveReason
		authTime time.Time
		premark  bool   // the id already carries a mark (a retry of a REMOTE removal)
		id       string // default devID (registered)
		wantErr  commonv1.ErrorReason
		wantMark bool
		// wantOps is the repository calls after the setup, in order.
		wantOps []string
	}{
		{name: "sign-out removes and marks nothing, with no sign-in check", reason: RemoveSignOut, authTime: stale,
			wantOps: []string{"Remove"}},
		{name: "sign-out with no auth_time at all", reason: RemoveSignOut, wantOps: []string{"Remove"}},
		{name: "remote with a recent sign-in marks then removes", reason: RemoveRemote, authTime: recent, wantMark: true,
			wantOps: []string{"RemovalMarked", "MarkRemoved", "Remove"}},
		{name: "remote with a sign-in exactly at the limit", reason: RemoveRemote, authTime: t0.Add(-testReauthMaxAge), wantMark: true,
			wantOps: []string{"RemovalMarked", "MarkRemoved", "Remove"}},
		{name: "remote with a stale sign-in writes nothing", reason: RemoveRemote, authTime: stale,
			wantErr: commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED, wantOps: []string{"RemovalMarked"}},
		{name: "remote with no auth_time writes nothing", reason: RemoveRemote,
			wantErr: commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED, wantOps: []string{"RemovalMarked"}},
		{name: "remote with a future sign-in past the skew writes nothing", reason: RemoveRemote, authTime: t0.Add(time.Minute),
			wantErr: commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED, wantOps: []string{"RemovalMarked"}},
		{name: "remote retry of a marked id needs no sign-in and finishes", reason: RemoveRemote, authTime: stale, premark: true,
			wantMark: true, wantOps: []string{"RemovalMarked", "MarkRemoved", "Remove"}},
		{name: "remote of an id never registered still marks it", reason: RemoveRemote, authTime: recent, id: devID2,
			wantMark: true, wantOps: []string{"RemovalMarked", "MarkRemoved", "Remove"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, repo, _ := newRemovalService(t)
			mustRegister(t, s, devID, sigKey(1))
			id := tc.id
			if id == "" {
				id = devID
			}
			earlier := t0.Add(-48 * time.Hour)
			if tc.premark {
				repo.marks[devKey(uidA, id)] = RemovalMark{DeviceID: id, RemovedAt: earlier, ExpireAt: earlier.Add(RemovalMarkTTL)}
				repo.removing[devKey(uidA, id)] = true
			}
			repo.ops = nil
			ctx, info := signedIn(tc.authTime)
			err := s.Remove(ctx, uidA, id, tc.reason)
			if !slices.Equal(repo.ops, tc.wantOps) {
				t.Errorf("repository calls = %v, want %v", repo.ops, tc.wantOps)
			}
			mark, marked := repo.marks[devKey(uidA, id)]
			if tc.wantErr != commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED {
				wantErr(t, err, connect.CodeFailedPrecondition, tc.wantErr)
				if marked || repo.find(uidA, devID) < 0 {
					t.Fatalf("a refused removal wrote something: marked=%v device present=%v", marked, repo.find(uidA, devID) >= 0)
				}
				if v, _ := info.Get(fieldOutcome); v != outcomeRejected+"reauth_required" {
					t.Errorf("outcome = %v, want rejected:reauth_required", v)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if repo.find(uidA, id) >= 0 {
				t.Fatal("the device is still there")
			}
			if marked != tc.wantMark {
				t.Fatalf("marked = %v, want %v", marked, tc.wantMark)
			}
			if tc.wantMark {
				want := t0
				if tc.premark {
					want = earlier // a retry keeps the first removal's time
				}
				if !mark.RemovedAt.Equal(want) || !mark.ExpireAt.Equal(want.Add(90*24*time.Hour)) {
					t.Fatalf("mark = %+v, want removedAt %v and expireAt 90 days later", mark, want)
				}
			}
			wantReason := "sign_out"
			if tc.reason == RemoveRemote {
				wantReason = "remote"
			}
			if v, _ := info.Get(fieldReason); v != wantReason {
				t.Errorf("%s = %v, want %s", fieldReason, v, wantReason)
			}
			for _, f := range info.Fields() {
				if strings.Contains(fmt.Sprint(f.Value.Any()), id) {
					t.Errorf("request-line field %s names the device id", f.Key)
				}
			}
		})
	}
}

// TestRemove_UnwiredReauthWindowFailsClosed: a service built without ReauthMaxAge refuses every REMOTE removal of an
// unmarked id, however fresh the sign-in (authn.RequireRecentSignIn with 0).
func TestRemove_UnwiredReauthWindowFailsClosed(t *testing.T) {
	s, repo, _ := newTestService(t)
	mustRegister(t, s, devID, sigKey(1))
	ctx, _ := signedIn(t0)
	wantErr(t, s.Remove(ctx, uidA, devID, RemoveRemote), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED)
	if len(repo.marks) != 0 {
		t.Fatal("marked without a reauth window")
	}
}

// TestRemove_RemoteFailuresAreMapped: a failed mark read or mark write is the usual mapped error, and nothing after it runs.
func TestRemove_RemoteFailuresAreMapped(t *testing.T) {
	s, repo, _ := newRemovalService(t)
	mustRegister(t, s, devID, sigKey(1))
	repo.markErr = errUnavailableForTest()
	repo.ops = nil
	ctx, _ := signedIn(t0)
	wantErr(t, s.Remove(ctx, uidA, devID, RemoveRemote), connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if slices.Contains(repo.ops, "Remove") {
		t.Fatalf("the delete ran after a failed mark: %v", repo.ops)
	}
}

func TestRemove_UnknownReasonIsValidation(t *testing.T) {
	s, repo, _ := newRemovalService(t)
	mustRegister(t, s, devID, sigKey(1))
	repo.ops = nil
	ctx, _ := signedIn(t0)
	wantValidation(t, s.Remove(ctx, uidA, devID, RemoveReason(7)), "reason")
	if len(repo.ops) != 0 {
		t.Fatalf("an unknown reason reached the repository: %v", repo.ops)
	}
}

func TestRegister_RemovedDevice(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, s Service, r *fakeRepo)
		id    string
		want  string // "removed" or "ok"
	}{
		{"a marked new id is refused", func(_ *testing.T, _ Service, r *fakeRepo) {
			r.marks[devKey(uidA, devID2)] = RemovalMark{DeviceID: devID2, RemovedAt: t0}
		}, devID2, "removed"},
		{"a marked id is refused before the cap", func(t *testing.T, s Service, r *fakeRepo) {
			for i := 1; i < MaxDevicesPerUser; i++ {
				mustRegister(t, s, fmt.Sprintf("device-%012d", i), sigKey(1))
			}
			r.marks[devKey(uidA, devID2)] = RemovalMark{DeviceID: devID2, RemovedAt: t0}
		}, devID2, "removed"},
		{"an existing document carrying removedAt is refused", func(_ *testing.T, _ Service, r *fakeRepo) {
			r.marks[devKey(uidA, devID)] = RemovalMark{DeviceID: devID, RemovedAt: t0}
			r.removing[devKey(uidA, devID)] = true
		}, devID, "removed"},
		{"after a remote removal the same id is refused", func(t *testing.T, s Service, _ *fakeRepo) {
			ctx, _ := signedIn(t0)
			if err := s.Remove(ctx, uidA, devID, RemoveRemote); err != nil {
				t.Fatal(err)
			}
		}, devID, "removed"},
		{"after a sign-out removal the same id registers again", func(t *testing.T, s Service, _ *fakeRepo) {
			ctx, _ := signedIn(time.Time{})
			if err := s.Remove(ctx, uidA, devID, RemoveSignOut); err != nil {
				t.Fatal(err)
			}
		}, devID, "ok"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, repo, _ := newRemovalService(t)
			mustRegister(t, s, devID, sigKey(1))
			tc.setup(t, s, repo)
			ctx, info := logger.WithRequestInfo(context.Background())
			_, err := s.Register(ctx, uidA, tc.id, sigKey(1))
			if tc.want == "ok" {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			wantDeviceRemoved(t, err)
			if v, _ := info.Get(fieldOutcome); v != outcomeRejected+"device_removed" {
				t.Errorf("outcome = %v, want rejected:device_removed", v)
			}
		})
	}
}

func TestUpload_RemovedDevice(t *testing.T) {
	cases := []struct {
		name  string
		setup func(r *fakeRepo)
		id    string
		want  connect.Code
	}{
		{"a marked id with no device document", func(r *fakeRepo) {
			r.marks[devKey(uidA, devID2)] = RemovalMark{DeviceID: devID2, RemovedAt: t0}
		}, devID2, connect.CodeFailedPrecondition},
		{"a device document carrying removedAt", func(r *fakeRepo) {
			r.marks[devKey(uidA, devID)] = RemovalMark{DeviceID: devID, RemovedAt: t0}
			r.removing[devKey(uidA, devID)] = true
		}, devID, connect.CodeFailedPrecondition},
		{"a missing device with no mark is still NOT_FOUND", func(*fakeRepo) {}, devID2, connect.CodeNotFound},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, repo, _ := newRemovalService(t)
			mustRegister(t, s, devID, sigKey(1))
			tc.setup(repo)
			_, _, err := s.Upload(context.Background(), uidA, tc.id, pkgs(0, 1), nil)
			if tc.want == connect.CodeNotFound {
				wantErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
				return
			}
			wantDeviceRemoved(t, err)
		})
	}
}

// TestServer_RemoveReason: the wire reason reaches the service (UNSPECIFIED as SIGN_OUT, for builds before the field);
// a value this server does not know is VALIDATION "reason" before the service.
func TestServer_RemoveReason(t *testing.T) {
	on := fakeFlags{on: map[string]bool{srvCaller: true}}
	cases := []struct {
		in      keysv1.RemoveReason
		want    RemoveReason
		invalid bool
	}{
		{keysv1.RemoveReason_REMOVE_REASON_UNSPECIFIED, RemoveSignOut, false},
		{keysv1.RemoveReason_REMOVE_REASON_SIGN_OUT, RemoveSignOut, false},
		{keysv1.RemoveReason_REMOVE_REASON_REMOTE, RemoveRemote, false},
		{keysv1.RemoveReason(99), 0, true},
	}
	for _, tc := range cases {
		t.Run(tc.in.String(), func(t *testing.T) {
			svc := &fakeService{reason: RemoveReason(-1)}
			_, err := NewServer(on, svc).RemoveKeyDevice(srvCtx(srvCaller), connect.NewRequest(&keysv1.RemoveKeyDeviceRequest{
				IdempotencyKey: srvKey, DeviceId: srvDevice, Reason: tc.in}))
			if tc.invalid {
				wantValidation(t, err, "reason")
				if len(svc.calls) != 0 {
					t.Fatal("an unknown reason reached the service")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if svc.reason != tc.want {
				t.Fatalf("service reason = %v, want %v", svc.reason, tc.want)
			}
		})
	}
}

// TestDeviceRemovedIsNotRetryable: the sentinel survives wrapping (a repository wraps it with the uid redacted).
func TestDeviceRemovedIsNotRetryable(t *testing.T) {
	s := &service{}
	err := s.mapErr(context.Background(), "register", uidA, fmt.Errorf("keys: register: %w", ErrDeviceRemoved))
	wantDeviceRemoved(t, err)
}
