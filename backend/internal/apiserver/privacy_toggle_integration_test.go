//go:build integration

package apiserver

// W3-26a: the is_private toggle (ADR-0025 D8) through the real Build chain on the emulators, budgets asserted from the
// request lines: protect 4 reads cold (interceptor + users, quotas, set doc) and 3 writes; an equal value 0 writes and no
// quota charge; unprotect from a caller outside the cohort accepted; the 5th toggle of an IST day QUOTA_EXCEEDED with 0
// writes; the cap LIMIT_REACHED limit=private_accounts with 0 writes; the set doc and users.isPrivate agree throughout.

import (
	"context"
	"slices"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func ptoggleSetUIDs(t *testing.T, e *chainEnv) []string {
	t.Helper()
	snap, err := e.fs.Doc("privacy/protectedAuthors").Get(context.Background())
	if err != nil {
		return nil
	}
	var d struct {
		UIDs []string `firestore:"uids"`
	}
	if err := snap.DataTo(&d); err != nil {
		t.Fatalf("decode set: %v", err)
	}
	return d.UIDs
}

func ptoggleStored(t *testing.T, e *chainEnv, uid string) (isPrivate bool, toggles int64) {
	t.Helper()
	u, err := e.fs.Doc("users/" + uid).Get(context.Background())
	if err != nil {
		t.Fatalf("read user: %v", err)
	}
	isPrivate, _ = u.Data()["isPrivate"].(bool)
	if q, err := e.fs.Doc("quotas/" + uid).Get(context.Background()); err == nil {
		toggles, _ = q.Data()["privacyToggles"].(int64)
	}
	return isPrivate, toggles
}

func TestPrivacyToggle_Chain(t *testing.T) {
	ctx := context.Background()
	token, uid := mintToken(t, "")
	cohort := func(c *config.Config) {
		relaxLimits(c)
		c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
		c.FeaturePrivateAccounts = flags.Spec{Name: privateAccountsFeature, Mode: flags.Allowlist, Allowlist: map[string]struct{}{uid: {}}}
	}
	seed := newChain(t, cohort)
	seed.createProfile(t, token)

	// A cold instance (nothing cached): the interceptor's profile read is part of the 4.
	cold := newW320BM(newChain(t, cohort))
	call := func(e *bmChain, key string, v bool) error {
		_, err := e.identity.UpdateProfile(ctx, authed(token, &identityv1.UpdateProfileRequest{IdempotencyKey: key, IsPrivate: &v}))
		return err
	}
	if err := call(cold, "ptoggle-key-0000001", true); err != nil {
		t.Fatalf("protect: %v", err)
	}
	c := cold.lineBudget(t, rpcUpdateProfile)
	budgettest.Assert(t, "protect, cold", c, budgettest.Budget{Reads: 4, Writes: 3})
	if c.Reads() != 4 || c.Writes() != 3 {
		t.Errorf("protect cold = %d reads / %d writes, want exactly 4 / 3", c.Reads(), c.Writes())
	}
	if priv, n := ptoggleStored(t, cold.chainEnv, uid); !priv || n != 1 || !slices.Contains(ptoggleSetUIDs(t, cold.chainEnv), uid) {
		t.Fatalf("after protect: isPrivate=%v quota=%d set=%v, want true / 1 / contains uid", priv, n, ptoggleSetUIDs(t, cold.chainEnv))
	}
	if line := cold.logs.requestLines(rpcUpdateProfile); line[len(line)-1]["privacy_toggle"] != "on" {
		t.Errorf("request line privacy_toggle = %v, want on", line[len(line)-1]["privacy_toggle"])
	}

	// The same value again: 1 read (users), 0 writes, quota unchanged.
	if err := call(cold, "ptoggle-key-0000002", true); err != nil {
		t.Fatalf("protect again: %v", err)
	}
	c = cold.lineBudget(t, rpcUpdateProfile)
	budgettest.Assert(t, "protect again", c, budgettest.Budget{Reads: 1, Writes: 0})
	if _, n := ptoggleStored(t, cold.chainEnv, uid); n != 1 {
		t.Errorf("equal value charged the quota: privacyToggles = %d, want 1", n)
	}

	// Undo from a caller OUTSIDE the cohort (a revision where the flag is off for them) is accepted.
	off := newW320BM(newChain(t, func(c *config.Config) {
		relaxLimits(c)
		c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
	}))
	if err := call(off, "ptoggle-key-0000003", false); err != nil {
		t.Fatalf("unprotect with the flag off: %v", err)
	}
	c = off.lineBudget(t, rpcUpdateProfile)
	budgettest.Assert(t, "unprotect, cold", c, budgettest.Budget{Reads: 3, Writes: 3})
	if priv, n := ptoggleStored(t, off.chainEnv, uid); priv || n != 2 || slices.Contains(ptoggleSetUIDs(t, off.chainEnv), uid) {
		t.Fatalf("after unprotect: isPrivate=%v quota=%d set=%v, want false / 2 / without uid", priv, n, ptoggleSetUIDs(t, off.chainEnv))
	}

	// Toggles 3 and 4 pass, the 5th is QUOTA_EXCEEDED with 0 writes.
	for i, v := range []bool{true, false} {
		if err := call(cold, "ptoggle-key-000001"+string(rune('0'+i)), v); err != nil {
			t.Fatalf("toggle %d: %v", i+3, err)
		}
	}
	err := call(cold, "ptoggle-key-0000020", true)
	d := wireError(t, err, connect.CodeResourceExhausted)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
	if d.GetMetadata()["quota"] != "privacy_toggles" {
		t.Errorf("metadata = %v, want quota=privacy_toggles", d.GetMetadata())
	}
	c = cold.lineBudget(t, rpcUpdateProfile)
	if c.Writes() != 0 {
		t.Errorf("5th toggle wrote %d, want 0", c.Writes())
	}
	if priv, n := ptoggleStored(t, cold.chainEnv, uid); priv || n != 4 {
		t.Errorf("after the refused toggle: isPrivate=%v quota=%d, want false / 4", priv, n)
	}
}

// TestPrivacyToggle_Cap: with the cap at the set's current size, a further protect is LIMIT_REACHED limit=private_accounts
// with 0 writes (the set size is read from the shared emulator, so other tests' entries do not matter).
func TestPrivacyToggle_Cap(t *testing.T) {
	ctx := context.Background()
	token, uid := mintToken(t, "")
	probe := newChain(t, relaxLimits)
	size := len(ptoggleSetUIDs(t, probe))
	e := newW320BM(newChain(t, func(c *config.Config) {
		relaxLimits(c)
		c.FeaturePrivateAccounts = flags.Spec{Name: privateAccountsFeature, Mode: flags.On}
		c.Privacy.ProtectedAuthorsMax = size
	}))
	e.createProfile(t, token)
	yes := true
	_, err := e.identity.UpdateProfile(ctx, authed(token, &identityv1.UpdateProfileRequest{IdempotencyKey: "ptoggle-cap-0000001", IsPrivate: &yes}))
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if d.GetMetadata()["limit"] != "private_accounts" {
		t.Errorf("metadata = %v, want limit=private_accounts", d.GetMetadata())
	}
	if c := e.lineBudget(t, rpcUpdateProfile); c.Writes() != 0 {
		t.Errorf("capped protect wrote %d, want 0", c.Writes())
	}
	if priv, n := ptoggleStored(t, e.chainEnv, uid); priv || n != 0 || slices.Contains(ptoggleSetUIDs(t, e.chainEnv), uid) {
		t.Errorf("capped protect left state: isPrivate=%v quota=%d", priv, n)
	}
}
