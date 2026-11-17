//go:build integration

package apiserver

// TestAccountLifecycle_PublicIDMintedAndErased: with FEATURE_PUBLIC_IDS on, signup mints the public id with its
// publicIds lookup, GetMe and GetProfile carry it, GetProfile serves the public_id target, and the deletion chain
// removes the lookup before users/{uid} so the erased id answers NOT_FOUND. Setup mirrors TestAccountLifecycle_Chain.

import (
	"context"
	"net/http"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestAccountLifecycle_PublicIDMintedAndErased(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		c.FeaturePublicIDs = flags.Spec{Name: identity.PublicIDsFlag, Mode: flags.On}
	})
	a, b := e.newUser(t), e.newUser(t)

	snap, err := e.fs.Doc("users/" + a.uid).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := snap.DataAt("publicId")
	pub, _ := raw.(string)
	if !identity.ValidPublicID(pub) {
		t.Fatalf("users/{a}.publicId = %v, want a minted public id", raw)
	}
	lookup, err := e.fs.Doc("publicIds/" + pub).Get(ctx)
	if err != nil {
		t.Fatalf("publicIds lookup: %v", err)
	}
	if owner, _ := lookup.DataAt("uid"); owner != a.uid {
		t.Fatalf("publicIds/{id}.uid = %v, want the owner", owner)
	}

	me, err := e.identity.GetMe(ctx, authed(a.token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if got := me.Msg.GetProfile().GetPublicId(); got != pub {
		t.Fatalf("GetMe public id = %q, want %q", got, pub)
	}
	got, err := e.identity.GetProfile(ctx, authed(b.token, &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_PublicId{PublicId: pub}}))
	if err != nil {
		t.Fatalf("GetProfile by public id: %v", err)
	}
	if p := got.Msg.GetProfile(); p.GetUserId() != a.uid || p.GetPublicId() != pub {
		t.Fatalf("GetProfile by public id = %v", p)
	}

	// --- delete A: gated delivery, then the work delivery after the gate ---
	if _, err := e.identity.DeleteAccount(ctx, authed(a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "pubid-delete-key-0001"})); err != nil {
		t.Fatalf("DeleteAccount: %v", err)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "account_delete" {
		t.Fatalf("delete messages = %v", msgs)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusTooManyRequests {
		t.Fatalf("delivery inside the start gate = %d, want 429", code)
	}
	if !fsDocExists(t, e.fs, "publicIds/"+pub) {
		t.Fatal("the gated delivery erased the lookup")
	}
	if _, err := e.fs.Doc("users/"+a.uid).Update(ctx, []firestore.Update{{Path: "deletionRequestedAt", Value: time.Now().Add(-5 * time.Minute)}}); err != nil {
		t.Fatal(err)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery after the gate = %d, want 204", code)
	}
	for _, rest := range e.pull(t) {
		if code := e.deliver(t, rest); code != http.StatusNoContent {
			t.Fatalf("continuation = %d", code)
		}
	}
	if fsDocExists(t, e.fs, "users/"+a.uid) || fsDocExists(t, e.fs, "publicIds/"+pub) {
		t.Fatal("users/{a} or its publicIds lookup survived the deletion")
	}
	left, err := e.fs.Collection("publicIds").Where("uid", "==", a.uid).Limit(5).Documents(ctx).GetAll()
	if err != nil || len(left) != 0 {
		t.Fatalf("publicIds naming the deleted uid: %d, %v", len(left), err)
	}
	// The erased id answers exactly what an unknown handle answers.
	_, erased := e.identity.GetProfile(ctx, authed(b.token, &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_PublicId{PublicId: pub}}))
	_, unknown := e.identity.GetProfile(ctx, authed(b.token, &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_Handle{Handle: "nosuchhandle"}}))
	wireError(t, erased, connect.CodeNotFound)
	wireError(t, unknown, connect.CodeNotFound)
	if erased.Error() != unknown.Error() {
		t.Errorf("erased id = %q, unknown handle = %q; want the same NOT_FOUND", erased, unknown)
	}
}
