package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

var (
	bulkNow    = time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	bulkBefore = time.Date(2026, 11, 13, 0, 0, 0, 0, time.UTC)
)

// bulkID is a post id created d before bulkBefore (negative d: after it), sequence seq.
func bulkID(t *testing.T, d time.Duration, seq int64) string {
	t.Helper()
	v, err := strconv.ParseInt(snowflake.MinID(bulkBefore.Add(-d)), 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%019d", v+seq)
}

// bulkPost is one stored post of fakeBulk: stored counters and the counted children.
type bulkPost struct {
	kind                     posts.Kind
	replies, quotes          int64
	countReplies, countQuote int64
	countErr, repairErr      error
	// reread replaces the stored counters before the repair transaction reads them (a concurrent fix).
	reread *[2]int64
	// vanish deletes the post before the repair (ErrNotFound).
	vanish bool
}

// fakeBulk is posts.ChildBulkRecounter over an in-memory posts collection, with the cap and transaction rules of the repo.
type fakeBulk struct {
	posts   map[string]*bulkPost
	scanned []string // every id a page returned, in order
	counted []string
	writes  int
	// onCount runs before each CountChildParent (tests cancel the run context there).
	onCount func(id string)
	scanErr error
}

func (f *fakeBulk) ScanChildParents(_ context.Context, before time.Time, after string, limit int) ([]posts.ChildParent, error) {
	if f.scanErr != nil {
		err := f.scanErr
		f.scanErr = nil
		return nil, err
	}
	bound := snowflake.MinID(before)
	ids := make([]string, 0, len(f.posts))
	for id := range f.posts {
		if id < bound && id > after {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	if len(ids) > limit {
		ids = ids[:limit]
	}
	out := make([]posts.ChildParent, len(ids))
	for i, id := range ids {
		p := f.posts[id]
		out[i] = posts.ChildParent{ID: id, Kind: p.kind, Replies: p.replies, Quotes: p.quotes}
		f.scanned = append(f.scanned, id)
	}
	return out, nil
}

func capRecount(stored, counted int64) posts.ChildRecount {
	return posts.ChildRecount{Stored: stored, Counted: counted, Capped: counted >= 100_000}
}

func (f *fakeBulk) CountChildParent(ctx context.Context, p posts.ChildParent) (posts.ChildRepair, error) {
	if f.onCount != nil {
		f.onCount(p.ID)
	}
	if err := ctx.Err(); err != nil {
		return posts.ChildRepair{}, err
	}
	if !p.Countable() {
		return posts.ChildRepair{Repost: true}, nil
	}
	f.counted = append(f.counted, p.ID)
	fp := f.posts[p.ID]
	if fp.countErr != nil {
		return posts.ChildRepair{}, fp.countErr
	}
	return posts.ChildRepair{Replies: capRecount(p.Replies, fp.countReplies), Quotes: capRecount(p.Quotes, fp.countQuote), Reads: 2}, nil
}

func (f *fakeBulk) RepairChildCounts(_ context.Context, id string) (posts.ChildRepair, error) {
	fp, ok := f.posts[id]
	if !ok || fp.vanish {
		delete(f.posts, id)
		return posts.ChildRepair{Reads: 1}, posts.ErrNotFound
	}
	if fp.repairErr != nil {
		return posts.ChildRepair{}, fp.repairErr
	}
	if fp.reread != nil {
		fp.replies, fp.quotes = fp.reread[0], fp.reread[1]
	}
	out := posts.ChildRepair{Replies: capRecount(fp.replies, fp.countReplies), Quotes: capRecount(fp.quotes, fp.countQuote), Reads: 3}
	if out.Replies.Stored != out.Replies.Counted && !out.Replies.Capped {
		fp.replies, out.Replies.Written = fp.countReplies, true
	}
	if out.Quotes.Stored != out.Quotes.Counted && !out.Quotes.Capped {
		fp.quotes, out.Quotes.Written = fp.countQuote, true
	}
	if out.Wrote() {
		f.writes++
	}
	return out, nil
}

// fakeClock is the injected now and sleep: a sleep advances the clock and is recorded, never waits.
type fakeClock struct {
	t      time.Time
	sleeps []time.Duration
}

func (c *fakeClock) now() time.Time { return c.t }

func (c *fakeClock) sleep(ctx context.Context, d time.Duration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.sleeps = append(c.sleeps, d)
	c.t = c.t.Add(d)
	return nil
}

type bulkRig struct {
	f      *fakeBulk
	clock  *fakeClock
	cpPath string
	opened int
}

func newBulkRig(t *testing.T, ps map[string]*bulkPost) *bulkRig {
	t.Helper()
	return &bulkRig{f: &fakeBulk{posts: ps}, clock: &fakeClock{t: bulkNow}, cpPath: filepath.Join(t.TempDir(), "cp.json")}
}

// run runs `opsctl recount-children --project demo-dev --before <bulkBefore> --checkpoint <rig file>` plus args.
func (r *bulkRig) run(ctx context.Context, args ...string) (int, string, string) {
	open := func(context.Context, string) (*backends, error) {
		r.opened++
		return &backends{childBulk: r.f, sleep: r.clock.sleep, close: func() {}}, nil
	}
	full := append([]string{"recount-children", "--project", "demo-dev", "--before", bulkBefore.Format(time.RFC3339), "--checkpoint", r.cpPath}, args...)
	var out, errOut bytes.Buffer
	code := run(ctx, full, strings.NewReader(""), &out, &errOut, open, r.clock.now)
	return code, out.String(), errOut.String()
}

func (r *bulkRig) checkpoint(t *testing.T) bulkCheckpointFile {
	t.Helper()
	c, err := loadBulkCheckpoint(r.cpPath)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestRecountChildrenBulk_FlagValidation(t *testing.T) {
	existing := filepath.Join(t.TempDir(), "cp.json")
	writeCP := func(c bulkCheckpointFile) {
		if err := saveBulkCheckpoint(existing, c); err != nil {
			t.Fatal(err)
		}
	}
	good := bulkCheckpointFile{Version: 1, Command: "recount-children", Project: "demo-dev", Before: bulkBefore.Format(time.RFC3339Nano), Mode: "dry-run", State: "running"}
	tests := []struct {
		name    string
		args    []string
		prep    func()
		wantErr string
	}{
		{name: "missing --before", args: []string{"recount-children", "--project", "demo-dev"}, wantErr: "needs --before"},
		{name: "bad timestamp", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13"}, wantErr: "RFC 3339"},
		{name: "future --before", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-15T00:00:00Z"}, wantErr: "in the future"},
		{name: "rate limit 0", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--rate-limit", "0"}, wantErr: "--rate-limit"},
		{name: "rate limit too high", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--rate-limit", "501"}, wantErr: "--rate-limit"},
		{name: "max posts 0", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--max-posts", "0"}, wantErr: "--max-posts"},
		{name: "--dry-run is refused (the default already is one)", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--dry-run"}, wantErr: "--dry-run is not supported"},
		{name: "--post is refused", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--post", "0000000000000000001"}, wantErr: "--post is not supported"},
		{name: "--before on another command", args: []string{"recount-replies", "--project", "demo-dev", "--post", "0000000000000000001", "--before", "2026-11-13T00:00:00Z"}, wantErr: "--before is not supported"},
		{name: "--resume on another command", args: []string{"recount-shares", "--project", "demo-dev", "--post", "0000000000000000001", "--resume"}, wantErr: "--resume is not supported"},
		{name: "bad --after", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--checkpoint", filepath.Join(t.TempDir(), "x"), "--after", "12"}, wantErr: "19-digit"},
		{name: "--after past the bound", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--checkpoint", filepath.Join(t.TempDir(), "x"), "--after", "9999999999999999999"}, wantErr: "nothing to scan"},
		{name: "--resume with --after", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--resume", "--after", "0000000000000000001"}, wantErr: "one or the other"},
		{name: "--resume with --force", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--resume", "--force"}, wantErr: "exclusive"},
		{name: "--resume without a file", args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--resume", "--checkpoint", filepath.Join(t.TempDir(), "none.json")}, wantErr: "read checkpoint"},
		{name: "existing checkpoint without --resume", prep: func() { writeCP(good) },
			args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--checkpoint", existing}, wantErr: "--resume to continue it or --force"},
		{name: "resume with another --before", prep: func() { writeCP(good) },
			args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-12T00:00:00Z", "--checkpoint", existing, "--resume"}, wantErr: "has --before"},
		{name: "resume with another mode", prep: func() { writeCP(good) },
			args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--checkpoint", existing, "--resume", "--write"}, wantErr: "is a dry-run run"},
		{name: "resume on another project", prep: func() { writeCP(good) },
			args: []string{"recount-children", "--project", "demo-other", "--before", "2026-11-13T00:00:00Z", "--checkpoint", existing, "--resume"}, wantErr: "for project"},
		{name: "resume of a corrupt file", prep: func() {
			if err := os.WriteFile(existing, []byte("{"), 0o600); err != nil {
				t.Fatal(err)
			}
		}, args: []string{"recount-children", "--project", "demo-dev", "--before", "2026-11-13T00:00:00Z", "--checkpoint", existing, "--resume"}, wantErr: "decode checkpoint"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.prep != nil {
				tt.prep()
			}
			opened := 0
			open := func(context.Context, string) (*backends, error) { opened++; return &backends{close: func() {}}, nil }
			var out, errOut bytes.Buffer
			code := run(context.Background(), tt.args, strings.NewReader(""), &out, &errOut, open, func() time.Time { return bulkNow })
			if code != 2 || !strings.Contains(errOut.String(), tt.wantErr) {
				t.Fatalf("code %d err %q, want 2 and %q", code, errOut.String(), tt.wantErr)
			}
			if opened != 0 {
				t.Fatal("a usage error opened the backends")
			}
		})
	}
	// The same --before in another zone is the same instant: the resume is accepted.
	writeCP(good)
	a, err := parseBulkRecountArgs(bulkRecountFlags{before: "2026-11-13T01:00:00+01:00", rate: 50, maxPosts: 10, checkpoint: existing, resume: true}, "demo-dev", bulkNow)
	if err != nil || a.prior == nil {
		t.Fatalf("same instant resume = %+v, %v", a, err)
	}
	// --force replaces an existing file.
	if _, err := parseBulkRecountArgs(bulkRecountFlags{before: "2026-11-13T00:00:00Z", rate: 50, maxPosts: 10, checkpoint: existing, force: true}, "demo-dev", bulkNow); err != nil {
		t.Fatalf("--force = %v", err)
	}
	// The page is sized to the rate so one page stays inside callTimeout.
	a, _ = parseBulkRecountArgs(bulkRecountFlags{before: "2026-11-13T00:00:00Z", rate: 1, maxPosts: 10, checkpoint: filepath.Join(t.TempDir(), "p")}, "demo-dev", bulkNow)
	if a.page != bulkPageSeconds || a.checkpoint == "" {
		t.Fatalf("rate 1 page = %d", a.page)
	}
	a, _ = parseBulkRecountArgs(bulkRecountFlags{before: "2026-11-13T00:00:00Z", rate: 50, maxPosts: 10}, "demo-dev", bulkNow)
	if a.page != posts.RecountChildPage || a.checkpoint != defaultBulkCheckpoint || a.maxWrites != posts.RecountChildMaxWrites {
		t.Fatalf("defaults = %+v", a)
	}
}

func TestPacer(t *testing.T) {
	c := &fakeClock{t: bulkNow}
	p := newPacer(4, c.now, c.sleep) // 250 ms apart
	ctx := context.Background()
	for range 3 {
		if err := p.Wait(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if want := []time.Duration{250 * time.Millisecond, 250 * time.Millisecond}; fmt.Sprint(c.sleeps) != fmt.Sprint(want) {
		t.Fatalf("sleeps = %v, want %v (the first call is immediate)", c.sleeps, want)
	}
	// Time spent elsewhere counts toward the next slot.
	c.t = c.t.Add(100 * time.Millisecond)
	_ = p.Wait(ctx)
	if got := c.sleeps[len(c.sleeps)-1]; got != 150*time.Millisecond {
		t.Fatalf("partial wait = %v, want 150ms", got)
	}
	// A slot long past: no sleep, and no burst credit afterwards.
	n := len(c.sleeps)
	c.t = c.t.Add(time.Hour)
	_ = p.Wait(ctx)
	_ = p.Wait(ctx)
	if len(c.sleeps) != n+1 || c.sleeps[n] != 250*time.Millisecond {
		t.Fatalf("after idle sleeps = %v", c.sleeps[n:])
	}
	cctx, cancel := context.WithCancel(ctx)
	cancel()
	if err := p.Wait(cctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled wait = %v", err)
	}
}

func TestBulkCheckpoint_RoundTripAndAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cp.json")
	c := bulkCheckpointFile{Version: 1, Command: "recount-children", Project: "p", Before: bulkBefore.Format(time.RFC3339Nano), Mode: "write",
		After: "0000000000000000042", State: "running", Totals: bulkStats{Scanned: 7, Written: 2, Reads: 21}}
	if err := saveBulkCheckpoint(path, c); err != nil {
		t.Fatal(err)
	}
	c.After, c.Totals.Scanned = "0000000000000000043", 8
	if err := saveBulkCheckpoint(path, c); err != nil { // replaces the existing file
		t.Fatal(err)
	}
	got, err := loadBulkCheckpoint(path)
	if err != nil || got != c {
		t.Fatalf("round trip = %+v, %v; want %+v", got, err, c)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("dir holds %d entries, want only the checkpoint (no temp file left)", len(entries))
	}
	// A failed save leaves the previous checkpoint intact.
	if err := saveBulkCheckpoint(filepath.Join(dir, "missing-dir", "cp.json"), c); err == nil {
		t.Fatal("a save into a missing directory succeeded")
	}
	if again, err := loadBulkCheckpoint(path); err != nil || again != c {
		t.Fatalf("after a failed save = %+v, %v", again, err)
	}
	var raw map[string]any
	data, _ := os.ReadFile(path)
	if err := json.Unmarshal(data, &raw); err != nil || raw["after"] != c.After || raw["before"] != c.Before || raw["mode"] != "write" {
		t.Fatalf("file = %s", data)
	}
}

func TestBulkStats(t *testing.T) {
	a := bulkStats{Scanned: 3, Reposts: 1, Mismatched: 2, Written: 1, Capped: 1, SkippedMissing: 1, Errors: 1, Reads: 9}
	got := a.add(a)
	if got != (bulkStats{Scanned: 6, Reposts: 2, Mismatched: 4, Written: 2, Capped: 2, SkippedMissing: 2, Errors: 2, Reads: 18}) {
		t.Fatalf("add = %+v", got)
	}
	if s := a.String(); s != "scanned=3 reposts_skipped=1 mismatched=2 written=1 capped=1 skipped_missing=1 errors=1 est_reads=9" {
		t.Fatalf("String = %q", s)
	}
}

// bulkFixture: 6 posts before the cutoff (one REPOST, one stale reply count, one stale quote count, one capped, two in
// step) and one after it.
func bulkFixture(t *testing.T) (map[string]*bulkPost, []string, string) {
	ids := []string{bulkID(t, 5*time.Hour, 0), bulkID(t, 4*time.Hour, 0), bulkID(t, 3*time.Hour, 0), bulkID(t, 2*time.Hour, 0), bulkID(t, time.Hour, 0), bulkID(t, time.Millisecond, 3)}
	newer := bulkID(t, -time.Hour, 0)
	ps := map[string]*bulkPost{
		ids[0]: {kind: posts.KindPost, replies: 2, countReplies: 2},
		ids[1]: {kind: posts.KindPost, replies: 9, countReplies: 4},
		ids[2]: {kind: posts.KindRepost},
		ids[3]: {kind: posts.KindQuote, quotes: 1, countQuote: 3},
		ids[4]: {kind: posts.KindPost, replies: 150_000, countReplies: 100_000},
		ids[5]: {kind: posts.KindReply},
		newer:  {kind: posts.KindPost, replies: 5, countReplies: 0},
	}
	return ps, ids, newer
}

func TestRecountChildrenBulk_DryRun(t *testing.T) {
	ps, ids, newer := bulkFixture(t)
	r := newBulkRig(t, ps)
	code, out, errOut := r.run(context.Background())
	if code != 0 {
		t.Fatalf("code %d out %q err %q", code, out, errOut)
	}
	for _, w := range []string{
		"post=" + ids[1] + " field=reply_count stored=9 recounted=4 action=dry-run",
		"post=" + ids[3] + " field=quote_count stored=1 recounted=3 action=dry-run",
		"post=" + ids[4] + " field=reply_count stored=150000 recounted=100000 action=capped-not-written",
		"recount-children: complete: scanned=6 reposts_skipped=1 mismatched=3 written=0 capped=1 skipped_missing=0 errors=0 est_reads=16",
		"checkpoint=" + ids[5],
	} {
		if !strings.Contains(out, w) {
			t.Errorf("out lacks %q:\n%s", w, out)
		}
	}
	if r.f.writes != 0 || ps[ids[1]].replies != 9 {
		t.Fatal("the dry run wrote")
	}
	if strings.Contains(out, newer) || strings.Contains(strings.Join(r.f.scanned, ","), newer) {
		t.Fatal("a post at or after --before was scanned")
	}
	if strings.Contains(strings.Join(r.f.counted, ","), ids[2]) {
		t.Fatal("the REPOST was counted")
	}
	cp := r.checkpoint(t)
	if cp.State != "complete" || cp.After != ids[5] || cp.Mode != "dry-run" || cp.Totals.Scanned != 6 {
		t.Fatalf("checkpoint = %+v", cp)
	}
	// 5 countable posts at 50/s: the pacer slept between them, on the injected clock only.
	if len(r.clock.sleeps) != 4 {
		t.Fatalf("sleeps = %v, want 4 x 20ms", r.clock.sleeps)
	}
	// A rerun without --resume refuses to overwrite; --resume of a complete file does nothing.
	if code, _, errOut := r.run(context.Background()); code != 2 || !strings.Contains(errOut, "exists") {
		t.Fatalf("rerun code %d err %q", code, errOut)
	}
	if code, out, _ := r.run(context.Background(), "--resume"); code != 0 || !strings.Contains(out, "already complete") {
		t.Fatalf("resume of complete code %d out %q", code, out)
	}
}

func TestRecountChildrenBulk_WriteFixesOnlyMismatches(t *testing.T) {
	ps, ids, newer := bulkFixture(t)
	ps[ids[0]].reread = nil
	r := newBulkRig(t, ps)
	code, out, errOut := r.run(context.Background(), "--write")
	if code != 0 {
		t.Fatalf("code %d out %q err %q", code, out, errOut)
	}
	if r.f.writes != 2 || ps[ids[1]].replies != 4 || ps[ids[3]].quotes != 3 {
		t.Fatalf("writes = %d, replies %d quotes %d", r.f.writes, ps[ids[1]].replies, ps[ids[3]].quotes)
	}
	if ps[ids[4]].replies != 150_000 {
		t.Fatal("a capped count was written")
	}
	if ps[newer].replies != 5 {
		t.Fatal("a post after --before was written")
	}
	for _, w := range []string{
		"post=" + ids[1] + " field=reply_count stored=9 recounted=4 action=written",
		"post=" + ids[3] + " field=quote_count stored=1 recounted=3 action=written",
		"action=capped-not-written",
		"complete: scanned=6 reposts_skipped=1 mismatched=3 written=2 capped=1 skipped_missing=0 errors=0 est_reads=22",
	} {
		if !strings.Contains(out, w) {
			t.Errorf("out lacks %q:\n%s", w, out)
		}
	}
	// Idempotent: a --force rerun finds everything in step but the capped post and writes nothing.
	r.f.writes = 0
	code, out, _ = r.run(context.Background(), "--write", "--force")
	if code != 0 || r.f.writes != 0 || !strings.Contains(out, "mismatched=1 written=0 capped=1") {
		t.Fatalf("rerun code %d writes %d out %q", code, r.f.writes, out)
	}
}

func TestRecountChildrenBulk_RepairOutcomes(t *testing.T) {
	stale, gone, fixedMeanwhile := bulkID(t, 3*time.Hour, 0), bulkID(t, 2*time.Hour, 0), bulkID(t, time.Hour, 0)
	ps := map[string]*bulkPost{
		stale:          {kind: posts.KindPost, replies: 3, countReplies: 1},
		gone:           {kind: posts.KindPost, replies: 3, countReplies: 0, vanish: true},
		fixedMeanwhile: {kind: posts.KindPost, quotes: 4, countQuote: 2, reread: &[2]int64{0, 2}},
	}
	r := newBulkRig(t, ps)
	code, out, errOut := r.run(context.Background(), "--write")
	if code != 0 {
		t.Fatalf("code %d out %q err %q", code, out, errOut)
	}
	for _, w := range []string{
		"post=" + gone + " field=reply_count stored=3 recounted=0 action=missing",
		"post=" + fixedMeanwhile + " field=quote_count stored=2 recounted=2 action=in-step-on-reread",
		"mismatched=3 written=1 capped=0 skipped_missing=1 errors=0",
	} {
		if !strings.Contains(out, w) {
			t.Errorf("out lacks %q:\n%s", w, out)
		}
	}
}

func TestRecountChildrenBulk_CapsAndResume(t *testing.T) {
	var ids []string
	ps := map[string]*bulkPost{}
	for i := range 7 {
		id := bulkID(t, time.Duration(10-i)*time.Minute, 0)
		ids = append(ids, id)
		ps[id] = &bulkPost{kind: posts.KindPost, replies: 1, countReplies: 0}
	}
	r := newBulkRig(t, ps)
	// --max-posts 3: stops after 3 posts with the checkpoint on the third.
	code, out, _ := r.run(context.Background(), "--write", "--max-posts", "3")
	if code != 0 || !strings.Contains(out, "--max-posts reached") || !strings.Contains(out, "rerun with --resume") {
		t.Fatalf("post cap code %d out %q", code, out)
	}
	if cp := r.checkpoint(t); cp.After != ids[2] || cp.State != "post-cap" || cp.Totals.Written != 3 {
		t.Fatalf("checkpoint = %+v", cp)
	}
	// The resume continues after it: every post decided exactly once, none skipped.
	code, out, _ = r.run(context.Background(), "--write", "--resume")
	if code != 0 || !strings.Contains(out, "totals with the resumed checkpoint: scanned=7") {
		t.Fatalf("resume code %d out %q", code, out)
	}
	if fmt.Sprint(r.f.counted) != fmt.Sprint(ids) {
		t.Fatalf("counted = %v, want each of %v once in order", r.f.counted, ids)
	}
	for id, p := range ps {
		if p.replies != 0 {
			t.Fatalf("post %s not repaired", id)
		}
	}
	// The write cap: a run stops before the post that would exceed it, with the checkpoint before that post.
	for _, p := range ps {
		p.replies = 1
	}
	r2 := newBulkRig(t, ps)
	b := &backends{childBulk: r2.f, sleep: r2.clock.sleep, close: func() {}}
	a := bulkRecountArgs{project: "demo-dev", before: bulkBefore, write: true, rate: 50, maxPosts: 100, maxWrites: 2, page: 4, checkpoint: r2.cpPath}
	var buf bytes.Buffer
	if err := recountChildrenBulk(context.Background(), b, a, &buf, r2.clock.now); err != nil {
		t.Fatal(err)
	}
	if r2.f.writes != 2 || !strings.Contains(buf.String(), "write cap") {
		t.Fatalf("writes = %d out %q", r2.f.writes, buf.String())
	}
	if cp, _ := loadBulkCheckpoint(r2.cpPath); cp.After != ids[1] || cp.State != "write-cap" {
		t.Fatalf("write cap checkpoint = %+v", cp)
	}
}

func TestRecountChildrenBulk_InterruptSavesCheckpoint(t *testing.T) {
	ps, ids, _ := bulkFixture(t)
	r := newBulkRig(t, ps)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r.f.onCount = func(id string) {
		if id == ids[3] {
			cancel() // Ctrl-C while the fourth post is counted
		}
	}
	code, out, errOut := r.run(ctx, "--write")
	if code != 1 || !strings.Contains(errOut, "interrupted") || !strings.Contains(out, "recount-children: interrupted") {
		t.Fatalf("code %d out %q err %q", code, out, errOut)
	}
	cp := r.checkpoint(t)
	if cp.State != "interrupted" || cp.After != ids[2] {
		t.Fatalf("checkpoint = %+v, want interrupted after %s", cp, ids[2])
	}
	r.f.onCount = nil
	r.f.counted = nil
	if code, out, errOut := r.run(context.Background(), "--write", "--resume"); code != 0 {
		t.Fatalf("resume code %d out %q err %q", code, out, errOut)
	}
	if r.f.counted[0] != ids[3] {
		t.Fatalf("resume counted %v first, want %s", r.f.counted, ids[3])
	}
}

func TestRecountChildrenBulk_Errors(t *testing.T) {
	// An isolated post error is printed, counted and passed; the run exits 1 at the end.
	ok1, bad, ok2 := bulkID(t, 3*time.Hour, 0), bulkID(t, 2*time.Hour, 0), bulkID(t, time.Hour, 0)
	ps := map[string]*bulkPost{ok1: {kind: posts.KindPost}, bad: {kind: posts.KindPost, countErr: errors.New("boom")}, ok2: {kind: posts.KindPost}}
	r := newBulkRig(t, ps)
	r.f.scanErr = errors.New("unavailable") // the first page query fails once: driveLoop retries it
	code, out, errOut := r.run(context.Background())
	if code != 1 || !strings.Contains(out, "error post="+bad+": boom") || !strings.Contains(out, "scanned=3") || !strings.Contains(out, "errors=1") ||
		!strings.Contains(errOut, "1 posts failed") {
		t.Fatalf("code %d out %q err %q", code, out, errOut)
	}
	// Five in a row abort with the checkpoint before the first of them.
	ps = map[string]*bulkPost{}
	first := bulkID(t, 10*time.Hour, 0)
	ps[first] = &bulkPost{kind: posts.KindPost}
	for i := range 6 {
		ps[bulkID(t, time.Duration(9-i)*time.Hour, 0)] = &bulkPost{kind: posts.KindPost, countErr: errors.New("quota")}
	}
	r = newBulkRig(t, ps)
	code, _, errOut = r.run(context.Background())
	if code != 1 || !strings.Contains(errOut, "consecutive post errors") {
		t.Fatalf("abort code %d err %q", code, errOut)
	}
	if cp := r.checkpoint(t); cp.After != first || cp.State != "aborted" || cp.Totals.Errors != 0 {
		t.Fatalf("abort checkpoint = %+v, want after %s", cp, first)
	}
}

func TestDriveLoop_StopsOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	var out bytes.Buffer
	err := driveLoop(ctx, &out, 0, func(context.Context, int) (int, bool, error) {
		calls++
		cancel()
		return 0, false, context.Canceled
	}, func(int) string { return "cp" }, "x")
	if calls != 1 || !errors.Is(err, context.Canceled) || !strings.Contains(err.Error(), "interrupted (checkpoint cp)") {
		t.Fatalf("calls %d err %v, want one call then interrupted", calls, err)
	}
}
