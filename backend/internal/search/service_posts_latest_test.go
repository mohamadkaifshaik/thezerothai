package search

import (
	"context"
	"fmt"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor/cursortest"
)

// W4-27 (security review L-1, ADR-0028 note 2026-10-31 part 3): LATEST queries fixed windows, filters the whole window and
// only then cuts to page_size, so a reply depends on the visible rows (and on whether the window was full), never on how
// many rows the caller cannot see. The tests compare a tag that has hidden posts (A) with a tag that has the same visible
// posts and none hidden (B): every (rows returned, token present) pair must match.

// hideCause is why a post is invisible to the caller "u": the four D6 / ADR-0025 causes.
type hideCause int

const (
	causeBlock hideCause = iota
	causeMute
	causeProtected
	causeTakedown
)

var allCauses = []hideCause{causeBlock, causeMute, causeProtected, causeTakedown}

func (c hideCause) String() string {
	return [...]string{"block", "mute", "protected", "takedown"}[c]
}

// hide turns p into a post the caller cannot see.
func (c hideCause) hide(p *posts.Post) {
	switch c {
	case causeBlock:
		p.AuthorID = "blk"
	case causeMute:
		p.AuthorID = "mut"
	case causeProtected:
		p.AuthorID = "prot"
	case causeTakedown:
		p.Moderation = posts.ModerationTakenDown
	}
}

// latestRig serves the given tags with the blocked, muted and protected authors of hideCause already set up.
func latestRig(byTag map[string][]*posts.Post) *rig {
	return newRig(byTag,
		withSnap(func(s *graph.Snapshot) { s.Blocked["blk"] = true; s.Muted["mut"] = true }),
		withProtected(fakeProtected{set: protectedSet{"prot": true}}),
	)
}

// tagWith builds total posts, newest first (ids total..1). hidden maps a post number to the cause that hides it.
func tagWith(total int, hidden map[int]hideCause) []*posts.Post {
	return newestFirst(total, func(n int, p *posts.Post) {
		if c, ok := hidden[n]; ok {
			c.hide(p)
		}
	})
}

// spread hides h posts of total, evenly through the tag, rotating the causes. offset moves them.
func spread(total, h, offset int) map[int]hideCause {
	out := map[int]hideCause{}
	for i := 0; i < h; i++ {
		out[1+(offset+i*total/h)%total] = allCauses[i%len(allCauses)]
	}
	return out
}

// newestHidden hides the h newest posts of total (the worst case for the old page-1 cut).
func newestHidden(total, h int) map[int]hideCause {
	out := map[int]hideCause{}
	for i := 0; i < h; i++ {
		out[total-i] = allCauses[i%len(allCauses)]
	}
	return out
}

type shape struct {
	rows int
	tok  bool
	tail bool
}

// isTail reports whether token is a LATEST_TAIL token of uid "u" on tag (it fails to decode as a plain LATEST token).
func isTail(r *rig, tag, token string) bool {
	if token == "" {
		return false
	}
	if _, err := cursor.DecodeAt(testKey, binding("u", tag, tabLatest), token, r.now()); err == nil {
		return false
	}
	_, err := cursor.DecodeAt(testKey, tailBinding("u", tag), token, r.now())
	return err == nil
}

// walk reads LATEST of tag to the end, page 1 at firstK and every later page at laterK, and returns each page's shape.
func walk(t *testing.T, r *rig, tag string, firstK, laterK int32) []shape {
	t.Helper()
	var out []shape
	tok := ""
	for i := 0; i < 200; i++ {
		k := laterK
		if i == 0 {
			k = firstK
		}
		resp := doPosts(t, r, "u", tag, latest, k, tok)
		if int32(len(resp.Posts)) > k {
			t.Fatalf("page %d has %d rows, page_size %d", i, len(resp.Posts), k)
		}
		out = append(out, shape{len(resp.Posts), resp.NextPageToken != "", isTail(r, tag, resp.NextPageToken)})
		if tok = resp.NextPageToken; tok == "" {
			return out
		}
	}
	t.Fatal("the chain did not end after 200 pages")
	return nil
}

// Page 1: tag A (V visible, H hidden, V+H < 30) and tag B (the same V visible, none hidden) answer identically at every
// page_size 1..30, with hidden rows spread and newest.
func TestLatest_Page1DoesNotDependOnHiddenRows(t *testing.T) {
	t.Parallel()
	for _, h := range []int{1, 5} {
		for _, v := range []int{0, 1, 10, 29 - h} {
			for _, placement := range []string{"spread", "newest"} {
				t.Run(fmt.Sprintf("H%d_V%d_%s", h, v, placement), func(t *testing.T) {
					t.Parallel()
					hidden := spread(v+h, h, 3)
					if placement == "newest" {
						hidden = newestHidden(v+h, h)
					}
					r := latestRig(map[string][]*posts.Post{"a": tagWith(v+h, hidden), "b": tagWith(v, nil)})
					for k := int32(1); k <= 30; k++ {
						ra := doPosts(t, r, "u", "a", latest, k, "")
						rb := doPosts(t, r, "u", "b", latest, k, "")
						if len(ra.Posts) != len(rb.Posts) || (ra.NextPageToken != "") != (rb.NextPageToken != "") {
							t.Fatalf("k=%d: hidden tag returned %d rows token %v; clean tag %d rows token %v",
								k, len(ra.Posts), ra.NextPageToken != "", len(rb.Posts), rb.NextPageToken != "")
						}
						if want := min(int(k), v); len(rb.Posts) != want {
							t.Fatalf("k=%d: %d rows, want %d", k, len(rb.Posts), want)
						}
					}
				})
			}
		}
	}
}

// The whole chain of a small tag (V+H of 25 and 29): A and B give the same (rows, token) sequence at k=1, at k=20 and at
// k=1 on page 1 then k=20 after (the review's leak), and every token the chain issues is a tail token. The old code showed
// the hidden count here: page 1 at k=1, then a full 20-row window at k=20.
func TestLatest_SmallTagChainIsIdenticalAndTailed(t *testing.T) {
	t.Parallel()
	for _, total := range []int{25, 29} {
		for _, h := range []int{1, 5} {
			for _, placement := range []string{"spread", "newest"} {
				for _, ks := range [][2]int32{{1, 1}, {20, 20}, {1, 20}, {20, 1}, {7, 13}} {
					t.Run(fmt.Sprintf("total%d_H%d_%s_k%d_%d", total, h, placement, ks[0], ks[1]), func(t *testing.T) {
						t.Parallel()
						hidden := spread(total, h, 2)
						if placement == "newest" {
							hidden = newestHidden(total, h)
						}
						r := latestRig(map[string][]*posts.Post{"a": tagWith(total, hidden), "b": tagWith(total-h, nil)})
						a := walk(t, r, "a", ks[0], ks[1])
						b := walk(t, r, "b", ks[0], ks[1])
						if fmt.Sprint(a) != fmt.Sprint(b) {
							t.Fatalf("hidden tag %v\nclean tag  %v", a, b)
						}
						for i, s := range a {
							if s.tok && !s.tail {
								t.Fatalf("page %d issued a normal token; a tag under 30 rows must only issue tail tokens: %v", i, a)
							}
						}
					})
				}
			}
		}
	}
}

// Busy tag, older pages: two full windows with the same number of visible rows give the same (rows, token) for every
// page_size of the tier (1..20 on a 20-row window, 21..50 on a 50-row window), whatever hides the other rows.
func TestLatest_OlderFullWindowsDoNotDependOnHiddenRows(t *testing.T) {
	t.Parallel()
	tiers := []struct {
		name     string
		firstK   int32 // the page-1 size that returns the whole first window uncut, so its token is at the window end
		first    int   // rows of that first window
		window   int   // the older window under test
		kLo, kHi int32
		hidden   int
	}{
		{"20-row window", 30, tagEntrySize, latestOlderSmall, 1, 20, 6},
		{"50-row window", 50, latestWide, latestWide, 21, 50, 14},
	}
	for _, tier := range tiers {
		for _, c := range allCauses {
			t.Run(tier.name+"_"+c.String(), func(t *testing.T) {
				t.Parallel()
				const total = 150
				// Page 1 is all visible in both tags. The next window has tier.hidden hidden rows in A and, in B, the same
				// number hidden by a DIFFERENT cause at other positions: the visible count matches, so the replies must too.
				hiddenA, hiddenB := map[int]hideCause{}, map[int]hideCause{}
				for i := 0; i < tier.hidden; i++ {
					hiddenA[total-tier.first-i*2] = c
					hiddenB[total-tier.first-tier.window+1+i] = allCauses[(int(c)+1)%len(allCauses)]
				}
				r := latestRig(map[string][]*posts.Post{"a": tagWith(total, hiddenA), "b": tagWith(total, hiddenB)})
				pa := doPosts(t, r, "u", "a", latest, tier.firstK, "")
				pb := doPosts(t, r, "u", "b", latest, tier.firstK, "")
				if len(pa.Posts) != len(pb.Posts) || pa.NextPageToken == "" || pb.NextPageToken == "" {
					t.Fatalf("page 1 differs: %d/%v vs %d/%v", len(pa.Posts), pa.NextPageToken != "", len(pb.Posts), pb.NextPageToken != "")
				}
				for k := tier.kLo; k <= tier.kHi; k++ {
					oa := doPosts(t, r, "u", "a", latest, k, pa.NextPageToken)
					ob := doPosts(t, r, "u", "b", latest, k, pb.NextPageToken)
					if len(oa.Posts) != len(ob.Posts) || (oa.NextPageToken != "") != (ob.NextPageToken != "") {
						t.Fatalf("older page k=%d: %d rows token %v vs %d rows token %v",
							k, len(oa.Posts), oa.NextPageToken != "", len(ob.Posts), ob.NextPageToken != "")
					}
					if oa.NextPageToken == "" || isTail(r, "a", oa.NextPageToken) {
						t.Fatalf("k=%d: a full window must issue a normal token (got %q)", k, oa.NextPageToken)
					}
				}
			})
		}
	}
}

// A full entry whose 30 rows are all hidden is an empty page 1 WITH a token, and the next page starts after the entry's
// 30th row (post 11 of 40): no stall, no repeat.
func TestLatest_FullyHiddenEntryKeepsItsToken(t *testing.T) {
	t.Parallel()
	r := latestRig(map[string][]*posts.Post{"go": tagWith(40, newestHidden(40, 30))})
	p1 := doPosts(t, r, "u", "go", latest, 20, "")
	if len(p1.Posts) != 0 || p1.NextPageToken == "" || isTail(r, "go", p1.NextPageToken) {
		t.Fatalf("page 1: %d rows token %q, want an empty page with a normal token", len(p1.Posts), p1.NextPageToken)
	}
	p2 := doPosts(t, r, "u", "go", latest, 20, p1.NextPageToken)
	if len(p2.Posts) != 10 || ids(p2)[0] != idOf(10) || p2.NextPageToken != "" {
		t.Fatalf("page 2: %d rows %v token %q, want posts 10..1 and no token", len(p2.Posts), ids(p2), p2.NextPageToken)
	}
}

// With len(kept) > k the next page's first row is kept[k]: walking the chain at several page sizes returns exactly the
// visible posts, newest first, with no gap and no duplicate.
func TestLatest_ChainReturnsEveryVisiblePostOnce(t *testing.T) {
	t.Parallel()
	const total = 130
	hidden := spread(total, 40, 5)
	var want []string
	for n := total; n >= 1; n-- {
		if _, h := hidden[n]; !h {
			want = append(want, idOf(n))
		}
	}
	for _, k := range []int32{1, 3, 7, 20, 21, 33, 50} {
		t.Run(fmt.Sprintf("k%d", k), func(t *testing.T) {
			t.Parallel()
			r := latestRig(map[string][]*posts.Post{"go": tagWith(total, hidden)})
			var got []string
			tok := ""
			for i := 0; i < 400; i++ {
				resp := doPosts(t, r, "u", "go", latest, k, tok)
				got = append(got, ids(resp)...)
				if tok = resp.NextPageToken; tok == "" {
					break
				}
			}
			if fmt.Sprint(got) != fmt.Sprint(want) {
				t.Fatalf("k=%d: got %d posts, want the %d visible ones in order\n got %v\nwant %v", k, len(got), len(want), got, want)
			}
		})
	}
}

// A tail page queries the whole remaining tail in one 50-row query and keeps issuing tail tokens (reads: the rows left).
func TestLatest_TailPageReadsTheWholeRest(t *testing.T) {
	t.Parallel()
	r := latestRig(map[string][]*posts.Post{"go": tagWith(25, nil)})
	p1 := doPosts(t, r, "u", "go", latest, 1, "")
	if len(p1.Posts) != 1 || !isTail(r, "go", p1.NextPageToken) {
		t.Fatalf("page 1 of a 25-post tag at k=1: %d rows, tail token %v", len(p1.Posts), isTail(r, "go", p1.NextPageToken))
	}
	p2 := doPosts(t, r, "u", "go", latest, 20, p1.NextPageToken)
	if len(p2.Posts) != 20 || !isTail(r, "go", p2.NextPageToken) || ids(p2)[0] != idOf(24) {
		t.Fatalf("tail page: %d rows, tail token %v, first %v", len(p2.Posts), isTail(r, "go", p2.NextPageToken), ids(p2)[:1])
	}
	p3 := doPosts(t, r, "u", "go", latest, 20, p2.NextPageToken)
	if len(p3.Posts) != 4 || p3.NextPageToken != "" || ids(p3)[0] != idOf(4) {
		t.Fatalf("last tail page: %d rows, token %q", len(p3.Posts), p3.NextPageToken)
	}
	if fmt.Sprint(r.reader.calls) != fmt.Sprint([]int{tagEntrySize, latestWide, latestWide}) {
		t.Fatalf("calls = %v, want the entry then two 50-row tail queries", r.reader.calls)
	}
	if want := 25 + 24 + 4; r.reader.reads != want {
		t.Fatalf("reads = %d, want %d (entry 25, then the rows left: 24 and 4)", r.reader.reads, want)
	}
}

// If 50 rows come back on a tail page (a late commit inside the settle gap), it falls back to the normal rules and issues a
// normal token.
func TestLatest_TailPageWith50RowsFallsBackToANormalToken(t *testing.T) {
	t.Parallel()
	r := latestRig(map[string][]*posts.Post{"go": tagWith(25, nil)})
	p1 := doPosts(t, r, "u", "go", latest, 1, "")
	if !isTail(r, "go", p1.NextPageToken) {
		t.Fatal("page 1 must carry a tail token")
	}
	// 60 older posts land after the token was issued: ids below the tag's oldest.
	late := newestFirst(25)
	for i := 0; i < 60; i++ {
		late = append(late, mkPost(-1-i, "a"))
	}
	r.reader.mu.Lock()
	r.reader.byTag["go"] = late
	r.reader.mu.Unlock()
	p2 := doPosts(t, r, "u", "go", latest, 20, p1.NextPageToken)
	if len(p2.Posts) != 20 || p2.NextPageToken == "" || isTail(r, "go", p2.NextPageToken) {
		t.Fatalf("page: %d rows, token tail %v, want 20 rows and a normal token", len(p2.Posts), isTail(r, "go", p2.NextPageToken))
	}
}

// A tampered tail token, a tail token on another tag, tab or caller, and a LATEST token on another tab are VALIDATION
// page_token with 0 reads.
func TestLatest_TailTokenBinding(t *testing.T) {
	t.Parallel()
	byTag := map[string][]*posts.Post{"go": tagWith(25, nil), "rust": tagWith(25, nil)}
	good := doPosts(t, latestRig(byTag), "u", "go", latest, 1, "").NextPageToken
	tests := []struct {
		name  string
		uid   string
		q     string
		tab   searchv1.SearchTab
		token string
	}{
		{"tampered tail token", "u", "go", latest, cursortest.Tamper(good)},
		{"tail token, another tag", "u", "rust", latest, good},
		{"tail token, another caller", "v", "go", latest, good},
		{"tail token on MEDIA", "u", "go", media, good},
		{"tail token on TOP", "u", "go", top, good},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			rr := latestRig(byTag)
			_, err := rr.svc.Posts(context.Background(), tt.uid, tt.q, tt.tab, 0, tt.token)
			wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "page_token")
			if rr.reader.callCount() != 0 || rr.graph.calls.Load() != 0 {
				t.Fatalf("a bad token must read nothing: %d queries %d graph", rr.reader.callCount(), rr.graph.calls.Load())
			}
		})
	}
	// A normal LATEST token (a busy tag) is not a tail token on another tab either: covered by TestPageToken_Rejections.
}

// Reads per tier, as the fake reader bills them (rows returned, minimum 1): page 1 at k <= 30 reads the 30-row entry, at
// k 31..50 one 50-row query; an older page 20 rows at k <= 20 and 50 rows at k 21..50, whatever the page size is inside the
// tier. The document figures are these + interceptor 1 + graph 1 + userLikes 1.
func TestLatest_QueryReadsPerTier(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		k     int32
		page1 int
		older int
	}{
		{1, tagEntrySize, latestOlderSmall},
		{20, tagEntrySize, latestOlderSmall},
		{30, tagEntrySize, latestWide},
		{31, latestWide, latestWide},
		{50, latestWide, latestWide},
	} {
		t.Run(fmt.Sprintf("k%d", tt.k), func(t *testing.T) {
			t.Parallel()
			r := latestRig(map[string][]*posts.Post{"go": tagWith(200, nil)})
			p1 := doPosts(t, r, "u", "go", latest, tt.k, "")
			if r.reader.reads != tt.page1 {
				t.Fatalf("page 1 at k=%d read %d, want %d", tt.k, r.reader.reads, tt.page1)
			}
			before := r.reader.reads
			doPosts(t, r, "u", "go", latest, tt.k, p1.NextPageToken)
			if got := r.reader.reads - before; got != tt.older {
				t.Fatalf("older page at k=%d read %d, want %d", tt.k, got, tt.older)
			}
		})
	}
}
