package graph

import "errors"

// Sentinel errors returned by repo_firestore.go's transactions, mapped to Connect errors at the service
// boundary (service.go) — the same convention identity/repo_firestore.go uses (ErrNotFound, ErrHandleTaken).
var (
	// ErrNotFoundOrBlocked covers every case that must be byte-identical to "user does not exist"
	// (ADR-0008 D9): the target is missing/not ACTIVE, or the target blocked the caller.
	ErrNotFoundOrBlocked = errors.New("graph: not found or blocked")
	// ErrCallerBlocksTarget: the caller blocks the target (ADR-0008 D9: TARGET_BLOCKED, no auto-unblock).
	ErrCallerBlocksTarget = errors.New("graph: caller blocks target")
	// ErrTargetPrivate: the target's stored isPrivate is true (legacy data only, ADR-0008 D1).
	ErrTargetPrivate = errors.New("graph: target is private")
)

// LimitReachedError names which cap was hit (ADR-0008: following 5,000 / blocked 2,000 / muted 2,000), for
// the FAILED_PRECONDITION + ERROR_REASON_LIMIT_REACHED response's metadata["limit"].
type LimitReachedError struct {
	Limit string
}

func (e *LimitReachedError) Error() string { return "graph: limit reached: " + e.Limit }
