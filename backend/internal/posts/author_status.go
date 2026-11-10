package posts

import (
	"context"
	"fmt"
	"slices"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The author-status rule (F-03), shared by every surface that lists or opens posts: GetPost and GetThread here, the
// Home, list, community and profile feeds, and hashtag search. A row whose author is not ACTIVE (SUSPENDED, DELETING, or
// no users doc) is not shown. A copy of a post whose author is not ACTIVE is shown the way suspend-user's copy clean-up
// and the account purge leave it once they reach it: a REPOST is dropped, a QUOTE keeps its own text with its embed
// reduced to {post id, unavailable} (TombstonedQuote). Before that clean-up runs (it is paged, and the erasers start
// minutes after a deletion request) the copies still carry the snapshot, so readers apply the rule per row.

// AuthorStatusBatch is the most uids one identity.Directory.GetProfiles call takes.
const AuthorStatusBatch = 50

// AuthorDirectory is the part of identity.Directory the rule reads (identity.Directory satisfies it). GetProfiles is
// cache-first (60 s) and omits missing, SUSPENDED and DELETING users.
type AuthorDirectory interface {
	GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error)
}

// AuthorVerdict is what the rule decides for one row.
type AuthorVerdict int

const (
	// AuthorShow: the row is shown as it is.
	AuthorShow AuthorVerdict = iota
	// AuthorDrop: the row's author, or the author of the post a REPOST copies, is not ACTIVE.
	AuthorDrop
	// AuthorTombstone: a QUOTE of a post whose author is not ACTIVE; show TombstonedQuote(row).
	AuthorTombstone
)

// ActiveAuthors is the account status of the uids one ResolveActiveAuthors call asked for.
type ActiveAuthors struct {
	active map[string]bool
}

// Active reports whether uid was proven ACTIVE (the caller, a known uid, or a profile the Directory returned as ACTIVE).
func (a ActiveAuthors) Active(uid string) bool { return a.active[uid] }

// Verdict applies the rule to p: AuthorDrop for an inactive author or a REPOST of an inactive author's post,
// AuthorTombstone for a QUOTE of one, else AuthorShow. A tombstone already carries no embedded author.
func (a ActiveAuthors) Verdict(p *Post) AuthorVerdict {
	if !a.Active(p.AuthorID) {
		return AuthorDrop
	}
	if ea := p.EmbeddedAuthor(); ea != "" && !a.Active(ea) {
		if p.Kind != KindQuote { // a REPOST of it: the clean-up deletes the copy
			return AuthorDrop
		}
		return AuthorTombstone
	}
	return AuthorShow
}

// ResolveActiveAuthors reads the account status of the authors of rows and of the posts their QUOTEs and REPOSTs copy,
// through dir (cache-first): an author it returns with status ACTIVE is active; a missing, SUSPENDED or DELETING one is not.
// Each uid is asked once. The caller and the known uids (already proven ACTIVE in this call) are never asked and are
// active: the account-status interceptor admits only ACTIVE callers. One call per AuthorStatusBatch uids, so a page of
// more than 50 distinct uids makes two; no uid to ask, no call. A failure is an error, never an assumed status, and it is
// redacted (identity's errors can name a uid, "decode profile <uid>").
func ResolveActiveAuthors(ctx context.Context, dir AuthorDirectory, caller string, rows []*Post, known ...string) (ActiveAuthors, error) {
	active := map[string]bool{}
	if caller != "" {
		active[caller] = true
	}
	for _, k := range known {
		active[k] = true
	}
	seen := map[string]bool{}
	var want []string
	add := func(a string) {
		if a != "" && !active[a] && !seen[a] {
			seen[a] = true
			want = append(want, a)
		}
	}
	for _, p := range rows {
		add(p.AuthorID)
		add(p.EmbeddedAuthor())
	}
	if len(want) > 0 && dir == nil {
		return ActiveAuthors{}, fmt.Errorf("author status: no directory") // fail closed: status is never assumed
	}
	for batch := range slices.Chunk(want, AuthorStatusBatch) {
		profiles, err := dir.GetProfiles(ctx, batch)
		if err != nil {
			return ActiveAuthors{}, logger.RedactErr(fmt.Errorf("author status: %w", err), append([]string{caller}, batch...)...)
		}
		for a, p := range profiles {
			if p.Status == identity.AccountStatusActive && seen[a] {
				active[a] = true
			}
		}
	}
	return ActiveAuthors{active: active}, nil
}

// TombstonedQuote is a copy of the QUOTE q as TombstoneQuotes leaves it once the quoted post's author is gone: the
// embed reduced to {post id, unavailable}, no quoteOfId and no embedded author. q itself (shared through the post and
// feed caches) is never changed.
func TombstonedQuote(q *Post) *Post {
	c := *q
	id := q.QuoteOfID
	if q.Embedded != nil && q.Embedded.PostID != "" {
		id = q.Embedded.PostID
	}
	c.Embedded = &Embedded{PostID: id, Unavailable: true}
	c.QuoteOfID, c.EmbeddedAuthorID = "", ""
	return &c
}
