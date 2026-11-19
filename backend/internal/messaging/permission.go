package messaging

// permission.go is CanMessage (Permission): the messaging send rules as a yes/no question, for the key directory
// (internal/keys), which may hand out a user's encryption keys only to someone allowed to message them.

import (
	"context"
	"errors"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ErrSelf is CanMessage asked about the caller themselves. It is not a refusal (not ErrCannotMessage): SendMessage
// answers it with VALIDATION, and the key directory never asks (it reads the caller's own devices without this check).
var ErrSelf = errors.New("messaging: cannot message yourself")

var _ Permission = (*service)(nil)

// CanMessage implements Permission: nil when a SendMessage from callerUID to targetUID would not be refused with
// CANNOT_MESSAGE, else exactly ErrCannotMessage, whatever the cause. It writes nothing to Firestore (the only state it
// touches is the instance conversation cache, which a read fills as on every other read path).
//
// The rules are the send's own functions, applied without the send transaction, in this order:
//   - callerUID == targetUID: ErrSelf (not a refusal).
//   - a malformed uid, or FEATURE_MESSAGING off for the caller (Send's per-caller gate, here a refusal rather than
//     FEATURE_DISABLED): ErrCannotMessage, no read.
//   - the caller's graph (Social.Snapshot): the target blocked the caller (BlockedBy): ErrCannotMessage, before the
//     profile read. When the caller's blockedBy list overflowed (it no longer names every blocker), the target's own
//     graph (Social.Snapshot, cache-first) decides instead: the target's Blocked set names the caller => ErrCannotMessage.
//     That is what SendMessage decides (its transaction reads the recipient's graph, never the caller's blockedBy), so
//     an overflowed caller is not refused here where a send would be allowed. (The thread header and the export keep
//     failing closed through peerBlockedCaller.)
//   - the target's profile (Profiles.GetProfiles), then recipientRefusal, the caller-side check Send runs before its
//     transaction: the caller blocked the target, the target is unknown or not ACTIVE, or messaging is off for the target.
//   - the target's FOLLOWING_ONLY policy (recipientFollowingOnly, the predicate Send passes as RecipientFollowingOnly),
//     decided by dmPolicyRefuses exactly as the send transaction decides it: the follow-back from graph's batched
//     FollowLookup and, only when the target does not follow the caller, the conversation (cache-first), so an existing
//     ACCEPTED conversation, or a request the target sent the caller, is never refused.
//
// Not refusals, by design: a message REQUEST (a non-mutual first message lands in the target's Requests, and sending it
// is allowed, so is this); the caps that limit sends (MESSAGES_REQUEST_MAX_UNANSWERED, QUOTA_DM_NEW_CONVERSATIONS_PER_DAY,
// the daily send caps), which bound messages, not key lookups; a mute either way. A conversation whose peer deleted the
// account is not read separately: the deleted peer is not ACTIVE, so recipientRefusal already refuses.
//
// Reads, all cache-first (CACHE_TTL, 60 s by default): at most 4 per call, or 5 when the caller's blockedBy list
// overflowed: the caller's graph snapshot, the target's graph snapshot (overflow only), one profile batch of one uid,
// one follow-edge lookup and one conversation document; the last two only when the target's FOLLOWING_ONLY policy
// applies (the conversation only when the target does not follow the caller). The cheapest refusals read nothing
// (self, malformed, caller flag off) or only the graphs (a block found there).
//
// Staleness: SendMessage reads the recipient's graph inside its transaction (fresh); this function cannot, so a block,
// unfollow or policy change made on another instance can take up to CACHE_TTL (60 s) to be seen here (this instance
// updates its own caches on its own graph writes). That is acceptable for a key lookup: keys are public material, and the
// message itself goes through SendMessage, which re-checks every rule freshly in its transaction.
//
// A failed read is returned as a plain error with both uids hashed out of its text, never ErrCannotMessage and never an
// *apierr.Error (a dependency's shaped error is flattened to its text).
func (s *service) CanMessage(ctx context.Context, callerUID, targetUID string) error {
	if callerUID == targetUID {
		return ErrSelf
	}
	if !ids.ValidUID(callerUID) || !ids.ValidUID(targetUID) || !s.enabledFor(callerUID, FlagName) {
		return ErrCannotMessage
	}
	if s.d.Repo == nil || s.d.Social == nil || s.d.Profiles == nil || s.d.Suggestions.Follows == nil {
		return errors.New("messaging: the permission check is not configured")
	}
	mine, err := s.d.Social.Snapshot(ctx, callerUID)
	if err != nil {
		return permissionFailure("caller graph", err, callerUID, targetUID)
	}
	if mine.BlockedBy[targetUID] {
		return ErrCannotMessage
	}
	if mine.BlockedByOverflow {
		// The caller's blockedBy list is truncated, so it cannot say: ask the target's own block list, as SendMessage's
		// transaction does (requestBlockedByPeer's fallback; a target with no graph document is an empty snapshot).
		theirs, err := s.d.Social.Snapshot(ctx, targetUID)
		if err != nil {
			return permissionFailure("target graph", err, callerUID, targetUID)
		}
		if theirs.Blocked[callerUID] {
			return ErrCannotMessage
		}
	}
	profiles, err := s.d.Profiles.GetProfiles(ctx, []string{targetUID})
	if err != nil {
		return permissionFailure("profiles", err, callerUID, targetUID)
	}
	peer, active := profiles[targetUID]
	if s.recipientRefusal(mine, targetUID, active) != "" {
		return ErrCannotMessage
	}
	if !s.recipientFollowingOnly(targetUID, peer) {
		return nil
	}
	back, err := s.d.Suggestions.Follows.FollowersAmong(ctx, callerUID, []string{targetUID})
	if err != nil {
		return permissionFailure("follow lookup", err, callerUID, targetUID)
	}
	if back[targetUID] {
		return nil // dmPolicyRefuses never refuses a caller the recipient follows
	}
	convID := ConversationID(callerUID, targetUID)
	var conv *ConvDoc
	switch c, err := s.conversation(ctx, callerUID, convID); {
	case errors.Is(err, ErrNotFound):
	case err != nil:
		return permissionFailure("conversation", err, callerUID, targetUID, convID)
	default:
		conv = &c
	}
	if dmPolicyRefuses(conv, callerUID, true, false) {
		return ErrCannotMessage
	}
	return nil
}

// permissionFailure is a failed read of CanMessage: a plain error naming the step, with the uids (and the conversation id)
// replaced by their hashes. The cause stays in the chain (a deadline or contention keeps its class) unless it is an
// *apierr.Error or ErrCannotMessage, which is flattened to text so the failure can never be read as a wire answer or a
// refusal.
func permissionFailure(step string, err error, redact ...string) error {
	red := logger.RedactErr(fmt.Errorf("messaging: can message: %s: %w", step, err), redact...)
	var ae *apierr.Error
	if errors.As(err, &ae) || errors.Is(err, ErrCannotMessage) {
		return errors.New(red.Error())
	}
	return red
}
