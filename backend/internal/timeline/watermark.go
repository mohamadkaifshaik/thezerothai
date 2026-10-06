package timeline

import (
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// zeroID sorts before every real post id at the same instant (ids are 19-digit zero-padded decimals), so a
// watermark token (W, zeroID) never hides a post created at W.
const zeroID = "0000000000000000000"

// Watermark is W of ADR-0010 D13: min(request start, loadedAt of every author-recent entry used) minus the settle
// window, as a position (floored to the millisecond, the resolution of createdAt).
func Watermark(start time.Time, loadedAt []time.Time, settle time.Duration) posts.Position {
	m := start
	for _, t := range loadedAt {
		if t.Before(m) {
			m = t
		}
	}
	return posts.Position{CreatedAt: m.Add(-settle).UTC().Truncate(time.Millisecond), ID: zeroID}
}

// NextSince computes the new since_token position (ADR-0010 D13): max(old, min(newest, w)) as (createdAt,
// postId) tuples. old and newest may be nil (a cold open has no old since; an empty result has no newest, and
// then the token advances to max(old, w)). clamped is true when w was the smaller of newest and w, that is when
// returned items newer than w will come back on the next refresh (the client dedupes by post_id).
func NextSince(old, newest *posts.Position, w posts.Position) (next posts.Position, clamped bool) {
	next = w
	if newest != nil {
		if Compare(*newest, w) < 0 { // newest is newer than w
			clamped = true
		} else {
			next = *newest
		}
	}
	if old != nil && Compare(*old, next) < 0 { // old is newer than next
		next = *old
	}
	return next, clamped
}
