package search

import (
	"context"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/sync/singleflight"
	"golang.org/x/text/unicode/norm"
	"google.golang.org/protobuf/types/known/timestamppb"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	// trendsCacheTTL is the staleness bound of the per-instance copy of trends/current (ADR-0028 D4): 10 minutes after a
	// refresh, so a tag is up to one sweep interval + 10 min old. At most one document read per instance per TTL.
	trendsCacheTTL = 10 * time.Minute
	// Limits of GetTrends (proto: 0 => 10, max 30, clamped) and of the prefix (ADR-0028 D1 step 7).
	defaultTrendsLimit = 10
	maxTrendsLimit     = 30
	maxPrefixPoints    = 50
)

// trendsCache is the instance copy of trends/current: one entry (a missing document is cached too, as an empty list), a
// TTL measured by an injectable clock, and singleflight so concurrent cold callers cost one read. Staleness: the TTL
// above. It sits behind this small type so Memorystore can replace it by ADR at Stage 2 with no caller change.
type trendsCache struct {
	store TrendsStore
	ttl   time.Duration
	now   func() time.Time

	mu       sync.Mutex
	doc      *TrendsDoc // nil = no list yet
	loadedAt time.Time
	loaded   bool
	sf       singleflight.Group
}

func newTrendsCache(store TrendsStore, ttl time.Duration, now func() time.Time) *trendsCache {
	if now == nil {
		now = time.Now
	}
	return &trendsCache{store: store, ttl: ttl, now: now}
}

// get returns the list and whether it came from the instance copy (no Firestore read). A failed load returns the error
// and caches nothing, so the next caller retries.
func (c *trendsCache) get(ctx context.Context) (doc *TrendsDoc, hit bool, err error) {
	if d, ok := c.fresh(); ok {
		return d, true, nil
	}
	// The shared load runs on the first caller's context (and its budget counter): the others wait for it and are not
	// charged, which matches "one read per instance per TTL". The copy is checked again inside the load: a caller that
	// saw it stale just before another load finished would otherwise start a second read (W4-20 D-1).
	v, err, _ := c.sf.Do("current", func() (any, error) {
		if d, ok := c.fresh(); ok {
			return trendsLoad{doc: d, hit: true}, nil
		}
		d, err := c.store.Get(ctx)
		if err != nil {
			return nil, err
		}
		c.mu.Lock()
		c.doc, c.loadedAt, c.loaded = d, c.now(), true
		c.mu.Unlock()
		return trendsLoad{doc: d}, nil
	})
	if err != nil {
		return nil, false, err
	}
	l, _ := v.(trendsLoad)
	return l.doc, l.hit, nil
}

// trendsLoad is one singleflight result: the list and whether it came from the instance copy.
type trendsLoad struct {
	doc *TrendsDoc
	hit bool
}

// fresh returns the instance copy when it is within the TTL.
func (c *trendsCache) fresh() (*TrendsDoc, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.loaded && c.now().Sub(c.loadedAt) < c.ttl {
		return c.doc, true
	}
	return nil, false
}

// Trends is GetTrends. Flag: trends.
//
// Firestore, worst case: 2 reads cold (the interceptor's profile read, then trends/current), 1 warm (the interceptor
// alone; the instance copy serves the list with 0 reads) and 0 writes. A flag refusal and a validation error read nothing
// beyond the interceptor. At most one document read per instance per 10 minutes, so <= 432 a day at 3 instances whatever
// the number of callers (ADR-0028 D4, D6).
func (s *service) Trends(ctx context.Context, uid string, limit int32, prefix string) (*searchv1.GetTrendsResponse, error) {
	if err := s.guard(ctx, uid, FlagTrends); err != nil {
		return nil, err
	}
	if s.trends == nil {
		return nil, errNotImplemented()
	}
	n, err := trendsLimit(limit)
	if err != nil {
		return nil, err
	}
	pfx, err := normalisePrefix(prefix)
	if err != nil {
		return nil, err
	}
	doc, hit, err := s.trends.get(ctx)
	if err != nil {
		return nil, err
	}
	out := &searchv1.GetTrendsResponse{}
	if doc == nil {
		s.logTrends(ctx, 0, hit, -1)
		return out, nil
	}
	out.ComputedAt = timestamppb.New(doc.ComputedAt)
	// Ranks are positions in the whole list, so a prefix keeps its gaps (proto Trend.rank).
	for i, it := range doc.Items {
		if len(out.Trends) >= n {
			break
		}
		if pfx != "" && !strings.HasPrefix(it.Tag, pfx) {
			continue
		}
		out.Trends = append(out.Trends, &searchv1.Trend{Tag: it.Tag, PostCount: it.Posts, Rank: int32(i + 1)})
	}
	s.logTrends(ctx, len(out.Trends), hit, int64(s.now().Sub(doc.ComputedAt).Seconds()))
	return out, nil
}

// logTrends adds the GetTrends fields to the request line (ADR-0028 D10): results, cache_hit and computed_age_s (-1 when
// there is no list). fs_reads comes from the request counter. No uid, no prefix text.
func (s *service) logTrends(ctx context.Context, results int, hit bool, ageSeconds int64) {
	logger.SetRequestField(ctx, "results", results)
	logger.SetRequestField(ctx, "cache_hit", hit)
	logger.SetRequestField(ctx, "computed_age_s", ageSeconds)
}

// trendsLimit: negative is VALIDATION "limit", 0 the default, above the maximum clamped.
func trendsLimit(limit int32) (int, error) {
	switch {
	case limit < 0:
		return 0, apierr.Validation("limit", "limit must not be negative")
	case limit == 0:
		return defaultTrendsLimit, nil
	case limit > maxTrendsLimit:
		return maxTrendsLimit, nil
	}
	return int(limit), nil
}

// normalisePrefix applies ADR-0028 D1 step 7: NFC and lower-case, one leading '#' removed, at most 50 code points after
// it, a control (\p{Cc}) or bidi formatting character => VALIDATION "prefix". Characters outside the hashtag body class
// are not rejected: they match no tag.
func normalisePrefix(raw string) (string, error) {
	p := strings.ToLower(norm.NFC.String(strings.TrimSpace(raw)))
	p = strings.TrimPrefix(p, "#")
	if utf8.RuneCountInString(p) > maxPrefixPoints {
		return "", apierr.Validation("prefix", "prefix is too long")
	}
	for _, r := range p {
		if unicode.Is(unicode.Cc, r) || (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069) {
			return "", apierr.Validation("prefix", "prefix contains a control character")
		}
	}
	return p, nil
}
