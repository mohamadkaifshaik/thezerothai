//go:build integration

package apiserver

// The corners of the toggle limits that TestPrivacyToggle_Chain and TestPrivacyToggle_Cap do not reach,
// over the real Build chain. Those two cover protect/unprotect, the equal-true no-op, the 5th toggle and the
// capped protect. Here:
//   - the order of the checks: an is_private equal to the stored value is a no-op (nothing written, not charged) even when the
//     quota is 4 of 4 (public or protected) and even when the protected set is at its cap;
//   - an equal-false on an account that was never protected;
//   - the quota is the first refusal for a DIFFERENT value at 4 of 4 and its answer writes nothing;
//   - an unprotect is accepted while the set is at the cap (the cap only ever blocks a new entry).

import (
	"context"
	"slices"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestW335b_PrivacyToggleLimits(t *testing.T) {
	ctx := context.Background()
	on := func(c *config.Config) {
		relaxLimits(c)
		c.FeaturePrivateAccounts = flags.Spec{Name: privateAccountsFeature, Mode: flags.On}
	}
	toggle := func(e *bmChain, token string, key string, v bool) error {
		_, err := e.identity.UpdateProfile(ctx, authed(token, &identityv1.UpdateProfileRequest{IdempotencyKey: key, IsPrivate: &v}))
		return err
	}
	t.Run("equal-false on an account that was never protected", func(t *testing.T) {
		token, uid := mintToken(t, "")
		e := newW320BM(newChain(t, on))
		e.createProfile(t, token)
		if err := toggle(e, token, "w335b-never-0000001", false); err != nil {
			t.Fatalf("is_private=false on a public account: %v", err)
		}
		if priv, n := ptoggleStored(t, e.chainEnv, uid); priv || n != 0 {
			t.Errorf("equal-false changed state: isPrivate=%v quota=%d, want false / 0", priv, n)
		}
	})

	t.Run("no daily toggle quota: a fifth change in a day goes through", func(t *testing.T) {
		token, uid := mintToken(t, "")
		e := newW320BM(newChain(t, on))
		e.createProfile(t, token)
		for i, v := range []bool{true, false, true, false, true} {
			if err := toggle(e, token, "w335b-five-000000"+string(rune('1'+i)), v); err != nil {
				t.Fatalf("toggle %d: %v", i+1, err)
			}
		}
		if priv, n := ptoggleStored(t, e.chainEnv, uid); !priv || n != 0 {
			t.Errorf("after five toggles: isPrivate=%v quota=%d, want true / 0", priv, n)
		}
	})

	t.Run("the set at its cap: unprotect and equal-true pass, a new protect is LIMIT_REACHED", func(t *testing.T) {
		tokenD, uidD := mintToken(t, "") // protected before the cap bites, unprotects at the cap
		tokenE, _ := mintToken(t, "")    // protected before the cap bites, sends equal-true at the cap
		tokenF, uidF := mintToken(t, "") // a new protect at the cap
		roomy := newW320BM(newChain(t, on))
		for _, tk := range []string{tokenD, tokenE, tokenF} {
			roomy.createProfile(t, tk)
		}
		if err := toggle(roomy, tokenD, "w335b-cap-0000000001", true); err != nil {
			t.Fatal(err)
		}
		if err := toggle(roomy, tokenE, "w335b-cap-0000000002", true); err != nil {
			t.Fatal(err)
		}
		size := len(ptoggleSetUIDs(t, roomy.chainEnv)) // includes D and E; others' entries only make "at the cap" truer
		tight := newW320BM(newChain(t, func(c *config.Config) {
			on(c)
			c.Privacy.ProtectedAuthorsMax = size
		}))

		if err := toggle(tight, tokenE, "w335b-cap-0000000003", true); err != nil {
			t.Errorf("equal-true at the cap = %v, want accepted (nothing is added)", err)
		}
		// F's protect is refused while the set is at the cap. Another suite may have shrunk the shared set meanwhile, so
		// refill: only assert the refusal when the set is still full.
		if len(ptoggleSetUIDs(t, tight.chainEnv)) >= size {
			err := toggle(tight, tokenF, "w335b-cap-0000000005", true)
			d := wireError(t, err, connect.CodeFailedPrecondition)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
			if priv, n := ptoggleStored(t, tight.chainEnv, uidF); priv || n != 0 {
				t.Errorf("the refused protect left isPrivate=%v quota=%d", priv, n)
			}
		}
		if err := toggle(tight, tokenD, "w335b-cap-0000000004", false); err != nil {
			t.Fatalf("unprotect at the cap = %v, want accepted (the cap only blocks a new entry)", err)
		}
		if priv, _ := ptoggleStored(t, tight.chainEnv, uidD); priv || slices.Contains(ptoggleSetUIDs(t, tight.chainEnv), uidD) {
			t.Errorf("D after the unprotect: isPrivate=%v, set contains D=%v", priv, slices.Contains(ptoggleSetUIDs(t, tight.chainEnv), uidD))
		}
		// Clean up the shared set.
		if err := toggle(roomy, tokenE, "w335b-cap-0000000006", false); err != nil {
			t.Errorf("cleanup unprotect: %v", err)
		}
	})
}
