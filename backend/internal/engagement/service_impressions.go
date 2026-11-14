// service_impressions.go is RecordImpressions (F1 post views, FEATURE_POST_VIEWS): the client reports the posts it showed,
// the server counts each (viewer, post, IST day) once, never the author's own views, through the impression doc
// (repo_impressions.go) and posts' sharded view counter. The impression docs are the idempotency record (the like rule):
// the idempotency_key is validated but not stored. The answer never depends on what one id was.
package engagement

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line fields of record_impressions: counts only, never an id.
const (
	fieldImpressionsIn      = "impressions_in"
	fieldImpressionsCounted = "impressions_counted"
)

// impressionRetryAfter is the retry_after of a batch that kept losing a hot post's shard race: the client drops it.
const impressionRetryAfter = 5 * time.Second

var _ Impressions = (*Module)(nil)

// RecordImpressions implements Impressions.
func (m *Module) RecordImpressions(ctx context.Context, uid, key string, postIDs []string) error {
	return m.s.recordImpressions(ctx, uid, key, postIDs)
}

// impressionIDs validates the request shape and merges duplicates, keeping the first-seen order.
func impressionIDs(key string, postIDs []string) ([]string, error) {
	if !idempotency.KeyFormatValid(key) {
		return nil, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if len(postIDs) == 0 || len(postIDs) > MaxImpressionsPerCall {
		return nil, apierr.Validation("post_ids", fmt.Sprintf("post_ids must hold 1 to %d post ids", MaxImpressionsPerCall))
	}
	seen := make(map[string]struct{}, len(postIDs))
	out := make([]string, 0, len(postIDs))
	for _, id := range postIDs {
		if !ids.ValidPostID(id) {
			return nil, apierr.Validation("post_ids", "every post id must be a 19-digit post id")
		}
		if _, dup := seen[id]; dup {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out, nil
}

// recordImpressions implements Impressions.RecordImpressions. The flag gate ran in the handler.
func (s *service) recordImpressions(ctx context.Context, uid, key string, postIDs []string) (err error) {
	logger.SetRequestField(ctx, fieldOp, "record_impressions")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	want, err := impressionIDs(key, postIDs)
	if err != nil {
		return err
	}
	logger.SetRequestField(ctx, fieldImpressionsIn, len(want))
	if err := authn.RequireVerifiedEmail(ctx, s.d.AllowAnonymous, "recording views"); err != nil {
		return err
	}
	if s.d.ImpressionRepo == nil {
		return errors.New("engagement: no impression repo configured")
	}
	countable, err := s.countableViews(ctx, uid, want)
	if err != nil {
		return logger.RedactErrPosts(fmt.Errorf("engagement: record impressions: %w", err), want, uid)
	}
	if len(countable) == 0 {
		logger.SetRequestField(ctx, fieldImpressionsCounted, 0)
		return nil
	}
	// The batch runs detached from the caller's cancellation and bounded by txTimeout, like the share batch.
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), txTimeout)
	defer cancel()
	n, err := s.d.ImpressionRepo.RecordImpressions(wctx, uid, countable, s.now())
	if err != nil {
		return s.mapImpressionErr(ctx, uid, countable, err)
	}
	logger.SetRequestField(ctx, fieldImpressionsCounted, n)
	return nil
}

// countableViews resolves ids to the posts a view of them counts for, in one cache-first GetMany (plus one for the
// originals of REPOST ids that were not in it): a REPOST counts its original; missing posts, posts uid may not see by
// the direct-surface rules (hidden, an author who blocks uid, a protected author uid does not follow; for a REPOST both
// the row and the original) and uid's own posts are dropped. The caller's graph snapshot (cached 60 s) is read once, only
// when a post by someone else is left. A protected-set error drops the post (never counts it).
func (s *service) countableViews(ctx context.Context, uid string, want []string) ([]string, error) {
	got, err := s.d.Reader.GetMany(ctx, want)
	if err != nil {
		return nil, err
	}
	var origIDs []string
	for _, id := range want {
		if p, ok := got[id]; ok && p.Kind == posts.KindRepost && p.RepostOfID != "" {
			if _, have := got[p.RepostOfID]; !have {
				origIDs = append(origIDs, p.RepostOfID)
			}
		}
	}
	if len(origIDs) > 0 {
		more, err := s.d.Reader.GetMany(ctx, origIDs)
		if err != nil {
			return nil, err
		}
		for id, p := range more {
			got[id] = p
		}
	}
	checked := s.d.Audience != nil && s.d.Graph != nil
	var snap graph.Snapshot
	snapLoaded := false
	visible := func(p *posts.Post) (bool, error) {
		if checked && !snapLoaded && p.AuthorID != uid {
			if snap, err = s.d.Graph.Snapshot(ctx, uid); err != nil {
				return false, err
			}
			snapLoaded = true
		}
		return s.countsVisible(ctx, uid, snap, checked, p), nil
	}
	out := make([]string, 0, len(want))
	seen := make(map[string]struct{}, len(want))
	for _, id := range want {
		p, ok := got[id]
		if !ok {
			continue
		}
		target := p
		if p.Kind == posts.KindRepost {
			if target, ok = got[p.RepostOfID]; !ok || p.RepostOfID == "" {
				continue
			}
			if v, err := visible(p); err != nil || !v {
				if err != nil {
					return nil, err
				}
				continue
			}
		}
		if target.AuthorID == uid || target.Kind == posts.KindRepost {
			continue
		}
		if _, dup := seen[target.ID]; dup {
			continue
		}
		v, err := visible(target)
		if err != nil {
			return nil, err
		}
		if v {
			seen[target.ID] = struct{}{}
			out = append(out, target.ID)
		}
	}
	return out, nil
}

// mapImpressionErr turns a write error into the wire answer: a caller that left is a client outcome; exhausted shard
// contention or the batch's own timeout is UNAVAILABLE with retry_after (the client drops the batch); anything else is a
// redacted internal error.
func (s *service) mapImpressionErr(ctx context.Context, uid string, postIDs []string, err error) error {
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	case errors.Is(err, store.ErrContended) || store.IsContention(err) || errors.Is(err, context.DeadlineExceeded):
		logger.SetRequestField(ctx, fieldContention, true)
		slog.WarnContext(ctx, "impressions_record_contention", "posts", len(postIDs))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "busy, please retry").WithRetryAfter(impressionRetryAfter)
	}
	return logger.RedactErrPosts(fmt.Errorf("engagement: record impressions: %w", err), postIDs, uid)
}
