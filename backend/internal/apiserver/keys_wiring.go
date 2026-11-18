// keys_wiring.go builds the key directory (internal/keys): the service on the one repository Build also registers the
// lifecycle with, the messaging send rules behind keys.Permission, and the KeyService handler. FEATURE_E2EE_DM is checked
// by the handler per RPC class (keys/server.go); the target's own flag by the service.
package apiserver

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
)

// keysModule is what Build needs of keys: the service and the handler (the lifecycle uses the repository directly).
type keysModule struct {
	svc    keys.Service
	server *keys.Server
}

// newKeysModule wires keys on the given repository (the same instance registerKeysLifecycle received, never a second
// one), the flag registry (handler gates and the target's flag) and the messaging permission.
func newKeysModule(repo keys.Repo, fc keys.FlagChecker, perm messaging.Permission, log *slog.Logger) (keysModule, error) {
	if repo == nil || perm == nil {
		return keysModule{}, errors.New("keys: nil repository or messaging permission")
	}
	svc := keys.New(keys.Deps{Repo: repo, Permission: keysPermission{m: perm}, Flags: fc, Log: log})
	return keysModule{svc: svc, server: keys.NewServer(fc, svc)}, nil
}

// keysPermission adapts messaging.Permission to keys.Permission: messaging's one refusal (messaging.ErrCannotMessage)
// becomes keys.ErrCannotMessage, which the keys service answers with its single CANNOT_MESSAGE. Every other error is a
// failure to decide and passes through as a plain wrapped error (keys seals it to a generic failure; messaging already
// hashed the uids out of its text).
type keysPermission struct{ m messaging.Permission }

var _ keys.Permission = keysPermission{}

func (p keysPermission) CanMessage(ctx context.Context, callerUID, targetUID string) error {
	err := p.m.CanMessage(ctx, callerUID, targetUID)
	switch {
	case err == nil:
		return nil
	case errors.Is(err, messaging.ErrCannotMessage):
		return keys.ErrCannotMessage
	}
	return fmt.Errorf("keys: messaging permission: %w", err)
}
