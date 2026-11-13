package billing

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"strings"
	"time"
)

// IdentityService allocates opaque provider IDs; a public Firebase UID must
// never be used as a purchase identity. Authentication is the caller's concern;
// storage rechecks the active account atomically with allocation.
type IdentityService struct {
	store BindingStore
	env   Environment
	now   func() time.Time
}

func NewIdentityService(store BindingStore, env Environment, now func() time.Time) (*IdentityService, error) {
	if store == nil || !validEnvironment(env) {
		return nil, ErrInvalidInput
	}
	if now == nil {
		now = time.Now
	}
	return &IdentityService{store: store, env: env, now: now}, nil
}

func (s *IdentityService) Ensure(ctx context.Context, uid string) (Binding, error) {
	if !validUID(uid) {
		return Binding{}, ErrInvalidInput
	}
	if err := ctx.Err(); err != nil {
		return Binding{}, err
	}
	// 256 random bits, URL/path safe, with a recognizable non-UID prefix.
	var entropy [32]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return Binding{}, ErrUnavailable
	}
	candidate := Binding{
		UID: uid, CustomerID: "dzb_" + base64.RawURLEncoding.EncodeToString(entropy[:]),
		Environment: s.env, CreatedAt: s.now().UTC(),
	}
	if candidate.CreatedAt.IsZero() {
		return Binding{}, ErrInvalidInput
	}
	stored, err := s.store.EnsureBinding(ctx, candidate)
	if err != nil {
		return Binding{}, err
	}
	if !validBinding(stored) || stored.UID != uid || stored.Environment != s.env {
		return Binding{}, ErrOwnership
	}
	return stored, nil
}

func validEnvironment(env Environment) bool { return env == Sandbox || env == Production }

func validUID(uid string) bool {
	return uid != "" && len(uid) <= 128 && uid != "." && uid != ".." && !strings.ContainsAny(uid, "/\x00\r\n")
}

func validBinding(b Binding) bool {
	if !validUID(b.UID) || !validEnvironment(b.Environment) || b.CreatedAt.IsZero() || !strings.HasPrefix(b.CustomerID, "dzb_") {
		return false
	}
	encoded := strings.TrimPrefix(b.CustomerID, "dzb_")
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(encoded)
	return err == nil && len(decoded) == 32 && base64.RawURLEncoding.EncodeToString(decoded) == encoded
}
