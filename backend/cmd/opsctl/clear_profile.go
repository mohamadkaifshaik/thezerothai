package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// profileClearer is identity.FirestoreRepo's field-level clear (the identity module owns users/{uid}; opsctl never
// writes the document itself).
type profileClearer interface {
	ClearProfileFields(ctx context.Context, uid string, fields []identity.ProfileField, now time.Time, dryRun bool) (identity.ClearResult, error)
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
// Cost: 1 read and at most 1 write; --report adds 1 read to check it, then the resolve (1 read, 1 write).
func clearProfileFields(ctx context.Context, b *backends, project, uid string, fields []identity.ProfileField, a modArgs, out io.Writer, now func() time.Time) error {
	if b.profiles == nil {
		return errors.New("clear-profile-fields: no profile writer configured")
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
	printImageObjects(out, project, res.Cleared)

	if a.report != "" {
		if a.dryRun {
			fmt.Fprintf(out, "dry-run: would resolve report %s as %s\n", a.report, moderation.ResolutionProfileCleared)
		} else if err := resolveReport(ctx, b, a.report, moderation.ResolutionProfileCleared, a.note, out, now); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "cost: reads=%d writes=%d\n", counter.Reads(), counter.Writes())
	return nil
}

// quotedValues renders the stored values a field held, quoted, in a fixed order (an empty second URL is shown as "").
func quotedValues(values []string) string {
	q := make([]string, len(values))
	for i, v := range values {
		q[i] = fmt.Sprintf("%q", v)
	}
	return strings.Join(q, " ")
}

// printImageObjects names the bucket objects behind a cleared banner or avatar. Clearing the field stops the profile
// from pointing at the image, but the public objects stay reachable by URL (and in older posts' author snapshots)
// until they are deleted.
//
// TODO(A4): ADR-0024 Amendment 1 A4 (PROFILE_MEDIA_RETIRE, identity.MediaRetirer) adds a retire step that deletes these
// objects after a grace. When it exists, call it in process here for the cleared banner and avatar, and keep this list
// for an image that must go at once. Until then the operator deletes the printed objects by hand, as
// docs/runbooks/moderation.md "Media on takedown" does (objects first, then the media/* docs).
func printImageObjects(out io.Writer, project string, cleared []identity.ClearedField) {
	bucket := project + "-media"
	for _, c := range cleared {
		if c.Field != identity.ProfileFieldBanner && c.Field != identity.ProfileFieldAvatar {
			continue
		}
		for _, v := range c.Values {
			if v == "" {
				continue
			}
			if name := objectName(v); name != "" {
				fmt.Fprintf(out, "%s object (still public until deleted): %s in bucket %s\n", c.Field, name, bucket)
			} else {
				fmt.Fprintf(out, "%s object (still public until deleted): could not derive the object name from %q; find it in bucket %s\n", c.Field, v, bucket)
			}
		}
	}
}

// objectName returns the media-bucket object name ("m/<mediaId>.<ext>" or "m/<mediaId>_t.<ext>") that a profile image
// URL points at, or "" when the URL has no such tail. The public base URL in front of it is deployment config that
// opsctl does not know, so it keys on the "/m/" segment.
func objectName(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	i := strings.LastIndex(u.Path, "/m/")
	if i < 0 {
		return ""
	}
	name := u.Path[i+1:]
	if len(name) <= len("m/") || strings.Contains(name[len("m/"):], "/") {
		return ""
	}
	return name
}
