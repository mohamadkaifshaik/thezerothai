package posts

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// CommunityModerator is the moderation seam of ADR-0031 D5 / A12, declared here and called by the communities module inside its own
// moderation transaction (communities imports posts for this one interface; posts never imports communities).
//
// SetCommunityListing reads the post FRESH inside tx (1 read, never the cache), then:
//   - ErrNotFound when the post is missing or does not carry community.id == cid (a reply, a REPOST and a plain post never do);
//   - listed=false (hide): when communityId is present, one field-level Update deletes communityId and sets communityHidden; when it is
//     already absent (hidden), nothing is written and changed is false;
//   - listed=true (restore): when communityId is absent, one field-level Update sets communityId to the label's id and deletes
//     communityHidden; when it is present, nothing is written and changed is false.
//
// A hide is never a takedown: it does not touch moderation, Hidden() or Visible(), so the post stays on the author's profile and in Home.
// All reads of a transaction must precede its writes, so the caller calls this LAST among its reads. Reads 1, writes 0 or 1. The posts
// instance cache and author-recent cache are not touched: a label already cached on an instance shows until its entry expires (60 s
// staleness bound, CACHE_TTL); the community feed does not depend on it (it drops the post through the community's recentRemovals).
type CommunityModerator interface {
	SetCommunityListing(ctx context.Context, tx *firestore.Transaction, postID, cid string, listed bool) (changed bool, err error)
}

// listingDoc is the part of a post document the moderator reads.
type listingDoc struct {
	CommunityID string        `firestore:"communityId"`
	Community   *communityDoc `firestore:"community"`
}

// firestoreModerator implements CommunityModerator on the process's Firestore client.
type firestoreModerator struct{ client *firestore.Client }

// NewCommunityModerator builds the moderation seam over the one Firestore client.
func NewCommunityModerator(client *firestore.Client) CommunityModerator {
	return &firestoreModerator{client: client}
}

// SetCommunityListing implements CommunityModerator.
func (m *firestoreModerator) SetCommunityListing(ctx context.Context, tx *firestore.Transaction, postID, cid string, listed bool) (bool, error) {
	if m == nil || m.client == nil {
		return false, errors.New("posts: moderator has no firestore client")
	}
	ref := m.client.Collection(postsCollection).Doc(postID)
	snap, err := tx.Get(ref)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return false, ErrNotFound
		}
		return false, fmt.Errorf("posts: get post for listing: %w", err)
	}
	var d listingDoc
	if err := snap.DataTo(&d); err != nil {
		return false, fmt.Errorf("posts: decode post for listing: %w", err)
	}
	if d.Community == nil || d.Community.ID != cid {
		return false, ErrNotFound
	}
	isListed := d.CommunityID != ""
	if isListed == listed {
		return false, nil
	}
	updates := []firestore.Update{{Path: "communityId", Value: firestore.Delete}, {Path: "communityHidden", Value: true}}
	if listed {
		updates = []firestore.Update{{Path: "communityId", Value: cid}, {Path: "communityHidden", Value: firestore.Delete}}
	}
	if err := tx.Update(ref, updates); err != nil {
		return false, fmt.Errorf("posts: set community listing: %w", err)
	}
	budget.FromContext(ctx).AddWrites(1)
	return true, nil
}
