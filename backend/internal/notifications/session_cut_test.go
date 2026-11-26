package notifications

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// RegisterDevice's session-cut check (lane D PR 5 fix round 1): a session from before the account's cut cannot register
// push, read fresh, unless device_sign_out is globally off; the check runs before the FCM dry run and any write.

type fakeFreshCuts struct {
	cut   time.Time
	err   error
	reads int
}

func (f *fakeFreshCuts) FreshSessionsValidAfter(context.Context, string) (time.Time, error) {
	f.reads++
	return f.cut, f.err
}

// countingValidator records whether the FCM dry run was reached.
type countingValidator struct{ calls int }

func (v *countingValidator) Validate(context.Context, string) error { v.calls++; return nil }

func TestRegisterDevice_SessionCut(t *testing.T) {
	cut := time.Date(2026, 11, 26, 9, 0, 0, 0, time.UTC)
	good := DeviceInput{IdempotencyKey: goodKey, DeviceID: "device-0123456789", Token: "fcm:APA91bH-token", Platform: PlatformAndroid}
	at := func(authTime time.Time) context.Context {
		return authn.WithClaims(context.Background(), authn.Claims{UID: "me", AuthTime: authTime})
	}
	for _, tc := range []struct {
		name      string
		ctx       context.Context
		cut       time.Time
		readErr   error
		on        bool
		wantCode  connect.Code // 0 = registered
		wantReads int
	}{
		{"no cut", at(cut.Add(-time.Hour)), time.Time{}, nil, true, 0, 1},
		{"signed in at the cut", at(cut), cut, nil, true, 0, 1},
		{"signed in after the cut", at(cut.Add(time.Minute)), cut, nil, true, 0, 1},
		{"signed in before the cut", at(cut.Add(-time.Second)), cut, nil, true, connect.CodeUnauthenticated, 1},
		{"zero auth_time with a cut", at(time.Time{}), cut, nil, true, connect.CodeUnauthenticated, 1},
		{"no claims with a cut", context.Background(), cut, nil, true, connect.CodeUnauthenticated, 1},
		{"device_sign_out globally off: no read, no refusal", at(cut.Add(-time.Hour)), cut, nil, false, 0, 0},
		{"a failed read is INTERNAL, never a pass", at(cut), time.Time{}, errors.New("firestore down for me"), true, connect.CodeInternal, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			repo, cuts, v := newFakeRepo(), &fakeFreshCuts{cut: tc.cut, err: tc.readErr}, &countingValidator{}
			on := tc.on
			svc := NewService(Deps{Repo: repo, Directory: newDirectory(), Social: &fakeSocial{}, Seen: &fakeSeen{}, Validator: v,
				CursorKey: testKey, SessionCuts: cuts, SessionCutOn: func() bool { return on }})
			ctx, info := logger.WithRequestInfo(tc.ctx)
			err := svc.RegisterDevice(ctx, "me", good)
			if cuts.reads != tc.wantReads {
				t.Errorf("fresh reads = %d, want %d", cuts.reads, tc.wantReads)
			}
			if tc.wantCode == 0 {
				mustNoErr(t, err)
				if len(repo.devices["me"]) != 1 {
					t.Errorf("devices = %+v, want the registration", repo.devices)
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Code != tc.wantCode {
				t.Fatalf("err = %v, want %v", err, tc.wantCode)
			}
			if len(repo.devices["me"]) != 0 || v.calls != 0 {
				t.Errorf("a refused call wrote (%v) or reached the FCM dry run (%d)", repo.devices, v.calls)
			}
			if tc.wantCode == connect.CodeUnauthenticated {
				if ae.Reason != commonv1.ErrorReason_ERROR_REASON_SESSION_ENDED {
					t.Errorf("reason = %v, want SESSION_ENDED", ae.Reason)
				}
				if v, _ := info.Get(fieldSessionCutRefused); v != true {
					t.Errorf("%s = %v, want true", fieldSessionCutRefused, v)
				}
			}
		})
	}
	// Unit rigs without the seam register as before.
	repo := newFakeRepo()
	if err := newService(repo, newDirectory(), &fakeSeen{}, nil).RegisterDevice(at(time.Time{}), "me", good); err != nil {
		t.Fatalf("no seam: %v", err)
	}
}
