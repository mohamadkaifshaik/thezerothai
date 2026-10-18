package posts

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"slices"
	"sort"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// fakeRemovalSource is an in-memory RemovalSource with the Firestore contract: ordered by At, strictly after the
// bound, Limit honoured, reads = max(len, 1) charged to the budget counter in ctx.
type fakeRemovalSource struct {
	entries map[string]RemovalEntry
	queries []string
	err     error
	// reads counts the documents the shared cache queries (Newest, After) returned; windowReads those of Window.
	reads, windowReads int64
	windowAuthors      [][]string
	// block, when set, is received from before each query answers (tests use it to hold a refresh open).
	block chan struct{}
	// entered is signalled when a query starts waiting on block.
	entered chan struct{}
}

func newFakeRemovalSource() *fakeRemovalSource {
	return &fakeRemovalSource{entries: map[string]RemovalEntry{}}
}

// testAuthor is the author put() gives entries; the rig's default scope is exactly this author.
const testAuthor = "a"

func (f *fakeRemovalSource) put(id string, st RemovalState, at time.Time) {
	f.putBy(id, testAuthor, st, at)
}

func (f *fakeRemovalSource) putBy(id, author string, st RemovalState, at time.Time) {
	f.entries[id] = RemovalEntry{PostID: id, AuthorID: author, State: st, At: at}
}

func (f *fakeRemovalSource) query(ctx context.Context, name string, keep func(RemovalEntry) bool, desc bool, limit int) ([]RemovalEntry, error) {
	f.queries = append(f.queries, name)
	if f.block != nil {
		if f.entered != nil {
			f.entered <- struct{}{}
		}
		select {
		case <-f.block:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if f.err != nil {
		return nil, f.err
	}
	var all []RemovalEntry
	for _, e := range f.entries {
		if keep(e) {
			all = append(all, e)
		}
	}
	sort.Slice(all, func(i, j int) bool {
		if desc {
			return afterPos(all[i].At, all[i].PostID, all[j].At, all[j].PostID)
		}
		return afterPos(all[j].At, all[j].PostID, all[i].At, all[i].PostID)
	})
	if len(all) > limit {
		all = all[:limit]
	}
	n := int64(max(len(all), 1))
	budget.FromContext(ctx).AddReads(n)
	if name == "window" {
		f.windowReads += n
	} else {
		f.reads += n
	}
	return all, nil
}

func (f *fakeRemovalSource) Window(ctx context.Context, authors []string, after, upTo time.Time, limit int) ([]RemovalEntry, error) {
	f.windowAuthors = append(f.windowAuthors, authors)
	return f.query(ctx, "window", func(e RemovalEntry) bool {
		return slices.Contains(authors, e.AuthorID) && e.At.After(after) && !e.At.After(upTo)
	}, true, limit)
}

func (f *fakeRemovalSource) Newest(ctx context.Context, floor time.Time, limit int) ([]RemovalEntry, error) {
	return f.query(ctx, "newest", func(e RemovalEntry) bool { return e.At.After(floor) }, true, limit)
}

func (f *fakeRemovalSource) After(ctx context.Context, afterAt time.Time, afterID string, limit int) ([]RemovalEntry, error) {
	return f.query(ctx, "after", func(e RemovalEntry) bool { return afterPos(e.At, e.PostID, afterAt, afterID) }, false, limit)
}

type removalRig struct {
	winSeen int64
	src     *fakeRemovalSource
	log     *RemovalLog
	now     time.Time
}

const testTTL = 60 * time.Second

// The rig clock sits after defaultRemovalAuthorScopedFrom (2026-10-25) so window queries are allowed; bump with it.
func newRemovalRig() *removalRig {
	r := &removalRig{src: newFakeRemovalSource(), now: time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)}
	r.log = NewRemovalLog(r.src, testTTL, func() time.Time { return r.now })
	return r
}

// since calls RemovedSince for the feed that shows testAuthor and returns the ids, truncation and the reads the
// shared cache refresh cost (the detached counter's reads; the window query is r.src.windowReads).
func (r *removalRig) since(t *testing.T, cutoff time.Time) (ids []string, truncated bool, reads int64) {
	t.Helper()
	return r.sinceFor(t, cutoff, testAuthor)
}

func (r *removalRig) sinceFor(t *testing.T, cutoff time.Time, authors ...string) (ids []string, truncated bool, reads int64) {
	t.Helper()
	ctx, c := budget.WithCounter(context.Background())
	before := r.src.reads
	ids, truncated, err := r.log.RemovedSince(ctx, cutoff, RemovalScope{Authors: authors})
	if err != nil {
		t.Fatalf("RemovedSince: %v", err)
	}
	if c.Reads() != r.windowDelta() {
		t.Fatalf("request counter = %d reads, want only the window query's (the shared refresh is detached)", c.Reads())
	}
	return ids, truncated, r.src.reads - before
}

// windowDelta is the reads the request counter must show after a call: the window query's, which the fake tallies
// cumulatively (r.winSeen is what earlier calls already accounted for).
func (r *removalRig) windowDelta() int64 {
	d := r.src.windowReads - r.winSeen
	r.winSeen = r.src.windowReads
	return d
}

func TestRemovalLog_ReadCounts(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	cutoff := r.now.Add(-time.Hour)

	// Empty log: cold = 1 read, warm hit = 0.
	ids, trunc, reads := r.since(t, cutoff)
	if len(ids) != 0 || trunc || reads != 1 {
		t.Fatalf("cold empty: ids=%v trunc=%v reads=%d, want none/false/1", ids, trunc, reads)
	}
	r.now = r.now.Add(testTTL - time.Second)
	if _, _, reads = r.since(t, cutoff); reads != 0 {
		t.Fatalf("warm hit reads = %d, want 0", reads)
	}
	// After the TTL the incremental query costs 1 read (empty answer) and is one "after" query, not a reload.
	r.now = r.now.Add(2 * time.Second)
	if _, _, reads = r.since(t, cutoff); reads != 1 {
		t.Fatalf("incremental empty reads = %d, want 1", reads)
	}
	if want := []string{"newest", "after"}; !reflect.DeepEqual(r.src.queries, want) {
		t.Fatalf("queries = %v, want %v", r.src.queries, want)
	}
}

// TestRemovalLog_WarmInstanceSeesLaterEntryAfterTTL is plan T15 (e): an entry written after the cache filled is
// not served before the TTL expires and is served right after (fake clock).
func TestRemovalLog_WarmInstanceSeesLaterEntryAfterTTL(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	cutoff := r.now.Add(-time.Hour)
	r.src.put("p1", RemovalRemoved, r.now.Add(-time.Minute))
	if ids, _, reads := r.since(t, cutoff); !reflect.DeepEqual(ids, []string{"p1"}) || reads != 1 {
		t.Fatalf("fill: ids=%v reads=%d", ids, reads)
	}

	r.src.put("p2", RemovalRemoved, r.now.Add(time.Second)) // written after the cache filled
	r.now = r.now.Add(testTTL - time.Second)
	if ids, _, reads := r.since(t, cutoff); !reflect.DeepEqual(ids, []string{"p1"}) || reads != 0 {
		t.Fatalf("before TTL: ids=%v reads=%d, want p1 only, 0 reads", ids, reads)
	}
	r.now = r.now.Add(time.Second) // TTL reached
	ids, _, reads := r.since(t, cutoff)
	if !reflect.DeepEqual(ids, []string{"p2", "p1"}) {
		t.Fatalf("after TTL: ids=%v, want [p2 p1] (newest first)", ids)
	}
	// p1 (At = lastSeen) is not read again: the query starts strictly after the last entry seen.
	if reads != 1 {
		t.Fatalf("incremental read cost = %d, want 1", reads)
	}
}

func TestRemovalLog_Filtering(t *testing.T) {
	t.Parallel()
	base := time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name      string
		entries   []RemovalEntry
		cutoff    time.Time
		want      []string
		wantTrunc bool
		wantReads int64
	}{
		{
			name: "only entries strictly newer than the cutoff, newest first",
			entries: []RemovalEntry{
				{PostID: "a", State: RemovalRemoved, At: base.Add(-3 * time.Hour)},
				{PostID: "b", State: RemovalRemoved, At: base.Add(-2 * time.Hour)},
				{PostID: "c", State: RemovalRemoved, At: base.Add(-time.Hour)},
			},
			cutoff: base.Add(-2 * time.Hour), want: []string{"c"}, wantReads: 3,
		},
		{
			name: "a restored post is not listed",
			entries: []RemovalEntry{
				{PostID: "a", State: RemovalRestored, At: base.Add(-time.Minute)},
				{PostID: "b", State: RemovalRemoved, At: base.Add(-2 * time.Minute)},
			},
			cutoff: base.Add(-time.Hour), want: []string{"b"}, wantReads: 2,
		},
		{
			name:    "empty log",
			entries: nil, cutoff: base.Add(-time.Hour), want: nil, wantReads: 1,
		},
		{
			name:    "cutoff older than the retention floor is not answerable even for an empty log",
			entries: nil, cutoff: base.Add(-RemovalRetention - time.Hour), wantTrunc: true, wantReads: 1,
		},
		{
			name: "ties on At are ordered by post id",
			entries: []RemovalEntry{
				{PostID: "a", State: RemovalRemoved, At: base.Add(-time.Minute)},
				{PostID: "b", State: RemovalRemoved, At: base.Add(-time.Minute)},
			},
			cutoff: base.Add(-time.Hour), want: []string{"b", "a"}, wantReads: 2,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r := newRemovalRig()
			r.now = base
			for _, e := range tt.entries {
				r.src.put(e.PostID, e.State, e.At)
			}
			ids, trunc, reads := r.since(t, tt.cutoff)
			if !reflect.DeepEqual(ids, tt.want) || trunc != tt.wantTrunc || reads != tt.wantReads {
				t.Fatalf("ids=%v trunc=%v reads=%d, want %v/%v/%d", ids, trunc, reads, tt.want, tt.wantTrunc, tt.wantReads)
			}
		})
	}
}

// TestRemovalLog_RestoreThenRehide: the same post id moves REMOVED -> RESTORED -> REMOVED with newer timestamps and
// a warm instance follows each step (a delete would never be seen by a createdAt query; that is why restores write).
func TestRemovalLog_RestoreThenRehide(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	cutoff := r.now.Add(-time.Hour)
	r.src.put("p", RemovalRemoved, r.now.Add(-time.Minute))
	if ids, _, _ := r.since(t, cutoff); !reflect.DeepEqual(ids, []string{"p"}) {
		t.Fatalf("hidden: %v", ids)
	}
	r.now = r.now.Add(testTTL)
	r.src.put("p", RemovalRestored, r.now.Add(-time.Second))
	if ids, _, _ := r.since(t, cutoff); len(ids) != 0 {
		t.Fatalf("restored but still listed: %v", ids)
	}
	r.now = r.now.Add(testTTL)
	r.src.put("p", RemovalRemoved, r.now.Add(-time.Second))
	if ids, _, _ := r.since(t, cutoff); !reflect.DeepEqual(ids, []string{"p"}) {
		t.Fatalf("re-hidden not listed: %v", ids)
	}
}

func TestRemovalLog_BurstReloadsNewestAndTruncatesOldTokens(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	start := r.now
	old := start.Add(-time.Hour)
	if _, _, reads := r.since(t, old); reads != 1 {
		t.Fatalf("cold reads = %d", reads)
	}

	// A suspension logs 120 posts, half a second apart, inside one TTL.
	r.now = start.Add(testTTL)
	for i := range 120 {
		r.src.put(fmt.Sprintf("p%03d", i), RemovalRemoved, start.Add(time.Duration(i+1)*time.Second/2))
	}
	r.src.queries = nil
	ids, trunc, reads := r.since(t, old)
	if !trunc || ids != nil {
		t.Fatalf("burst with an old token: ids=%d trunc=%v, want truncated (the log cannot list 120)", len(ids), trunc)
	}
	// A full incremental page (50) is followed by a reload of the newest 50, never paging forward; the old token
	// then asks the window query for the rest, which says there is more than the 50 cached hits allow.
	if want := []string{"after", "newest", "window"}; !reflect.DeepEqual(r.src.queries, want) {
		t.Fatalf("queries = %v, want %v", r.src.queries, want)
	}
	if reads != RemovalWorstReads {
		t.Fatalf("burst reads = %d, want %d (the documented worst case)", reads, RemovalWorstReads)
	}
	// The burst is behind lastSeen now: the next TTL costs one read, not another reload.
	r.now = r.now.Add(testTTL)
	if _, _, reads = r.since(t, old); reads != 1 {
		t.Fatalf("TTL after the burst reads = %d, want 1", reads)
	}

	// A token issued after the burst's first 70 entries is covered by the newest 50 and gets an answer.
	cutoff := start.Add(71 * time.Second / 2) // p070 is At = 35.5 s, the oldest of the newest 50: p071..p119 are newer
	ids, trunc, reads = r.since(t, cutoff)
	if trunc || len(ids) != 49 || reads != 0 {
		t.Fatalf("recent token: ids=%d trunc=%v reads=%d, want 49/false/0", len(ids), trunc, reads)
	}
	if ids[0] != "p119" {
		t.Fatalf("newest first, got %s", ids[0])
	}
	// A cutoff just below the oldest loaded entry is below the cache's coverage: the window query finds p070 (already
	// cached) and nothing else, so the answer is complete: 50 ids, no reset.
	if ids, trunc, _ = r.since(t, cutoff.Add(-time.Second/2)); trunc || len(ids) != 50 {
		t.Fatalf("cutoff just below the cache: ids=%d trunc=%v, want 50/false", len(ids), trunc)
	}
	// A cutoff that leaves more than 50 matches in total cannot be listed: truncated.
	if _, trunc, _ = r.since(t, cutoff.Add(-5*time.Second)); !trunc {
		t.Fatal("more than 50 matches must truncate")
	}
}

func TestRemovalLog_KeepsAtMostRemovalKeep(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	start := r.now
	cutoff := start.Add(-time.Hour)
	r.since(t, cutoff)
	// Trickle in 40 entries per TTL for 8 TTLs; the instance keeps the newest removalKeep and the floor rises.
	n := 0
	for range 8 {
		r.now = r.now.Add(testTTL)
		for range 40 {
			n++
			r.src.put(fmt.Sprintf("q%04d", n), RemovalRemoved, r.now.Add(-time.Second))
		}
		r.since(t, r.now)
	}
	if got := len(r.log.entries); got > removalKeep {
		t.Fatalf("entries = %d, want <= %d", got, removalKeep)
	}
	if _, trunc, _ := r.since(t, cutoff); !trunc {
		t.Fatal("a token older than the dropped entries must be truncated")
	}
}

func TestRemovalLog_SourceErrorIsReturnedAndRetried(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	boom := errors.New("boom")
	r.src.err = boom
	if _, _, err := r.log.RemovedSince(context.Background(), r.now.Add(-time.Hour), RemovalScope{Authors: []string{testAuthor}}); !errors.Is(err, boom) {
		t.Fatalf("err = %v, want boom", err)
	}
	r.src.err = nil
	r.src.put("p", RemovalRemoved, r.now.Add(-time.Minute))
	ids, _, _ := r.since(t, r.now.Add(-time.Hour))
	if !reflect.DeepEqual(ids, []string{"p"}) {
		t.Fatalf("after recovery ids=%v", ids)
	}
}

func TestRemovalRetention_OutlivesDefaultTokenTTL(t *testing.T) {
	t.Parallel()
	// config.TimelineTokenTTL defaults to 720 h; the reader subtracts at most about 2.5 minutes and Firestore TTL
	// deletes up to 24 h late, so retention must exceed 30 days by more than that.
	if RemovalRetention < 30*24*time.Hour+time.Hour {
		t.Fatalf("RemovalRetention = %v, too short for a 30-day since token", RemovalRetention)
	}
}

// TestRemovalLog_SharedTimestamp: a 250-post batch commits with one server timestamp, so a whole suspension page
// shares one At. The strict "> cutoff" rule and the coverage floor must still give a complete answer or truncate.
func TestRemovalLog_SharedTimestamp(t *testing.T) {
	t.Parallel()
	r := newRemovalRig()
	at := r.now.Add(-10 * time.Second)
	for i := range 30 {
		r.src.put(fmt.Sprintf("p%02d", i), RemovalRemoved, at)
	}
	ids, trunc, _ := r.since(t, at.Add(-time.Second))
	if trunc || len(ids) != 30 {
		t.Fatalf("30 entries at one instant: ids=%d trunc=%v, want 30/false", len(ids), trunc)
	}
	if ids, _, _ = r.since(t, at); len(ids) != 0 {
		t.Fatalf("cutoff equal to the shared instant must exclude them (strictly newer only), got %d", len(ids))
	}

	// 80 at one instant overflow the newest-50 load: the floor is that instant, so a cutoff before it is truncated
	// and a cutoff at it is answerable (nothing is strictly newer).
	r2 := newRemovalRig()
	for i := range 80 {
		r2.src.put(fmt.Sprintf("q%02d", i), RemovalRemoved, at)
	}
	if _, trunc, _ = r2.since(t, at.Add(-time.Second)); !trunc {
		t.Fatal("80 entries at one instant with a cutoff before it must truncate")
	}
	if ids, trunc, _ = r2.since(t, at); trunc || len(ids) != 0 {
		t.Fatalf("cutoff at the shared instant: ids=%d trunc=%v, want 0/false", len(ids), trunc)
	}
}
