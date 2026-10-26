// lifecycle_bookmarks.go joins bookmarks (ADR-0023 D6, D8) to the account-lifecycle registry: the `bookmarks` Eraser
// step (users/{uid}/bookmarks is a subcollection, which deleting users/{uid} does not remove) and the `bookmarks`
// export section (post id and bookmark time per row, never the post's content). Both are registered whether or not
// FEATURE_BOOKMARKS is on, because documents outlive the flag. The step is appended after `scheduled`: its name is
// persisted in deletionJob.step, so it never joins engagement's checkpoint.
package apiserver

import (
	"context"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// bookmarkSection is the export's `bookmarks` section: the embedded engagement.BookmarkExporter streams one JSON value.
type bookmarkSection struct{ *engagement.BookmarkExporter }

func (bookmarkSection) Name() string { return "bookmarks" }

func (s bookmarkSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.ExportUser(ctx, uid, w)
}

// bookmarkEraserStep is the bookmarks step (step "bookmarks"): BeforeIdentity, after scheduled.
func bookmarkEraserStep(e *engagement.BookmarkEraser) identity.StepEraser {
	return eraserStep[engagement.BookmarkCheckpoint]{name: "bookmarks", purge: e.PurgeUser}
}

// registerBookmarkLifecycle registers the bookmarks step and export section on l. Call it after
// registerScheduledLifecycle (Lifecycle always runs the identity step last).
func registerBookmarkLifecycle(l *identity.Lifecycle, repo *engagement.FirestoreRepo) error {
	err := l.RegisterEraser(identity.BeforeIdentity, bookmarkEraserStep(engagement.NewBookmarkEraser(repo)))
	if err == nil {
		err = l.RegisterExportSection(bookmarkSection{engagement.NewBookmarkExporter(repo)})
	}
	return err
}
