// profile_snapshot_wiring.go adapts posts to identity's consumer-side SnapshotWriter (P2, ADR-0003 "Author
// snapshot refresh"): identity cannot import posts, so the field mapping lives here (the lifecycle_wiring.go
// pattern).
package apiserver

import (
	"context"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// authorRefresher is the one method of posts' repo the profile-snapshot-refresh job needs.
type authorRefresher interface {
	RefreshAuthor(ctx context.Context, uid string, author posts.AuthorSnapshot, version int64) (int, error)
}

// profileSnapshotWriter implements identity.SnapshotWriter over posts.
type profileSnapshotWriter struct{ p authorRefresher }

func (w profileSnapshotWriter) RefreshAuthor(ctx context.Context, uid string, f identity.SnapshotFields, version int64) (int, error) {
	return w.p.RefreshAuthor(ctx, uid, posts.AuthorSnapshot{
		UserID: uid, Handle: f.Handle, DisplayName: f.DisplayName, AvatarURL: f.AvatarURL, Verified: f.Verified,
	}, version)
}
