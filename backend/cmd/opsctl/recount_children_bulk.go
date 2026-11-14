package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// recountChildrenBulkUsage documents `opsctl recount-children`.
const recountChildrenBulkUsage = `  opsctl recount-children --project P --before RFC3339 [--write] [--rate-limit N] [--max-posts N]
                          [--checkpoint FILE] [--resume | --after POST_ID] [--force]
                          (bulk recount-replies + recount-quotes in one pass over every post created before --before
                          (required: the deploy time of the counter fix, never an unbounded scan), in post id order; dry run
                          unless --write: prints one line per mismatched counter and a summary. Writes only a counter that
                          differs, in one transaction that re-reads the post and recounts both counters; a count at its
                          100,000 cap is never written. REPOSTs are skipped (their counters stay 0). --rate-limit is posts
                          per second (default 50, max 500); --max-posts bounds one run (default 50,000) and --write stops
                          after 5,000 writes; rerun with --resume. Reads: about 3 per post (1 page read + 2 count()
                          aggregations, each 1 read per 1,000 children, at least 1), so ~3,000 per 1,000 posts; a REPOST
                          costs 1; a repaired post adds 1 read + 2 aggregations + 1 write. The checkpoint (default
                          ./recount-children.checkpoint.json, written atomically after every page) records the last post id,
                          --before and the mode; --resume continues from it and refuses a different --before or mode. An
                          existing checkpoint is never overwritten without --resume or --force (which starts over). The
                          last post id is printed on every page too: --after POST_ID resumes without the file. Ctrl-C
                          saves the checkpoint)
`

const (
	// defaultBulkCheckpoint is the checkpoint file in the working directory.
	defaultBulkCheckpoint = "recount-children.checkpoint.json"
	defaultBulkRate       = 50
	maxBulkRate           = 500
	defaultBulkMaxPosts   = 50_000
	maxBulkMaxPosts       = 1_000_000
	// bulkPageSeconds sizes a page to this many seconds of pacing, so one page stays well inside callTimeout.
	bulkPageSeconds = 30
	// bulkCheckpointVersion is the checkpoint file format.
	bulkCheckpointVersion = 1
)

// bulkRecountFlags is the raw command line of recount-children.
type bulkRecountFlags struct {
	before, after, checkpoint string
	rate, maxPosts            int
	write, resume, force      bool
}

// bulkRecountArgs is a validated recount-children run.
type bulkRecountArgs struct {
	project    string
	before     time.Time
	after      string
	write      bool
	rate       int
	maxPosts   int
	maxWrites  int
	page       int
	checkpoint string
	// prior is the checkpoint file a --resume continues (its totals carry over); nil for a fresh run.
	prior *bulkCheckpointFile
}

func (a bulkRecountArgs) mode() string {
	if a.write {
		return "write"
	}
	return "dry-run"
}

// parseBulkRecountArgs validates the flags and the checkpoint file before anything is opened or confirmed. Every failure is
// a usage error (exit 2).
func parseBulkRecountArgs(f bulkRecountFlags, project string, now time.Time) (bulkRecountArgs, error) {
	if f.before == "" {
		return bulkRecountArgs{}, usageErr("recount-children needs --before RFC3339 (the deploy time of the counter fix): an unbounded scan is refused")
	}
	before, err := time.Parse(time.RFC3339, f.before)
	if err != nil {
		return bulkRecountArgs{}, usageErr("--before must be an RFC 3339 time, e.g. 2026-11-14T09:00:00Z")
	}
	if before.After(now) {
		return bulkRecountArgs{}, usageErr("--before is in the future: that is an unbounded scan")
	}
	if f.rate < 1 || f.rate > maxBulkRate {
		return bulkRecountArgs{}, usageErr(fmt.Sprintf("--rate-limit must be 1..%d posts per second", maxBulkRate))
	}
	if f.maxPosts < 1 || f.maxPosts > maxBulkMaxPosts {
		return bulkRecountArgs{}, usageErr(fmt.Sprintf("--max-posts must be 1..%d", maxBulkMaxPosts))
	}
	if f.resume && f.force {
		return bulkRecountArgs{}, usageErr("--resume and --force are exclusive (--force starts over)")
	}
	if f.resume && f.after != "" {
		return bulkRecountArgs{}, usageErr("--resume reads --after from the checkpoint; pass one or the other")
	}
	a := bulkRecountArgs{
		project: project, before: before.UTC(), after: f.after, write: f.write, rate: f.rate, maxPosts: f.maxPosts,
		maxWrites: posts.RecountChildMaxWrites, page: min(posts.RecountChildPage, f.rate*bulkPageSeconds), checkpoint: f.checkpoint,
	}
	if a.checkpoint == "" {
		a.checkpoint = defaultBulkCheckpoint
	}
	if f.resume {
		cp, err := loadBulkCheckpoint(a.checkpoint)
		if err != nil {
			return bulkRecountArgs{}, usageErr(fmt.Sprintf("--resume: %v", err))
		}
		if err := cp.matches(a); err != nil {
			return bulkRecountArgs{}, usageErr(fmt.Sprintf("--resume: %v", err))
		}
		a.after, a.prior = cp.After, &cp
	} else if !f.force {
		if _, err := os.Stat(a.checkpoint); err == nil {
			return bulkRecountArgs{}, usageErr(fmt.Sprintf("checkpoint %s exists: pass --resume to continue it or --force to start over", a.checkpoint))
		} else if !errors.Is(err, os.ErrNotExist) {
			return bulkRecountArgs{}, usageErr(fmt.Sprintf("checkpoint %s: %v", a.checkpoint, err))
		}
	}
	if a.after != "" {
		if !postIDRe.MatchString(a.after) {
			return bulkRecountArgs{}, usageErr("--after must be a 19-digit post id")
		}
		if a.after >= snowflake.MinID(a.before) {
			return bulkRecountArgs{}, usageErr("--after is not before --before: nothing to scan")
		}
	}
	return a, nil
}

// bulkStats are the counts of one run (or, in the checkpoint file, of every run on it).
type bulkStats struct {
	Scanned        int64 `json:"scanned"`
	Reposts        int64 `json:"reposts_skipped"`
	Mismatched     int64 `json:"mismatched"`
	Written        int64 `json:"written"`
	Capped         int64 `json:"capped"`
	SkippedMissing int64 `json:"skipped_missing"`
	Errors         int64 `json:"errors"`
	Reads          int64 `json:"est_reads"`
}

func (s bulkStats) add(o bulkStats) bulkStats {
	return bulkStats{
		Scanned: s.Scanned + o.Scanned, Reposts: s.Reposts + o.Reposts, Mismatched: s.Mismatched + o.Mismatched,
		Written: s.Written + o.Written, Capped: s.Capped + o.Capped, SkippedMissing: s.SkippedMissing + o.SkippedMissing,
		Errors: s.Errors + o.Errors, Reads: s.Reads + o.Reads,
	}
}

func (s bulkStats) String() string {
	return fmt.Sprintf("scanned=%d reposts_skipped=%d mismatched=%d written=%d capped=%d skipped_missing=%d errors=%d est_reads=%d",
		s.Scanned, s.Reposts, s.Mismatched, s.Written, s.Capped, s.SkippedMissing, s.Errors, s.Reads)
}

// bulkCheckpointFile is the --checkpoint file: enough to resume the id-ordered scan exactly and to refuse a mismatched run.
type bulkCheckpointFile struct {
	Version int    `json:"version"`
	Command string `json:"command"`
	Project string `json:"project"`
	Before  string `json:"before"`
	Mode    string `json:"mode"`
	// After is the last post id decided; the next page starts after it ("" = the start).
	After string `json:"after"`
	// State is running, complete, write-cap, post-cap, interrupted or aborted.
	State   string    `json:"state"`
	Totals  bulkStats `json:"totals"`
	SavedAt string    `json:"saved_at"`
}

// matches refuses a resume whose project, --before (as an instant) or mode differ from the file's.
func (c bulkCheckpointFile) matches(a bulkRecountArgs) error {
	if c.Version != bulkCheckpointVersion || c.Command != "recount-children" {
		return fmt.Errorf("the checkpoint is not a recount-children v%d file", bulkCheckpointVersion)
	}
	if c.Project != a.project {
		return fmt.Errorf("the checkpoint is for project %q, not %q", c.Project, a.project)
	}
	before, err := time.Parse(time.RFC3339Nano, c.Before)
	if err != nil || !before.Equal(a.before) {
		return fmt.Errorf("the checkpoint has --before %s, this run %s", c.Before, a.before.Format(time.RFC3339))
	}
	if c.Mode != a.mode() {
		return fmt.Errorf("the checkpoint is a %s run, this one %s", c.Mode, a.mode())
	}
	return nil
}

func loadBulkCheckpoint(path string) (bulkCheckpointFile, error) {
	data, err := os.ReadFile(path) //nolint:gosec // G304: the operator-chosen checkpoint path
	if err != nil {
		return bulkCheckpointFile{}, fmt.Errorf("read checkpoint: %w", err)
	}
	var c bulkCheckpointFile
	if err := json.Unmarshal(data, &c); err != nil {
		return bulkCheckpointFile{}, fmt.Errorf("decode checkpoint %s: %w", path, err)
	}
	return c, nil
}

// saveBulkCheckpoint writes the file atomically: a temp file in the same directory (0600), synced, closed, then renamed over
// the target, so a crash leaves the old checkpoint or the new one, never a torn file.
func saveBulkCheckpoint(path string, c bulkCheckpointFile) (err error) {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("encode checkpoint: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return fmt.Errorf("checkpoint temp file: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmp.Name()) //nolint:gosec // G703: the temp file this call just created
		}
	}()
	if _, err = tmp.Write(append(data, '\n')); err != nil {
		return fmt.Errorf("write checkpoint: %w", err)
	}
	if err = tmp.Sync(); err != nil {
		return fmt.Errorf("sync checkpoint: %w", err)
	}
	if err = tmp.Close(); err != nil {
		return fmt.Errorf("close checkpoint: %w", err)
	}
	if err = os.Rename(tmp.Name(), path); err != nil { //nolint:gosec // G703: the operator-chosen checkpoint path
		return fmt.Errorf("replace checkpoint: %w", err)
	}
	return nil
}

// pacer spaces calls at least interval apart (no burst): Wait returns at once when the slot is due, else sleeps until it.
// now and sleep are injected (tests use a fake clock; no real sleeps).
type pacer struct {
	interval time.Duration
	next     time.Time
	now      func() time.Time
	sleep    func(ctx context.Context, d time.Duration) error
}

func newPacer(perSecond int, now func() time.Time, sleep func(context.Context, time.Duration) error) *pacer {
	return &pacer{interval: time.Second / time.Duration(perSecond), now: now, sleep: sleep}
}

func (p *pacer) Wait(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	t := p.now()
	if p.next.After(t) {
		if err := p.sleep(ctx, p.next.Sub(t)); err != nil {
			return err
		}
		t = p.next
	}
	p.next = t.Add(p.interval)
	return nil
}

// bulkState is driveLoop's checkpoint: the last post id decided and this run's counts.
type bulkState struct {
	After string
	Run   bulkStats
}

// bulkStop says why a run ended early.
type bulkStop string

const (
	stopNone        bulkStop = ""
	stopWriteCap    bulkStop = "write-cap"
	stopPostCap     bulkStop = "post-cap"
	stopInterrupted bulkStop = "interrupted"
	stopAborted     bulkStop = "aborted"
)

// fieldLabel is the printed name of a counter.
var fieldLabel = [2]string{"reply_count", "quote_count"}

// recountChildrenBulk is `opsctl recount-children`. One driveLoop step is one page: the page query, then per countable post
// (paced) the two outside counts and, with --write and a stale counter, RepairChildCounts. A per-post error is printed with
// the post id and counted, and the scan goes on; five in a row stop the run with the checkpoint before them. The checkpoint
// file is saved after every page and when the run stops.
func recountChildrenBulk(ctx context.Context, b *backends, a bulkRecountArgs, out io.Writer, now func() time.Time) error {
	if b.childBulk == nil {
		return errors.New("recount-children is not wired")
	}
	if a.prior != nil && a.prior.State == "complete" {
		fmt.Fprintf(out, "recount-children: the checkpoint %s is already complete (%s); nothing to do\n", a.checkpoint, a.prior.Totals)
		return nil
	}
	start := now()
	pace := newPacer(a.rate, now, b.wait)
	var prior bulkStats
	if a.prior != nil {
		prior = a.prior.Totals
	}
	stop := stopNone
	var saveErr error
	save := func(st bulkState, state string) {
		if saveErr != nil {
			return
		}
		saveErr = saveBulkCheckpoint(a.checkpoint, bulkCheckpointFile{
			Version: bulkCheckpointVersion, Command: "recount-children", Project: a.project, Before: a.before.Format(time.RFC3339Nano),
			Mode: a.mode(), After: st.After, State: state, Totals: prior.add(st.Run), SavedAt: now().UTC().Format(time.RFC3339),
		})
	}
	fmt.Fprintf(out, "recount-children: before=%s (ids < %s) mode=%s rate=%d/s max_posts=%d checkpoint=%s after=%s\n",
		a.before.Format(time.RFC3339), snowflake.MinID(a.before), a.mode(), a.rate, a.maxPosts, a.checkpoint, checkpointOrDash(a.after))
	last := bulkState{After: a.after}
	save(last, "running")
	if saveErr != nil {
		return saveErr
	}
	err := driveLoop(ctx, out, last, func(sctx context.Context, cp bulkState) (bulkState, bool, error) {
		next, st, done, err := bulkPage(sctx, ctx, b.childBulk, a, pace, cp, out)
		if err != nil {
			return cp, false, err
		}
		last, stop = next, st
		state := "running"
		switch {
		case st != stopNone:
			state = string(st)
		case done:
			state = "complete"
		}
		save(next, state)
		return next, done || st != stopNone || saveErr != nil, nil
	}, describeBulk, "recount-children")
	if err != nil {
		if ctx.Err() != nil {
			stop = stopInterrupted
			save(last, string(stop))
		} else {
			return err
		}
	}
	fmt.Fprintf(out, "recount-children: %s: %s elapsed=%s checkpoint=%s\n",
		bulkVerdict(stop), last.Run, now().Sub(start).Round(time.Millisecond), checkpointOrDash(last.After))
	if a.prior != nil {
		fmt.Fprintf(out, "recount-children: totals with the resumed checkpoint: %s\n", prior.add(last.Run))
	}
	if saveErr != nil {
		return fmt.Errorf("checkpoint %s not saved (%w): resume with --after %s", a.checkpoint, saveErr, checkpointOrDash(last.After))
	}
	switch stop {
	case stopWriteCap, stopPostCap:
		fmt.Fprintf(out, "more posts may be stale: rerun with --resume (or --after %s)\n", checkpointOrDash(last.After))
	case stopInterrupted:
		return fmt.Errorf("interrupted: checkpoint saved at %s; rerun with --resume", checkpointOrDash(last.After))
	case stopAborted:
		return fmt.Errorf("stopped after %d consecutive post errors; checkpoint saved before them at %s; rerun with --resume", maxConsecutiveErrors, checkpointOrDash(last.After))
	}
	if last.Run.Errors > 0 {
		return fmt.Errorf("%d posts failed (printed above): rerun them with recount-replies / recount-quotes --post", last.Run.Errors)
	}
	return nil
}

func bulkVerdict(s bulkStop) string {
	switch s {
	case stopWriteCap:
		return fmt.Sprintf("write cap of %d reached", posts.RecountChildMaxWrites)
	case stopPostCap:
		return "--max-posts reached"
	case stopInterrupted:
		return "interrupted"
	case stopAborted:
		return "aborted"
	}
	return "complete"
}

// describeBulk renders a state for driveLoop's per-page progress line (the checkpoint id is the --after of a resume).
func describeBulk(s bulkState) string {
	return fmt.Sprintf("scanned=%d mismatched=%d written=%d checkpoint=%s", s.Run.Scanned, s.Run.Mismatched, s.Run.Written, checkpointOrDash(s.After))
}

// bulkPage reads one page and decides its posts in order. sctx bounds this page's calls; run is the run's context, whose
// cancellation (Ctrl-C) ends the page at the last decided post (stopInterrupted). It returns done when the scan reached
// the end. Only the page query fails the step (driveLoop retries it from cp; nothing of the page has been counted).
func bulkPage(sctx, run context.Context, r posts.ChildBulkRecounter, a bulkRecountArgs, pace *pacer, cp bulkState, out io.Writer,
) (bulkState, bulkStop, bool, error) {
	limit := min(a.page, a.maxPosts-int(cp.Run.Scanned))
	if limit <= 0 {
		return cp, stopPostCap, false, nil
	}
	page, err := r.ScanChildParents(sctx, a.before, cp.After, limit)
	if err != nil {
		return cp, stopNone, false, err
	}
	next := cp
	next.Run.Reads += max(1, int64(len(page))) // an empty page still bills one read
	var rewind *bulkState                      // the state before the current run of consecutive errors
	streak := 0
	interrupted := func() bool { return run.Err() != nil }
	for _, p := range page {
		if interrupted() {
			return next, stopInterrupted, false, nil
		}
		if !p.Countable() {
			next.Run.Scanned++
			next.Run.Reposts++
			next.After = p.ID
			continue
		}
		if err := pace.Wait(sctx); err != nil {
			if interrupted() {
				return next, stopInterrupted, false, nil
			}
			return next, stopNone, false, nil // the page deadline: the next step continues from here
		}
		res, err := decidePost(sctx, r, a, p, next.Run.Written)
		if err != nil {
			if interrupted() {
				return next, stopInterrupted, false, nil
			}
			if rewind == nil {
				saved := next
				rewind = &saved
			}
			streak++
			fmt.Fprintf(out, "error post=%s: %v\n", p.ID, err)
			next.Run.Scanned++
			next.Run.Errors++
			next.After = p.ID
			if streak >= maxConsecutiveErrors {
				return *rewind, stopAborted, false, nil
			}
			continue
		}
		rewind, streak = nil, 0
		if res.writeCapped {
			return next, stopWriteCap, false, nil
		}
		for _, l := range res.lines {
			fmt.Fprintln(out, l)
		}
		next.Run = next.Run.add(res.stats)
		next.Run.Scanned++
		next.After = p.ID
	}
	return next, stopNone, len(page) < limit, nil
}

// postResult is one decided post: its counts and the mismatch lines to print.
type postResult struct {
	stats       bulkStats
	lines       []string
	writeCapped bool
}

// decidePost counts one post and, with --write and a stale counter, repairs it. A post that would write once the run has
// written maxWrites is not decided (writeCapped): the checkpoint stays before it.
func decidePost(ctx context.Context, r posts.ChildBulkRecounter, a bulkRecountArgs, p posts.ChildParent, written int64) (postResult, error) {
	pre, err := r.CountChildParent(ctx, p)
	if err != nil {
		return postResult{}, err
	}
	res := postResult{stats: bulkStats{Reads: pre.Reads}}
	if pre.Repost {
		res.stats.Reposts++
		return res, nil
	}
	preFields := [2]posts.ChildRecount{pre.Replies, pre.Quotes}
	var fix posts.ChildRepair
	missing := false
	if a.write && pre.Stale() {
		if written >= int64(a.maxWrites) {
			return postResult{writeCapped: true}, nil
		}
		fix, err = r.RepairChildCounts(ctx, p.ID)
		res.stats.Reads += fix.Reads
		switch {
		case errors.Is(err, posts.ErrNotFound):
			missing = true
			res.stats.SkippedMissing++
		case err != nil:
			return postResult{}, err
		case fix.Wrote():
			res.stats.Written++
		}
	}
	fixFields := [2]posts.ChildRecount{fix.Replies, fix.Quotes}
	for i, f := range preFields {
		if f.Stored == f.Counted {
			continue
		}
		res.stats.Mismatched++
		stored, counted, action := f.Stored, f.Counted, "dry-run"
		switch {
		case f.Capped:
			res.stats.Capped++
			action = "capped-not-written"
		case !a.write:
		case missing:
			action = "missing"
		case fixFields[i].Written:
			stored, counted, action = fixFields[i].Stored, fixFields[i].Counted, "written"
		case fixFields[i].Capped:
			res.stats.Capped++
			stored, counted, action = fixFields[i].Stored, fixFields[i].Counted, "capped-not-written"
		default:
			stored, counted, action = fixFields[i].Stored, fixFields[i].Counted, "in-step-on-reread"
		}
		res.lines = append(res.lines, fmt.Sprintf("post=%s field=%s stored=%d recounted=%d action=%s", p.ID, fieldLabel[i], stored, counted, action))
	}
	return res, nil
}
