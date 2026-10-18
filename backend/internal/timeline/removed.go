package timeline

import (
	"context"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FlagRemovedIDs is the wire name of the FEATURE_REMOVED_IDS server flag (ADR-0016 D10). Off for the caller: the
// refresh answers without removed_ids, reads nothing from the log and never rejects a since_token for the log.
const FlagRemovedIDs = "removed_ids"

// removalLag is posts.RemovalLag (ADR-0016 D10): how far before a since token's issue time the removal log is consulted.
const removalLag = posts.RemovalLag

// Request-log fields: how many ids a refresh returned, and whether it was rejected because the log could not answer
// completely (counts and a boolean, never ids).
const (
	fieldRemoved      = "removed_ids"
	fieldRemovedReset = "removed_reset"
)

// removedIDs returns the removal ids for a refresh (ADR-0016 D10) and nil for every other mode or when no log is
// wired. A log that cannot answer completely (token older than its coverage, or more than 50 matches) rejects the
// refresh exactly like an expired since_token, before any post is read: the client then cold-opens and replaces
// its cache. Reads: see posts.Removals.RemovedSince.
func (s *Server) removedIDs(ctx context.Context, tok request) ([]string, error) {
	if tok.Since == nil || s.deps.Removals == nil {
		return nil, nil
	}
	// FEATURE_REMOVED_IDS per caller (allowlist/percent rollout); 0 reads, checked before the log is touched.
	if uid, ok := authn.UIDFromContext(ctx); !ok || s.deps.Flags == nil || !s.deps.Flags.Enabled(uid, FlagRemovedIDs) {
		return nil, nil
	}
	ids, truncated, err := s.deps.Removals.RemovedSince(ctx, tok.SinceIssued.Add(-removalLag))
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("timeline: removal log: %w", err))
	}
	if truncated {
		logger.SetRequestField(ctx, fieldRemovedReset, true)
		return nil, apierr.Validation(fieldSince, "since_token is invalid or expired")
	}
	logger.SetRequestField(ctx, fieldRemoved, len(ids))
	return ids, nil
}
