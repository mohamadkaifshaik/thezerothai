package posts

import (
	"context"
	"errors"
	"fmt"
)

// PinChecker validates UpdateProfile.pinned_post_id (ADR-0024 D3). identity consumes it through its own consumer-side
// PinChecker interface (the BlockChecker pattern, so identity never imports posts); the method below has exactly that
// interface's shape, so apiserver passes *PinChecker to identity.WithPinChecker without an adapter.
type PinChecker struct {
	reader Reader
}

// NewPinChecker builds the checker on the posts Reader (the concrete service returned by New satisfies it).
func NewPinChecker(r Reader) *PinChecker { return &PinChecker{reader: r} }

// CanPin reports whether postID is uid's own, still visible POST, QUOTE or REPLY. Every "no" is (false, nil) and
// carries no cause, so the caller can give one answer for all of them and stay no existence oracle: a missing or
// malformed id, a deleted post, one a moderator hid (taken down or author suspended), another user's post, a REPOST
// (ADR-0024 D3), or an empty uid. A non-nil error is an infrastructure failure and is never collapsed into false.
//
// Reads: 1 cold, 0 warm (Reader.Get is cache-first); writes 0. Staleness bound: the posts instance cache TTL
// (CACHE_TTL, 60 s): a post deleted or taken down on another instance can still pass for up to that long; the D3
// client backstop (GetPost answers NOT_FOUND for a hidden pin) and the post_delete job's Pins.ClearIfPinned cover it.
func (c *PinChecker) CanPin(ctx context.Context, uid, postID string) (bool, error) {
	p, err := c.reader.Get(ctx, postID)
	if err != nil {
		if errors.Is(err, ErrNotFound) || errors.Is(err, ErrInvalidID) {
			return false, nil
		}
		return false, fmt.Errorf("posts: pin check: %w", err)
	}
	if uid == "" || p.AuthorID != uid || !p.Visible() {
		return false, nil
	}
	switch p.Kind { // an allowlist: a kind added later is not pinnable until decided
	case KindPost, KindQuote, KindReply:
		return true, nil
	default:
		return false, nil
	}
}
