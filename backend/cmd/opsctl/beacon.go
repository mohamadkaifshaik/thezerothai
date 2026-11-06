package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const beaconUsage = `  opsctl beacon hide    BEACON_ID --project P [--report R] [--note N] [--dry-run]   (every read of the beacon answers NOT_FOUND on the next request; the organiser too)
  opsctl beacon restore BEACON_ID --project P [--dry-run]
`

// parseBeaconArgs validates `opsctl beacon <hide|restore> BEACON_ID` before anything is opened or confirmed.
func parseBeaconArgs(sub, beaconID string, a modArgs) error {
	return parseHideRestoreArgs("beacon", "beacon", sub, beaconID, beacons.ValidateBeaconID, a)
}

// beaconCommand is `opsctl beacon hide|restore` (docs/beacons-plan.md PR 4, D6): the platform hide of one beacon, the
// only hide lever there is (no in-app moderator surface). Every read already honours `hidden`: a hidden beacon answers
// NOT_FOUND to everyone, its organiser included, on Get, the lists and the participation RPCs, and the eraser still
// reaches it (hidden is invisible, not frozen). The write is beacons.Moderator.SetHidden, a field-level Update of `hidden`
// and `updatedAt` inside a transaction (restore deletes the field); a missing beacon is refused. Beacon docs are not cached
// by the api, so the next request on every server sees the change.
//
// Hide and restore write only when the flag differs (a repeat writes nothing). --dry-run only reads. --report R (hide
// only; checked first: R must be a BEACON report of exactly this beacon) resolves R as TAKEDOWN after the write, also when
// the beacon was already hidden. Output holds no title, details, venue or organiser: the id appears only as beacon_hash
// (the same one-way hash as uid_hash), in a fixed-shape audit line that is the moderation trail because the document
// records no actor.
func beaconCommand(ctx context.Context, b *backends, project, sub, beaconID string, a modArgs, out io.Writer, now func() time.Time) error {
	if b.beacons == nil {
		return errors.New("beacon: no beacons moderator configured")
	}
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	hide := sub == "hide"
	if a.report != "" {
		// Checked first: the report must be a BEACON report of exactly this beacon, so a typo cannot close an unrelated report.
		if err := checkReport(cctx, b, a.report, moderation.TargetBeacon, beaconID, "", out); err != nil {
			return err
		}
	}
	hash := logger.HashUID(beaconID)
	if a.dryRun {
		return beaconDryRun(cctx, b, sub, beaconID, hash, hide, a.report, out)
	}
	changed, err := b.beacons.SetHidden(cctx, beaconID, hide, now())
	if errors.Is(err, beacons.ErrNotFound) {
		return errors.New("no such beacon (nothing written)")
	}
	if err != nil {
		return err
	}
	switch {
	case changed && hide:
		fmt.Fprintf(out, "hidden: beacon_hash=%s\nevery read answers NOT_FOUND from the next request on every server (the organiser too); a screen already open keeps its copy until it refreshes\n", hash)
	case changed:
		fmt.Fprintf(out, "restored: beacon_hash=%s\nit is visible again from the next request on every server\n", hash)
	case hide:
		fmt.Fprintf(out, "already hidden: beacon_hash=%s; nothing written\n", hash)
	default:
		fmt.Fprintf(out, "not hidden: beacon_hash=%s; nothing written\n", hash)
	}
	report := "-"
	if a.report != "" {
		report = a.report
	}
	fmt.Fprintf(out, "audit: beacon %s project=%s at=%s beacon_hash=%s wrote=%t report=%s\n", sub, project, now().UTC().Format(time.RFC3339), hash, changed, report)
	if a.report != "" {
		// Also when the beacon was already hidden: the operator's decision on the report still stands.
		return resolveReport(ctx, b, a.report, moderation.ResolutionTakedown, a.note, out, now)
	}
	return nil
}

// beaconDryRun reads the beacon and prints what a real run would write; a missing beacon is refused the same way.
func beaconDryRun(ctx context.Context, b *backends, sub, beaconID, hash string, hide bool, report string, out io.Writer) error {
	bc, err := b.beacons.Get(ctx, beaconID)
	if errors.Is(err, beacons.ErrNotFound) {
		return errors.New("no such beacon (nothing written)")
	}
	if err != nil {
		return err
	}
	verb := "would write"
	if bc.Hidden == hide {
		verb = "already so; would write nothing"
	}
	fmt.Fprintf(out, "dry-run: beacon %s beacon_hash=%s currently hidden=%t: %s (nothing written)\n", sub, hash, bc.Hidden, verb)
	if report != "" {
		fmt.Fprintf(out, "dry-run: would resolve report %s as %s\n", report, moderation.ResolutionTakedown)
	}
	return nil
}
