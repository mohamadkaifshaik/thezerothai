// Package graph will own follows/blocks/mutes (ADR-0003: graph/{uid}, follows/{a}_{b},
// followRequests/{a}_{b}). The full GraphService (follow/unfollow/block/mute, GraphService Connect
// handler) is out of scope for this bootstrap — see CLAUDE.md's module list and the task that asked for
// Phase 0 identity only; "register nothing yet" for graph's Connect server.
//
// identity.CreateProfile's documented budget (ADR-0003, proto comment: "create users, handles, graph";
// reads 2/2, writes 3/3) requires the empty graph/{uid} doc to exist from signup onward, and ADR-0003's
// rule "no module ever builds a document path it does not own" means identity may not write it directly.
// FirestoreRepo.InitGraph is therefore the one seam identity depends on (identity.GraphInitializer)
// until the real GraphService lands; it does nothing else and owns nothing beyond this one Create().
package graph

import (
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const collection = "graph"

// doc is the graph/{uid} shape (ADR-0003). Arrays are exempt from indexing; capped at 5,000/2,000/2,000/500.
type doc struct {
	Following []string  `firestore:"following"`
	Blocked   []string  `firestore:"blocked"`
	Muted     []string  `firestore:"muted"`
	Requested []string  `firestore:"requested"`
	UpdatedAt time.Time `firestore:"updatedAt"`
}

// FirestoreRepo implements identity.GraphInitializer against the shared Firestore client.
type FirestoreRepo struct {
	client *firestore.Client
}

func NewFirestoreRepo(client *firestore.Client) *FirestoreRepo {
	return &FirestoreRepo{client: client}
}

// InitGraph appends a Create() of an empty graph/{uid} doc to b. Idempotent: if the doc already exists
// (e.g. a CreateProfile replay reaching this point, which shouldn't happen since identity short-circuits
// replays before calling this), the Create() fails the whole atomic write, which is the correct
// behavior — an existing graph doc must never be silently reset.
func (r *FirestoreRepo) InitGraph(b store.Batch, uid string, now time.Time) {
	ref := r.client.Collection(collection).Doc(uid)
	b.Create(ref, doc{
		Following: []string{},
		Blocked:   []string{},
		Muted:     []string{},
		Requested: []string{},
		UpdatedAt: now,
	})
}
