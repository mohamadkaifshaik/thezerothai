package main

// messages_plaintext.go is `opsctl messages plaintext-count` and `opsctl messages purge-plaintext` (Plan 6 §2.4): the
// plaintext cut-over of the end-to-end encryption launch. The count is read-only and allowed on prod (G-52, expected 0).
// The purge is irreversible and owner-run: it needs --confirm equal to today's date in IST on every project, so a command
// pasted from an older day fails, and on a -prod project also the usual typed project id. Neither is ever a cron.
//
// Output: one fixed-shape NOTICE audit line per page and a final one with totals, counts only (no uid, no id, no text);
// the driver's per-call line carries the cursor (the last conversation id, for --after) so a stopped run resumes.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
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

// plaintextCursor is the driver's checkpoint: the page number (for the audit line) and the last conversation id.
type plaintextCursor struct {
	page  int
	after string
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
		if err := walkPlaintext(ctx, b, project, "", messaging.PlaintextCountOnly, &sum, out); err != nil {
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

// purgePlaintext is `opsctl messages purge-plaintext`: the walk in purge (or dry-run) mode from --after. run() has already
// checked --confirm and, on prod, the typed project id.
func purgePlaintext(ctx context.Context, b *backends, project, after string, dryRun bool, out io.Writer, now func() time.Time) error {
	if b.plaintext == nil {
		return errors.New("messages purge-plaintext: no plaintext purger configured")
	}
	mode := messaging.PlaintextPurge
	if dryRun {
		mode = messaging.PlaintextDryRun
	}
	var sum messaging.PlaintextPage
	err := walkPlaintext(ctx, b, project, after, mode, &sum, out)
	// The totals line is printed even after a failure: what was written is written (the cursor above says where to resume).
	fmt.Fprintf(out, "audit: NOTICE messages purge-plaintext project=%s at=%s conversations=%d messages=%d plaintext=%d purged=%d skipped=%d previews=%d previews_skipped=%d dry_run=%t complete=%t\n",
		project, now().UTC().Format(time.RFC3339), sum.Conversations, sum.Messages, sum.Plaintext, sum.Purged, sum.Skipped, sum.Previews, sum.PreviewsSkipped, dryRun, err == nil)
	if err != nil {
		return err
	}
	switch {
	case dryRun:
		fmt.Fprintf(out, "dry-run: would purge %d message(s) and rewrite %d preview(s) (nothing written)\n", sum.Plaintext, sum.Previews)
	case sum.Skipped > 0 || sum.PreviewsSkipped > 0:
		fmt.Fprintf(out, "purge-plaintext: %d message(s) and %d preview(s) changed during the run and were skipped: run it again\n", sum.Skipped, sum.PreviewsSkipped)
	default:
		fmt.Fprintln(out, "purge-plaintext: no readable direct message is left")
	}
	return nil
}

// walkPlaintext drives PurgePlaintextPage from after to the end (driveLoop: a failed page is retried with the same cursor;
// every page is idempotent) and sums the pages into sum. One audit line per page, counts only.
func walkPlaintext(ctx context.Context, b *backends, project, after string, mode messaging.PlaintextMode, sum *messaging.PlaintextPage, out io.Writer) error {
	label, withCursor := "purge-plaintext", true
	if mode == messaging.PlaintextCountOnly {
		label, withCursor = "plaintext-count", false // read-only: nothing to resume, so no id is printed at all
	}
	return driveLoop(ctx, out, plaintextCursor{after: after},
		func(ctx context.Context, cp plaintextCursor) (plaintextCursor, bool, error) {
			p, err := b.plaintext.PurgePlaintextPage(ctx, cp.after, mode)
			if err != nil {
				return cp, false, err
			}
			sum.Add(p)
			fmt.Fprintf(out, "audit: NOTICE messages %s project=%s page=%d conversations=%d messages=%d plaintext=%d purged=%d skipped=%d previews=%d previews_skipped=%d dry_run=%t\n",
				label, project, cp.page+1, p.Conversations, p.Messages, p.Plaintext, p.Purged, p.Skipped, p.Previews, p.PreviewsSkipped, mode == messaging.PlaintextDryRun)
			next := plaintextCursor{page: cp.page + 1, after: cp.after}
			if p.Last != "" {
				next.after = p.Last
			}
			return next, !p.More, nil
		}, func(cp plaintextCursor) string {
			if !withCursor {
				return fmt.Sprintf("page=%d", cp.page)
			}
			return fmt.Sprintf("page=%d after=%s", cp.page, checkpointOrDash(cp.after))
		}, label)
}
