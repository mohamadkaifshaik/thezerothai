package search

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestTrendKey(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name, in, want string
	}{
		{"plain", "slur", "slur"},
		{"leading hash and case", " #SLUR ", "slur"},
		{"two hashes are dropped (before and after NFKC)", "##slur", "slur"},
		{"zero width joiner", "sl\u200dur", "slur"},
		{"zero width non-joiner", "s\u200cl\u200cur", "slur"},
		{"underscore", "s_l_u_r", "slur"},
		{"decomposed input equals the composed tag", "café", "café"},
		{"composed input", "café", "café"},
		{"fullwidth letters", "ｓｌｕｒ", "slur"},
		{"fullwidth hash", "＃slur", "slur"},
		{"mathematical bold letters", "\U0001d42c\U0001d425\U0001d42e\U0001d42b", "slur"},
		{"ligature folds to letters", "ﬁnd", "find"},
		{"all of them together", "#\uff33_L\u200d\u200cur", "slur"},
		{"devanagari is kept", "भारत", "भारत"},
		{"empty", "", ""},
		{"only a hash", "#", ""},
		{"only folded characters", "_\u200d\u200c_", ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := TrendKey(tc.in); got != tc.want {
				t.Errorf("TrendKey(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
	t.Run("idempotent", func(t *testing.T) {
		t.Parallel()
		for _, tc := range tests {
			if k := TrendKey(tc.in); TrendKey(k) != k {
				t.Errorf("TrendKey is not idempotent on %q: %q then %q", tc.in, k, TrendKey(k))
			}
		}
	})
}

func TestHideKey(t *testing.T) {
	t.Parallel()
	if _, err := HideKey("_\u200d"); !errors.Is(err, ErrEmptyTrendKey) {
		t.Errorf("empty key: %v", err)
	}
	if _, err := HideKey(repeat("a", 51)); !errors.Is(err, ErrTrendKeyTooLong) {
		t.Errorf("51 points: %v", err)
	}
	if k, err := HideKey(repeat("a", 50)); err != nil || len(k) != 50 {
		t.Errorf("50 points: %q %v", k, err)
	}
}

// --- the sweep ---

func threeAuthors(tags ...string) []*posts.Post {
	return []*posts.Post{
		post(1, "a", ago(5*time.Hour), tags...), post(2, "b", ago(4*time.Hour), tags...), post(3, "c", ago(3*time.Hour), tags...),
	}
}

func TestRefresh_HideListAndSkeletonDenylist(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		tags   []string
		deny   []string
		hidden []string
		want   []string
	}{
		{"a hidden key is dropped", []string{"bad", "ok"}, nil, []string{"bad"}, []string{"ok"}},
		{"the hide list is folded: a joiner variant in the posts is dropped", []string{"b\u200dad", "ok"}, nil, []string{"bad"}, []string{"ok"}},
		{"an underscore variant is dropped", []string{"b_a_d", "ok"}, nil, []string{"bad"}, []string{"ok"}},
		{"a fullwidth variant is dropped", []string{"ｂａｄ", "ok"}, nil, []string{"bad"}, []string{"ok"}},
		{"a denylist entry typed decomposed matches the stored composed tag", []string{"café", "ok"}, []string{"café"}, nil, []string{"ok"}},
		{"a denylist entry with a joiner matches the plain tag", []string{"bad", "ok"}, []string{"b\u200dad"}, nil, []string{"ok"}},
		{"the denylist and the hide list both apply", []string{"bad", "worse", "ok"}, []string{"bad"}, []string{"worse"}, []string{"ok"}},
		{"nothing hidden keeps everything", []string{"x", "y"}, nil, nil, []string{"x", "y"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			h := newHarness(t, true, func(c *RefresherConfig) { c.Denylist = tc.deny })
			h.store.hidden = tc.hidden
			h.scan.posts = threeAuthors(tc.tags...)
			if res, err := h.run(t); err != nil || res.Skipped != "" {
				t.Fatalf("res %+v err %v", res, err)
			}
			var got []string
			for _, it := range h.items() {
				got = append(got, it.Tag)
			}
			if !equal(got, tc.want) {
				t.Fatalf("tags = %v, want %v", got, tc.want)
			}
			if h.store.hideWrites != 0 {
				t.Error("the sweep must never write the hide list")
			}
		})
	}
}

func TestRefresh_HideListReadFailureWritesNothing(t *testing.T) {
	t.Parallel()
	h := newHarness(t, true, nil)
	h.store.hiddenErr = errors.New("unavailable")
	h.scan.posts = threeAuthors("bad")
	if _, err := h.run(t); err == nil || h.store.puts != 0 || h.scan.calls != 0 {
		t.Fatalf("err %v puts %d scan calls %d, want an error, nothing written and no post read", err, h.store.puts, h.scan.calls)
	}
}

// The hide list is read only by a run that will write: flag off, readonly and fresh skips never read it.
func TestRefresh_HideListReadIsSkippedWithTheSkips(t *testing.T) {
	t.Parallel()
	off := newHarness(t, false, nil)
	if res, _ := off.run(t); res.Skipped != SkipFlagOff || off.store.hiddenGets != 0 {
		t.Errorf("flag off: %+v hidden gets %d", res, off.store.hiddenGets)
	}
	ro := newHarness(t, true, func(c *RefresherConfig) { c.ReadOnly = true })
	if res, _ := ro.run(t); res.Skipped != SkipReadonly || ro.store.hiddenGets != 0 {
		t.Errorf("readonly: %+v hidden gets %d", res, ro.store.hiddenGets)
	}
	h := newHarness(t, true, nil)
	h.scan.posts = threeAuthors("x")
	if _, err := h.run(t); err != nil || h.store.hiddenGets != 1 {
		t.Fatalf("first run: err %v hidden gets %d, want 1", err, h.store.hiddenGets)
	}
	h.clk.advance(time.Minute)
	if res, _ := h.run(t); res.Skipped != SkipFresh || h.store.hiddenGets != 1 {
		t.Errorf("fresh skip: %+v hidden gets %d, want still 1", res, h.store.hiddenGets)
	}
}

// --- GetTrends ---

func hideSvc(t *testing.T, store TrendsStore, clk *fakeClock, deny []string) *service {
	t.Helper()
	reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.On}, flags.Spec{Name: FlagSearch, Mode: flags.On})
	// The denylist option is given before WithTrends on purpose: the order of options must not matter.
	return New(reg, WithTrendsDenylist(deny), WithTrends(store, clk.now)).(*service)
}

func TestTrends_HiddenAndDenylistedAreDroppedAndRanksRenumbered(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		deny   []string
		hidden []string
		prefix string
		want   []string
		ranks  []int32
	}{
		{"nothing hidden", nil, nil, "", []string{"launch", "lakers", "go", "lang", "भारत"}, []int32{1, 2, 3, 4, 5}},
		{"a hidden tag leaves no gap", nil, []string{"lakers"}, "", []string{"launch", "go", "lang", "भारत"}, []int32{1, 2, 3, 4}},
		{"the first one hidden", nil, []string{"launch"}, "", []string{"lakers", "go", "lang", "भारत"}, []int32{1, 2, 3, 4}},
		{"a denylisted tag leaves no gap", []string{"#GO"}, nil, "", []string{"launch", "lakers", "lang", "भारत"}, []int32{1, 2, 3, 4}},
		{"both", []string{"go"}, []string{"launch"}, "", []string{"lakers", "lang", "भारत"}, []int32{1, 2, 3}},
		{"a prefix keeps gaps of the served list", nil, []string{"lakers"}, "la", []string{"launch", "lang"}, []int32{1, 3}},
		{"a hide list entry written in another fold still matches", nil, []string{"L_a\u200dkers"}, "", []string{"launch", "go", "lang", "भारत"}, []int32{1, 2, 3, 4}},
		{"everything hidden", nil, []string{"launch", "lakers", "go", "lang", "भारत"}, "", nil, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store := &fakeTrendsStore{doc: sampleDoc(), hidden: tc.hidden}
			svc := hideSvc(t, store, &fakeClock{t: trendsT0}, tc.deny)
			got, err := svc.Trends(context.Background(), "u1", 0, tc.prefix)
			if err != nil {
				t.Fatal(err)
			}
			if !equal(tags(got), tc.want) {
				t.Fatalf("tags = %v, want %v", tags(got), tc.want)
			}
			for i, tr := range got.Trends {
				if tr.Rank != tc.ranks[i] {
					t.Errorf("rank[%d] = %d, want %d", i, tr.Rank, tc.ranks[i])
				}
			}
		})
	}
}

// A stored tag with a joiner in it (a variant the ring posts) is dropped by the plain-form entry.
func TestTrends_SkeletonMatchesStoredVariants(t *testing.T) {
	t.Parallel()
	doc := &TrendsDoc{ComputedAt: trendsT0, Items: []TrendItem{
		{Tag: "sl\u200dur", Posts: 9, Authors: 5}, {Tag: "s_lur", Posts: 8, Authors: 5}, {Tag: "ok", Posts: 7, Authors: 4},
	}}
	svc := hideSvc(t, &fakeTrendsStore{doc: doc, hidden: []string{"slur"}}, &fakeClock{t: trendsT0}, nil)
	got, err := svc.Trends(context.Background(), "u1", 0, "")
	if err != nil || !equal(tags(got), []string{"ok"}) || got.Trends[0].Rank != 1 {
		t.Fatalf("got %v err %v, want only ok at rank 1", tags(got), err)
	}
}

// A hide reaches the instance when its copy expires (staleness bound: 10 min), and not before.
func TestTrends_HideAppliesAtTheNextLoad(t *testing.T) {
	t.Parallel()
	clk := &fakeClock{t: trendsT0}
	store := &fakeTrendsStore{doc: sampleDoc()}
	svc := hideSvc(t, store, clk, nil)
	first := func() string {
		got, err := svc.Trends(context.Background(), "u1", 0, "")
		if err != nil {
			t.Fatal(err)
		}
		return got.Trends[0].Tag
	}
	if first() != "launch" {
		t.Fatal("setup")
	}
	if _, err := store.Hide(context.Background(), "#Launch"); err != nil {
		t.Fatal(err)
	}
	clk.advance(trendsCacheTTL - time.Second)
	if first() != "launch" {
		t.Fatal("inside the TTL the old copy is served")
	}
	clk.advance(time.Second)
	if first() != "lakers" {
		t.Fatal("after the TTL the hide applies")
	}
	if _, err := store.Unhide(context.Background(), "launch"); err != nil {
		t.Fatal(err)
	}
	clk.advance(trendsCacheTTL)
	if first() != "launch" {
		t.Fatal("after an unhide and the TTL the tag is back")
	}
}

// A failed hide-list load returns the error and caches nothing: an unknown list is never served as empty.
func TestTrends_HideListFailureIsNotCachedAndNotServedAsEmpty(t *testing.T) {
	t.Parallel()
	store := &fakeTrendsStore{doc: sampleDoc(), hidden: []string{"launch"}, hiddenErr: errors.New("boom")}
	svc := hideSvc(t, store, &fakeClock{t: trendsT0}, nil)
	if got, err := svc.Trends(context.Background(), "u1", 0, ""); err == nil {
		t.Fatalf("want an error, got %v", tags(got))
	}
	store.hiddenErr = nil
	got, err := svc.Trends(context.Background(), "u1", 0, "")
	if err != nil || tags(got)[0] != "lakers" {
		t.Fatalf("after recovery: %v %v, want launch hidden", tags(got), err)
	}
}

func TestTrends_LoadBudget(t *testing.T) {
	t.Parallel()
	svc := hideSvc(t, &fakeTrendsStore{doc: sampleDoc(), hidden: []string{"go"}}, &fakeClock{t: trendsT0}, nil)
	ctx, c := budget.WithCounter(context.Background())
	if _, err := svc.Trends(ctx, "u1", 0, ""); err != nil || c.Reads() != 2 || c.Writes() != 0 {
		t.Fatalf("cold: err %v reads %d writes %d, want 2 and 0 (the interceptor adds 1 outside)", err, c.Reads(), c.Writes())
	}
	ctx, c = budget.WithCounter(context.Background())
	if _, err := svc.Trends(ctx, "u1", 0, ""); err != nil || c.Reads() != 0 {
		t.Fatalf("warm: err %v reads %d, want 0", err, c.Reads())
	}
}

func TestFakeHideRules(t *testing.T) {
	t.Parallel()
	f := &fakeTrendsStore{}
	for i := range maxHiddenTags {
		if _, err := f.Hide(context.Background(), fmt.Sprintf("t%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.Hide(context.Background(), "one-too-many"); !errors.Is(err, ErrHiddenFull) {
		t.Fatalf("101st key: %v", err)
	}
}
