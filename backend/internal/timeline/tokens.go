package timeline

import (
	"time"

	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

// Field names of the VALIDATION error for a rejected token (ADR-0010 D14).
const (
	fieldSince = "since_token"
	fieldPage  = "page_token"
)

// feed names one token family: a home feed for a caller, or one effective tab of a user's feed. Its two bindings keep
// since tokens and page tokens in separate AEAD domains, bound to the caller (and target and tab), so no token
// opens for another caller, feed, tab or kind (ADR-0010 D14; `|` is safe because uids never contain it).
type feed struct{ since, page string }

func homeFeed(caller string) feed {
	return feed{since: "tl|home|" + caller + "|since", page: "tl|home|" + caller + "|page"}
}

// userTab is the EFFECTIVE profile tab of a GetUserTimeline call (ADR-0024 D5): what the call reads and the tab part
// of its token bindings. The string values are the binding values, so they never change: "posts" and "replies" are
// the pre-W3 values, which keeps every token issued before the tab field existed valid on the tab it was issued for.
type userTab string

const (
	tabPosts   userTab = "posts"
	tabReplies userTab = "replies"
	tabMedia   userTab = "media"
	tabReposts userTab = "reposts"
)

// effectiveTab resolves the request's tab and include_replies (ADR-0024 D5). UNSPECIFIED, the default and every
// pre-W3 client, means include_replies decides exactly as before; any other known value wins and include_replies is
// ignored with no error. ok is false for a number this build does not know (a newer client): the caller answers
// VALIDATION rather than guessing a tab, because the tab is part of the token binding.
func effectiveTab(tab timelinev1.UserTimelineTab, includeReplies bool) (t userTab, ok bool) {
	switch tab {
	case timelinev1.UserTimelineTab_USER_TIMELINE_TAB_UNSPECIFIED:
		if includeReplies {
			return tabReplies, true
		}
		return tabPosts, true
	case timelinev1.UserTimelineTab_USER_TIMELINE_TAB_POSTS:
		return tabPosts, true
	case timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPLIES:
		return tabReplies, true
	case timelinev1.UserTimelineTab_USER_TIMELINE_TAB_MEDIA:
		return tabMedia, true
	case timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPOSTS:
		return tabReposts, true
	}
	return "", false
}

// gated reports whether the tab needs FEATURE_PROFILE_TABS (ADR-0024 D5, D9): Media and Reposts. Posts and Replies
// stay ungated.
func (t userTab) gated() bool { return t == tabMedia || t == tabReposts }

func userFeed(caller, target string, tab userTab) feed {
	base := "tl|user|" + caller + "|" + target + "|" + string(tab) + "|"
	return feed{since: base + "since", page: base + "page"}
}

// request is the decoded token state of one call.
type request struct {
	// Since is the refresh watermark (nil unless a since_token was sent).
	Since *posts.Position
	// SinceIssued is when that since_token was issued (sealed in the token; zero unless Since is set).
	SinceIssued time.Time
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
		cur, issued, err := cursor.DecodeIssuedAtTTL(c.key, f.since, sinceToken, c.now(), c.ttl)
		if err != nil || cursor.IsFirstPage(cur) {
			return r, apierr.Validation(fieldSince, "since_token is invalid or expired")
		}
		r.Since = &posts.Position{CreatedAt: cur.CreatedAt, ID: cur.DocID}
		r.SinceIssued = issued
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

// listFeed is the token family of one list read by one caller (ADR-0030 D5): bound to the caller AND the list, so a Home or
// user token on a list, a list token on another list or for another caller is VALIDATION with 0 reads. ids never contain a pipe.
func listFeed(caller, listID string) feed {
	base := "tl|list|" + caller + "|" + listID + "|"
	return feed{since: base + "since", page: base + "page"}
}
