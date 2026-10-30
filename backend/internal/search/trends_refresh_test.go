package search

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// fakeScanner implements CreatedAfter over a fixed list ordered by (createdAt, id), strictly after the watermark, and
// bills like the reader: len(result), minimum 1.
type fakeScanner struct {
	posts []*posts.Post
	calls int
	err   error
	// errAfter, when > 0, fails every call after that many calls.
	errAfter int
	// slowFirst sleeps this long in the first call without honouring ctx; blockAfter makes every call after that many
	// block until its context is done (a slow Firestore page).
	slowFirst  time.Duration
	blockAfter int
}

func (f *fakeScanner) CreatedAfter(ctx context.Context, after posts.Position, limit int) ([]*posts.Post, error) {
	f.calls++
	if f.calls == 1 && f.slowFirst > 0 {
		time.Sleep(f.slowFirst)
	}
	if f.blockAfter > 0 && f.calls > f.blockAfter {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if f.err != nil {
		return nil, f.err
	}
	if f.errAfter > 0 && f.calls > f.errAfter {
		return nil, errors.New("page failed")
	}
	var out []*posts.Post
	for _, p := range f.posts {
		later := p.CreatedAt.After(after.CreatedAt) || (p.CreatedAt.Equal(after.CreatedAt) && after.ID != "" && p.ID > after.ID)
		if later {
			out = append(out, p)
			if len(out) == limit {
				break
			}
		}
	}
	budget.FromContext(ctx).AddQueryReads(len(out))
	return out, nil
}

type trendsFakeProtected struct {
	set map[string]bool
	err error
	n   int
}

type protSet map[string]bool

func (p protSet) Has(uid string) bool { return p[uid] }
func (p protSet) CanSee(viewer, author string, following bool) bool {
	return viewer == author || !p[author] || following
}

func (f *trendsFakeProtected) Current(context.Context) (identity.ProtectedSet, error) {
	f.n++
	if f.err != nil {
		return nil, f.err
	}
	return protSet(f.set), nil
}

func post(n int, author string, at time.Time, tags ...string) *posts.Post {
	return &posts.Post{ID: fmt.Sprintf("%020d", n), AuthorID: author, Kind: posts.KindPost, Hashtags: tags, CreatedAt: at}
}

type harness struct {
	clk   *fakeClock
	store *fakeTrendsStore
	scan  *fakeScanner
	prot  *trendsFakeProtected
	logs  *bytes.Buffer
	r     *Refresher
}

func newHarness(t *testing.T, on bool, mutate func(*RefresherConfig)) *harness {
	t.Helper()
	h := &harness{clk: &fakeClock{t: trendsT0}, store: &fakeTrendsStore{}, scan: &fakeScanner{}, prot: &trendsFakeProtected{set: map[string]bool{}}, logs: &bytes.Buffer{}}
	mode := flags.Off
	if on {
		mode = flags.On
	}
	reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: mode})
	cfg := RefresherConfig{MinAuthors: 3, MaxPosts: 2000, MinInterval: 12 * time.Hour, Now: h.clk.now,
		Log: slog.New(slog.NewJSONHandler(h.logs, nil))}
	if mutate != nil {
		mutate(&cfg)
	}
	h.r = NewRefresher(h.store, h.scan, h.prot, reg, cfg)
	return h
}

func (h *harness) run(t *testing.T) (RunResult, error) {
	t.Helper()
	return h.r.Run(context.Background())
}

func (h *harness) items() []TrendItem {
	if h.store.doc == nil {
		return nil
	}
	return h.store.doc.Items
}

func ago(d time.Duration) time.Time { return trendsT0.Add(-d) }

func TestRefresh_Counting(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		posts func() []*posts.Post
		deny  []string
		prot  []string
		want  []TrendItem
	}{
		{"5 posts by 1 author do not trend", func() []*posts.Post {
			var ps []*posts.Post
			for i := 1; i <= 5; i++ {
				ps = append(ps, post(i, "a", ago(time.Duration(10-i)*time.Hour), "spam"))
			}
			return ps
		}, nil, nil, []TrendItem{}},
		{"3 authors trend with authors 3", func() []*posts.Post {
			return []*posts.Post{post(1, "a", ago(5*time.Hour), "launch"), post(2, "b", ago(4*time.Hour), "launch"), post(3, "c", ago(3*time.Hour), "launch"), post(4, "c", ago(2*time.Hour), "launch")}
		}, nil, nil, []TrendItem{{Tag: "launch", Posts: 4, Authors: 3}}},
		{"2 authors do not trend", func() []*posts.Post {
			return []*posts.Post{post(1, "a", ago(5*time.Hour), "x"), post(2, "b", ago(4*time.Hour), "x")}
		}, nil, nil, []TrendItem{}},
		{"a taken-down post is not counted", func() []*posts.Post {
			down := post(3, "c", ago(3*time.Hour), "launch")
			down.Moderation = posts.ModerationTakenDown
			return []*posts.Post{post(1, "a", ago(5*time.Hour), "launch"), post(2, "b", ago(4*time.Hour), "launch"), down}
		}, nil, nil, []TrendItem{}},
		{"a REPOST is not counted", func() []*posts.Post {
			rp := post(3, "c", ago(3*time.Hour), "launch")
			rp.Kind = posts.KindRepost
			return []*posts.Post{post(1, "a", ago(5*time.Hour), "launch"), post(2, "b", ago(4*time.Hour), "launch"), rp}
		}, nil, nil, []TrendItem{}},
		{"a protected author is not counted", func() []*posts.Post {
			return []*posts.Post{post(1, "a", ago(5*time.Hour), "launch"), post(2, "b", ago(4*time.Hour), "launch"), post(3, "p", ago(3*time.Hour), "launch")}
		}, nil, []string{"p"}, []TrendItem{}},
		{"a denylisted tag is absent (denylist is normalised)", func() []*posts.Post {
			return []*posts.Post{
				post(1, "a", ago(5*time.Hour), "bad", "ok"), post(2, "b", ago(4*time.Hour), "bad", "ok"), post(3, "c", ago(3*time.Hour), "bad", "ok"),
			}
		}, []string{" #BAD "}, nil, []TrendItem{{Tag: "ok", Posts: 3, Authors: 3}}},
		{"rank is authors, then posts, then tag", func() []*posts.Post {
			var ps []*posts.Post
			n := 0
			add := func(author string, tags ...string) {
				n++
				ps = append(ps, post(n, author, ago(time.Duration(100-n)*time.Minute), tags...))
			}
			for _, a := range []string{"a", "b", "c"} {
				add(a, "bb")
				add(a, "bb") // 6 posts, 3 authors
				add(a, "aa") // 3 posts, 3 authors
				add(a, "zz") // 3 posts, 3 authors
			}
			for _, a := range []string{"a", "b", "c", "d"} {
				add(a, "wide") // 4 authors wins
			}
			return ps
		}, nil, nil, []TrendItem{{Tag: "wide", Posts: 4, Authors: 4}, {Tag: "bb", Posts: 6, Authors: 3}, {Tag: "aa", Posts: 3, Authors: 3}, {Tag: "zz", Posts: 3, Authors: 3}}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			h := newHarness(t, true, func(c *RefresherConfig) { c.Denylist = tc.deny })
			h.scan.posts = tc.posts()
			for _, u := range tc.prot {
				h.prot.set[u] = true
			}
			res, err := h.run(t)
			if err != nil || res.Skipped != "" {
				t.Fatalf("res %+v err %v", res, err)
			}
			got := h.items()
			if len(got) != len(tc.want) {
				t.Fatalf("items = %+v, want %+v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("items[%d] = %+v, want %+v", i, got[i], tc.want[i])
				}
			}
			if h.store.puts != 1 {
				t.Errorf("writes = %d, want 1", h.store.puts)
			}
		})
	}
}

func TestRefresh_TopHundredOnly(t *testing.T) {
	t.Parallel()
	h := newHarness(t, true, nil)
	n := 0
	for i := 0; i < 150; i++ {
		for _, a := range []string{"a", "b", "c"} {
			n++
			h.scan.posts = append(h.scan.posts, post(n, a, ago(20*time.Hour).Add(time.Duration(n)*time.Second), fmt.Sprintf("t%03d", i)))
		}
	}
	if _, err := h.run(t); err != nil {
		t.Fatal(err)
	}
	if got := len(h.items()); got != maxTrendItems {
		t.Fatalf("items = %d, want %d", got, maxTrendItems)
	}
}

func TestRefresh_Switches(t *testing.T) {
	t.Parallel()
	t.Run("flag globally off: 0 reads, 0 writes", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, false, nil)
		h.scan.posts = []*posts.Post{post(1, "a", ago(time.Hour), "x")}
		res, err := h.run(t)
		if err != nil || res.Skipped != SkipFlagOff || h.store.gets != 0 || h.store.puts != 0 || h.scan.calls != 0 {
			t.Fatalf("res %+v err %v gets %d puts %d calls %d", res, err, h.store.gets, h.store.puts, h.scan.calls)
		}
		if !strings.Contains(h.logs.String(), `"reason":"flag_off"`) || !strings.Contains(h.logs.String(), `"msg":"trends_skipped"`) {
			t.Errorf("missing trends_skipped line: %s", h.logs)
		}
	})
	t.Run("percent 0 is a rollout, not a kill switch", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		h.r.flags = flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.Percent, Percent: 0})
		res, err := h.run(t)
		if err != nil || res.Skipped != "" || h.store.puts != 1 {
			t.Fatalf("res %+v err %v puts %d, want a normal run", res, err, h.store.puts)
		}
	})
	t.Run("nil flag checker is off", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		h.r.flags = nil
		if res, _ := h.run(t); res.Skipped != SkipFlagOff {
			t.Fatalf("res %+v", res)
		}
	})
	t.Run("readonly: 0 reads, 0 writes", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, func(c *RefresherConfig) { c.ReadOnly = true })
		res, err := h.run(t)
		if err != nil || res.Skipped != SkipReadonly || h.store.gets != 0 || h.store.puts != 0 {
			t.Fatalf("res %+v err %v", res, err)
		}
	})
}

func TestRefresh_FreshSkipAndWindow(t *testing.T) {
	t.Parallel()
	h := newHarness(t, true, nil)
	h.scan.posts = []*posts.Post{post(1, "a", ago(5*time.Hour), "x"), post(2, "b", ago(4*time.Hour), "x"), post(3, "c", ago(3*time.Hour), "x")}
	if res, err := h.run(t); err != nil || res.Skipped != "" {
		t.Fatalf("first run: %+v %v", res, err)
	}
	first := *h.store.doc
	if !first.WindowStart.Equal(trendsT0.Add(-24 * time.Hour)) {
		t.Errorf("first window start = %v, want now-24h", first.WindowStart)
	}
	if first.Watermark.ID != post(3, "", time.Time{}).ID || !first.Watermark.At.Equal(ago(3*time.Hour)) {
		t.Errorf("watermark = %+v, want the newest post read", first.Watermark)
	}
	// A Scheduler retry 5 minutes later: skipped as fresh, the list stays.
	h.clk.advance(5 * time.Minute)
	h.scan.posts = nil
	res, err := h.run(t)
	if err != nil || res.Skipped != SkipFresh || h.store.puts != 1 || len(h.store.doc.Items) != 1 {
		t.Fatalf("retry: %+v %v puts %d items %d, want skipped fresh with the list intact", res, err, h.store.puts, len(h.store.doc.Items))
	}
	// 12 h later it runs again, resuming at the watermark: the window starts there.
	h.clk.advance(12 * time.Hour)
	h.scan.posts = append(h.scan.posts, post(4, "a", trendsT0.Add(time.Hour), "y"))
	if res, err := h.run(t); err != nil || res.Skipped != "" {
		t.Fatalf("next day: %+v %v", res, err)
	}
	if !h.store.doc.WindowStart.Equal(ago(3 * time.Hour)) {
		t.Errorf("window start = %v, want the previous watermark", h.store.doc.WindowStart)
	}
}

func TestRefresh_Cap_Resume_And_StaleWatermark(t *testing.T) {
	t.Parallel()
	t.Run("2,500 new posts with the cap at 2,000: 2,000 counted, watermark at the 2,000th, next run continues", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		for i := 1; i <= 2500; i++ {
			h.scan.posts = append(h.scan.posts, post(i, fmt.Sprintf("u%d", i%7), ago(20*time.Hour).Add(time.Duration(i)*time.Second), "busy"))
		}
		res, err := h.run(t)
		if err != nil || !res.Backlog || res.PostsScanned != 2000 {
			t.Fatalf("res %+v err %v", res, err)
		}
		if h.store.doc.Watermark.ID != h.scan.posts[1999].ID || !h.store.doc.Backlog {
			t.Fatalf("watermark %+v backlog %v, want the 2,000th post", h.store.doc.Watermark, h.store.doc.Backlog)
		}
		if h.scan.calls != 4 { // 500 x 4
			t.Errorf("pages = %d, want 4", h.scan.calls)
		}
		// The very next call is NOT skipped as fresh: a backlog resumes at once.
		res, err = h.run(t)
		if err != nil || res.Skipped != "" || res.PostsScanned != 500 || res.Backlog {
			t.Fatalf("resume: %+v %v, want 500 posts and no backlog", res, err)
		}
		if h.store.doc.Watermark.ID != h.scan.posts[2499].ID {
			t.Errorf("watermark after resume = %+v", h.store.doc.Watermark)
		}
		if !strings.Contains(h.logs.String(), `"msg":"trends_backlog"`) {
			t.Error("missing trends_backlog line")
		}
	})
	t.Run("exactly the cap with no more posts is a backlog of one empty resume", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, func(c *RefresherConfig) { c.MaxPosts = 3 })
		for i := 1; i <= 3; i++ {
			h.scan.posts = append(h.scan.posts, post(i, "a", ago(time.Hour).Add(time.Duration(i)*time.Second), "x"))
		}
		res, _ := h.run(t)
		if !res.Backlog {
			t.Fatalf("res %+v", res)
		}
		res, _ = h.run(t)
		if res.Backlog || res.PostsScanned != 0 {
			t.Fatalf("resume res %+v, want an empty, finished run", res)
		}
	})
	t.Run("a watermark older than 48 h jumps to now-24h", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		h.store.doc = &TrendsDoc{ComputedAt: ago(60 * time.Hour), Watermark: Watermark{At: ago(60 * time.Hour), ID: "old"}}
		h.scan.posts = []*posts.Post{
			post(1, "a", ago(55*time.Hour), "stale"), post(2, "b", ago(50*time.Hour), "stale"), post(3, "c", ago(49*time.Hour), "stale"),
			post(4, "a", ago(10*time.Hour), "fresh"), post(5, "b", ago(9*time.Hour), "fresh"), post(6, "c", ago(8*time.Hour), "fresh"),
		}
		res, err := h.run(t)
		if err != nil || !res.WatermarkReset || res.PostsScanned != 3 {
			t.Fatalf("res %+v err %v, want the three recent posts only", res, err)
		}
		if got := h.items(); len(got) != 1 || got[0].Tag != "fresh" {
			t.Fatalf("items = %+v, want only #fresh", got)
		}
		if !strings.Contains(h.logs.String(), "trends_backlog_skipped") {
			t.Error("missing trends_backlog_skipped line")
		}
	})
	t.Run("an empty run advances the watermark to just behind now", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		if _, err := h.run(t); err != nil {
			t.Fatal(err)
		}
		if !h.store.doc.Watermark.At.Equal(trendsT0.Add(-emptySettle)) || len(h.store.doc.Items) != 0 || h.store.puts != 1 {
			t.Fatalf("doc %+v puts %d", h.store.doc, h.store.puts)
		}
	})
}

func TestRefresh_Failures(t *testing.T) {
	t.Parallel()
	t.Run("document read fails: error, nothing written", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		h.store.getErr = errors.New("unavailable")
		if _, err := h.run(t); err == nil || h.store.puts != 0 {
			t.Fatalf("err %v puts %d", err, h.store.puts)
		}
	})
	t.Run("first page fails: error, nothing written", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		h.scan.err = errors.New("deadline exceeded")
		if _, err := h.run(t); err == nil || h.store.puts != 0 {
			t.Fatalf("err %v puts %d", err, h.store.puts)
		}
	})
	t.Run("a later page fails: the partial list is written as a backlog and the run succeeds", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		for i := 1; i <= 800; i++ {
			h.scan.posts = append(h.scan.posts, post(i, fmt.Sprintf("u%d", i%5), ago(20*time.Hour).Add(time.Duration(i)*time.Second), "t"))
		}
		h.scan.errAfter = 1
		res, err := h.run(t)
		if err != nil || res.LaterPageErr == nil || !res.Backlog || res.PostsScanned != 500 {
			t.Fatalf("res %+v err %v", res, err)
		}
		if h.store.doc.Watermark.ID != h.scan.posts[499].ID || !h.store.doc.Backlog {
			t.Fatalf("doc %+v", h.store.doc)
		}
	})
	// The step deadline can expire while paging. Progress must still be saved: the Put keeps a reserve of the deadline.
	for _, tc := range []struct {
		name  string
		setup func(*fakeScanner)
	}{
		{"deadline reached between pages: stop paging as a backlog and still write", func(s *fakeScanner) { s.slowFirst = 200 * time.Millisecond }},
		{"a page runs into the reserve: its error is a later-page error and the write still lands", func(s *fakeScanner) { s.blockAfter = 1 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			h := newHarness(t, true, nil)
			for i := 1; i <= 900; i++ {
				h.scan.posts = append(h.scan.posts, post(i, fmt.Sprintf("u%d", i%5), ago(20*time.Hour).Add(time.Duration(i)*time.Second), "t"))
			}
			tc.setup(h.scan)
			// writeReserve + 150 ms: the first page leaves less than the reserve (slowFirst) or the second page gets 150 ms.
			ctx, cancel := context.WithTimeout(context.Background(), writeReserve+150*time.Millisecond)
			defer cancel()
			res, err := h.r.Run(ctx)
			if err != nil || !res.Backlog || res.PostsScanned != 500 || h.store.puts != 1 {
				t.Fatalf("res %+v err %v puts %d, want a backlog of 500 posts written once", res, err, h.store.puts)
			}
			if h.store.doc.Watermark.ID != h.scan.posts[499].ID || !h.store.doc.Backlog {
				t.Fatalf("doc %+v, want the watermark at the 500th post and backlog", h.store.doc)
			}
		})
	}
	t.Run("protected set unavailable: the run fails and nothing is written", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		h.scan.posts = []*posts.Post{post(1, "a", ago(time.Hour), "x")}
		h.prot.err = errors.New("stale")
		if _, err := h.run(t); err == nil || h.store.puts != 0 {
			t.Fatalf("err %v puts %d", err, h.store.puts)
		}
	})
	t.Run("a nil protected loader fails closed", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		h.scan.posts = []*posts.Post{post(1, "a", ago(time.Hour), "x")}
		h.r.protected = nil
		if _, err := h.run(t); err == nil || h.store.puts != 0 {
			t.Fatalf("err %v puts %d", err, h.store.puts)
		}
	})
	t.Run("protected set is read once per run, and not at all for an empty window", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		if _, err := h.run(t); err != nil || h.prot.n != 0 {
			t.Fatalf("empty window read the set %d times (err %v)", h.prot.n, err)
		}
		h2 := newHarness(t, true, nil)
		for i := 1; i <= 900; i++ {
			h2.scan.posts = append(h2.scan.posts, post(i, "a", ago(5*time.Hour).Add(time.Duration(i)*time.Second), "x"))
		}
		if _, err := h2.run(t); err != nil || h2.prot.n != 1 {
			t.Fatalf("set loads = %d (err %v), want 1", h2.prot.n, err)
		}
	})
	t.Run("the write fails: error", func(t *testing.T) {
		t.Parallel()
		h := newHarness(t, true, nil)
		h.store.putErr = errors.New("aborted")
		if _, err := h.run(t); err == nil {
			t.Fatal("want an error")
		}
	})
}

// TestRefresh_Budget: 1 read for the document + 1 for the hide list + the posts read + 1 write, via the log line's own counter fields.
func TestRefresh_Budget(t *testing.T) {
	t.Parallel()
	h := newHarness(t, true, nil)
	for i := 1; i <= 37; i++ {
		h.scan.posts = append(h.scan.posts, post(i, fmt.Sprintf("u%d", i%4), ago(5*time.Hour).Add(time.Duration(i)*time.Second), "x"))
	}
	if _, err := h.run(t); err != nil {
		t.Fatal(err)
	}
	line := lastLine(h.logs.String(), "trends_refresh")
	for _, want := range []string{`"fs_reads":39`, `"fs_writes":1`, `"trends_posts_scanned":37`, `"tags_kept":1`, `"backlog":false`} {
		if !strings.Contains(line, want) {
			t.Errorf("trends_refresh line lacks %s: %s", want, line)
		}
	}
	for _, banned := range []string{`"u1"`, `"u2"`, "uid"} {
		if strings.Contains(line, banned) {
			t.Errorf("trends_refresh line leaks %s", banned)
		}
	}
	// A fresh-skipped run: 1 read, 0 writes.
	h.clk.advance(time.Minute)
	if _, err := h.run(t); err != nil {
		t.Fatal(err)
	}
	line = lastLine(h.logs.String(), "trends_skipped")
	if !strings.Contains(line, `"fs_reads":1`) || !strings.Contains(line, `"fs_writes":0`) || !strings.Contains(line, `"reason":"fresh"`) {
		t.Errorf("fresh skip line: %s", line)
	}
}

func lastLine(logs, msg string) string {
	var last string
	for _, l := range strings.Split(logs, "\n") {
		if strings.Contains(l, `"msg":"`+msg+`"`) {
			last = l
		}
	}
	return last
}
