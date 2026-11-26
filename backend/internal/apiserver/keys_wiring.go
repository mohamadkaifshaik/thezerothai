// keys_wiring.go builds the key directory (internal/keys): the service on the one repository Build also registers the
// lifecycle with, the messaging send rules behind keys.Permission, and the KeyService handler. FEATURE_E2EE_DM is checked
// by the handler per RPC class (keys/server.go); the target's own flag by the service.
package apiserver

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// The push seam is filled by the notifications repository, and its stage errors give keys' WARN a fixed reason
// (matched by shape: neither module imports the other).
var (
	_ keys.PushRegistrations = (*notifications.FirestoreRepo)(nil)
	_ keys.PushDropReasoner  = (*notifications.DropError)(nil)
)

// freshSessionCuts answers notifications.FreshSessionCuts from an uncached read of users/{uid} (identity's repository,
// never the 60 s profile cache): RegisterPushDevice's session-cut check, once per app start per device. A missing
// profile is no cut.
type freshSessionCuts struct {
	repo interface {
		GetProfile(ctx context.Context, uid string) (identity.Profile, error)
	}
}

var _ notifications.FreshSessionCuts = freshSessionCuts{}

func (f freshSessionCuts) FreshSessionsValidAfter(ctx context.Context, uid string) (time.Time, error) {
	p, err := f.repo.GetProfile(ctx, uid)
	switch {
	case errors.Is(err, identity.ErrNotFound):
		return time.Time{}, nil
	case err != nil:
		return time.Time{}, fmt.Errorf("session cut: %w", err)
	}
	return p.SessionsValidAfter, nil
}

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
//
// reauthMaxAge is config.AccountDeleteReauthMaxAge (ACCOUNT_DELETE_REAUTH_MAX_AGE, validated in (0, 10m]): the recent
// sign-in a REMOTE RemoveKeyDevice of an id not yet marked needs. Required: zero would refuse every REMOTE removal.
//
// push is notifications' push registrations (keys.PushRegistrations, the notifications repository), dropped by a REMOTE
// removal that carries a session cut (lane D PR 5); required, like the session cutter.
//
// sessions is identity's session cut and its refresh-token revoke (security audit H1), one value (Build passes
// newIdentityKeysSessions): a REMOTE removal writes the cut, then revokes. One value, so the revoke can never be wired
// to a different identity than the cut.
//
// serverOpts configure the handler (Build passes the app version floor, keys.WithClientFloor).
func newKeysModule(repo keys.Repo, fc keys.FlagChecker, perm messaging.Permission, convID func(a, b string) string, claimCap *ratelimit.DailyCap, chargeLookups func(context.Context, string, int) error, reauthMaxAge time.Duration, sessions sessionCutRevoker, push keys.PushRegistrations, log *slog.Logger, serverOpts ...keys.ServerOption) (keysModule, error) {
	if repo == nil || perm == nil || convID == nil || claimCap == nil || chargeLookups == nil || sessions == nil || push == nil {
		return keysModule{}, errors.New("keys: missing repository, permission, conversation id function, claim cap, lookup cap, session cutter or push registrations")
	}
	if reauthMaxAge <= 0 {
		return keysModule{}, errors.New("keys: missing reauth max age")
	}
	svc := keys.New(keys.Deps{Repo: repo, Permission: keysPermission{m: perm}, Flags: fc, ClaimCap: claimCap, ChargeLookups: chargeLookups,
		ConversationID: convID, Log: log, ReauthMaxAge: reauthMaxAge, Sessions: sessions, Revoke: sessions, Push: push})
	return keysModule{svc: svc, server: keys.NewServer(fc, svc, serverOpts...)}, nil
}

// sessionCutRevoker is what keys needs from identity: the cut write and the H1 revoke.
type sessionCutRevoker interface {
	keys.SessionCutter
	keys.SessionRevoker
}

// identityKeysSessions is keys' view of identity's session cut (identity.SessionCuts) and refresh-token revoke
// (identity.SessionRevokes). This file is the only place outside identity that holds an identity.SessionRevokes
// (identity's TestSessionRevokes_OnlyKeysWiring): the revoke is not on identity.Service, so no other module can reach it.
// It maps identity.ErrNoSessionCut to keys.ErrNoCutToRevoke (keys never imports identity).
type identityKeysSessions struct {
	cuts    identity.SessionCuts
	revokes identity.SessionRevokes
}

var _ sessionCutRevoker = identityKeysSessions{}

// newIdentityKeysSessions builds the seam from the identity service; it fails when the service has no revoke.
func newIdentityKeysSessions(svc identity.Service) (identityKeysSessions, error) {
	revokes, ok := svc.(identity.SessionRevokes)
	if svc == nil || !ok {
		return identityKeysSessions{}, errors.New("keys: the identity service does not implement identity.SessionRevokes")
	}
	return identityKeysSessions{cuts: svc, revokes: revokes}, nil
}

func (s identityKeysSessions) EndSessionsBefore(ctx context.Context, uid string, t time.Time) error {
	return s.cuts.EndSessionsBefore(ctx, uid, t)
}

func (s identityKeysSessions) RevokeSessionsAt(ctx context.Context, uid string, cut time.Time) error {
	err := s.revokes.RevokeSessionsAt(ctx, uid, cut)
	if errors.Is(err, identity.ErrNoSessionCut) {
		return fmt.Errorf("%w: %w", keys.ErrNoCutToRevoke, err)
	}
	return err
}

func keysLookupCap(established, newAccount int64, isNew func(string) bool) func(context.Context, string, int) error {
	cap := ratelimit.NewDailyCap(established)
	return func(ctx context.Context, uid string, targets int) error {
		limit := established
		if isNew(uid) {
			limit = newAccount
		}
		if !cap.AllowNUpTo(uid, int64(targets), limit) {
			return cap.ExceededError(ctx, "keys_device_lookups_daily")
		}
		return nil
	}
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

// SharesEncryptedConversation (true only for an accepted MLS conversation) forwards unchanged; a failure is wrapped (messaging already hashed the uids and the
// conversation id out of its text), and is never turned into false.
func (p keysPermission) SharesEncryptedConversation(ctx context.Context, callerUID, targetUID string) (bool, error) {
	shared, err := p.m.SharesEncryptedConversation(ctx, callerUID, targetUID)
	if err != nil {
		return false, fmt.Errorf("keys: messaging shared conversation: %w", err)
	}
	return shared, nil
}
