//go:build integration

package e2e

import (
	"context"
	"strings"
	"testing"

	"google.golang.org/protobuf/encoding/protojson"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestE2E_PublicIDs_FlagOnSmoke: through apiserver.Build, with FEATURE_PUBLIC_IDS on for everyone, a caller's own
// profile names itself by public id only: user_id and public_id are the same valid public id, and the Firebase uid is
// nowhere in the response. Flag off, the same caller sees its uid and no public id. (The full scan of every procedure
// is backend/internal/apiserver TestUIDScan_EndToEnd.)
func TestE2E_PublicIDs_FlagOnSmoke(t *testing.T) {
	skipIfNoEmulators(t)
	idToken, uid := newAnonymousIDToken(t)
	ctx := context.Background()

	onClient, _ := newTestServerCfg(t, func(cfg *config.Config) {
		cfg.FeaturePublicIDs = flags.Spec{Name: identity.PublicIDsFlag, Mode: flags.On}
	})
	if _, err := onClient.CreateProfile(ctx, authedRequest(idToken, &identityv1.CreateProfileRequest{
		IdempotencyKey: "e2e-public-ids-create-profile", Handle: uniqueHandle("pi"), DisplayName: "Public IDs",
	})); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	me, err := onClient.GetMe(ctx, authedRequest(idToken, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe (flag on): %v", err)
	}
	p := me.Msg.GetProfile()
	if !identity.ValidPublicID(p.GetPublicId()) || p.GetUserId() != p.GetPublicId() {
		t.Errorf("flag on: user_id = %q, public_id = %q, want one valid public id in both", p.GetUserId(), p.GetPublicId())
	}
	if raw, _ := protojson.Marshal(me.Msg); strings.Contains(string(raw), uid) {
		t.Errorf("flag on: the response carries the caller's uid")
	}

	// Same caller, same Firestore project, flag off: the stored form.
	offClient, _ := newTestServerCfg(t, func(cfg *config.Config) {
		cfg.FeaturePublicIDs = flags.Spec{Name: identity.PublicIDsFlag, Mode: flags.Off}
	})
	me, err = offClient.GetMe(ctx, authedRequest(idToken, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe (flag off): %v", err)
	}
	if p := me.Msg.GetProfile(); p.GetUserId() != uid || p.GetPublicId() != "" {
		t.Errorf("flag off: user_id = %q, public_id = %q, want the uid and no public id", p.GetUserId(), p.GetPublicId())
	}
}
