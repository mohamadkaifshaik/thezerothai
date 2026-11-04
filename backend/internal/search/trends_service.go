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
	// trendsCacheTTL is the staleness bound of the per-instance copy of the served list, loaded from trends/current and
	// trends/hidden: 10 minutes after a refresh or a hide, so a tag is up to one sweep interval + 10 min old.
	// At most one load (2 document reads) per instance per TTL.
	trendsCacheTTL = 10 * time.Minute
	// Limits of GetTrends (proto: 0 => 10, max 30, clamped) and of the prefix.
	defaultTrendsLimit = 10
	maxTrendsLimit     = 30
	maxPrefixPoints    = 50
)

// trendsServed is the list GetTrends serves: trends/current with the denylisted and hidden keys already dropped, in rank
// order. Its position + 1 is the rank, so a hidden tag leaves no gap (part 1).
type trendsServed struct {
	ComputedAt time.Time
	Items      []TrendItem
}

// serve drops every item whose TrendKey is denied (TRENDS_DENYLIST) or hidden (trends/hidden). The hide list is folded
// again here, so a key written by an older fold still matches. A nil doc is no list.
func serve(doc *TrendsDoc, hidden []string, deny map[string]struct{}) *trendsServed {
	if doc == nil {
		return nil
	}
	hide := trendKeySet(hidden)
	out := &trendsServed{ComputedAt: doc.ComputedAt, Items: make([]TrendItem, 0, len(doc.Items))}
	for _, it := range doc.Items {
		k := TrendKey(it.Tag)
		if k == "" {
			continue
		}
		if _, ok := deny[k]; ok {
			continue
		}
		if _, ok := hide[k]; ok {
			continue
		}
		out.Items = append(out.Items, it)
	}
	return out
}

// trendsCache is the instance copy of the served list: one entry (a missing document is cached too, as no list), a TTL
// measured by an injectable clock, and singleflight so concurrent cold callers cost one load. It loads trends/current
// and trends/hidden together and caches the list after the filter. Staleness: the TTL above, for the list and
// for a hide alike (a hide reaches every server within 10 min and every screen within 15 min). It sits behind this small
// type so Memorystore can replace it at Stage 2 with no caller change.
type trendsCache struct {
	store TrendsStore
	ttl   time.Duration
	now   func() time.Time
	// deny is the folded TRENDS_DENYLIST (set once by New, before the first request).
	deny map[string]struct{}

	mu       sync.Mutex
	list     *trendsServed // nil = no list yet
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

// get returns the served list and whether it came from the instance copy (no Firestore read). A failed load, of either
// document, returns the error and caches nothing, so the next caller retries: an unknown hide list is never served as
// empty.
func (c *trendsCache) get(ctx context.Context) (list *trendsServed, hit bool, err error) {
	if l, ok := c.fresh(); ok {
		return l, true, nil
	}
	// The shared load runs on the first caller's context: the others wait for it, which
	// matches "one load per instance per TTL". The copy is checked again inside the load: a caller that
	// saw it stale just before another load finished would otherwise start a second read (D-1).
	v, err, _ := c.sf.Do("current", func() (any, error) {
		if l, ok := c.fresh(); ok {
			return trendsLoad{list: l, hit: true}, nil
		}
		d, hidden, err := c.store.Load(ctx)
		if err != nil {
			return nil, err
		}
		l := serve(d, hidden, c.deny)
		c.mu.Lock()
		c.list, c.loadedAt, c.loaded = l, c.now(), true
		c.mu.Unlock()
		return trendsLoad{list: l}, nil
	})
	if err != nil {
		return nil, false, err
	}
	l, _ := v.(trendsLoad)
	return l.list, l.hit, nil
}

// trendsLoad is one singleflight result: the list and whether it came from the instance copy.
type trendsLoad struct {
	list *trendsServed
	hit  bool
}

// fresh returns the instance copy when it is within the TTL.
func (c *trendsCache) fresh() (*trendsServed, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.loaded && c.now().Sub(c.loadedAt) < c.ttl {
		return c.list, true
	}
	return nil, false
}

// Trends is GetTrends. Flag: trends.
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
	list, hit, err := s.trends.get(ctx)
	if err != nil {
		return nil, err
	}
	out := &searchv1.GetTrendsResponse{}
	if list == nil {
		s.logTrends(ctx, 0, hit, -1)
		return out, nil
	}
	out.ComputedAt = timestamppb.New(list.ComputedAt)
	// Ranks are positions in the whole served list (hidden tags are already gone, so none leaves a gap), so a prefix keeps
	// its gaps (proto Trend.rank).
	for i, it := range list.Items {
		if len(out.Trends) >= n {
			break
		}
		if pfx != "" && !strings.HasPrefix(it.Tag, pfx) {
			continue
		}
		out.Trends = append(out.Trends, &searchv1.Trend{Tag: it.Tag, PostCount: it.Posts, Rank: int32(i + 1)})
	}
	s.logTrends(ctx, len(out.Trends), hit, int64(s.now().Sub(list.ComputedAt).Seconds()))
	return out, nil
}

// logTrends adds the GetTrends fields to the request line: results, cache_hit and computed_age_s (-1 when
// there is no list). No uid, no prefix text.
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

// normalisePrefix applies the prefix rules: NFC and lower-case, one leading '#' removed, at most 50 code points after
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
