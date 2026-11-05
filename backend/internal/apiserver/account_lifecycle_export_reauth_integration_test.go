//go:build integration

package apiserver

// RequestAccountExport needs a recent sign-in, like DeleteAccount, over the real Build chain: a stale auth_time is
// FAILED_PRECONDITION + REAUTH_REQUIRED on the wire and writes no exports doc, also on a replay; GetAccountExport
// is not gated. Helpers come from account_lifecycle_integration_test.go and signup_auth_integration_test.go.

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// agedSignInVerifier verifies emulator tokens like prodLikeVerifier but reports the sign-in as signInAge old
// (nanoseconds, changeable mid-test), so one token can be fresh and then stale.
type agedSignInVerifier struct {
	inner     prodLikeVerifier
	signInAge *atomic.Int64
}

func (v agedSignInVerifier) VerifyIDToken(ctx context.Context, idToken string) (authn.Claims, error) {
	c, err := v.inner.VerifyIDToken(ctx, idToken)
	if err != nil {
		return c, err
	}
	c.AuthTime = time.Now().Add(-time.Duration(v.signInAge.Load()))
	return c, nil
}

func TestAccountExport_RequiresRecentSignIn(t *testing.T) {
	ctx := context.Background()
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	age := &atomic.Int64{}
	e := newLifecycleEnvWith(t, agedSignInVerifier{inner: prodLikeVerifier{projectID: cfg.ProjectID}, signInAge: age})
	u := e.newUser(t) // signed in just now

	exportDocs := func() int {
		docs, err := e.fs.Collection("exports").Where("uid", "==", u.uid).Limit(5).Documents(ctx).GetAll()
		if err != nil {
			t.Fatal(err)
		}
		return len(docs)
	}
	reauthRequired := func(err error) {
		t.Helper()
		d := wireError(t, err, connect.CodeFailedPrecondition)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED {
			t.Errorf("reason = %v, want REAUTH_REQUIRED", d.GetReason())
		}
	}

	// Stale sign-in: rejected, nothing written.
	age.Store(int64(time.Hour))
	_, err = e.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "reauth-export-key-0001"}))
	reauthRequired(err)
	if n := exportDocs(); n != 0 {
		t.Fatalf("a rejected RequestAccountExport left %d exports docs", n)
	}

	// Fresh sign-in: accepted.
	age.Store(int64(time.Minute))
	first, err := e.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "reauth-export-key-0001"}))
	if err != nil {
		t.Fatalf("fresh sign-in: %v", err)
	}
	if n := exportDocs(); n != 1 {
		t.Fatalf("exports docs = %d after the accepted request, want 1", n)
	}

	// Stale again: a replay of the same key is rejected too, but the poll still works.
	age.Store(int64(time.Hour))
	_, err = e.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "reauth-export-key-0001"}))
	reauthRequired(err)
	got, err := e.identity.GetAccountExport(ctx, authed(u.token, &identityv1.GetAccountExportRequest{ExportId: first.Msg.GetExportId()}))
	if err != nil || got.Msg.GetExportId() != first.Msg.GetExportId() {
		t.Fatalf("GetAccountExport with a stale sign-in = %v, %v", got, err)
	}
	if n := exportDocs(); n != 1 {
		t.Errorf("exports docs = %d after the rejected replay, want 1", n)
	}
}
