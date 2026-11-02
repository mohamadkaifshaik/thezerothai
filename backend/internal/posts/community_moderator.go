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
// moderation transaction (posts never imports communities).
//
// SetCommunityListing reads the post FRESH inside tx (1 read, never the cache), then:
//   - found=false (and no error) when the post is missing, carries `moderation` (a platform takedown or suspended author: a community hide and
//     restore must never touch it, W5-53 L-2), is a REPOST or a plain post, is a root whose community.id is not cid, or is a reply
//     (kind REPLY) whose conversationCommunityId is not cid (ADR-0031 Amendment 1 D4a, W5-51b); reply reports which of the two it was;
//   - guard (when non-nil) is called with the post's authorId once the post is found and BEFORE any write, whether or not the call would change
//     anything; its error is returned unchanged and nothing is written (F16, W5-53: the communities module passes the author-vs-actor role check,
//     so the decision costs 0 extra reads and posts never learns what a role is). It applies to replies unchanged;
//   - listed=false (hide) of a root: when communityId is present, one field-level Update deletes communityId and sets communityHidden and
//     communityHiddenAt (server time); when it is already absent (hidden), nothing is written and changed is false;
//   - listed=true (restore) of a root: when communityId is absent, one field-level Update sets communityId to the label's id and deletes
//     communityHidden and communityHiddenAt; when it is present, nothing is written and changed is false;
//   - a reply has no communityId: it is "listed" while communityHidden is absent; a hide sets communityHidden and communityHiddenAt, a restore
//     deletes both; the same no-op rules.
//
// posts never imports communities and communities never imports posts (the in-package posts integration tests import communities), so the seam
// uses primitives and *firestore.Transaction only; communities declares the identical interface (communities.PostModerator) and apiserver hands
// posts.NewCommunityModerator to it.
//
// A hide is never a takedown: it does not touch moderation, Hidden() or Visible(), so the post stays on the author's profile and in Home.
// All reads of a transaction must precede its writes, so the caller calls this LAST among its reads. Reads 1, writes 0 or 1. The posts
// instance cache and author-recent cache are not touched: a label already cached on an instance shows until its entry expires (60 s
// staleness bound, CACHE_TTL); the community feed does not depend on it (it drops the post through the community's recentRemovals).
type CommunityModerator interface {
	SetCommunityListing(ctx context.Context, tx *firestore.Transaction, postID, cid string, listed bool, guard func(authorID string) error) (changed, found, reply bool, err error)
	// ListHidden and RestoreHiddenPage are the platform's side (ADR-0031 D14a, W5-52b); see community_hidden.go.
	ListHidden(ctx context.Context, cid, after string, limit int, each HiddenRowFunc) (rows int, last string, err error)
	RestoreHiddenPage(ctx context.Context, tx *firestore.Transaction, cid, after string, limit int, want HiddenRowFunc) (res HiddenPageResult, err error)
}

// listingDoc is the part of a post document the moderator reads.
type listingDoc struct {
	CommunityID             string        `firestore:"communityId"`
	ConversationCommunityID string        `firestore:"conversationCommunityId"`
	AuthorID                string        `firestore:"authorId"`
	Kind                    string        `firestore:"kind"`
	Moderation              string        `firestore:"moderation"`
	CommunityHidden         bool          `firestore:"communityHidden"`
	Community               *communityDoc `firestore:"community"`
}

// firestoreModerator implements CommunityModerator on the process's Firestore client.
type firestoreModerator struct{ client *firestore.Client }

// NewCommunityModerator builds the moderation seam over the one Firestore client.
func NewCommunityModerator(client *firestore.Client) CommunityModerator {
	return &firestoreModerator{client: client}
}

// SetCommunityListing implements CommunityModerator.
func (m *firestoreModerator) SetCommunityListing(ctx context.Context, tx *firestore.Transaction, postID, cid string, listed bool, guard func(authorID string) error) (changed, found, reply bool, err error) {
	if m == nil || m.client == nil {
		return false, false, false, errors.New("posts: moderator has no firestore client")
	}
	ref := m.client.Collection(postsCollection).Doc(postID)
	snap, err := tx.Get(ref)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return false, false, false, nil
		}
		return false, false, false, fmt.Errorf("posts: get post for listing: %w", err)
	}
	var d listingDoc
	if err := snap.DataTo(&d); err != nil {
		return false, false, false, fmt.Errorf("posts: decode post for listing: %w", err)
	}
	// ADR-0031 Amendment 1 D4a: a reply qualifies through the conversation's community, a root POST or QUOTE through its label.
	reply = d.Kind == string(KindReply)
	switch {
	case reply && d.ConversationCommunityID != cid:
		return false, false, false, nil
	case !reply && (d.Kind == string(KindRepost) || d.Community == nil || d.Community.ID != cid):
		return false, false, false, nil
	}
	if d.Moderation != "" {
		return false, false, false, nil
	}
	if guard != nil {
		if err := guard(d.AuthorID); err != nil {
			return false, true, reply, err
		}
	}
	isListed := d.CommunityID != ""
	if reply {
		isListed = !d.CommunityHidden
	}
	if isListed == listed {
		return false, true, reply, nil
	}
	if err := tx.Update(ref, listingUpdates(reply, listed, cid)); err != nil {
		return false, true, reply, fmt.Errorf("posts: set community listing: %w", err)
	}
	budget.FromContext(ctx).AddWrites(1)
	return true, true, reply, nil
}

// listingUpdates are the field-level updates of one hide (listed=false) or restore (listed=true), shared by SetCommunityListing and the
// platform's RestoreHiddenPage so the two writers of communityHidden and communityHiddenAt can never drift apart.
func listingUpdates(reply, listed bool, cid string) []firestore.Update {
	switch {
	case reply && listed:
		return []firestore.Update{{Path: "communityHidden", Value: firestore.Delete}, {Path: "communityHiddenAt", Value: firestore.Delete}}
	case reply:
		return []firestore.Update{{Path: "communityHidden", Value: true}, {Path: "communityHiddenAt", Value: firestore.ServerTimestamp}}
	case listed:
		return []firestore.Update{{Path: "communityId", Value: cid}, {Path: "communityHidden", Value: firestore.Delete}, {Path: "communityHiddenAt", Value: firestore.Delete}}
	default:
		return []firestore.Update{{Path: "communityId", Value: firestore.Delete}, {Path: "communityHidden", Value: true}, {Path: "communityHiddenAt", Value: firestore.ServerTimestamp}}
	}
}
