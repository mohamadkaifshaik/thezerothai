package apiserver

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// stubMessagingPermission answers every CanMessage with err.
type stubMessagingPermission struct{ err error }

func (p stubMessagingPermission) CanMessage(context.Context, string, string) error { return p.err }

// TestKeysPermission_Adapter: messaging's one refusal becomes keys' refusal; nil stays nil; ErrSelf and any other error
// pass through as failures to decide (never keys.ErrCannotMessage), with the original still in the chain.
func TestKeysPermission_Adapter(t *testing.T) {
	plain := errors.New("messaging: profiles: boom")
	tests := []struct {
		name    string
		in      error
		refusal bool
	}{
		{"nil is allowed", nil, false},
		{"messaging refusal becomes the keys refusal", messaging.ErrCannotMessage, true},
		{"self passes through, not a refusal", messaging.ErrSelf, false},
		{"a plain error passes through, not a refusal", plain, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := keysPermission{m: stubMessagingPermission{err: tc.in}}.CanMessage(context.Background(), "uid-a", "uid-b")
			switch {
			case tc.in == nil:
				if got != nil {
					t.Fatalf("got %v, want nil", got)
				}
			case tc.refusal:
				if got != keys.ErrCannotMessage {
					t.Fatalf("got %v, want exactly keys.ErrCannotMessage", got)
				}
			default:
				if got == nil || errors.Is(got, keys.ErrCannotMessage) || !errors.Is(got, tc.in) {
					t.Fatalf("got %v, want a non-refusal wrapping %v", got, tc.in)
				}
			}
		})
	}
}

// unusedKeysRepo satisfies keys.Repo for wiring tests whose calls never reach the repository (a nil embedded interface:
// any call panics).
type unusedKeysRepo struct{ keys.Repo }

// TestNewKeysModule_PerTargetClaimCapIsWired: the cap handed to newKeysModule is the one the service draws on (through
// the real adapter), before the permission check: with a cap of 2 the third claim of one target is RATE_LIMITED
// keys_claims_per_target_daily although every claim was refused; and a nil cap fails the wiring.
func TestNewKeysModule_PerTargetClaimCapIsWired(t *testing.T) {
	perm := stubMessagingPermission{err: messaging.ErrCannotMessage}
	if _, err := newKeysModule(unusedKeysRepo{}, nil, perm, nil, nil); err == nil {
		t.Fatal("a nil per-target claim cap was accepted")
	}
	mod, err := newKeysModule(unusedKeysRepo{}, nil, perm, ratelimit.NewDailyCap(2), nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	for i := 0; i < 2; i++ {
		_, err := mod.svc.Claim(ctx, "uid-claimer", "uid-target", "")
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE {
			t.Fatalf("claim %d = %v, want CANNOT_MESSAGE", i+1, err)
		}
	}
	_, err = mod.svc.Claim(ctx, "uid-claimer", "uid-target", "")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeResourceExhausted || ae.Reason != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED ||
		ae.Metadata["limit"] != keys.LimitClaimsPerTargetDaily {
		t.Fatalf("third claim = %v, want RATE_LIMITED limit=%s", err, keys.LimitClaimsPerTargetDaily)
	}
	if _, err := mod.svc.Claim(ctx, "uid-claimer", "uid-elsewhere", ""); errors.As(err, &ae) && ae.Code == connect.CodeResourceExhausted {
		t.Fatal("another target shares the counter")
	}
}
