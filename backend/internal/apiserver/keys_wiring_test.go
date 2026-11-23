package apiserver

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// stubMessagingPermission answers every CanMessage with err.
type stubMessagingPermission struct {
	err error
	// shares and sharesErr answer SharesEncryptedConversation; the last arguments are recorded for the forwarding test.
	shares    bool
	sharesErr error
	gotCaller *string
	gotTarget *string
}

func (p stubMessagingPermission) CanMessage(context.Context, string, string) error { return p.err }

func (p stubMessagingPermission) SharesEncryptedConversation(_ context.Context, callerUID, targetUID string) (bool, error) {
	if p.gotCaller != nil {
		*p.gotCaller, *p.gotTarget = callerUID, targetUID
	}
	return p.shares, p.sharesErr
}

// TestKeysPermission_SharesEncryptedConversation: the adapter forwards the answer and the arguments unchanged, and wraps
// a failure (never false) so the original stays in the chain.
func TestKeysPermission_SharesEncryptedConversation(t *testing.T) {
	boom := errors.New("messaging: boom")
	for _, tc := range []struct {
		name      string
		shares    bool
		sharesErr error
	}{
		{"true", true, nil},
		{"false", false, nil},
		{"failure", false, boom},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var caller, target string
			p := keysPermission{m: stubMessagingPermission{shares: tc.shares, sharesErr: tc.sharesErr, gotCaller: &caller, gotTarget: &target}}
			got, err := p.SharesEncryptedConversation(context.Background(), "uid-a", "uid-b")
			if got != tc.shares || caller != "uid-a" || target != "uid-b" {
				t.Fatalf("got %v from (%q, %q), want %v from (uid-a, uid-b)", got, caller, target, tc.shares)
			}
			if tc.sharesErr != nil && got {
				t.Fatalf("got true alongside the error %v, want false", err)
			}
			if tc.sharesErr == nil && err != nil {
				t.Fatalf("err = %v, want nil", err)
			}
			if tc.sharesErr != nil && (err == nil || !errors.Is(err, boom) || !strings.Contains(err.Error(), "keys: messaging shared conversation")) {
				t.Fatalf("err = %v, want a wrapped %v", err, boom)
			}
		})
	}
}

// TestNewKeysModule_RequiresConversationID: a nil conversation id function fails the wiring (keys never imports messaging,
// so the composition root injects messaging.ConversationID).
func TestNewKeysModule_RequiresConversationID(t *testing.T) {
	if _, err := newKeysModule(unusedKeysRepo{}, nil, stubMessagingPermission{}, nil, ratelimit.NewDailyCap(2), keysLookupCap(4, 3, func(string) bool { return false }), testKeysReauth, nil); err == nil {
		t.Fatal("a nil conversation id function was accepted")
	}
}

// testKeysReauth stands in for config.AccountDeleteReauthMaxAge.
const testKeysReauth = 5 * time.Minute

// TestNewKeysModule_RequiresReauthMaxAge: a zero reauth window fails the wiring (it would refuse every REMOTE removal).
func TestNewKeysModule_RequiresReauthMaxAge(t *testing.T) {
	lookup := keysLookupCap(4, 3, func(string) bool { return false })
	if _, err := newKeysModule(unusedKeysRepo{}, nil, stubMessagingPermission{}, messaging.ConversationID, ratelimit.NewDailyCap(2), lookup, 0, nil); err == nil {
		t.Fatal("a zero reauth max age was accepted")
	}
}

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

func TestKeysLookupDailyCap(t *testing.T) {
	isNew := true
	cap := keysLookupCap(4, 3, func(string) bool { return isNew })
	mod, err := newKeysModule(unusedKeysRepo{}, nil, stubMessagingPermission{}, messaging.ConversationID, ratelimit.NewDailyCap(2), cap, testKeysReauth, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, caller string
		targets      []string
		newAccount   bool
		want         commonv1.ErrorReason
	}{
		{"invalid costs nothing", "caller", []string{"peer", "peer"}, true, commonv1.ErrorReason_ERROR_REASON_VALIDATION},
		{"two targets", "caller", []string{"caller", "peer"}, true, 0},
		{"batch exceeds new tier", "caller", []string{"peer", "other"}, true, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED},
		{"remaining unit", "caller", []string{"peer"}, true, 0},
		{"new tier full", "caller", []string{"peer"}, true, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED},
		{"caller ages out", "caller", []string{"peer"}, false, 0},
		{"prior usage still counts", "caller", []string{"peer"}, false, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED},
		{"another caller", "second", []string{"peer", "other"}, true, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			isNew = tc.newAccount
			_, err := mod.svc.GetDevices(context.Background(), tc.caller, tc.targets)
			if tc.want == 0 {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Reason != tc.want {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
			if tc.want == commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED && (ae.Code != connect.CodeResourceExhausted || ae.Metadata["limit"] != "keys_device_lookups_daily") {
				t.Fatalf("unexpected quota refusal: %+v", ae)
			}
		})
	}
}

// TestNewKeysModule_PerTargetClaimCapIsWired: the cap handed to newKeysModule is the one the service draws on (through
// the real adapter), before the permission check: with a cap of 2 the third claim of one target is RATE_LIMITED
// keys_claims_per_target_daily although every claim was refused; and a nil cap fails the wiring.
func TestNewKeysModule_PerTargetClaimCapIsWired(t *testing.T) {
	perm := stubMessagingPermission{err: messaging.ErrCannotMessage}
	lookup := keysLookupCap(4, 3, func(string) bool { return false })
	if _, err := newKeysModule(unusedKeysRepo{}, nil, perm, messaging.ConversationID, nil, lookup, testKeysReauth, nil); err == nil {
		t.Fatal("a nil per-target claim cap was accepted")
	}
	mod, err := newKeysModule(unusedKeysRepo{}, nil, perm, messaging.ConversationID, ratelimit.NewDailyCap(2), lookup, testKeysReauth, nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	for i := 0; i < 2; i++ {
		_, _, err := mod.svc.Claim(ctx, "uid-claimer", "uid-target", "")
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE {
			t.Fatalf("claim %d = %v, want CANNOT_MESSAGE", i+1, err)
		}
	}
	_, _, err = mod.svc.Claim(ctx, "uid-claimer", "uid-target", "")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeResourceExhausted || ae.Reason != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED ||
		ae.Metadata["limit"] != keys.LimitClaimsPerTargetDaily {
		t.Fatalf("third claim = %v, want RATE_LIMITED limit=%s", err, keys.LimitClaimsPerTargetDaily)
	}
	if _, _, err := mod.svc.Claim(ctx, "uid-claimer", "uid-elsewhere", ""); errors.As(err, &ae) && ae.Code == connect.CodeResourceExhausted {
		t.Fatal("another target shares the counter")
	}
}
