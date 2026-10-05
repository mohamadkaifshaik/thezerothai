package timeline

import (
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

// Field names of the VALIDATION error for a rejected token (ADR-0010 D14).
const (
	fieldSince = "since_token"
	fieldPage  = "page_token"
)

// feed names one token family: a home feed for a caller, or one tab of a user's feed. Its two bindings keep
// since tokens and page tokens in separate AEAD domains, bound to the caller (and target and tab), so no token
// opens for another caller, feed, tab or kind (ADR-0010 D14; `|` is safe because uids never contain it).
type feed struct{ since, page string }

func homeFeed(caller string) feed {
	return feed{since: "tl|home|" + caller + "|since", page: "tl|home|" + caller + "|page"}
}

func userFeed(caller, target string, includeReplies bool) feed {
	tab := "posts"
	if includeReplies {
		tab = "replies"
	}
	base := "tl|user|" + caller + "|" + target + "|" + tab + "|"
	return feed{since: base + "since", page: base + "page"}
}

// request is the decoded token state of one call.
type request struct {
	// Since is the refresh watermark (nil unless a since_token was sent).
	Since *posts.Position
	// Upper and Lower are the page window of a page_token: resume strictly below Upper; stop strictly above
	// Lower (a gap). Both nil without a page token.
	Upper, Lower *posts.Position
	// Reached is true when a gap token's Lower bound is not below its Upper: the gap is closed and the page
	// is empty with no next token (T28 carry-over; never an error).
	Reached bool
}

// mode is the log value timeline_mode.
type mode string

const (
	modeCold    mode = "cold"
	modeRefresh mode = "refresh"
	modeOlder   mode = "older"
	modeGap     mode = "gap"
)

func (r request) mode() mode {
	switch {
	case r.Since != nil:
		return modeRefresh
	case r.Lower != nil:
		return modeGap
	case r.Upper != nil:
		return modeOlder
	}
	return modeCold
}

// after is the lower bound of every query of the call: the since of a refresh or the Lower of a gap page.
func (r request) after() *posts.Position {
	if r.Since != nil {
		return r.Since
	}
	return r.Lower
}

// window is the posts.Window of the call's queries.
func (r request) window() posts.Window { return posts.Window{Before: r.Upper, After: r.after()} }

// codec seals and opens timeline tokens with the cursor key and TIMELINE_TOKEN_TTL (never the 24 h default
// decode: a client persists since and gap tokens across days).
type codec struct {
	key []byte
	ttl time.Duration
	now func() time.Time
}

// parse decodes and validates both tokens against f with 0 reads. Any failure is VALIDATION with the field of
// the offending token; sending both tokens is VALIDATION field=page_token.
func (c codec) parse(f feed, sinceToken, pageToken string) (request, error) {
	var r request
	if sinceToken != "" && pageToken != "" {
		return r, apierr.Validation(fieldPage, "send either since_token or page_token, not both")
	}
	if sinceToken != "" {
		cur, err := cursor.DecodeAtTTL(c.key, f.since, sinceToken, c.now(), c.ttl)
		if err != nil || cursor.IsFirstPage(cur) {
			return r, apierr.Validation(fieldSince, "since_token is invalid or expired")
		}
		r.Since = &posts.Position{CreatedAt: cur.CreatedAt, ID: cur.DocID}
		return r, nil
	}
	if pageToken != "" {
		w, err := cursor.DecodeWindowAt(c.key, f.page, pageToken, c.now(), c.ttl)
		if err != nil || w.IsZero() {
			return r, apierr.Validation(fieldPage, "page_token is invalid or expired")
		}
		up := posts.Position{CreatedAt: w.Upper.CreatedAt, ID: w.Upper.DocID}
		r.Upper = &up
		if w.Lower != nil {
			lo := posts.Position{CreatedAt: w.Lower.CreatedAt, ID: w.Lower.DocID}
			r.Lower = &lo
			r.Reached = Compare(up, lo) >= 0 // Upper at or below Lower: nothing left in the gap
		}
	}
	return r, nil
}

func (c codec) encodeSince(f feed, p posts.Position) string {
	return cursor.EncodeAt(c.key, f.since, cursor.Cursor{CreatedAt: p.CreatedAt, DocID: p.ID}, c.now())
}

// encodePage seals the resume point (strictly below upper) with an optional gap lower bound.
func (c codec) encodePage(f feed, upper posts.Position, lower *posts.Position) string {
	w := cursor.Window{Upper: cursor.Cursor{CreatedAt: upper.CreatedAt, DocID: upper.ID}}
	if lower != nil {
		w.Lower = &cursor.Cursor{CreatedAt: lower.CreatedAt, DocID: lower.ID}
	}
	return cursor.EncodeWindowAt(c.key, f.page, w, c.now())
}
