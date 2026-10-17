package timeline

import (
	"context"
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// removalLag is how far before a since token's issue time the removal log is consulted (ADR-0016 D10). A card can
// reach a client up to CACHE_TTL after a moderator hid its post (the author-recent and post caches), and the log
// cache of the serving instance can lag the log by another CACHE_TTL, so a removal can first become visible to a
// refresh up to 2 x CACHE_TTL after it was written; the margin covers clock skew between instances. The cost of
// being generous is a few ids repeated in a response, which the client ignores.
const removalLag = 2*config.MaxCacheTTL + 15*time.Second

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
