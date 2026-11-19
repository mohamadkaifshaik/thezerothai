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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// keysModule is what Build needs of keys: the service and the handler (the lifecycle uses the repository directly).
type keysModule struct {
	svc    keys.Service
	server *keys.Server
}

// newKeysModule wires keys on the given repository (the same instance registerKeysLifecycle received, never a second
// one), the flag registry (handler gates and the target's flag), the messaging permission and the per-(caller, target)
// claim cap (KEYS_CLAIMS_PER_TARGET_PER_DAY, drawn on by the service; required, so a missed wire-up fails Build).
//
// convID is messaging.ConversationID, injected so keys never imports messaging (ClaimKeyPackagesResponse.conversation_id);
// required, like the cap.
func newKeysModule(repo keys.Repo, fc keys.FlagChecker, perm messaging.Permission, convID func(a, b string) string, claimCap *ratelimit.DailyCap, log *slog.Logger) (keysModule, error) {
	if repo == nil || perm == nil || convID == nil || claimCap == nil {
		return keysModule{}, errors.New("keys: nil repository, messaging permission, conversation id function or per-target claim cap")
	}
	svc := keys.New(keys.Deps{Repo: repo, Permission: keysPermission{m: perm}, Flags: fc, ClaimCap: claimCap, ConversationID: convID, Log: log})
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

// SharesEncryptedConversation forwards unchanged; a failure is wrapped (messaging already hashed the uids and the
// conversation id out of its text), and is never turned into false.
func (p keysPermission) SharesEncryptedConversation(ctx context.Context, callerUID, targetUID string) (bool, error) {
	shared, err := p.m.SharesEncryptedConversation(ctx, callerUID, targetUID)
	if err != nil {
		return false, fmt.Errorf("keys: messaging shared conversation: %w", err)
	}
	return shared, nil
}
