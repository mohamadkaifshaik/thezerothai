package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
)

const communityHiddenUsage = `  opsctl community hidden CID --project P [--page-token T]                        (read-only: the posts and replies a moderator hid, ids and times only, 50 a page)
  opsctl community restore-hidden CID --project P [--since RFC3339] [--page-token T] [--dry-run]   (platform recovery of a rogue moderator's or a raid's hides; posts under a takedown stay hidden)
`

// hiddenPageSize is the page of both commands (Limit <= 50); a variable so a test can exercise paging with a few rows.
var hiddenPageSize = 50

// restoreHiddenMaxPages caps one run of restore-hidden (100 pages = at most 5,000 post writes, a quarter of the Firestore free write quota
// of a day). A larger backlog is finished by re-running; the printed next_page_token resumes a --since run.
const restoreHiddenMaxPages = 100

// communityEntryBound is timeline's communityEntryMaxAge (5 min), the longest a restored root can stay missing from a feed on an instance
// whose shared community entry is cached. opsctl is a separate process and cannot evict it; a literal here avoids importing timeline.
const communityEntryBound = "5 minutes"

// hiddenPageTokenPrefix versions the --page-token (the id of the last row printed).
const hiddenPageTokenPrefix = "h1."

// hiddenCommunityHash is the community_hash of the hidden commands: the keyed hash (CURSOR_HMAC_KEY), else the unavailable marker.
func hiddenCommunityHash(cid string) string { return communityHashForAudit(cid) }

func isHiddenSub(sub string) bool { return sub == "hidden" || sub == "restore-hidden" }

// parseHiddenArgs validates `opsctl community hidden|restore-hidden CID` before anything is opened.
func parseHiddenArgs(sub, cid string, a modArgs) error {
	if cid == "" {
		return usageErr("community " + sub + " needs the community id as its first argument")
	}
	if err := communities.ValidateCommunityID(cid); err != nil {
		return usageErr("community " + sub + ": the community id must be 19 digits")
	}
	if a.limit != 0 {
		return usageErr("--limit is not for community " + sub + " (a page is 50 rows)")
	}
	if a.report != "" || a.note != "" {
		return usageErr("--report and --note are not for community " + sub)
	}
	if sub == "hidden" && (a.dryRun || a.since != "") {
		return usageErr("community hidden is read-only: --dry-run and --since are for restore-hidden")
	}
	if _, err := parseHiddenSince(a.since); err != nil {
		return err
	}
	if _, err := decodeHiddenToken(a.pageToken); err != nil {
		return err
	}
	return nil
}

func parseHiddenSince(s string) (time.Time, error) {
	if s == "" {
		return time.Time{}, nil
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, usageErr("--since must be an RFC 3339 time such as 2026-11-02T09:30:00Z")
	}
	return t.UTC(), nil
}

func decodeHiddenToken(tok string) (string, error) {
	if tok == "" {
		return "", nil
	}
	id, ok := strings.CutPrefix(tok, hiddenPageTokenPrefix)
	if !ok || id == "" || len(id) > 40 || strings.Trim(id, "0123456789") != "" {
		return "", usageErr("--page-token is not a token printed by this command")
	}
	return id, nil
}

func hiddenToken(id string) string { return hiddenPageTokenPrefix + id }

// hiddenCommand is `opsctl community hidden|restore-hidden`, the platform recovery of what a rogue or
// hijacked moderator hid, or a raid cleaned badly. Output holds ids and times only: never text, a name or a uid; the community appears only as
// community_hash. It works in any community status and any flag state (it touches documents only).
//
// hidden: read-only. restore-hidden: a field-level Update per restored post, one community
// Update for the recentRemovals deletes and the run's single RESTORE modlog entry with the actor _platform. A re-run with nothing hidden
// writes nothing; --dry-run reads the same documents and writes nothing. --since T keeps posts hidden before T and skips (skipped_no_time) those hidden
// before communityHiddenAt existed; a run without --since restores them. A post with `moderation` set stays hidden (skipped_platform).
// Staleness: opsctl cannot evict a server cache. A restored root returns to community feeds within 5 minutes (communityEntryMaxAge), a
// restored reply to thread pages at once and to parent slots within 60 s.
func hiddenCommand(ctx context.Context, b *backends, project, sub, cid string, a modArgs, out io.Writer, now func() time.Time) error {
	if b.hidden == nil {
		return errors.New("community: no hidden-post recovery configured")
	}
	after, err := decodeHiddenToken(a.pageToken)
	if err != nil {
		return err
	}
	hash := hiddenCommunityHash(cid)
	if sub == "hidden" {
		return listHidden(ctx, b, project, cid, hash, after, out, now)
	}
	since, err := parseHiddenSince(a.since)
	if err != nil {
		return err
	}
	return restoreHidden(ctx, b, project, cid, hash, after, since, a.dryRun, out, now)
}

func listHidden(ctx context.Context, b *backends, project, cid, hash, after string, out io.Writer, now func() time.Time) error {
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	rows, next, err := b.hidden.ListHidden(cctx, cid, after, hiddenPageSize)
	if errors.Is(err, communities.ErrNotFound) {
		return errors.New("no such community (nothing read)")
	}
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "hidden: community_hash=%s\n", hash)
	for _, r := range rows {
		kind, at, mod := "root", "unknown", "none"
		if r.Reply {
			kind = "reply"
		}
		if !r.HiddenAt.IsZero() {
			at = r.HiddenAt.UTC().Format(time.RFC3339)
		}
		if r.Moderated {
			mod = "set"
		}
		fmt.Fprintf(out, "post=%s kind=%s hidden_at=%s moderation=%s\n", r.PostID, kind, at, mod)
	}
	tok := "none"
	if next != "" {
		tok = hiddenToken(next)
	}
	fmt.Fprintf(out, "page: rows=%d next_page_token=%s\n", len(rows), tok)
	fmt.Fprintf(out, "audit: community hidden project=%s at=%s community_hash=%s listed=%d\n", project, now().UTC().Format(time.RFC3339), hash, len(rows))
	return nil
}

func restoreHidden(ctx context.Context, b *backends, project, cid, hash, after string, since time.Time, dryRun bool, out io.Writer, now func() time.Time) error {
	var tot communities.RestoreHiddenResult
	entry := false  // the run's single modlog entry, once a page wrote it
	capped := false // stopped at the page cap with a full last page
	var runErr error
	pages, notFound := 0, false
	for pages < restoreHiddenMaxPages {
		cctx, cancel := context.WithTimeout(ctx, callTimeout)
		res, err := b.hidden.RestoreHidden(cctx, communities.RestoreHiddenParams{
			CID: cid, After: after, Limit: hiddenPageSize, Since: since, WriteEntry: !entry && !dryRun, DryRun: dryRun, Now: now(),
		})
		cancel()
		if err != nil {
			runErr = err
			if errors.Is(err, communities.ErrNotFound) {
				runErr, notFound = errors.New("no such community (nothing written)"), true
			}
			break
		}
		pages++
		tot.Listed += res.Listed
		tot.Restored += res.Restored
		tot.SkippedPlatform += res.SkippedPlatform
		tot.SkippedNoTime += res.SkippedNoTime
		tot.SkippedOther += res.SkippedOther
		entry = entry || res.EntryWritten
		if res.Listed < hiddenPageSize {
			after = ""
			break
		}
		after = res.Last
		capped = pages == restoreHiddenMaxPages
	}
	if notFound && pages == 0 {
		return runErr // nothing was read or written: no summary, no audit line
	}
	verb, noun := "restored", "restored"
	if dryRun {
		verb, noun = "dry-run: would restore", "would_restore"
	}
	fmt.Fprintf(out, "%s: community_hash=%s listed=%d %s=%d skipped_platform=%d skipped_no_time=%d skipped_other=%d\n", verb, hash, tot.Listed, noun, tot.Restored, tot.SkippedPlatform, tot.SkippedNoTime, tot.SkippedOther)
	outcome := "ok"
	switch {
	case runErr != nil:
		outcome = "error"
		resume := ""
		if after != "" {
			resume = "; resume with --page-token " + hiddenToken(after)
		}
		fmt.Fprintf(out, "error after %d pages%s\n", pages, resume)
	case capped:
		outcome = "capped"
		fmt.Fprintf(out, "stopped at the page cap (%d pages): run again; with --since resume with --page-token %s\n", restoreHiddenMaxPages, hiddenToken(after))
	}
	if dryRun {
		fmt.Fprintln(out, "dry-run: nothing written")
		return runErr
	}
	fmt.Fprintf(out, "modlog: %d platform entry written; roots return to community feeds within %s on every server (communityEntryMaxAge), replies to thread pages at once; posts with a platform takedown stay hidden\n", boolInt(entry), communityEntryBound)
	fmt.Fprintf(out, "audit: community restore-hidden project=%s at=%s community_hash=%s outcome=%s listed=%d restored=%d skipped_platform=%d skipped_no_time=%d skipped_other=%d\n",
		project, now().UTC().Format(time.RFC3339), hash, outcome, tot.Listed, tot.Restored, tot.SkippedPlatform, tot.SkippedNoTime, tot.SkippedOther)
	return runErr
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
