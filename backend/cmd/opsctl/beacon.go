package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const beaconUsage = `  opsctl beacon hide    BEACON_ID --project P [--report R] [--note N] [--dry-run]   (NOT_FOUND to everyone but its organiser from the next request; the organiser still sees and manages it)
  opsctl beacon restore BEACON_ID --project P [--dry-run]
  opsctl beacon clear-area BEACON_ID --project P [--dry-run]   (removes the plan's area: it leaves Explore Nearby from the next request; prints only beacon_hash, never the area)
  opsctl beacon counts  --project P   (read-only; prints aggregate counts only: beacons_open, beacons_full, beacons_cancelled, beacons_hidden, beacons_ended, participants_requested, participants_accepted; open and full include ended plans not yet swept, ended includes cancelled ones, participants count rows on every beacon until their TTL sweep; while the beaconParticipants.state collection-group index is missing or building they read "unavailable" with a warning on stderr)
`

// parseBeaconArgs validates `opsctl beacon <hide|restore> BEACON_ID` before anything is opened or confirmed.
func parseBeaconArgs(sub, beaconID string, a modArgs) error {
	if sub == "counts" {
		if a.dryRun || a.report != "" || a.note != "" {
			return usageErr("beacon counts is read-only: it takes --project only")
		}
		return nil
	}
	if sub == "clear-area" {
		if a.report != "" || a.note != "" {
			return usageErr("beacon clear-area takes no --report or --note")
		}
		if beaconID == "" {
			return usageErr("beacon clear-area needs the beacon id as its first argument")
		}
		if err := beacons.ValidateBeaconID(beaconID); err != nil {
			return usageErr("beacon clear-area: the beacon id must be 19 digits")
		}
		return nil
	}
	if sub == "" || sub == "hide" || sub == "restore" {
		return parseHideRestoreArgs("beacon", "beacon", sub, beaconID, beacons.ValidateBeaconID, a)
	}
	return usageErr("beacon needs a sub-command: hide, restore, clear-area or counts")
}

// participantsUnavailable is the value printed for a participant count Firestore refused for a missing index.
const participantsUnavailable = "unavailable"

// participantsIndexWarning is the stderr line when the participant counts are unavailable: it names the index and the
// deploy step, and nothing about the data.
const participantsIndexWarning = "warning: participants_requested and participants_accepted are unavailable: the " +
	"beaconParticipants.state collection-group index (fieldOverrides in firebase/firestore.indexes.json) is missing or " +
	"still building; deploy it with `firebase deploy --only firestore:indexes` and rerun once it has finished building"

// beaconCounts is `opsctl beacon counts` (docs/beacons-plan.md PR 8, the pilot's daily read): the five aggregate
// counts of beacons/ and the two of beaconParticipants (open join requests, seats taken) through beacons.Stats (count
// aggregations, no document read), one key=value per line in a fixed order and nothing else. The counters are
// independent (see beacons.Stats): ENDED is never stored, so beacons_open and beacons_full include finished plans until
// their TTL sweep, and beacons_ended includes cancelled ones. It never prints an id, title, uid or hash, so the output is
// safe to paste into a readiness record.
//
// The participant counts need the beaconParticipants.state collection-group index. While it is missing or still
// building (beacons.ErrParticipantsIndex, or any FAILED_PRECONDITION) the five beacon counts are still printed, the two
// participant keys read "unavailable", a warning naming the index and its deploy step goes to stderr, and the command
// succeeds. Any other failing read prints nothing on stdout and fails.
func beaconCounts(ctx context.Context, s beacons.Stats, out, errOut io.Writer) error {
	if s == nil {
		return errors.New("beacon counts: no beacons stats configured")
	}
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	c, err := s.Counts(cctx)
	if err != nil {
		return err
	}
	requested, accepted := participantsUnavailable, participantsUnavailable
	p, err := s.ParticipantCounts(cctx)
	switch {
	case err == nil:
		requested, accepted = strconv.FormatInt(p.Requested, 10), strconv.FormatInt(p.Accepted, 10)
	case participantsIndexMissing(err):
		fmt.Fprintln(errOut, participantsIndexWarning)
	default:
		return err
	}
	_, err = fmt.Fprintf(out,
		"beacons_open=%d\nbeacons_full=%d\nbeacons_cancelled=%d\nbeacons_hidden=%d\nbeacons_ended=%d\nparticipants_requested=%s\nparticipants_accepted=%s\n",
		c.Open, c.Full, c.Cancelled, c.Hidden, c.Ended, requested, accepted)
	return err
}

// participantsIndexMissing reports whether a ParticipantCounts error is Firestore refusing the query for a missing or
// building index: the repo's beacons.ErrParticipantsIndex, or a FAILED_PRECONDITION status anywhere in the chain.
func participantsIndexMissing(err error) bool {
	return errors.Is(err, beacons.ErrParticipantsIndex) || status.Code(err) == codes.FailedPrecondition
}

// beaconCommand is `opsctl beacon hide|restore` (docs/beacons-plan.md PR 4, D6): the platform hide of one beacon, the
// only hide lever there is (no in-app moderator surface). Every read already honours `hidden`: a hidden beacon answers
// NOT_FOUND to everyone but its organiser on Get, the lists and the participation RPCs; the organiser still sees it and
// keeps Update, Cancel, Respond and Remove (R18: hidden is invisible, not frozen), and the eraser still reaches it. The
// write is beacons.Moderator.SetHidden, a field-level Update of `hidden` and `updatedAt` inside a transaction (restore
// deletes the field); a missing beacon is refused. Beacon docs are not cached by the api, so the next request on every
// server sees the change.
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
		fmt.Fprintf(out, "hidden: beacon_hash=%s\nNOT_FOUND to everyone but its organiser from the next request on every server (the organiser still sees it and can update, cancel and manage requests); a screen already open keeps its copy until it refreshes\n", hash)
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

// beaconClearArea is `opsctl beacon clear-area` (location design 5.6): the operator lever for a plan area that is abuse or
// the wrong place. beacons.AreaClearer deletes areaId, cityId and nearAreaIds in one transaction (field-level, never a
// Set); a plan without an area writes nothing and a missing beacon is refused. The plan leaves Explore Nearby from the
// next request on every server (beacon docs are not cached); the organiser may set an area again. --dry-run only reads.
// Output holds no area, title or organiser: the id appears only as beacon_hash, in a fixed-shape audit line.
func beaconClearArea(ctx context.Context, b *backends, project, beaconID string, dryRun bool, out io.Writer, now func() time.Time) error {
	if b.beaconAreas == nil || b.beacons == nil {
		return errors.New("beacon clear-area: no beacons repo configured")
	}
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	hash := logger.HashUID(beaconID)
	if dryRun {
		bc, err := b.beacons.Get(cctx, beaconID)
		if errors.Is(err, beacons.ErrNotFound) {
			return errors.New("no such beacon (nothing written)")
		}
		if err != nil {
			return err
		}
		has := bc.Area.AreaID != ""
		verb := "would remove it"
		if !has {
			verb = "would write nothing"
		}
		fmt.Fprintf(out, "dry-run: beacon clear-area beacon_hash=%s has_area=%t: %s (nothing written)\n", hash, has, verb)
		return nil
	}
	changed, err := b.beaconAreas.ClearArea(cctx, beaconID, now())
	if errors.Is(err, beacons.ErrNotFound) {
		return errors.New("no such beacon (nothing written)")
	}
	if err != nil {
		return err
	}
	if changed {
		fmt.Fprintf(out, "area cleared: beacon_hash=%s\nthe plan leaves Explore Nearby from the next request on every server; the organiser may set an area again\n", hash)
	} else {
		fmt.Fprintf(out, "no area: beacon_hash=%s; nothing written\n", hash)
	}
	fmt.Fprintf(out, "audit: beacon clear-area project=%s at=%s beacon_hash=%s wrote=%t\n", project, now().UTC().Format(time.RFC3339), hash, changed)
	return nil
}
