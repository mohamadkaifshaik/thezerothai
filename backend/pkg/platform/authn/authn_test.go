package authn_test

import (
	"context"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

func TestUIDFromContext_Unset(t *testing.T) {
	if _, ok := authn.UIDFromContext(context.Background()); ok {
		t.Fatal("expected ok=false when no claims are attached")
	}
}

func TestUIDFromContext_Set(t *testing.T) {
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-1"})
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid != "uid-1" {
		t.Fatalf("got (%q, %v), want (uid-1, true)", uid, ok)
	}
}
