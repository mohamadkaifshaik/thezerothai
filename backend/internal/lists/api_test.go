package lists

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestGuard_FlagModes: the gate in every mode (off, allowlist, percent, on) with the real registry. A refusal is
// FAILED_PRECONDITION + FEATURE_DISABLED with feature=lists; an unconfigured checker is off for everyone.
func TestGuard_FlagModes(t *testing.T) {
	allow := map[string]struct{}{"in": {}}
	tests := []struct {
		name    string
		spec    flags.Spec
		uid     string
		wantOff bool
	}{
		{"off", flags.Spec{Name: FlagName, Mode: flags.Off, Allowlist: allow}, "in", true},
		{"allowlist, listed", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allow}, "in", false},
		{"allowlist, unlisted", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allow}, "out", true},
		{"percent 0", flags.Spec{Name: FlagName, Mode: flags.Percent}, "in", true},
		{"percent 100", flags.Spec{Name: FlagName, Mode: flags.Percent, Percent: 100}, "out", false},
		{"on", flags.Spec{Name: FlagName, Mode: flags.On}, "out", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := Guard(context.Background(), flags.NewRegistry(tt.spec), tt.uid)
			if !tt.wantOff {
				if err != nil {
					t.Fatalf("Guard() = %v, want nil", err)
				}
				return
			}
			assertDisabled(t, err)
		})
	}
	t.Run("nil checker", func(t *testing.T) { assertDisabled(t, Guard(context.Background(), nil, "in")) })
	t.Run("unregistered flag", func(t *testing.T) {
		assertDisabled(t, Guard(context.Background(), flags.NewRegistry(), "in"))
	})
}

func assertDisabled(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("Guard() = %v, want an *apierr.Error", err)
	}
	if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != "lists" {
		t.Fatalf("Guard() = %+v, want FAILED_PRECONDITION FEATURE_DISABLED feature=lists", ae)
	}
}
