package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const listsUsage = `  opsctl lists hide    LIST_ID --project P [--report R] [--note N] [--dry-run]   (non-owners get NOT_FOUND on every list read within 60 s on every server; the owner still sees it)
  opsctl lists restore LIST_ID --project P [--dry-run]
`

// listsCacheBound is the longest an api instance serves a cached copy of a list doc (lists cacheTTL, ADR-0030 D11). opsctl is
// a separate process and cannot evict another process's memory, so this is the honest bound printed to the operator.
const listsCacheBound = "60 s"

// parseListsArgs validates `opsctl lists <hide|restore> LIST_ID` before anything is opened or confirmed.
func parseListsArgs(sub, listID string, a modArgs) error {
	switch sub {
	case "hide", "restore":
		if listID == "" {
			return usageErr("lists " + sub + " needs the list id as its first argument")
		}
		if err := lists.ValidateListID(listID); err != nil {
			return usageErr("lists " + sub + ": the list id must be 19 digits")
		}
	default:
		return usageErr("lists needs a sub-command: hide or restore")
	}
	if a.report != "" && sub != "hide" {
		return usageErr("--report is for lists hide only (a restore resolves nothing)")
	}
	if a.report != "" && !reportIDRe.MatchString(a.report) {
		return usageErr("--report must be a 32-character report id")
	}
	if a.note != "" && a.report == "" {
		return usageErr("--note is the report resolution note: it needs --report")
	}
	return nil
}

// listsCommand is `opsctl lists hide|restore` (security review W5-17 M-4, plan W5-44): the platform hide of one list. The
// reads already honour `hidden` (ADR-0030 D3): a hidden list answers NOT_FOUND to everyone but its owner on GetList,
// ListUserLists, ListListMembers and GetListTimeline, and a pinned tab of it shows "unavailable". The write is
// lists.Moderator.SetHidden, a field-level Update of `hidden` and `updatedAt` (never a Set); a missing list is refused.
//
// Cache: the api caches a list doc per instance for at most 60 s from the moment it was read (a fixed TTL, not refreshed by
// reads), so a hide reaches every warm instance within 60 s and a restore likewise. Client caches (a screen already open)
// follow their own refresh. Nothing in opsctl can evict a server's cache; the printed line says so.
//
// Cost: hide and restore are 1 read and, when the flag changes, 1 write (a repeat writes 0; a missing list refuses with 0
// writes). --dry-run is 1 read and no write. --report R (hide only; checked first: R must be a LIST report of exactly this list)
// resolves R as TAKEDOWN after the write, also when the list was already hidden; it adds 1 read to check and the resolve (1 read,
// 1 write). The cost line is printed last. Output holds no list name, description or owner:
// the id appears only as list_hash (the same one-way hash as uid_hash), in a fixed-shape audit line that is the moderation
// trail because the document records no actor.
func listsCommand(ctx context.Context, b *backends, project, sub, listID string, a modArgs, out io.Writer, now func() time.Time) error {
	if b.lists == nil {
		return errors.New("lists: no lists moderator configured")
	}
	ctx, counter := budget.WithCounter(ctx)
	defer func() { fmt.Fprintf(out, "cost: reads=%d writes=%d\n", counter.Reads(), counter.Writes()) }()
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	dryRun := a.dryRun
	hide := sub == "hide"
	if a.report != "" {
		// Checked first: the report must be a LIST report of exactly this list, so a typo cannot close an unrelated report.
		if err := checkReport(cctx, b, a.report, moderation.TargetList, listID, "", out); err != nil {
			return err
		}
	}
	hash := logger.HashUID(listID)
	if dryRun {
		l, err := b.lists.Get(cctx, listID)
		if errors.Is(err, lists.ErrNotFound) {
			return errors.New("no such list (nothing written)")
		}
		if err != nil {
			return err
		}
		verb := "would write"
		if l.Hidden == hide {
			verb = "already so; would write nothing"
		}
		fmt.Fprintf(out, "dry-run: lists %s list_hash=%s currently hidden=%t: %s (nothing written)\n", sub, hash, l.Hidden, verb)
		if a.report != "" {
			fmt.Fprintf(out, "dry-run: would resolve report %s as %s\n", a.report, moderation.ResolutionTakedown)
		}
		return nil
	}
	changed, err := b.lists.SetHidden(cctx, listID, hide, now())
	if errors.Is(err, lists.ErrNotFound) {
		return errors.New("no such list (nothing written)")
	}
	if err != nil {
		return err
	}
	switch {
	case changed && hide:
		fmt.Fprintf(out, "hidden: list_hash=%s\nnon-owners get NOT_FOUND within %s on every server (cached copies expire; the owner still sees the list); a screen already open keeps its copy until it refreshes\n", hash, listsCacheBound)
	case changed:
		fmt.Fprintf(out, "restored: list_hash=%s\nit is visible to non-owners again within %s on every server if it is public\n", hash, listsCacheBound)
	case hide:
		fmt.Fprintf(out, "already hidden: list_hash=%s; nothing written\n", hash)
	default:
		fmt.Fprintf(out, "not hidden: list_hash=%s; nothing written\n", hash)
	}
	report := "-"
	if a.report != "" {
		report = a.report
	}
	fmt.Fprintf(out, "audit: lists %s project=%s at=%s list_hash=%s wrote=%t report=%s\n", sub, project, now().UTC().Format(time.RFC3339), hash, changed, report)
	if a.report != "" {
		// Also when the list was already hidden: the operator's decision on the report still stands.
		return resolveReport(ctx, b, a.report, moderation.ResolutionTakedown, a.note, out, now)
	}
	return nil
}
