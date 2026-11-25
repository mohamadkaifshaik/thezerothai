package identity

import (
	"context"
	"slices"
)

// messagingFamily is every GetMe.enabled_features name a build below the client floor must not see (plan 6 section 3.1):
// direct messages, the key directory and the settings and extras that only make sense with them. "e2ee_required" is
// listed ahead of its flag (Plan 6 Task 1.A); a name that is not registered is simply never in the list.
// "chat_shared_plans" (BeaconService.ListSharedBeacons) is the "Shared plan" box of the DM thread: the client reads it
// only on the thread screen, so it goes with messaging. The RPC itself stays a beacons RPC and is not floor-gated.
var messagingFamily = []string{
	MessagingFlag, "e2ee_dm", "e2ee_required", "dm_share_check", "dm_post_share",
	"message_search", "read_receipts", "dm_suggestions", "dm_policy", "chat_shared_plans",
}

// featureMessagingUpdate is the name GetMe.features_needing_update carries for messaging.
const featureMessagingUpdate = "messaging"

// WithClientFloor wires the app version floor into GetMe. Nil (the default) or a floor of 0 everywhere changes nothing.
func WithClientFloor(f ClientFloor) Option {
	return func(s *service) { s.clientFloor = f }
}

// applyClientFloor is GetMe's floor filter, run before anything reads enabled (the messages badge, the home tabs): for a
// build below the floor it returns enabled without the messaging family (a new slice; the provider's is never changed)
// and ["messaging"] when messaging was on for the caller, so the client shows an update prompt only for a feature the
// caller would really get. At or above the floor, or with no floor wired, enabled is returned unchanged and the list is
// nil. 0 reads: the floor is config and the header is in ctx.
func (s *service) applyClientFloor(ctx context.Context, enabled []string) ([]string, []string) {
	if s.clientFloor == nil || !s.clientFloor.BelowFloor(ctx) {
		return enabled, nil
	}
	var needing []string
	if slices.Contains(enabled, MessagingFlag) {
		needing = []string{featureMessagingUpdate}
	}
	kept := make([]string, 0, len(enabled))
	for _, name := range enabled {
		if !slices.Contains(messagingFamily, name) {
			kept = append(kept, name)
		}
	}
	return kept, needing
}
