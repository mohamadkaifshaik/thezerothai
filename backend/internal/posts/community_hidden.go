package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// hiddenPageMax is the most rows one page of the platform's hidden-post listing reads (Limit <= 50, ADR-0031 D14a).
const hiddenPageMax = 50

// HiddenRowFunc sees one hidden post or reply of a community: its id, whether it is a reply (a root otherwise), the server time of the
// hide (the zero time when the post was hidden before W5-51b wrote communityHiddenAt: "unknown", no backfill), and whether `moderation` is
// set (a platform takedown or suspended author, ADR-0031 D5a), and whether the row is `other` (a REPOST or a root labelled with another community: never restored). It never receives text or a uid. For RestoreHiddenPage the answer says
// whether to restore the row (a moderated or other row is never restored, whatever the answer); ListHidden ignores it.
type HiddenRowFunc = func(id string, reply bool, hiddenAt time.Time, moderated, other bool) bool

// HiddenPageResult is what RestoreHiddenPage read and did (an alias of an unnamed struct, identical to communities.HiddenPage, so the two seams match structurally).
type HiddenPageResult = struct {
	// Rows is the number of hidden posts the page read, Last the id of the last one (the next page's `after`).
	Rows int
	Last string
	// Restored is the number of posts whose restore was staged; RestoredRoots are the ids among them that are roots (the caller drops
	// their recentRemovals entries; a reply has none, R1).
	Restored      int
	RestoredRoots []string
}

// hiddenDoc is the part of a post document the platform listing reads.
type hiddenDoc struct {
	Kind              string        `firestore:"kind"`
	Moderation        string        `firestore:"moderation"`
	CommunityHiddenAt time.Time     `firestore:"communityHiddenAt"`
	Community         *communityDoc `firestore:"community"`
}

// hiddenQuery is `posts where conversationCommunityId == cid AND communityHidden == true ORDER BY __name__ LIMIT n`, after the post `after`
// (ADR-0031 D14a). A hidden root keeps conversationCommunityId and every reply carries it, so one query covers both. Two equalities and the
// document id order is served by merging the automatic single-field indexes; the dev proof of this shape is recorded in the W5-52b ticket.
func (m *firestoreModerator) hiddenQuery(cid, after string, limit int) firestore.Query {
	if limit <= 0 || limit > hiddenPageMax {
		limit = hiddenPageMax
	}
	q := m.client.Collection(postsCollection).
		Where("conversationCommunityId", "==", cid).
		Where("communityHidden", "==", true).
		OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(after)
	}
	return q.Limit(limit)
}

// ListHidden implements CommunityModerator: one page of hidden posts and replies of cid after the id `after` (read-only, outside any
// transaction). Reads: max(1, rows). Rows are passed to each in id order; last is the id of the last row ("" when there are none).
func (m *firestoreModerator) ListHidden(ctx context.Context, cid, after string, limit int, each HiddenRowFunc) (int, string, error) {
	if m == nil || m.client == nil {
		return 0, "", errors.New("posts: moderator has no firestore client")
	}
	snaps, err := m.hiddenQuery(cid, after, limit).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(snaps))
	if err != nil {
		return 0, "", fmt.Errorf("posts: list hidden: %w", err)
	}
	last := ""
	for _, s := range snaps {
		var d hiddenDoc
		if err := s.DataTo(&d); err != nil {
			return 0, "", fmt.Errorf("posts: decode hidden post: %w", err)
		}
		each(s.Ref.ID, d.Kind == string(KindReply), d.CommunityHiddenAt, d.Moderation != "", d.unrestorable(d.Kind == string(KindReply), cid))
		last = s.Ref.ID
	}
	return len(snaps), last, nil
}

// RestoreHiddenPage implements CommunityModerator: the platform's restore of one page, inside tx (ADR-0031 D14a). It reads the page
// FRESH in tx (max(1, rows) reads), asks want about every row, and stages one field-level Update per wanted row (the same updates as
// SetCommunityListing(listed=true), never a Set). The page is read as a query first and written after, because a Firestore transaction
// refuses a read that follows a write, so SetCommunityListing (a Get then an Update per post) cannot be called once per post here. A row
// with `moderation` set, a REPOST or a root whose label is not cid is never restored (D5a, L-2). No F16 rule: this is the platform.
// Writes: one per restored row. The caller calls this after its own reads and before its writes.
func (m *firestoreModerator) RestoreHiddenPage(ctx context.Context, tx *firestore.Transaction, cid, after string, limit int, want HiddenRowFunc) (HiddenPageResult, error) {
	var res HiddenPageResult
	if m == nil || m.client == nil {
		return res, errors.New("posts: moderator has no firestore client")
	}
	snaps, err := tx.Documents(m.hiddenQuery(cid, after, limit)).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(snaps))
	if err != nil {
		return res, fmt.Errorf("posts: read hidden page: %w", err)
	}
	for _, s := range snaps {
		var d hiddenDoc
		if err := s.DataTo(&d); err != nil {
			return res, fmt.Errorf("posts: decode hidden post: %w", err)
		}
		res.Rows++
		res.Last = s.Ref.ID
		reply := d.Kind == string(KindReply)
		moderated, other := d.Moderation != "", d.unrestorable(reply, cid)
		if !want(s.Ref.ID, reply, d.CommunityHiddenAt, moderated, other) || moderated || other {
			continue
		}
		if err := tx.Update(s.Ref, listingUpdates(reply, true, cid)); err != nil {
			return res, fmt.Errorf("posts: restore hidden post: %w", err)
		}
		budget.FromContext(ctx).AddWrites(1)
		res.Restored++
		if !reply {
			res.RestoredRoots = append(res.RestoredRoots, s.Ref.ID)
		}
	}
	return res, nil
}

// unrestorable is true for a row restore-hidden never restores besides a moderated one: a REPOST, or a root whose label names another community
// (a reply qualifies through conversationCommunityId, which the query already matched). The listing, --dry-run and the real run all use it.
func (d hiddenDoc) unrestorable(reply bool, cid string) bool {
	return !reply && (d.Kind == string(KindRepost) || d.Community == nil || d.Community.ID != cid)
}
