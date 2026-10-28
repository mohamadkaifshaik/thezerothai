package identity

import (
	"context"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W3-25b (ADR-0025 D12): UpdateProfile(is_private=true) needs private_accounts on for the caller, FEATURE_DISABLED
// feature=private_accounts before any read otherwise; is_private=false is never gated. Until W3-26a builds the toggle, a
// caller who passes the gate still gets the old VALIDATION refusal and nothing is written.

func privateRegistry(mode flags.Mode, pct int, allow ...string) *flags.Registry {
	set := map[string]struct{}{}
	for _, u := range allow {
		set[u] = struct{}{}
	}
	return flags.NewRegistry(flags.Spec{Name: PrivateAccountsFlag, Mode: mode, Allowlist: set, Percent: pct})
}

func TestUpdateProfile_PrivateAccountsFlagModes(t *testing.T) {
	const uid = "uid-1"
	var in, out string
	pct := privateRegistry(flags.Percent, 50)
	for i := 0; i < 1000 && (in == "" || out == ""); i++ {
		u := "bucket-" + strings.Repeat("x", i%7) + string(rune('a'+i%26)) + string(rune('a'+i/26%26))
		if pct.Enabled(u, PrivateAccountsFlag) && in == "" {
			in = u
		}
		if !pct.Enabled(u, PrivateAccountsFlag) && out == "" {
			out = u
		}
	}
	if in == "" || out == "" {
		t.Fatal("could not find a uid inside and one outside the 50% cohort")
	}
	yes, no := true, false
	name := "Renamed"
	tests := []struct {
		name         string
		reg          ExtrasFlags // nil = no flags wired
		uid          string
		params       UpdateProfileParams
		wantDisabled bool
	}{
		{"no flags wired", nil, uid, UpdateProfileParams{IsPrivate: &yes}, true},
		{"off", privateRegistry(flags.Off, 0), uid, UpdateProfileParams{IsPrivate: &yes}, true},
		{"allowlist, caller listed", privateRegistry(flags.Allowlist, 0, uid), uid, UpdateProfileParams{IsPrivate: &yes}, false},
		{"allowlist, caller not listed", privateRegistry(flags.Allowlist, 0, "other"), uid, UpdateProfileParams{IsPrivate: &yes}, true},
		{"percent, inside cohort", privateRegistry(flags.Percent, 50), in, UpdateProfileParams{IsPrivate: &yes}, false},
		{"percent, outside cohort", privateRegistry(flags.Percent, 50), out, UpdateProfileParams{IsPrivate: &yes}, true},
		{"on", privateRegistry(flags.On, 0), uid, UpdateProfileParams{IsPrivate: &yes}, false},
		{"mixed request refused whole while off", privateRegistry(flags.Off, 0), uid, UpdateProfileParams{IsPrivate: &yes, DisplayName: &name}, true},
		{"is_private=false accepted while off", privateRegistry(flags.Off, 0), uid, UpdateProfileParams{IsPrivate: &no, DisplayName: &name}, false},
		{"is_private=false accepted outside the cohort", privateRegistry(flags.Allowlist, 0, "other"), uid, UpdateProfileParams{IsPrivate: &no}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			var opts []Option
			if tt.reg != nil {
				opts = append(opts, WithExtrasFlags(tt.reg))
			}
			svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, opts...).(*service)
			if _, err := svc.CreateProfile(context.Background(), tt.uid, validKey, "Alice", "Alice A."); err != nil {
				t.Fatal(err)
			}
			before := repo.updateCalls
			tt.params.IdempotencyKey = validKey
			ctx, counter := budget.WithCounter(context.Background())
			_, err := svc.UpdateProfile(ctx, tt.uid, tt.params)
			switch {
			case tt.wantDisabled:
				_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "private_accounts")
				if repo.updateCalls != before {
					t.Errorf("updateCalls = %d, want %d: a refused request must not reach the repo", repo.updateCalls, before)
				}
				budgettest.Assert(t, "UpdateProfile(is_private=true) refused", counter, budgettest.Budget{}) // 0 reads, 0 writes, 0 deletes
			case tt.params.IsPrivate != nil && *tt.params.IsPrivate:
				// Past the gate, before W3-26a: the old refusal, still 0 writes.
				wantValidationField(t, err, "is_private")
				if repo.updateCalls != before {
					t.Errorf("updateCalls = %d, want %d (0 writes)", repo.updateCalls, before)
				}
			default:
				if err != nil {
					t.Fatalf("UpdateProfile(is_private=false) error = %v, want accepted whatever the flag", err)
				}
			}
		})
	}
}
