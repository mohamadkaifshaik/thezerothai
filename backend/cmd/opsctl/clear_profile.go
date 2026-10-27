package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// profileClearer is identity.FirestoreRepo's field-level clear (the identity module owns users/{uid}; opsctl never
// writes the document itself).
type profileClearer interface {
	ClearProfileFields(ctx context.Context, uid string, fields []identity.ProfileField, now time.Time, dryRun bool) (identity.ClearResult, error)
}

// profileRetirer is media.Jobs' profile_media_retired step, run in process (ADR-0024 Amendment 1 A4): the same code the Pub/Sub
// handler runs, without Pub/Sub. It returns the step's outcome ("retired", "disabled", "unparseable", ...).
type profileRetirer interface {
	Retire(ctx context.Context, m media.RetireMessage) (string, error)
}

// parseClearArgs validates the clear-profile-fields flags before anything is opened or confirmed: --fields (one or more
// of website, location, banner, avatar, bio; an unknown, empty or repeated name is a usage error, exit 2), --report
// (a 32-character report id) and --note (only meaningful with --report).
func parseClearArgs(a modArgs) ([]identity.ProfileField, error) {
	fields, err := identity.ParseProfileFields(a.fields)
	if err != nil {
		return nil, usageErr(err.Error())
	}
	if a.report != "" && !reportIDRe.MatchString(a.report) {
		return nil, usageErr("--report must be a 32-character report id")
	}
	if a.note != "" && a.report == "" {
		return nil, usageErr("--note is the report resolution note: it needs --report")
	}
	return fields, nil
}

// clearProfileFields is `opsctl clear-profile-fields` (ADR-0024 Amendment 1 A3): the narrow lever between doing nothing
// and suspend-user for a malicious profile link, location, bio or image. It clears the named fields of users/{uid} with
// one field-level update (never a Set), skips fields that are already empty (so a rerun writes 0), and bumps no
// snapshotVersion. --dry-run prints the stored values and the plan and writes nothing. --report R (checked first: R must
// be about this user) resolves R as PROFILE_CLEARED after the write; a report that is already RESOLVED only warns.
// A DELETING account is refused (the deletion job's checkpoints must not race an operator write) and a missing one is an
// error, both exit 1. Each API instance keeps serving its cached profile for up to 60 s.
//
// Cleared banner and avatar images go through the A4 retire step in process once the clear has committed, so their
// objects are deleted by the media bucket's lifecycle rule 24-48 h later. That needs PROFILE_MEDIA_RETIRE in the operator's
// shell (this project's value; unset is off, which changes nothing and prints the objects for deleting by hand); an
// invalid value is refused before any write. A retire failure after the clear does not undo it and does not skip the
// report: the report is resolved, the failure is printed with the objects, and the exit code is 1.
//
// Cost: 1 read and at most 1 write; --report adds 1 read to check it, then the resolve (1 read, 1 write); each retired
// image adds 2 reads, 1 write and 2 Class A operations.
func clearProfileFields(ctx context.Context, b *backends, project, uid string, fields []identity.ProfileField, a modArgs, out io.Writer, now func() time.Time) error {
	if b.profiles == nil {
		return errors.New("clear-profile-fields: no profile writer configured")
	}
	if b.retireErr != nil && slicesHaveImage(fields) {
		return usageErr(b.retireErr.Error() + " (fix the variable before clearing an image)")
	}
	ctx, counter := budget.WithCounter(ctx)
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	if a.report != "" {
		if err := checkReport(cctx, b, a.report, "", "", uid, out); err != nil {
			return err
		}
	}
	res, err := b.profiles.ClearProfileFields(cctx, uid, fields, now(), a.dryRun)
	switch {
	case errors.Is(err, identity.ErrNotFound):
		return errors.New("no such user")
	case errors.Is(err, identity.ErrStatusConflict):
		return errors.New("the account is DELETING: refusing to change it")
	case err != nil:
		return err
	}

	verb := "cleared"
	if a.dryRun {
		verb = "would clear"
	}
	for _, c := range res.Cleared {
		fmt.Fprintf(out, "%s: %s %s\n", c.Field, verb, quotedValues(c.Values))
	}
	for _, f := range res.Skipped {
		fmt.Fprintf(out, "%s: already empty, skipped\n", f)
	}
	switch {
	case a.dryRun:
		fmt.Fprintf(out, "dry-run: %d field(s) to clear, %d already empty (nothing written)\n", len(res.Cleared), len(res.Skipped))
	case res.Written:
		fmt.Fprintf(out, "%d field(s) cleared with one field-level update, updatedAt set; API instances keep serving the old profile for up to 60 s (cache TTL)\n", len(res.Cleared))
	default:
		fmt.Fprintln(out, "nothing to clear: 0 writes")
	}
	// The retire step runs only after the clear committed (res.Written): never on a dry run, never when nothing changed.
	outcomes, retireErr := retireClearedImages(cctx, b, uid, res, now())
	printImageObjects(out, project, res.Cleared, outcomes, a.dryRun, b.retireMode)

	if a.report != "" {
		if a.dryRun {
			fmt.Fprintf(out, "dry-run: would resolve report %s as %s\n", a.report, moderation.ResolutionProfileCleared)
		} else if err := resolveReport(ctx, b, a.report, moderation.ResolutionProfileCleared, a.note, out, now); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "cost: reads=%d writes=%d\n", counter.Reads(), counter.Writes())
	return retireErr
}

// slicesHaveImage reports whether the requested fields include a banner or an avatar (the ones the retire step handles).
func slicesHaveImage(fields []identity.ProfileField) bool {
	for _, f := range fields {
		if _, ok := retirePurpose(f); ok {
			return true
		}
	}
	return false
}

// retirePurpose maps a clearable image field to the media purpose the retire step takes.
func retirePurpose(f identity.ProfileField) (string, bool) {
	switch f {
	case identity.ProfileFieldBanner:
		return string(media.PurposeBanner), true
	case identity.ProfileFieldAvatar:
		return string(media.PurposeAvatar), true
	}
	return "", false
}

// retireClearedImages runs the A4 retire step in process for each cleared banner or avatar of a committed clear and
// returns its outcome per field ("error" for a failed one) and the joined failures. No retirer wired counts as off.
func retireClearedImages(ctx context.Context, b *backends, uid string, res identity.ClearResult, at time.Time) (map[identity.ProfileField]string, error) {
	outcomes := map[identity.ProfileField]string{}
	if !res.Written || b.retire == nil {
		return outcomes, nil
	}
	var errs []error
	for _, c := range res.Cleared {
		purpose, ok := retirePurpose(c.Field)
		if !ok || len(c.Values) < 2 {
			continue
		}
		outcome, err := b.retire.Retire(ctx, media.RetireMessage{
			Kind: media.JobKindProfileMediaRetired, UID: uid, Purpose: purpose,
			OldURL: c.Values[0], OldThumbURL: c.Values[1], ChangedAt: at,
		})
		if err != nil {
			outcomes[c.Field] = "error"
			errs = append(errs, fmt.Errorf("%s retire failed after the clear committed (delete the objects by hand if the image must go): %w", c.Field, err))
			continue
		}
		outcomes[c.Field] = outcome
	}
	return outcomes, errors.Join(errs...)
}

// quotedValues renders the stored values a field held, quoted, in a fixed order (an empty second URL is shown as "").
func quotedValues(values []string) string {
	q := make([]string, len(values))
	for i, v := range values {
		q[i] = fmt.Sprintf("%q", v)
	}
	return strings.Join(q, " ")
}

// printImageObjects reports what happened to each cleared banner or avatar and names its bucket objects. Clearing the
// field only stops the profile from pointing at the image: the public objects stay reachable by URL (and in older posts'
// author snapshots) until they are deleted. With the A4 retire step switched on (PROFILE_MEDIA_RETIRE covering the
// image) that is the bucket lifecycle rule, 24-48 h after the clear; otherwise the operator deletes the printed objects by
// hand, as docs/runbooks/moderation.md "Media on takedown" does (objects first, then the media/* docs). The names are
// always printed, for an image that must go at once. outcomes holds the retire step's outcome per field (empty when it did
// not run); on a dry run the plan says whether it would.
func printImageObjects(out io.Writer, project string, cleared []identity.ClearedField, outcomes map[identity.ProfileField]string, dryRun bool, mode config.ProfileMediaRetire) {
	bucket := project + "-media"
	for _, c := range cleared {
		purpose, isImage := retirePurpose(c.Field)
		if !isImage {
			continue
		}
		outcome := outcomes[c.Field]
		switch {
		case dryRun && mode.Allows(purpose):
			fmt.Fprintf(out, "%s retire: would run after the clear (PROFILE_MEDIA_RETIRE=%s): the objects are deleted 24-48 h later\n", c.Field, mode)
		case dryRun:
			fmt.Fprintf(out, "%s retire: would not run (PROFILE_MEDIA_RETIRE=%s does not cover it): delete the objects by hand\n", c.Field, mode)
		case outcome == "retired":
			fmt.Fprintf(out, "%s retire: done. Both objects are tagged for deletion; the media bucket's lifecycle rule deletes them 24-48 h from now and the image URL stays live until then\n", c.Field)
		case outcome == "" || outcome == "disabled":
			fmt.Fprintf(out, "%s retire: not run (PROFILE_MEDIA_RETIRE=%s in this shell does not cover it): set it to this project's value to schedule the delete, or delete the objects by hand\n", c.Field, mode)
		case outcome == "error":
			fmt.Fprintf(out, "%s retire: FAILED (see the error below): delete the objects by hand if the image must go\n", c.Field)
		default:
			fmt.Fprintf(out, "%s retire: %s, nothing was scheduled: delete the objects by hand if the image must go\n", c.Field, outcome)
		}
		state := "still public until deleted"
		if outcome == "retired" {
			state = "public until the lifecycle rule deletes it"
		}
		for _, v := range c.Values {
			if v == "" {
				continue
			}
			if name := media.ObjectNameFromURL(v); name != "" {
				fmt.Fprintf(out, "%s object (%s): %s in bucket %s\n", c.Field, state, name, bucket)
			} else {
				fmt.Fprintf(out, "%s object (%s): could not derive the object name from %q; find it in bucket %s\n", c.Field, state, v, bucket)
			}
		}
	}
}
