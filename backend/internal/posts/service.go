package posts

import (
	"context"
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FlagName is the wire name PostService and TimelineService RPCs check (ADR-0010 D1: FEATURE_POSTS <-> "posts").
const FlagName = "posts"

// Request-log fields (ADR-0010 D20). They ride on the mw.Logging line through logger.RequestInfo; values are
// booleans, counts and enums only, never ids, handles or text. fs_reads/fs_writes/fs_deletes are already
// emitted by mw.Logging. posts_op and outcome are set by the RPCs (T8/T9); the Reader sets only the cache field.
const fieldCacheHit = "posts_cache_hit"

// Deps is everything New needs.
type Deps struct {
	Repo   Repo
	Cache  *Cache
	Events PostEvents
	// Now is overridable for tests; nil means time.Now.
	Now func() time.Time
}

type service struct {
	repo   Repo
	cache  *Cache
	events PostEvents
	now    func() time.Time
}

// New builds the posts service. A nil Events defaults to the no-op hook.
func New(d Deps) Service {
	s := &service{repo: d.Repo, cache: d.Cache, events: d.Events, now: d.Now}
	if s.events == nil {
		s.events = NopEvents{}
	}
	if s.now == nil {
		s.now = time.Now
	}
	return s
}

var _ Service = (*service)(nil)

// clampLimit maps a requested query Limit onto 1..MaxLimit (0 or negative means the default page size).
func clampLimit(n int) int {
	switch {
	case n <= 0:
		return limits.DefaultPageSize
	case n > limits.MaxPageSize:
		return limits.MaxPageSize
	default:
		return n
	}
}

// Get implements Reader.
func (s *service) Get(ctx context.Context, id string) (*Post, error) {
	m, err := s.GetMany(ctx, []string{id})
	if err != nil {
		return nil, err
	}
	p, ok := m[id]
	if !ok {
		return nil, ErrNotFound
	}
	return p, nil
}

// GetMany implements Reader: cache-first, then one GetAll for the misses (rule 6: no reads in a loop). Absence
// is never cached, so a deleted post is NOT_FOUND as soon as its own cache entry expires (<= CACHE_TTL).
func (s *service) GetMany(ctx context.Context, ids []string) (map[string]*Post, error) {
	out := make(map[string]*Post, len(ids))
	var missing []string
	seen := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		if _, dup := seen[id]; dup {
			continue
		}
		seen[id] = struct{}{}
		if p, ok := s.cache.GetPost(id); ok {
			out[id] = p
			continue
		}
		missing = append(missing, id)
	}
	if len(seen) > MaxGetMany {
		return nil, fmt.Errorf("posts: GetMany of %d ids exceeds the limit of %d", len(seen), MaxGetMany)
	}
	logger.SetRequestField(ctx, fieldCacheHit, len(missing) == 0)
	if len(missing) == 0 {
		return out, nil
	}
	found, err := s.repo.GetAll(ctx, missing)
	if err != nil {
		return nil, err
	}
	for id, p := range found {
		s.cache.SetPost(p)
		out[id] = p
	}
	return out, nil
}

// ByAuthors implements Reader. No authors means no query (0 reads).
func (s *service) ByAuthors(ctx context.Context, authorIDs []string, w Window, limit int) ([]*Post, error) {
	if len(authorIDs) == 0 {
		return nil, nil
	}
	if len(authorIDs) > MaxByAuthors {
		return nil, fmt.Errorf("posts: ByAuthors of %d authors exceeds the limit of %d", len(authorIDs), MaxByAuthors)
	}
	if err := w.validate(); err != nil {
		return nil, err
	}
	out, err := s.repo.ByAuthors(ctx, authorIDs, w, clampLimit(limit))
	if err != nil {
		return nil, err
	}
	s.fill(out)
	return out, nil
}

// ByAuthor implements Reader.
func (s *service) ByAuthor(ctx context.Context, authorID string, includeReplies bool, w Window, limit int) ([]*Post, error) {
	if authorID == "" {
		return nil, fmt.Errorf("posts: ByAuthor needs an author id")
	}
	if err := w.validate(); err != nil {
		return nil, err
	}
	out, err := s.repo.ByAuthor(ctx, authorID, includeReplies, w, clampLimit(limit))
	if err != nil {
		return nil, err
	}
	s.fill(out)
	return out, nil
}

// fill puts query results in the posts cache (every read path fills it, ADR-0010 D15).
func (s *service) fill(ps []*Post) {
	for _, p := range ps {
		s.cache.SetPost(p)
	}
}

func (w Window) validate() error {
	if w.Before != nil && w.Before.ID == "" {
		return fmt.Errorf("posts: window Before needs a post id")
	}
	if w.After != nil && w.After.ID == "" {
		return fmt.Errorf("posts: window After needs a post id")
	}
	return nil
}

// AuthorRecent implements Reader.
func (s *service) AuthorRecent(authorID string) (Recent, bool) {
	return s.cache.AuthorRecent(authorID)
}

// StoreAuthorRecent implements Reader.
func (s *service) StoreAuthorRecent(authorID string, newest []*Post, truncated bool, loadedAt time.Time) {
	s.cache.StoreAuthorRecent(authorID, newest, truncated, loadedAt)
	s.fill(newest)
}
