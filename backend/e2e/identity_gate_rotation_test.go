//go:build integration

package e2e

import (
	"context"
	"fmt"
	"math/rand"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// TestE2E_UnverifiedAccountRotation_CostsNoReads (audit item 3, T20 AC4): mint five unverified password accounts
// and rotate 20 calls over them, alternating GetMe and CheckHandleAvailability. Every call is answered from the
// token claims (EMAIL_NOT_VERIFIED / PROFILE_REQUIRED) with fs_reads == 0, gate=email_unverified and no
// limit_name. PerUserPerMinute = 1 and CheckHandle 1/min make the gate-before-limiter order observable: if any
// minted uid reached the limiter, its second call would be RATE_LIMITED. A bank of minted uids therefore creates
// no limiter state and no Firestore read.
func TestE2E_UnverifiedAccountRotation_CostsNoReads(t *testing.T) {
	skipIfNoEmulators(t)
	const accounts, calls = 5, 20
	log, logs := captureLogger()
	client, _ := newTestServerCfgLog(t, func(cfg *config.Config) {
		cfg.RateLimit.PerUserPerMinute = 1
		cfg.RateLimit.CheckHandlePerUserPerMinute = 1
		cfg.RateLimit.PerIPPerMinute = 1000
	}, log)

	tokens := make([]string, accounts)
	for i := range tokens {
		tokens[i], _ = newPasswordIDToken(t, fmt.Sprintf("rot-unverified-%d-%d@example.com", i, rand.Int63()), "correct horse battery staple")
	}

	ctx := context.Background()
	var nCheck, nMe int
	for i := 0; i < calls; i++ {
		token := tokens[i%accounts]
		if i%2 == 0 {
			nCheck++
			_, err := client.CheckHandleAvailability(ctx, authedRequest(token, &identityv1.CheckHandleAvailabilityRequest{Handle: uniqueHandle("rot")}))
			assertErrorReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED)
		} else {
			nMe++
			_, err := client.GetMe(ctx, authedRequest(token, &identityv1.GetMeRequest{}))
			assertErrorReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED)
		}
	}

	for rpc, want := range map[string]int{
		identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: nCheck,
		identityv1connect.IdentityServiceGetMeProcedure:                   nMe,
	} {
		lines := logs.requestLines(t, rpc)
		if len(lines) != want {
			t.Fatalf("%s: %d request lines, want %d", rpc, len(lines), want)
		}
		for i, rec := range lines {
			if reads, _ := rec["fs_reads"].(float64); reads != 0 {
				t.Errorf("%s call %d: fs_reads = %v, want 0", rpc, i, rec["fs_reads"])
			}
			if rec["gate"] != "email_unverified" {
				t.Errorf("%s call %d: gate = %v, want email_unverified", rpc, i, rec["gate"])
			}
			if rec["limit_name"] != nil {
				t.Errorf("%s call %d: limit_name = %v, want none (the gate runs before the limiter)", rpc, i, rec["limit_name"])
			}
		}
	}
}
