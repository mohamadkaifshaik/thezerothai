// follow_requests.go is the service layer of ListFollowRequests, RespondToFollowRequest and the pending-request count
// (ADR-0025 D7, AQ3; ticket W3-28a), plus the PROTECTED_ACCOUNT rule of the follower and following lists (D5). The D12
// gate (follow_requests_gate.go) comes first in both RPCs; accept and decline are undo-class and never need
// FEATURE_PRIVATE_ACCOUNTS from a protected caller. The accept transaction is repo_requests.go.
package graph

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// requestsBinding seals a ListFollowRequests token to the caller and the list (24 h TTL, the cursor package default).
func requestsBinding(callerUID string) string { return callerUID + "|follow-requests" }

// ListFollowRequests (ADR-0025 D7): the caller's incoming requests, newest first, page 20 by default and 50 at most.
// Rows are hydrated through identity.Directory; requesters who are not ACTIVE, whom the caller blocks or who block the
// caller are dropped (a short page keeps its token), and each row carries the caller's relationship to the requester
// from the snapshot already held. The cursor is graph's list cursor, bound to `caller|follow-requests`; a foreign,
// expired or tampered token is VALIDATION page_token at 0 reads.
//
// Firestore: reads 42 cold at page 20 / 102 at page 50 (interceptor 1, caller graph 1, query <= page, hydration <= page),
// 21 / 51 warm (the interceptor's profile and the caller snapshot cached); 0 reads beyond the interceptor on a flag
// refusal or a bad token. Writes 0.
func (s *service) ListFollowRequests(ctx context.Context, callerUID string, pageSize int32, pageToken string) (_ Page, err error) {
	defer begin(ctx, "list_follow_requests")(&err)
	if err := s.followRequestsGate(ctx, callerUID); err != nil {
		return Page{}, err
	}
	after, err := s.decodeBoundCursor(requestsBinding(callerUID), pageToken, func(id string) bool { return strings.HasSuffix(id, "_"+callerUID) })
	if err != nil {
		return Page{}, err
	}
	snap, err := s.Snapshot(ctx, callerUID)
	if err != nil {
		return Page{}, logger.RedactErr(fmt.Errorf("graph: list follow requests: %w", err), callerUID)
	}
	size := limits.ClampPageSize(pageSize)
	edges, err := s.repo.ListEdges(ctx, EdgeQuery{UID: callerUID, Requests: true, Limit: size, After: after})
	if err != nil {
		return Page{}, logger.RedactErr(fmt.Errorf("graph: list follow requests: %w", err), callerUID)
	}
	return s.edgePage(ctx, callerUID, snap, edges, size, requestsBinding(callerUID), func(e Edge) string { return e.FollowerID })
}

// RespondToFollowRequest (ADR-0025 D7): accept or decline the pending request from requesterUID. Validation order: gate,
// idempotency key format (validated, not stored: the request doc is the state), requester id, self. Then one transaction
// (Repo.RespondToRequest). After an accept: the requester's snapshot, the edge answer and the directory counters are
// dropped on this instance, and FollowRequestAccepted is reported (never Followed; a decline reports nothing). The
// response is the caller's Relationship to the requester from the caller's snapshot ("Follow back" is offered when it
// is NONE).
//
// Firestore: reads 3 cold / 2 warm (interceptor, the request fresh, the requester's graph fresh); the requester's status
// (Directory, only for an accept of a request that exists) and the caller's snapshot are cache-first, so List then
// Respond adds nothing, and a truly cold standalone accept pays up to 2 more. A replay (the request is gone) reads 2
// cold / 1 warm. Writes: accept 4 + 1 delete, decline 1 + 1 delete, requester not ACTIVE or drift 1 + 1 delete, requester
// at the 5,000 cap or a replay 0.
func (s *service) RespondToFollowRequest(ctx context.Context, callerUID, idempotencyKey, requesterUID string, accept bool) (_ Relationship, err error) {
	defer begin(ctx, "respond_follow_request")(&err)
	if err := s.followRequestsGate(ctx, callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(requesterUID) {
		return Relationship{}, apierr.Validation("requester_user_id", ids.UIDMessage)
	}
	if callerUID == requesterUID {
		return Relationship{}, selfActionErr("requester_user_id")
	}

	now := s.now()
	outcome, err := s.repo.RespondToRequest(ctx, RespondArgs{
		TargetUID: callerUID, RequesterUID: requesterUID, Accept: accept, Now: now,
		RequesterActive: func(ctx context.Context) (bool, error) {
			profiles, err := s.directory.GetProfiles(ctx, []string{requesterUID})
			if err != nil {
				return false, err
			}
			_, ok := profiles[requesterUID] // the Directory drops accounts that are not ACTIVE
			return ok, nil
		},
	})
	if err != nil {
		var lim *LimitReachedError
		if errors.As(err, &lim) {
			logger.SetRequestField(ctx, fieldRespond, string(RespondRequesterCap))
			return Relationship{}, limitReachedErr(lim.Limit)
		}
		return Relationship{}, s.internalErr("respond follow request", err, callerUID, requesterUID)
	}
	logger.SetRequestField(ctx, fieldRespond, string(outcome))
	if outcome != RespondReplay {
		// The requester's graph changed (`requested`, and `following` on an accept): drop this instance's copy.
		s.cache.Invalidate(requesterUID)
	}
	if outcome == RespondAccept {
		s.cache.ForgetEdge(requesterUID, callerUID)
		s.directory.Forget(requesterUID, callerUID) // followingCount and followersCount moved
		s.dropSuggested(requesterUID, callerUID)
		s.events.FollowRequestAccepted(ctx, callerUID, requesterUID, now)
	}

	snap, err := s.Snapshot(ctx, callerUID)
	if err != nil {
		return Relationship{}, s.internalErr("respond follow request", err, callerUID, requesterUID)
	}
	return relationshipFor(snap, requesterUID), nil
}

// PendingFollowRequests implements identity.FollowRequestCounter (ADR-0025 AQ3): the number of requests addressed to uid,
// capped at 1,000. Not flag-gated: GetMe asks only for a protected caller, and identity caches the answer 30 s.
// Firestore: 1 read, 0 writes.
func (s *service) PendingFollowRequests(ctx context.Context, uid string) (int64, error) {
	n, err := s.repo.CountRequests(ctx, uid)
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("graph: pending follow requests: %w", err), uid)
	}
	return n, nil
}

// refuseProtectedList is the ADR-0025 D5 rule for ListFollowers and ListFollowing: the lists of a protected account are
// visible to that account and to the viewers who follow it; anyone else gets FAILED_PRECONDITION PROTECTED_ACCOUNT before
// any page read. It runs on the caller's snapshot already held and asks the protected set only for a viewer who is
// neither the target nor a follower (0 reads: the set is a detached instance cache). The answer comes from the set
// (identity.ProtectedAuthors), never from the profile's isPrivate, and not from FEATURE_PRIVATE_ACCOUNTS: ramping that
// flag down never un-hides a list. A set that cannot be loaded is UNAVAILABLE, never "everyone is public".
func (s *service) refuseProtectedList(ctx context.Context, callerUID, targetUID string, snap Snapshot) error {
	if s.protected == nil || callerUID == targetUID || snap.isFollowing(targetUID) {
		return nil
	}
	set, err := s.protected.Current(ctx)
	if err != nil {
		logger.SetRequestField(ctx, "audience", "set_unavailable")
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
			WithRetryAfter(time.Second).WithCause(fmt.Errorf("graph: protected set: %w", err))
	}
	if set.CanSee(callerUID, targetUID, false) { // the viewer is not a follower here
		return nil
	}
	logger.SetRequestField(ctx, "audience", "protected")
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, "this account is protected")
}
