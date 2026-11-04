// follow_requests_gate.go is the gate of ListFollowRequests and RespondToFollowRequest. The two
// RPCs are built in follow_requests.go; this file holds the gate they share.
package graph

import (
	"context"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// PrivateAccountsFlagName is the wire name of FEATURE_PRIVATE_ACCOUNTS.
const PrivateAccountsFlagName = "private_accounts"

// globallyOffChecker is the optional second seam of FlagChecker (*flags.Registry implements it): the kill switch, a
// flag off for every caller. A checker without it is treated as "off unless Enabled for this caller", failing closed.
type globallyOffChecker interface {
	GloballyOff(name string) bool
}

// FollowRequestsGate is the D12 gate of ListFollowRequests and RespondToFollowRequest: FEATURE_GRAPH on for the caller,
// then private_accounts not globally off OR the caller protected now. The second half is what keeps a protected account
// able to manage its requests (and unprotect) after the flag is switched off: ramping the flag down never strands them.
// A refusal is FEATURE_DISABLED with metadata feature=private_accounts.
//
// It does no Firestore access while the flag is not globally off. While it is, it makes one
// identity.Directory.GetProfiles call for the caller, cache-first (the account-status interceptor just loaded the
// profile). It writes nothing.
func (s *service) FollowRequestsGate(ctx context.Context, callerUID string) (err error) {
	defer begin(ctx, "follow_requests_gate")(&err)
	return s.followRequestsGate(ctx, callerUID)
}

// followRequestsGate is FollowRequestsGate without its own graph_op, for the two RPCs that name themselves.
func (s *service) followRequestsGate(ctx context.Context, callerUID string) error {
	if err := s.checkFlag(callerUID); err != nil {
		return err
	}
	if !s.privateAccountsGloballyOff(callerUID) {
		return nil
	}
	profiles, err := s.directory.GetProfiles(ctx, []string{callerUID})
	if err != nil {
		return s.internalErr("follow requests gate", err, callerUID)
	}
	if p, ok := profiles[callerUID]; ok && p.IsPrivate {
		return nil
	}
	logger.SetRequestField(ctx, "feature_disabled", true)
	logger.SetRequestField(ctx, "feature", PrivateAccountsFlagName)
	return flags.DisabledError().WithMeta("feature", PrivateAccountsFlagName)
}

// privateAccountsGloballyOff reports the kill switch. Without a GloballyOff-capable checker it falls back to the
// per-caller answer, which can only over-report "off" (fail closed).
func (s *service) privateAccountsGloballyOff(callerUID string) bool {
	if g, ok := s.flags.(globallyOffChecker); ok {
		return g.GloballyOff(PrivateAccountsFlagName)
	}
	return !s.flags.Enabled(callerUID, PrivateAccountsFlagName)
}
