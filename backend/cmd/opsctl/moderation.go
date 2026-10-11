// moderation.go holds the P7 moderator commands (ADR-0016 D4): reports list|show|resolve, takedown-post,
// restore-post, suspend-user, unsuspend-user. There is no admin console at Stage 0; the founder runs these from
// their machine with Application Default Credentials, with the same --project / typed-prod-confirmation rules as
// every other opsctl command.
//
// Cost (printed at the end of every write command): suspend-user reads and writes one document per post of the
// user, once, in batches of 500; everything else is 1-2 reads and 1-2 writes.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// accountStatusSetter is identity.FirestoreRepo's moderation write (the existing identity module, never Auth).
type accountStatusSetter interface {
	SetAccountStatus(ctx context.Context, uid string, from, to identity.AccountStatus, now time.Time) (bool, error)
}

var (
	postIDRe   = regexp.MustCompile(`^[0-9]{19}$`)
	reportIDRe = regexp.MustCompile(`^[0-9a-f]{32}$`)
)

// modArgs are the flag values the moderator commands use.
type modArgs struct {
	id, post, report, status, resolution, note string
	limit                                      int
	dryRun                                     bool
}

const modUsage = `  opsctl reports list     --project P [--status OPEN|RESOLVED] [--limit N]
  opsctl reports show     --project P --id REPORT
  opsctl reports resolve  --project P --id REPORT --resolution NO_ACTION|DISMISSED|TAKEDOWN|SUSPENDED [--note TEXT]
  opsctl takedown-post    --project P --post POSTID [--report REPORT] [--note TEXT]
  opsctl restore-post     --project P --post POSTID
  opsctl suspend-user     --project P --uid U [--report REPORT] [--dry-run]   (also hides every post of the user)
  opsctl unsuspend-user   --project P --uid U                                (restores only suspension-hidden posts)
`

// reportsCommand dispatches `opsctl reports <list|show|resolve>`. sub is the first positional argument.
func reportsCommand(ctx context.Context, b *backends, sub string, a modArgs, out io.Writer, now func() time.Time) error {
	ctx, counter := budget.WithCounter(ctx)
	defer func() { fmt.Fprintf(out, "cost: reads=%d writes=%d\n", counter.Reads(), counter.Writes()) }()
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	switch sub {
	case "list":
		st := moderation.Status(strings.ToUpper(a.status))
		if st == "" {
			st = moderation.StatusOpen
		}
		if st != moderation.StatusOpen && st != moderation.StatusResolved {
			return fmt.Errorf("--status must be OPEN or RESOLVED")
		}
		rs, err := b.reports.List(cctx, st, a.limit)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "%d %s report(s), oldest first\n", len(rs), st)
		for _, r := range rs {
			fmt.Fprintf(out, "%s  %s  %-7s %-13s target=%s owner=%s\n", r.ID, r.CreatedAt.Format(time.RFC3339), r.TargetType, r.Reason, r.TargetID, r.TargetOwnerID)
		}
		return nil
	case "show":
		if !reportIDRe.MatchString(a.id) {
			return errors.New("--id must be a 32-character report id")
		}
		r, err := b.reports.Get(cctx, a.id)
		if err != nil {
			return err
		}
		printReport(out, r)
		return nil
	case "resolve":
		if !reportIDRe.MatchString(a.id) {
			return errors.New("--id must be a 32-character report id")
		}
		res := moderation.Resolution(strings.ToUpper(a.resolution))
		if !res.Valid() {
			return errors.New("--resolution must be NO_ACTION, DISMISSED, TAKEDOWN or SUSPENDED")
		}
		r, err := b.reports.Resolve(cctx, a.id, res, a.note, now())
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "report %s: %s (%s); evidence expires %s\n", r.ID, r.Status, r.Resolution, r.ExpireAt.Format(time.RFC3339))
		return nil
	}
	return fmt.Errorf("unknown reports subcommand %q (list, show, resolve)", sub)
}

func printReport(out io.Writer, r moderation.Report) {
	fmt.Fprintf(out, "report   %s\nstatus   %s", r.ID, r.Status)
	if r.Resolution != "" {
		fmt.Fprintf(out, " (%s at %s)", r.Resolution, r.ResolvedAt.Format(time.RFC3339))
	}
	fmt.Fprintf(out, "\ncreated  %s\nreporter %s\ntarget   %s %s (owner %s)\nreason   %s\nnote     %q\n",
		r.CreatedAt.Format(time.RFC3339), orDash(r.ReporterID), r.TargetType, r.TargetID, r.TargetOwnerID, r.Reason, r.Note)
	if r.Evidence != nil {
		fmt.Fprintf(out, "evidence post by @%s at %s: %q\n", r.Evidence.AuthorHandle, r.Evidence.PostCreatedAt.Format(time.RFC3339), r.Evidence.Text)
	}
	if r.ResolutionNote != "" {
		fmt.Fprintf(out, "resolution note %q\n", r.ResolutionNote)
	}
	if !r.ExpireAt.IsZero() {
		fmt.Fprintf(out, "expires  %s\n", r.ExpireAt.Format(time.RFC3339))
	}
}

func orDash(s string) string {
	if s == "" {
		return "- (reporter deleted)"
	}
	return s
}

// resolveReport closes report id with res (a no-op for an already resolved one) and prints the outcome.
func resolveReport(ctx context.Context, b *backends, id string, res moderation.Resolution, note string, out io.Writer, now func() time.Time) error {
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	r, err := b.reports.Resolve(cctx, id, res, note, now())
	if err != nil {
		return fmt.Errorf("resolve report %s: %w", id, err)
	}
	fmt.Fprintf(out, "report %s: %s (%s)\n", r.ID, r.Status, r.Resolution)
	return nil
}

// takedownPost is takedown-post: the post is hidden from every read path within CACHE_TTL (60 s).
func takedownPost(ctx context.Context, b *backends, a modArgs, out io.Writer, now func() time.Time) error {
	if !postIDRe.MatchString(a.post) {
		return errors.New("--post must be a 19-digit post id")
	}
	if a.report != "" && !reportIDRe.MatchString(a.report) {
		return errors.New("--report must be a 32-character report id")
	}
	ctx, counter := budget.WithCounter(ctx)
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	r, err := b.moderator.Takedown(cctx, a.post, now())
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "post %s: %s -> %s (hidden from GetPost, profile and Home within 60 s)\n", a.post, stateName(r.Before), stateName(r.After))
	if a.report != "" {
		if err := resolveReport(ctx, b, a.report, moderation.ResolutionTakedown, a.note, out, now); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "cost: reads=%d writes=%d\n", counter.Reads(), counter.Writes())
	return nil
}

// restorePost is restore-post: it clears TAKEN_DOWN only.
func restorePost(ctx context.Context, b *backends, a modArgs, out io.Writer) error {
	if !postIDRe.MatchString(a.post) {
		return errors.New("--post must be a 19-digit post id")
	}
	if a.report != "" && !reportIDRe.MatchString(a.report) {
		return errors.New("--report must be a 32-character report id")
	}
	ctx, counter := budget.WithCounter(ctx)
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	r, err := b.moderator.Restore(cctx, a.post)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "post %s: %s -> %s\n", a.post, stateName(r.Before), stateName(r.After))
	if r.Before == posts.ModerationSuspendedAuthor {
		fmt.Fprintln(out, "note: hidden because the author is suspended; unsuspend-user restores it")
	}
	fmt.Fprintf(out, "cost: reads=%d writes=%d\n", counter.Reads(), counter.Writes())
	return nil
}

func stateName(m posts.Moderation) string {
	if m == posts.ModerationNone {
		return "VISIBLE"
	}
	return string(m)
}

// suspendUser is suspend-user (ADR-0016 D4, ADR-0010 D10). Order: status first, then every post (resumable), so a
// crash leaves a suspended user with some posts still visible and re-running finishes the job.
func suspendUser(ctx context.Context, b *backends, uid string, a modArgs, out io.Writer, now func() time.Time) error {
	if a.dryRun {
		cctx, cancel := context.WithTimeout(ctx, callTimeout)
		defer cancel()
		p, err := b.profile(cctx, uid)
		if err != nil {
			return fmt.Errorf("read profile: %w", err)
		}
		plan, err := b.postsPlanner.PlanPurge(cctx, uid)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "dry-run: status=%s posts=%d -> would set SUSPENDED and hide up to %d post(s): reads~%d writes~%d (nothing written)\n",
			statusName(p.Status), plan.Posts, plan.Posts, plan.Posts+1, plan.Posts+1)
		return nil
	}
	ctx, _ = budget.WithCounter(ctx)
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	changed, err := b.accounts.SetAccountStatus(cctx, uid, identity.AccountStatusActive, identity.AccountStatusSuspended, now())
	cancel()
	switch {
	case errors.Is(err, identity.ErrStatusConflict):
		return errors.New("the account is DELETING (or not ACTIVE/SUSPENDED): refusing to change it")
	case errors.Is(err, identity.ErrNotFound):
		return errors.New("no such user")
	case err != nil:
		return err
	}
	if changed {
		fmt.Fprintln(out, "status: ACTIVE -> SUSPENDED (callers see ACCOUNT_RESTRICTED within the 60 s cache TTL)")
	} else {
		fmt.Fprintln(out, "status: already SUSPENDED; continuing with the posts")
	}
	if err := driveLoop(ctx, out, posts.ModerationCheckpoint{},
		func(ctx context.Context, cp posts.ModerationCheckpoint) (posts.ModerationCheckpoint, bool, error) {
			return b.moderator.HideAuthor(ctx, uid, cp, now())
		},
		func(cp posts.ModerationCheckpoint) string { return fmt.Sprintf("hidden=%d", cp.Changed) }, "hidden"); err != nil {
		return fmt.Errorf("%w (re-run suspend-user to resume)", err)
	}
	if a.report != "" {
		if err := resolveReport(ctx, b, a.report, moderation.ResolutionSuspended, a.note, out, now); err != nil {
			return err
		}
	}
	return nil
}

// unsuspendUser is unsuspend-user: ACTIVE again, then restore only the posts the suspension hid.
func unsuspendUser(ctx context.Context, b *backends, uid string, out io.Writer, now func() time.Time) error {
	ctx, _ = budget.WithCounter(ctx)
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	changed, err := b.accounts.SetAccountStatus(cctx, uid, identity.AccountStatusSuspended, identity.AccountStatusActive, now())
	cancel()
	switch {
	case errors.Is(err, identity.ErrStatusConflict):
		return errors.New("the account is DELETING (or not ACTIVE/SUSPENDED): refusing to change it")
	case errors.Is(err, identity.ErrNotFound):
		return errors.New("no such user")
	case err != nil:
		return err
	}
	if changed {
		fmt.Fprintln(out, "status: SUSPENDED -> ACTIVE")
	} else {
		fmt.Fprintln(out, "status: already ACTIVE; continuing with the posts")
	}
	if err := driveLoop(ctx, out, posts.ModerationCheckpoint{},
		func(ctx context.Context, cp posts.ModerationCheckpoint) (posts.ModerationCheckpoint, bool, error) {
			return b.moderator.RestoreAuthor(ctx, uid, cp)
		},
		func(cp posts.ModerationCheckpoint) string { return fmt.Sprintf("restored=%d", cp.Changed) }, "restored"); err != nil {
		return fmt.Errorf("%w (re-run unsuspend-user to resume)", err)
	}
	return nil
}

func statusName(s identity.AccountStatus) string {
	switch s {
	case identity.AccountStatusActive:
		return "ACTIVE"
	case identity.AccountStatusSuspended:
		return "SUSPENDED"
	case identity.AccountStatusDeleting:
		return "DELETING"
	}
	return "UNKNOWN"
}
