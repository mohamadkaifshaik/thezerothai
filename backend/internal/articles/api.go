package articles

import "context"

// PostGone reports, from a fresh read that bypasses every cache, whether the post no longer exists. It is the same
// shape as media.PostGone and identity.PostGone; apiserver's postGone adapter over the posts repo implements all of
// them, so the post_delete step never acts on a message's word alone.
type PostGone interface {
	PostGone(ctx context.Context, postID string) (bool, error)
}
