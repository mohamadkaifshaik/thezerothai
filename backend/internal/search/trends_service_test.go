package search

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// fakeTrendsStore is an in-memory TrendsStore that counts like the Firestore one: Get bills 1 read (a missing document
// too), Put 1 write.
type fakeTrendsStore struct {
	mu     sync.Mutex
	doc    *TrendsDoc
	getErr error
	putErr error
	gets   int
	puts   int
}

func (f *fakeTrendsStore) Get(ctx context.Context) (*TrendsDoc, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gets++
	budget.FromContext(ctx).AddReads(1)
	if f.getErr != nil {
		return nil, f.getErr
	}
	if f.doc == nil {
		return nil, nil
	}
	d := *f.doc
	return &d, nil
}

func (f *fakeTrendsStore) Put(ctx context.Context, d *TrendsDoc) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.putErr != nil {
		return f.putErr
	}
	f.puts++
	budget.FromContext(ctx).AddWrites(1)
	cp := *d
	f.doc = &cp
	return nil
}

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

var t0 = time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC)

func sampleDoc() *TrendsDoc {
	return &TrendsDoc{ComputedAt: t0.Add(-2 * time.Hour), Items: []TrendItem{
		{Tag: "launch", Posts: 9, Authors: 5}, {Tag: "lakers", Posts: 7, Authors: 4}, {Tag: "go", Posts: 6, Authors: 4},
		{Tag: "lang", Posts: 5, Authors: 3}, {Tag: "भारत", Posts: 4, Authors: 3},
	}}
}

func trendsSvc(t *testing.T, store TrendsStore, clk *fakeClock) *service {
	t.Helper()
	reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.On}, flags.Spec{Name: FlagSearch, Mode: flags.On})
	return New(reg, WithTrends(store, clk.now)).(*service)
}

func tags(r *searchv1.GetTrendsResponse) []string {
	var out []string
	for _, tr := range r.Trends {
		out = append(out, tr.Tag)
	}
	return out
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestTrends_ListPrefixLimitAndRanks(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		limit  int32
		prefix string
		want   []string
		ranks  []int32
	}{
		{"default limit returns all five in rank order", 0, "", []string{"launch", "lakers", "go", "lang", "भारत"}, []int32{1, 2, 3, 4, 5}},
		{"limit 2", 2, "", []string{"launch", "lakers"}, []int32{1, 2}},
		{"prefix la keeps rank gaps, in rank order", 0, "la", []string{"launch", "lakers", "lang"}, []int32{1, 2, 4}},
		{"prefix with a leading hash", 0, "#LA", []string{"launch", "lakers", "lang"}, []int32{1, 2, 4}},
		{"prefix and limit", 2, "la", []string{"launch", "lakers"}, []int32{1, 2}},
		{"prefix matching nothing", 0, "zzz", nil, nil},
		{"indic prefix", 0, "भा", []string{"भारत"}, []int32{5}},
		{"limit above the maximum is clamped, not refused", 500, "", []string{"launch", "lakers", "go", "lang", "भारत"}, []int32{1, 2, 3, 4, 5}},
		{"characters outside the tag class match nothing", 0, "la!", nil, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			clk := &fakeClock{t: t0}
			svc := trendsSvc(t, &fakeTrendsStore{doc: sampleDoc()}, clk)
			got, err := svc.Trends(context.Background(), "u1", tc.limit, tc.prefix)
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
			if !got.ComputedAt.AsTime().Equal(sampleDoc().ComputedAt) {
				t.Errorf("computed_at = %v", got.ComputedAt.AsTime())
			}
		})
	}
	t.Run("post_count carries the posts", func(t *testing.T) {
		t.Parallel()
		svc := trendsSvc(t, &fakeTrendsStore{doc: sampleDoc()}, &fakeClock{t: t0})
		got, _ := svc.Trends(context.Background(), "u1", 1, "")
		if got.Trends[0].PostCount != 9 {
			t.Errorf("post_count = %d, want 9", got.Trends[0].PostCount)
		}
	})
}

func TestTrends_NoDocumentIsAnEmptyList(t *testing.T) {
	t.Parallel()
	store := &fakeTrendsStore{}
	svc := trendsSvc(t, store, &fakeClock{t: t0})
	got, err := svc.Trends(context.Background(), "u1", 0, "")
	if err != nil || len(got.Trends) != 0 || got.ComputedAt != nil {
		t.Fatalf("got %+v err %v, want an empty answer with computed_at unset", got, err)
	}
	// The missing document is cached too: the next call within the TTL reads nothing.
	if _, err := svc.Trends(context.Background(), "u1", 0, ""); err != nil || store.gets != 1 {
		t.Fatalf("gets = %d err %v, want 1", store.gets, err)
	}
}

func TestTrends_Validation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		limit  int32
		prefix string
		field  string
	}{
		{"negative limit", -1, "", "limit"},
		{"control character in the prefix", 0, "la\x07", "prefix"},
		{"bidi override in the prefix", 0, "la\u202e", "prefix"},
		{"51 code points after the hash", 0, "#" + string(make([]rune, 0)) + repeat("a", 51), "prefix"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store := &fakeTrendsStore{doc: sampleDoc()}
			svc := trendsSvc(t, store, &fakeClock{t: t0})
			_, err := svc.Trends(context.Background(), "u1", tc.limit, tc.prefix)
			ae := apiErr(t, err)
			if ae.Code != connect.CodeInvalidArgument || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != tc.field {
				t.Fatalf("err = %+v, want VALIDATION field=%s", ae, tc.field)
			}
			if store.gets != 0 {
				t.Errorf("a rejected request read %d documents, want 0", store.gets)
			}
		})
	}
	t.Run("50 code points after the hash is accepted", func(t *testing.T) {
		t.Parallel()
		svc := trendsSvc(t, &fakeTrendsStore{doc: sampleDoc()}, &fakeClock{t: t0})
		if _, err := svc.Trends(context.Background(), "u1", 0, "#"+repeat("a", 50)); err != nil {
			t.Fatal(err)
		}
	})
}

func repeat(s string, n int) string {
	out := ""
	for range n {
		out += s
	}
	return out
}

// TestTrends_CacheTTLAndBudget: cold = the document read (1, plus the interceptor's 1 outside this layer = 2), warm = 0,
// and the copy expires after exactly 10 minutes by the injected clock.
func TestTrends_CacheTTLAndBudget(t *testing.T) {
	t.Parallel()
	clk := &fakeClock{t: t0}
	store := &fakeTrendsStore{doc: sampleDoc()}
	svc := trendsSvc(t, store, clk)
	call := func() int64 {
		ctx, c := budget.WithCounter(context.Background())
		if _, err := svc.Trends(ctx, "u1", 0, ""); err != nil {
			t.Fatal(err)
		}
		return c.Reads()
	}
	if r := call(); r != 1 {
		t.Fatalf("cold reads = %d, want 1 (the document; the interceptor's read is counted outside the service)", r)
	}
	for range 3 {
		if r := call(); r != 0 {
			t.Fatalf("warm reads = %d, want 0", r)
		}
	}
	clk.advance(trendsCacheTTL - time.Second)
	if r := call(); r != 0 {
		t.Fatalf("just inside the TTL: reads = %d, want 0", r)
	}
	// A refresh lands; the instance still serves the old list until the TTL runs out.
	store.doc = &TrendsDoc{ComputedAt: t0, Items: []TrendItem{{Tag: "new", Posts: 3, Authors: 3}}}
	got, _ := svc.Trends(context.Background(), "u1", 0, "")
	if tags(got)[0] != "launch" {
		t.Fatalf("inside the TTL the old list must be served, got %v", tags(got))
	}
	clk.advance(time.Second)
	if r := call(); r != 1 {
		t.Fatalf("after the TTL: reads = %d, want 1", r)
	}
	got, _ = svc.Trends(context.Background(), "u1", 0, "")
	if tags(got)[0] != "new" {
		t.Fatalf("after the TTL the new list must be served, got %v", tags(got))
	}
}

func TestTrends_StoreErrorIsNotCached(t *testing.T) {
	t.Parallel()
	store := &fakeTrendsStore{getErr: errors.New("boom"), doc: sampleDoc()}
	svc := trendsSvc(t, store, &fakeClock{t: t0})
	if _, err := svc.Trends(context.Background(), "u1", 0, ""); err == nil {
		t.Fatal("want an error")
	}
	store.getErr = nil
	if got, err := svc.Trends(context.Background(), "u1", 0, ""); err != nil || len(got.Trends) == 0 {
		t.Fatalf("after recovery: %v %v", got, err)
	}
}

// TestTrends_ConcurrentColdCallersShareOneRead: the singleflight bound, "one read per instance per TTL".
func TestTrends_ConcurrentColdCallersShareOneRead(t *testing.T) {
	t.Parallel()
	store := &fakeTrendsStore{doc: sampleDoc()}
	svc := trendsSvc(t, store, &fakeClock{t: t0})
	var wg sync.WaitGroup
	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := svc.Trends(context.Background(), "u1", 0, ""); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if store.gets > 2 { // a caller that arrives after the first load finished is a cache hit; never 20
		t.Fatalf("store reads = %d for 20 concurrent callers, want 1 (2 tolerated for a late race)", store.gets)
	}
}

func TestTrends_FlagOffReadsNothing(t *testing.T) {
	t.Parallel()
	store := &fakeTrendsStore{doc: sampleDoc()}
	reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.Off})
	svc := New(reg, WithTrends(store, nil))
	_, err := svc.Trends(context.Background(), "u1", 0, "")
	ae := apiErr(t, err)
	if ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != FlagTrends || store.gets != 0 {
		t.Fatalf("err %+v gets %d, want FEATURE_DISABLED trends and 0 reads", ae, store.gets)
	}
}

func TestTrends_NotWiredIsUnimplemented(t *testing.T) {
	t.Parallel()
	reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.On})
	_, err := New(reg).Trends(context.Background(), "u1", 0, "")
	if ae := apiErr(t, err); ae.Code != connect.CodeUnimplemented {
		t.Fatalf("code = %v", ae.Code)
	}
}
