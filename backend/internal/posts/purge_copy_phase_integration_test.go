//go:build integration

package posts

import (
	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// releaseStub stands in for engagement's RepostLinks where a test only needs the purge copy phase to be wired.
type releaseStub struct{}

func (releaseStub) StageRelease(store.Batch, string, string) {}

// withCopyPhase wires the collaborators PurgeUser's copy phase needs.
func withCopyPhase(repo *FirestoreRepo, client *firestore.Client) {
	repo.SetWriters(WriteDeps{Counters: countersStub{client}})
	repo.SetRepostLinks(releaseStub{})
}
