package publicid

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// NegativeCache is a Resolver decorator that remembers, for ttl, that a uid has no public id, so an erased author in a
// frozen snapshot (a post, a quote, a notification actor) is not looked up again on every page that shows it. Only
// that one direction is cached: a found pair is the identity cache's business, and public id -> uid misses already
// have their own short negative cache there.
//
// "No public id" also covers an account that is not minted yet (no backfill and no GetMe since the flag came on): such
// a uid goes out as Tombstone for up to ttl after its id appears. The rollout gate (the backfill reports zero accounts
// without an id before any allowlist) keeps that to erased accounts, which never get an id.
//
// Bounded: at most size entries (least recently used evicted first). Per instance, cold after a start. Safe for
// concurrent use.
type NegativeCache struct {
	inner Resolver
	ttl   time.Duration
	now   func() time.Time
	// none maps uid -> the time its "no public id" entry expires. The LRU itself never expires entries (ttl 0): the
	// expiry is compared against now here, so tests can inject a clock.
	none *cache.LRU[string, time.Time]
}

var _ Resolver = (*NegativeCache)(nil)

// NewNegativeCache wraps inner. now is time.Now in production.
func NewNegativeCache(inner Resolver, size int, ttl time.Duration, now func() time.Time) (*NegativeCache, error) {
	switch {
	case inner == nil:
		return nil, errors.New("publicid: negative cache: nil resolver")
	case size <= 0:
		return nil, errors.New("publicid: negative cache: size must be positive")
	case ttl <= 0:
		return nil, errors.New("publicid: negative cache: ttl must be positive")
	case now == nil:
		return nil, errors.New("publicid: negative cache: nil clock")
	}
	return &NegativeCache{inner: inner, ttl: ttl, now: now, none: cache.New[string, time.Time](size, 0)}, nil
}

// known reports whether uid has a live "no public id" entry, dropping an expired one.
func (c *NegativeCache) known(uid string, now time.Time) bool {
	exp, ok := c.none.Get(uid)
	if !ok {
		return false
	}
	if !now.Before(exp) {
		c.none.Delete(uid)
		return false
	}
	return true
}

// PublicIDsForUIDs asks inner only for the uids not known to have no public id, and remembers every asked uid inner
// did not answer. Nothing is remembered when inner fails. When every uid is known, inner is not called.
func (c *NegativeCache) PublicIDsForUIDs(ctx context.Context, uids []string) (map[string]string, error) {
	now := c.now()
	ask := uids
	for i, uid := range uids {
		if c.known(uid, now) {
			// First hit: copy what came before, then keep filtering.
			ask = append(make([]string, 0, len(uids)-1), uids[:i]...)
			for _, rest := range uids[i+1:] {
				if !c.known(rest, now) {
					ask = append(ask, rest)
				}
			}
			break
		}
	}
	if len(ask) == 0 {
		return map[string]string{}, nil
	}
	got, err := c.inner.PublicIDsForUIDs(ctx, ask)
	if err != nil {
		return nil, err
	}
	exp := now.Add(c.ttl)
	for _, uid := range ask {
		if _, ok := got[uid]; !ok {
			c.none.Set(uid, exp)
		}
	}
	return got, nil
}

// UIDsForPublicIDs is inner's, uncached.
func (c *NegativeCache) UIDsForPublicIDs(ctx context.Context, publicIDs []string) (map[string]string, error) {
	return c.inner.UIDsForPublicIDs(ctx, publicIDs)
}

// Len is the number of entries held, expired ones not yet dropped included.
func (c *NegativeCache) Len() int { return c.none.Len() }
