package timeline

import (
	"errors"
	"testing"
	"time"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor/cursortest"
)

var testKey = []byte("0123456789abcdef0123456789abcdef")

func newCodec(c *fakeClock) codec {
	return codec{key: testKey, ttl: 720 * time.Hour, now: c.Now}
}

func wantField(t *testing.T, err error, field string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != field {
		t.Fatalf("err = %#v, want VALIDATION field=%s", err, field)
	}
}

func pos(ms int64, id int64) posts.Position {
	return posts.Position{CreatedAt: time.UnixMilli(ms).UTC(), ID: pid(id)}
}

func TestCodec_BindingMatrix(t *testing.T) {
	t.Parallel()
	c := newClock()
	cd := newCodec(c)
	home := homeFeed("alice")
	feeds := map[string]feed{
		"other caller":        homeFeed("bob"),
		"user feed":           userFeed("alice", "carol", tabPosts),
		"user feed (replies)": userFeed("alice", "carol", tabReplies),
	}
	since := cd.encodeSince(home, pos(5000, 5))
	page := cd.encodePage(home, pos(4000, 4), nil)
	gap := cd.encodePage(home, pos(4000, 4), ptr(pos(1000, 1)))

	// own tokens round-trip.
	if r, err := cd.parse(home, since, ""); err != nil || r.Since == nil || *r.Since != pos(5000, 5) {
		t.Fatalf("since round trip = %+v, %v", r, err)
	}
	if r, err := cd.parse(home, "", page); err != nil || r.Upper == nil || r.Lower != nil || r.mode() != modeOlder {
		t.Fatalf("page round trip = %+v, %v", r, err)
	}
	if r, err := cd.parse(home, "", gap); err != nil || r.Lower == nil || *r.Lower != pos(1000, 1) || r.mode() != modeGap || r.Reached {
		t.Fatalf("gap round trip = %+v, %v", r, err)
	}

	for name, f := range feeds {
		_, err := cd.parse(f, since, "")
		wantField(t, err, fieldSince)
		_, err = cd.parse(f, "", page)
		wantField(t, err, fieldPage)
		_, err = cd.parse(f, "", gap)
		wantField(t, err, fieldPage)
		_ = name
	}
	// a since token is never a page token and vice versa.
	_, err := cd.parse(home, "", since)
	wantField(t, err, fieldPage)
	_, err = cd.parse(home, page, "")
	wantField(t, err, fieldSince)
	// tab-bound: Posts-tab tokens fail on the Replies tab.
	pt := cd.encodePage(userFeed("alice", "carol", tabPosts), pos(1, 1), nil)
	_, err = cd.parse(userFeed("alice", "carol", tabReplies), "", pt)
	wantField(t, err, fieldPage)
	// tampered.
	_, err = cd.parse(home, cursortest.Tamper(since), "")
	wantField(t, err, fieldSince)
	_, err = cd.parse(home, "", "garbage")
	wantField(t, err, fieldPage)
	// both set.
	_, err = cd.parse(home, since, page)
	wantField(t, err, fieldPage)
}

func ptr[T any](v T) *T { return &v }

func TestCodec_TTLBoundaryAndAboveTheDefault24h(t *testing.T) {
	t.Parallel()
	c := newClock()
	cd := newCodec(c)
	f := homeFeed("alice")
	issuedAt := c.Now()
	since := cd.encodeSince(f, pos(5000, 5))
	page := cd.encodePage(f, pos(4000, 4), ptr(pos(1000, 1)))

	tests := []struct {
		name string
		age  time.Duration
		ok   bool
	}{
		{"25 h old is accepted (the 24 h default would reject it)", 25 * time.Hour, true},
		{"30 d - 1 s accepted", 720*time.Hour - time.Second, true},
		{"30 d + 1 s rejected", 720*time.Hour + time.Second, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			c.t = issuedAt.Add(tc.age)
			_, e1 := cd.parse(f, since, "")
			_, e2 := cd.parse(f, "", page)
			if (e1 == nil) != tc.ok || (e2 == nil) != tc.ok {
				t.Fatalf("since err=%v page err=%v, want ok=%v", e1, e2, tc.ok)
			}
			if !tc.ok {
				wantField(t, e1, fieldSince)
				wantField(t, e2, fieldPage)
			}
		})
	}
}

// A Lower bound at or above Upper is "lower bound reached", never an error (T28 carry-over).
func TestCodec_LowerAtOrAboveUpperIsReached(t *testing.T) {
	t.Parallel()
	c := newClock()
	cd := newCodec(c)
	f := homeFeed("alice")
	tests := []struct {
		name         string
		upper, lower posts.Position
		reached      bool
	}{
		{"lower older than upper", pos(5000, 5), pos(1000, 1), false},
		{"equal", pos(5000, 5), pos(5000, 5), true},
		{"same instant, lower id above upper id", pos(5000, 5), pos(5000, 6), true},
		{"lower newer than upper", pos(1000, 1), pos(5000, 5), true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r, err := cd.parse(f, "", cd.encodePage(f, tc.upper, &tc.lower))
			if err != nil || r.Reached != tc.reached {
				t.Fatalf("reached = %v err = %v, want %v", r.Reached, err, tc.reached)
			}
		})
	}
}

func TestCodec_RejectsForeignKeyAndCursorAsWindow(t *testing.T) {
	t.Parallel()
	c := newClock()
	cd := newCodec(c)
	f := homeFeed("alice")
	other := codec{key: []byte("ffffffffffffffffffffffffffffffff"), ttl: cd.ttl, now: c.Now}
	_, err := cd.parse(f, other.encodeSince(f, pos(1, 1)), "")
	wantField(t, err, fieldSince)
	// a raw cursor token under the page binding opens as no Window.
	raw := cursor.EncodeAt(testKey, f.page, cursor.Cursor{CreatedAt: time.UnixMilli(1).UTC(), DocID: pid(1)}, c.Now())
	_, err = cd.parse(f, "", raw)
	wantField(t, err, fieldPage)
}

// flip returns tok with one character in the middle replaced, so the AEAD tag or ciphertext no longer matches.
func flip(tok string) string {
	b := []byte(tok)
	i := len(b) / 2
	if b[i] == 'A' {
		b[i] = 'B'
	} else {
		b[i] = 'A'
	}
	return string(b)
}

// ADR-0010 D14 on user feeds: since, page and gap tokens open only for the caller, target and tab that sealed
// them (posts<->replies in both directions, caller A<->B), and a tampered page or gap token is VALIDATION.
func TestCodec_UserTokenBinding(t *testing.T) {
	t.Parallel()
	cd := newCodec(newClock())
	posts := userFeed("alice", "carol", tabPosts)
	replies := userFeed("alice", "carol", tabReplies)
	tokens := func(f feed) (since, page, gap string) {
		return cd.encodeSince(f, pos(5000, 5)), cd.encodePage(f, pos(4000, 4), nil), cd.encodePage(f, pos(4000, 4), ptr(pos(1000, 1)))
	}
	pSince, pPage, pGap := tokens(posts)
	rSince, rPage, rGap := tokens(replies)

	// Own tokens open.
	for name, f := range map[string]feed{"posts": posts, "replies": replies} {
		since, page, gap := tokens(f)
		if _, err := cd.parse(f, since, ""); err != nil {
			t.Fatalf("%s since: %v", name, err)
		}
		if _, err := cd.parse(f, "", page); err != nil {
			t.Fatalf("%s page: %v", name, err)
		}
		if r, err := cd.parse(f, "", gap); err != nil || r.mode() != modeGap {
			t.Fatalf("%s gap: %+v %v", name, r, err)
		}
	}

	tests := []struct {
		name string
		on   feed
	}{
		{"posts tokens on the replies tab", replies},
		{"caller B", userFeed("bob", "carol", tabPosts)},
		{"caller B, replies tab", userFeed("bob", "carol", tabReplies)},
		{"another target", userFeed("alice", "dave", tabPosts)},
		{"home feed", homeFeed("alice")},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := cd.parse(tc.on, pSince, "")
			wantField(t, err, fieldSince)
			_, err = cd.parse(tc.on, "", pPage)
			wantField(t, err, fieldPage)
			_, err = cd.parse(tc.on, "", pGap)
			wantField(t, err, fieldPage)
		})
	}
	t.Run("replies tokens on the posts tab", func(t *testing.T) {
		_, err := cd.parse(posts, rSince, "")
		wantField(t, err, fieldSince)
		_, err = cd.parse(posts, "", rPage)
		wantField(t, err, fieldPage)
		_, err = cd.parse(posts, "", rGap)
		wantField(t, err, fieldPage)
	})
	t.Run("kind: a since token is not a page token and vice versa", func(t *testing.T) {
		_, err := cd.parse(posts, "", pSince)
		wantField(t, err, fieldPage)
		_, err = cd.parse(posts, pPage, "")
		wantField(t, err, fieldSince)
		_, err = cd.parse(posts, pGap, "")
		wantField(t, err, fieldSince)
	})
	t.Run("tampered", func(t *testing.T) {
		_, err := cd.parse(posts, flip(pSince), "")
		wantField(t, err, fieldSince)
		_, err = cd.parse(posts, "", flip(pPage))
		wantField(t, err, fieldPage)
		_, err = cd.parse(posts, "", flip(pGap))
		wantField(t, err, fieldPage)
		_, err = cd.parse(posts, "", pPage[:len(pPage)-8]) // truncated
		wantField(t, err, fieldPage)
	})
}

// ADR-0024 D5/D14 at the codec: the four effective tabs are four separate token families. A since, page or gap token
// opens only on the tab (and caller and target) that sealed it, with no cross-tab pair accepted.
func TestCodec_UserTabTokenMatrix(t *testing.T) {
	t.Parallel()
	cd := newCodec(newClock())
	tabs := []userTab{tabPosts, tabReplies, tabMedia, tabReposts}
	for _, from := range tabs {
		f := userFeed("alice", "carol", from)
		since := cd.encodeSince(f, pos(5000, 5))
		page := cd.encodePage(f, pos(4000, 4), nil)
		gap := cd.encodePage(f, pos(4000, 4), ptr(pos(1000, 1)))
		for _, on := range tabs {
			g := userFeed("alice", "carol", on)
			_, errSince := cd.parse(g, since, "")
			_, errPage := cd.parse(g, "", page)
			r, errGap := cd.parse(g, "", gap)
			if from == on {
				if errSince != nil || errPage != nil || errGap != nil || r.mode() != modeGap {
					t.Fatalf("%s tokens on %s: %v / %v / %v (mode %s)", from, on, errSince, errPage, errGap, r.mode())
				}
				continue
			}
			wantField(t, errSince, fieldSince)
			wantField(t, errPage, fieldPage)
			wantField(t, errGap, fieldPage)
		}
	}
}

// Every token issued before the tab field existed stays valid (ADR-0024 D5): the binding strings of the Posts and
// Replies tabs are frozen, and the new tabs' strings differ from them.
func TestUserFeed_BindingStringsAreFrozen(t *testing.T) {
	t.Parallel()
	tests := []struct {
		tab         userTab
		since, page string
	}{
		{tabPosts, "tl|user|alice|carol|posts|since", "tl|user|alice|carol|posts|page"},
		{tabReplies, "tl|user|alice|carol|replies|since", "tl|user|alice|carol|replies|page"},
		{tabMedia, "tl|user|alice|carol|media|since", "tl|user|alice|carol|media|page"},
		{tabReposts, "tl|user|alice|carol|reposts|since", "tl|user|alice|carol|reposts|page"},
	}
	for _, tc := range tests {
		f := userFeed("alice", "carol", tc.tab)
		if f.since != tc.since || f.page != tc.page {
			t.Errorf("userFeed(%s) = %+v, want since=%q page=%q", tc.tab, f, tc.since, tc.page)
		}
	}
	// A token sealed under the literal pre-W3 binding opens through the effective tab of a request that never set `tab`.
	c := newClock()
	cd := newCodec(c)
	old := cursor.EncodeAt(testKey, "tl|user|alice|carol|replies|since", cursor.Cursor{CreatedAt: time.UnixMilli(5000).UTC(), DocID: pid(5)}, c.Now())
	tab, ok := effectiveTab(0, true) // UNSPECIFIED + include_replies
	if !ok {
		t.Fatal("UNSPECIFIED must resolve")
	}
	if _, err := cd.parse(userFeed("alice", "carol", tab), old, ""); err != nil {
		t.Fatalf("a pre-W3 replies since_token no longer opens: %v", err)
	}
}
