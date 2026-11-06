package beacons

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// assertDisabled checks err is FAILED_PRECONDITION + FEATURE_DISABLED with metadata feature=want.
func assertDisabled(t *testing.T, err error, want string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want *apierr.Error", err)
	}
	if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		t.Fatalf("err = code %v reason %v, want FAILED_PRECONDITION FEATURE_DISABLED", ae.Code, ae.Reason)
	}
	if got := ae.Metadata["feature"]; got != want {
		t.Fatalf("metadata feature = %q, want %q", got, want)
	}
}

// TestGuard_Classes: Guard needs the flag on for the caller; GuardNotOff only needs it not globally off, so a caller dropped
// from an allowlist keeps the read class.
func TestGuard_Classes(t *testing.T) {
	allow := map[string]struct{}{"in": {}}
	modes := []struct {
		name       string
		spec       flags.Spec
		uid        string
		wantOff    bool // Guard
		wantNotOff bool // GuardNotOff
	}{
		{"off", flags.Spec{Name: FlagName, Mode: flags.Off, Allowlist: allow}, "in", true, true},
		{"allowlist, listed", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allow}, "in", false, false},
		{"allowlist, unlisted", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allow}, "out", true, false},
		{"percent 0", flags.Spec{Name: FlagName, Mode: flags.Percent}, "in", true, false},
		{"percent 100", flags.Spec{Name: FlagName, Mode: flags.Percent, Percent: 100}, "out", false, false},
		{"on", flags.Spec{Name: FlagName, Mode: flags.On}, "out", false, false},
	}
	for _, m := range modes {
		t.Run(m.name, func(t *testing.T) {
			reg := flags.NewRegistry(m.spec)
			err := Guard(context.Background(), reg, m.uid)
			if m.wantOff {
				assertDisabled(t, err, FlagName)
			} else if err != nil {
				t.Fatalf("Guard = %v, want nil", err)
			}
			err = GuardNotOff(context.Background(), reg, m.uid)
			if m.wantNotOff {
				assertDisabled(t, err, FlagName)
			} else if err != nil {
				t.Fatalf("GuardNotOff = %v, want nil", err)
			}
		})
	}
	t.Run("nil checker is off", func(t *testing.T) {
		assertDisabled(t, Guard(context.Background(), nil, "in"), FlagName)
		assertDisabled(t, GuardNotOff(context.Background(), nil, "in"), FlagName)
	})
}

// TestGuardCommunities: the community-audience gate names feature=communities, on for the caller when mustBeOn, else not
// globally off.
func TestGuardCommunities(t *testing.T) {
	allow := map[string]struct{}{"in": {}}
	reg := flags.NewRegistry(flags.Spec{Name: communities.FlagName, Mode: flags.Allowlist, Allowlist: allow})
	if err := GuardCommunities(context.Background(), reg, "in", true); err != nil {
		t.Fatalf("listed caller, mustBeOn: %v", err)
	}
	assertDisabled(t, GuardCommunities(context.Background(), reg, "out", true), communities.FlagName)
	if err := GuardCommunities(context.Background(), reg, "out", false); err != nil {
		t.Fatalf("unlisted caller, not globally off: %v", err)
	}
	off := flags.NewRegistry(flags.Spec{Name: communities.FlagName, Mode: flags.Off})
	assertDisabled(t, GuardCommunities(context.Background(), off, "in", false), communities.FlagName)
}
