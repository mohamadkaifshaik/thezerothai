package main

// messages_plaintext.go is `opsctl messages plaintext-count` and `opsctl messages purge-plaintext` (Plan 6 §2.4): the
// plaintext cut-over of the end-to-end encryption launch. The count is read-only and allowed on prod (G-52, expected 0).
// The purge is irreversible and owner-run: it needs --confirm equal to today's date in IST on every project, so a command
// pasted from an older day fails, and on a -prod project also the usual typed project id. Neither is ever a cron.
//
// Output: page numbers and counts only (no uid, no id, no text), as fixed-shape NOTICE audit lines, one per page and a
// final one with totals. The purge's resume point (the last conversation id, an unkeyed hash of the uid pair) is never
// printed: like backfill-public-ids it lives only in the checkpoint file (0600, written after every page), and --resume
// continues from it.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
)

const (
	// defaultPlaintextCheckpoint is the purge's checkpoint file in the working directory.
	defaultPlaintextCheckpoint = "purge-plaintext.checkpoint.json"
	plaintextCheckpointVersion = 1
	plaintextCheckpointCommand = "messages purge-plaintext"
)

// istZone is India Standard Time (Asia/Kolkata), UTC+05:30. A fixed zone and not time.LoadLocation: IST has had no
// daylight saving since 1945, and a fixed zone needs no tz database on the operator's machine (Windows ships none to Go).
var istZone = time.FixedZone("IST", 5*60*60+30*60)

// checkPurgeConfirm is the re-confirmation of purge-plaintext: date must be today's date in IST (YYYY-MM-DD) at now.
func checkPurgeConfirm(date string, now time.Time) error {
	today := now.In(istZone).Format(time.DateOnly)
	if date == "" {
		return usageErr("messages purge-plaintext is irreversible: it needs --confirm " + today + " (today's date in IST) to run")
	}
	if _, err := time.Parse(time.DateOnly, date); err != nil {
		return usageErr("--confirm must be a date as YYYY-MM-DD (today's date in IST)")
	}
	if date != today {
		return usageErr("--confirm " + date + " is not today's date in IST (" + today + "): a command pasted from another day never runs")
	}
	return nil
}

// plaintextCheckpointFile is the purge's --checkpoint file. After is a raw conversation id: the file is the only place it
// is written (0600, in the operator's working directory). Do not share it.
type plaintextCheckpointFile struct {
	Version int    `json:"version"`
	Command string `json:"command"`
	Project string `json:"project"`
	// After is the last conversation id walked ("" = the start).
	After string `json:"after"`
	// State is running, complete or failed.
	State   string `json:"state"`
	SavedAt string `json:"saved_at"`
}

// purgePlaintextArgs is a validated purge-plaintext invocation.
type purgePlaintextArgs struct {
	project, checkpoint, after string
	dryRun, resumed            bool
}

// parsePurgePlaintextArgs validates the checkpoint flags and file before anything is opened or confirmed (usage errors),
// as parsePublicIDsArgs does: a dry run writes nothing, not even a checkpoint; a write run refuses to overwrite an
// existing checkpoint without --resume (continue it) or --force (start over).
func parsePurgePlaintextArgs(project, checkpoint string, resume, force, dryRun bool) (purgePlaintextArgs, error) {
	if resume && force {
		return purgePlaintextArgs{}, usageErr("--resume and --force are exclusive (--force starts over)")
	}
	a := purgePlaintextArgs{project: project, dryRun: dryRun}
	if dryRun {
		if checkpoint != "" || resume || force {
			return purgePlaintextArgs{}, usageErr("messages purge-plaintext --dry-run writes nothing, not even a checkpoint: drop --checkpoint, --resume and --force")
		}
		return a, nil
	}
	a.checkpoint = checkpoint
	if a.checkpoint == "" {
		a.checkpoint = defaultPlaintextCheckpoint
	}
	if resume {
		cp, err := loadPlaintextCheckpoint(a.checkpoint)
		if err != nil {
			return purgePlaintextArgs{}, usageErr(fmt.Sprintf("--resume: %v", err))
		}
		if cp.Version != plaintextCheckpointVersion || cp.Command != plaintextCheckpointCommand {
			return purgePlaintextArgs{}, usageErr(fmt.Sprintf("--resume: %s is not a %s v%d checkpoint", a.checkpoint, plaintextCheckpointCommand, plaintextCheckpointVersion))
		}
		if cp.Project != project {
			return purgePlaintextArgs{}, usageErr(fmt.Sprintf("--resume: the checkpoint is for project %q, not %q", cp.Project, project))
		}
		if cp.After != "" && !messaging.ValidID(cp.After) {
			return purgePlaintextArgs{}, usageErr("--resume: the checkpoint's resume point is not a conversation id")
		}
		a.after, a.resumed = cp.After, true
		return a, nil
	}
	if !force {
		if _, err := os.Stat(a.checkpoint); err == nil {
			return purgePlaintextArgs{}, usageErr(fmt.Sprintf("checkpoint %s exists: pass --resume to continue it or --force to start over", a.checkpoint))
		} else if !errors.Is(err, os.ErrNotExist) {
			return purgePlaintextArgs{}, usageErr(fmt.Sprintf("checkpoint %s: %v", a.checkpoint, err))
		}
	}
	return a, nil
}

func loadPlaintextCheckpoint(path string) (plaintextCheckpointFile, error) {
	var c plaintextCheckpointFile
	data, err := os.ReadFile(path) //nolint:gosec // G304: the operator-chosen checkpoint path
	if err != nil {
		return c, fmt.Errorf("read checkpoint: %w", err)
	}
	if err := json.Unmarshal(data, &c); err != nil {
		return c, fmt.Errorf("decode checkpoint %s: %w", path, err)
	}
	return c, nil
}

// plaintextCount is `opsctl messages plaintext-count`: the two aggregation counts first (about 2 reads when both are 0,
// and then it stops), else the read-only walk that counts the messages still holding readable data.
func plaintextCount(ctx context.Context, b *backends, project string, out io.Writer, now func() time.Time) error {
	if b.plaintext == nil {
		return errors.New("messages plaintext-count: no plaintext purger configured")
	}
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	totals, err := b.plaintext.CountPlaintext(cctx)
	cancel()
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "plaintext-count: conversations=%d messages=%d (aggregation counts)\n", totals.Conversations, totals.Messages)
	var sum messaging.PlaintextPage
	if totals.Conversations > 0 || totals.Messages > 0 {
		if _, err := walkPlaintext(ctx, b, project, "", messaging.PlaintextCountOnly, &sum, out, nil); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "audit: NOTICE messages plaintext-count project=%s at=%s conversations=%d messages=%d plaintext=%d\n",
		project, now().UTC().Format(time.RFC3339), sum.Conversations, sum.Messages, sum.Plaintext)
	if sum.Plaintext == 0 {
		fmt.Fprintln(out, "plaintext-count: no readable direct message is stored")
	} else {
		fmt.Fprintf(out, "plaintext-count: %d readable direct message(s) are stored (on prod: stop, see Plan 6 §2.6)\n", sum.Plaintext)
	}
	return nil
}

// purgePlaintext is `opsctl messages purge-plaintext`: the walk in purge (or dry-run) mode from the checkpoint's resume
// point. run() has already checked --confirm, the checkpoint flags and, on prod, the typed project id.
func purgePlaintext(ctx context.Context, b *backends, a purgePlaintextArgs, out io.Writer, now func() time.Time) error {
	if b.plaintext == nil {
		return errors.New("messages purge-plaintext: no plaintext purger configured")
	}
	mode, cpName := messaging.PlaintextPurge, a.checkpoint
	if a.dryRun {
		mode, cpName = messaging.PlaintextDryRun, "-"
	}
	fmt.Fprintf(out, "purge-plaintext: project=%s dry_run=%t checkpoint=%s resumed=%t (the checkpoint file holds a conversation id: do not share it)\n",
		a.project, a.dryRun, cpName, a.resumed)
	save := func(after, state string) error {
		if a.dryRun {
			return nil
		}
		return writeCheckpointFile(a.checkpoint, plaintextCheckpointFile{
			Version: plaintextCheckpointVersion, Command: plaintextCheckpointCommand, Project: a.project,
			After: after, State: state, SavedAt: now().UTC().Format(time.RFC3339),
		})
	}
	if err := save(a.after, "running"); err != nil {
		return fmt.Errorf("checkpoint %s not saved: %w", a.checkpoint, err)
	}
	var sum messaging.PlaintextPage
	last, err := walkPlaintext(ctx, b, a.project, a.after, mode, &sum, out, func(after string) error { return save(after, "running") })
	state := "complete"
	if err != nil {
		state = "failed"
	}
	var serr error
	saveFailed := errors.Is(err, errCheckpointNotSaved)
	if !saveFailed {
		serr = save(last, state)
	}
	// The totals line is printed even after a failure: what was written is written.
	fmt.Fprintf(out, "audit: NOTICE messages purge-plaintext project=%s at=%s conversations=%d messages=%d plaintext=%d purged=%d skipped=%d previews=%d previews_skipped=%d dry_run=%t complete=%t\n",
		a.project, now().UTC().Format(time.RFC3339), sum.Conversations, sum.Messages, sum.Plaintext, sum.Purged, sum.Skipped, sum.Previews, sum.PreviewsSkipped, a.dryRun, err == nil)
	switch {
	case saveFailed:
		// Fatal: the run stopped after the page whose resume point could not be written; nothing further was purged.
		return fmt.Errorf("stopped: checkpoint %s could not be saved, no further page was purged (fix the file's location, then rerun with --force): %w", a.checkpoint, err)
	case err != nil && serr != nil:
		return fmt.Errorf("stopped, and the checkpoint %s was not saved (%v): %w", a.checkpoint, serr, err)
	case err != nil && !a.dryRun:
		return fmt.Errorf("stopped: checkpoint %s saved, rerun with --resume: %w", a.checkpoint, err)
	case err != nil:
		return err
	case serr != nil:
		return fmt.Errorf("checkpoint %s not saved: %w", a.checkpoint, serr)
	}
	switch {
	case a.dryRun:
		fmt.Fprintf(out, "dry-run: would purge %d message(s) and rewrite %d preview(s) (nothing written)\n", sum.Plaintext, sum.Previews)
	case sum.Skipped > 0 || sum.PreviewsSkipped > 0:
		fmt.Fprintf(out, "purge-plaintext: %d message(s) and %d preview(s) were skipped (changed during the run or entry missing): run it again with --force, then confirm with `opsctl messages plaintext-count`\n", sum.Skipped, sum.PreviewsSkipped)
	default:
		fmt.Fprintln(out, "purge-plaintext: run finished; confirm nothing readable is left with `opsctl messages plaintext-count --project "+a.project+"` (expect plaintext=0)")
	}
	return nil
}

// walkPlaintext drives PurgePlaintextPage from after to the end (driveLoop: a failed page is retried with the same cursor;
// every page is idempotent), sums the pages into sum and returns the last conversation id walked. One audit line per
// page, counts only; the driver's lines show the page number only. A failed attempt still adds its write counts (Purged,
// Skipped, Previews, PreviewsSkipped: those writes happened, and the retry does not count them again), never its read
// counts (the retry reads the page again). saved, when set, records the resume point after every page.
func walkPlaintext(ctx context.Context, b *backends, project, after string, mode messaging.PlaintextMode, sum *messaging.PlaintextPage, out io.Writer, saved func(after string) error) (string, error) {
	label := "purge-plaintext"
	if mode == messaging.PlaintextCountOnly {
		label = "plaintext-count"
	}
	last := after
	page := 0
	// A checkpoint that cannot be saved stops the run at once: no retry and no further page, since a later crash could
	// not resume where the writes stopped. cancel ends driveLoop before its next call; saveErr is what the run returns.
	lctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var saveErr error
	err := driveLoop(lctx, out, page,
		func(ctx context.Context, n int) (int, bool, error) {
			p, err := b.plaintext.PurgePlaintextPage(ctx, last, mode)
			if err != nil {
				if mode == messaging.PlaintextPurge {
					// The failed attempt's writes happened and the retry does not redo them. Skipped and PreviewsSkipped are
					// upper bounds after a retry: a document skipped in the failed attempt may be skipped (or purged) again.
					// A dry run's counts are "would" counts the retry recounts, so they are not added.
					sum.Purged += p.Purged
					sum.Skipped += p.Skipped
					sum.Previews += p.Previews
					sum.PreviewsSkipped += p.PreviewsSkipped
				}
				return n, false, err
			}
			sum.Add(p)
			if p.Last != "" {
				last = p.Last
			}
			fmt.Fprintf(out, "audit: NOTICE messages %s project=%s page=%d conversations=%d messages=%d plaintext=%d purged=%d skipped=%d previews=%d previews_skipped=%d dry_run=%t\n",
				label, project, n+1, p.Conversations, p.Messages, p.Plaintext, p.Purged, p.Skipped, p.Previews, p.PreviewsSkipped, mode == messaging.PlaintextDryRun)
			if saved != nil {
				if serr := saved(last); serr != nil {
					saveErr = serr
					cancel()
					return n + 1, false, errCheckpointNotSaved
				}
			}
			return n + 1, !p.More, nil
		}, func(n int) string { return fmt.Sprintf("page=%d", n) }, label)
	if saveErr != nil {
		return last, fmt.Errorf("%w: %w", errCheckpointNotSaved, saveErr)
	}
	return last, err
}

// errCheckpointNotSaved marks a run stopped because its checkpoint could not be written.
var errCheckpointNotSaved = errors.New("checkpoint not saved")
