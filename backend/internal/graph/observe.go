package graph

import (
	"context"
	"errors"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-log fields ADR-0008 "Required log fields" asks of every graph RPC. They ride on the mw.Logging
// line through logger.RequestInfo (the same mechanism as uid_hash/limit_name), so there is no extra log line
// and no new middleware. fs_reads/fs_writes/fs_deletes/limit_name are already emitted by mw.Logging.
// Values are enums, counts and bools only - never uids or graph array contents (security review L4).
const (
	fieldOp        = "graph_op"
	fieldOutcome   = "outcome"
	fieldCacheHit  = "graph_cache_hit"
	fieldEdgesGone = "edges_removed"
	fieldFlagOff   = "feature_disabled"
	// confirmed_missing counts only uids whose users/{uid} doc a fresh read confirmed absent on this page;
	// SUSPENDED/DELETING users and negatively-cached uids are not counted (see identity.Directory).
	fieldConfirmedMissing = "confirmed_missing"
	fieldLazyGone         = "lazy_removed"
	fieldTxnAttempt       = "txn_attempts"
)

// begin records graph_op and returns the finisher to defer as `defer begin(ctx, "follow")(&err)` on a
// function with a named error result: a returned error becomes outcome=rejected:<reason>. Success paths set
// outcome themselves (setOutcome) where the code distinguishes created/replay/noop; reads leave it absent.
func begin(ctx context.Context, op string) func(errp *error) {
	logger.SetRequestField(ctx, fieldOp, op)
	return func(errp *error) {
		if *errp != nil {
			noteRejected(ctx, *errp)
		}
	}
}

func setOutcome(ctx context.Context, o MutationOutcome) {
	logger.SetRequestField(ctx, fieldOutcome, string(o))
}

// setChanged maps the boolean state-change answer of Unfollow/Unblock/Unmute onto the ADR enum.
func setChanged(ctx context.Context, changed bool) {
	if changed {
		setOutcome(ctx, OutcomeCreated)
		return
	}
	setOutcome(ctx, OutcomeNoop)
}

// noteRejected classifies err into the ADR's rejected:<reason> vocabulary.
func noteRejected(ctx context.Context, err error) {
	reason := rejectReason(err)
	logger.SetRequestField(ctx, fieldOutcome, "rejected:"+reason)
	if reason == "feature_disabled" {
		logger.SetRequestField(ctx, fieldFlagOff, true)
	}
}

func rejectReason(err error) string {
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		return "error"
	}
	switch {
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED:
		return "feature_disabled"
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED:
		return "target_blocked"
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED:
		return "limit_reached"
	case ae.Code == connect.CodeInvalidArgument:
		return "invalid"
	case ae.Code == connect.CodeNotFound:
		return "not_found"
	case ae.Code == connect.CodeUnavailable:
		return "contention"
	}
	return "error"
}

// noteTxnAttempts records txn_attempts on the request line and WARNs above store.TxnWarnAttempts (plan T7);
// the WARN fires only under real contention and carries no uids.
func noteTxnAttempts(ctx context.Context, attempts int) {
	store.NoteTxnAttempts(ctx, "graph_txn_contention", attempts)
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// noteCacheHit records graph_cache_hit for RPCs served from the 60 s Snapshot cache. A request that reads
// the snapshot more than once reports true only if every read was a hit, so false always means "cost a
// Firestore read".
func noteCacheHit(ctx context.Context, hit bool) {
	if prev, ok := logger.RequestField(ctx, fieldCacheHit); ok {
		if p, _ := prev.(bool); !p {
			hit = false
		}
	}
	logger.SetRequestField(ctx, fieldCacheHit, hit)
}
