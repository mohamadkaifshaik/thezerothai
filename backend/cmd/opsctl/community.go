package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"slices"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

const communityUsage = `  opsctl community suspend CID --project P [--report R] [--note N] [--dry-run]   (NOT_FOUND to everyone on every read, posting refused, within 60 s on every server; the owner still sees it)
  opsctl community restore CID --project P [--dry-run]                            (ACTIVE again; an ownerless community comes back ARCHIVED)
  opsctl community archive CID --project P [--dry-run]                            (an owner's support request: read-only, ownerless, out of the directory; NOT undone by restore)
  opsctl community loghash [--community CID] [--post ID] [--user UID]   (no project; needs CURSOR_HMAC_KEY: the keyed community_hash, post_hash, target_hash and uid_hash of the request lines)
`

// communityCacheBound is the longest an api instance serves a cached copy of a community doc (communities cache). opsctl is
// a separate process and cannot evict another process's memory, so this is the honest bound printed to the operator.
const communityCacheBound = "60 s"

// parseCommunityArgs validates `opsctl community <suspend|restore|archive> CID` before anything is opened or confirmed.
func parseCommunityArgs(sub, cid string, a modArgs) error {
	switch sub {
	case "suspend", "restore", "archive":
		if cid == "" {
			return usageErr("community " + sub + " needs the community id as its first argument")
		}
		if err := communities.ValidateCommunityID(cid); err != nil {
			return usageErr("community " + sub + ": the community id must be 19 digits")
		}
	default:
		return usageErr("community needs a sub-command: suspend, restore or archive")
	}
	if a.report != "" && sub != "suspend" {
		return usageErr("--report is for community suspend only (restore and archive resolve nothing)")
	}
	if a.report != "" && !reportIDRe.MatchString(a.report) {
		return usageErr("--report must be a 32-character report id")
	}
	if a.note != "" && a.report == "" {
		return usageErr("--note is the report resolution note: it needs --report")
	}
	return nil
}

// communityCommand is `opsctl community suspend|restore|archive`. The reads already honour SUSPENDED
// (N3): a suspended community is NOT_FOUND on every RPC for everyone but, on GetCommunity and ListMyCommunities, its owner; it is out of
// the directory and CreatePost into it is refused. The writes are communities.Platform's field-level Updates (never a Set).
//
// Cache: the api caches a community doc per instance for at most 60 s, so a suspend, a restore and an archive reach every warm instance
// within 60 s. Client caches (a screen already open) follow their own refresh. Nothing in opsctl can evict a server's cache; the printed
// line says so.
//
// Cost (an ops path): suspend and restore are 1 read and, when the status changes, 1 write (a repeat writes 0; a missing community
// refuses with 0 writes). archive is 3 reads and 2 writes (a repeat 1 read, 0 writes). --dry-run is 1 read and no write. --report R
// (suspend only; checked first: R must be a COMMUNITY report of exactly this community) resolves R as TAKEDOWN after the write, also when
// the community was already suspended; it adds 1 read to check and the resolve (1 read, 1 write). The cost line is printed last.
// Output holds no name, description or owner: the id appears only as community_hash (the keyed logger.HashCommunity; a marker without CURSOR_HMAC_KEY), in a fixed-shape audit
// line that is the moderation trail because the community document records no platform actor.
func communityCommand(ctx context.Context, b *backends, project, sub, cid string, a modArgs, out io.Writer, now func() time.Time) error {
	if b.communities == nil {
		return errors.New("community: no communities platform configured")
	}
	ctx, counter := budget.WithCounter(ctx)
	defer func() { fmt.Fprintf(out, "cost: reads=%d writes=%d\n", counter.Reads(), counter.Writes()) }()
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	if a.report != "" {
		// Checked first: the report must be a COMMUNITY report of exactly this community, so a typo cannot close an unrelated report.
		if err := checkReport(cctx, b, a.report, moderation.TargetCommunity, cid, "", out); err != nil {
			return err
		}
	}
	hash := communityHashForAudit(cid)
	if a.dryRun {
		c, err := b.communities.Get(cctx, cid)
		if errors.Is(err, communities.ErrNotFound) {
			return errors.New("no such community (nothing written)")
		}
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "dry-run: community %s community_hash=%s currently %s: %s (nothing written)\n", sub, hash, c.Status, dryRunVerdict(sub, c))
		if a.report != "" {
			fmt.Fprintf(out, "dry-run: would resolve report %s as %s\n", a.report, moderation.ResolutionTakedown)
		}
		return nil
	}
	wrote, err := runCommunityWrite(cctx, b, sub, cid, now(), hash, out)
	if err != nil {
		return err
	}
	report := "-"
	if a.report != "" {
		report = a.report
	}
	fmt.Fprintf(out, "audit: community %s project=%s at=%s community_hash=%s wrote=%t report=%s\n", sub, project, now().UTC().Format(time.RFC3339), hash, wrote, report)
	if a.report != "" {
		// Also when the community was already suspended: the operator's decision on the report still stands.
		return resolveReport(ctx, b, a.report, moderation.ResolutionTakedown, a.note, out, now)
	}
	return nil
}

// dryRunVerdict is what the real command would do to c.
func dryRunVerdict(sub string, c communities.Community) string {
	switch sub {
	case "suspend":
		if c.Status == communities.StatusSuspended {
			return "already so; would write nothing"
		}
	case "restore":
		if c.Status != communities.StatusSuspended {
			return "not suspended; would write nothing"
		}
		if c.OwnerID == "" {
			return "would write status ARCHIVED (no owner)"
		}
		return "would write status ACTIVE"
	case "archive":
		switch {
		case c.Status == communities.StatusSuspended:
			return "refused: SUSPENDED (restore it first)"
		case c.OwnerID == "":
			return "already ownerless; would write nothing"
		}
		return "would write status ARCHIVED and clear the owner (not undone by restore)"
	}
	return "would write status SUSPENDED"
}

// runCommunityWrite performs the write of sub and prints its outcome; wrote says whether anything changed.
func runCommunityWrite(ctx context.Context, b *backends, sub, cid string, at time.Time, hash string, out io.Writer) (wrote bool, err error) {
	if sub == "archive" {
		res, err := b.communities.Archive(ctx, cid, at, 0)
		switch {
		case errors.Is(err, communities.ErrNotFound):
			return false, errors.New("no such community (nothing written)")
		case errors.Is(err, communities.ErrSuspendedArchive):
			return false, errors.New("the community is SUSPENDED: run community restore first, then archive (nothing written)")
		case err != nil:
			return false, err
		}
		if !res.Changed {
			fmt.Fprintf(out, "already ownerless: community_hash=%s; nothing written\n", hash)
			return false, nil
		}
		fmt.Fprintf(out, "archived: community_hash=%s\nread-only and out of the directory within %s on every server; the former owner stays a member; restore does NOT undo this (an ownerless community stays ARCHIVED)\n", hash, communityCacheBound)
		if res.OwnerMember != communities.MemberJoined {
			fmt.Fprintf(out, "note: the former owner had no JOINED member document (state %q); check invariant I-M by hand\n", res.OwnerMember)
		}
		return true, nil
	}
	suspend := sub == "suspend"
	changed, before, after, err := b.communities.SetSuspended(ctx, cid, suspend, at)
	if errors.Is(err, communities.ErrNotFound) {
		return false, errors.New("no such community (nothing written)")
	}
	if err != nil {
		return false, err
	}
	switch {
	case changed && suspend:
		fmt.Fprintf(out, "suspended: community_hash=%s (was %s)\nNOT_FOUND to everyone within %s on every server (cached copies expire; GetCommunity and ListMyCommunities still show the owner their community); CreatePost into it is refused; a screen already open keeps its copy until it refreshes\n", hash, before, communityCacheBound)
	case changed:
		fmt.Fprintf(out, "restored: community_hash=%s status=%s\nvisible again within %s on every server\n", hash, after, communityCacheBound)
	case suspend:
		fmt.Fprintf(out, "already suspended: community_hash=%s; nothing written\n", hash)
	default:
		fmt.Fprintf(out, "not suspended: community_hash=%s (status %s); nothing written\n", hash, before)
	}
	return changed, nil
}

// removalTotals counts what the removal-log appends of one command did.
type removalTotals struct {
	communities int // communities whose log was written
	entries     int // entries added
	missing     int // communities that no longer exist
}

// appendCommunityRemovals appends the posts to each community's recentRemovals, once per community. A missing community is
// counted, not an error: the posts are hidden either way. Any other failure is returned so the caller's checkpoint repeats (the append is
// idempotent: a post already listed writes nothing).
func appendCommunityRemovals(ctx context.Context, b *backends, byCommunity map[string][]string, at time.Time, tot *removalTotals) error {
	if b.removals == nil || len(byCommunity) == 0 {
		return nil
	}
	cids := make([]string, 0, len(byCommunity))
	for cid := range byCommunity {
		cids = append(cids, cid)
	}
	slices.Sort(cids)
	for _, cid := range cids {
		n, err := b.removals.Append(ctx, cid, byCommunity[cid], at, 0)
		switch {
		case errors.Is(err, communities.ErrNotFound):
			tot.missing++
		case err != nil:
			return fmt.Errorf("community removal log %s: %w", communityHashForAudit(cid), err)
		case n > 0:
			tot.communities++
			tot.entries += n
		}
	}
	return nil
}

// groupCommunityPosts groups a HideAuthor page's community posts by community.
func groupCommunityPosts(in []posts.CommunityPostRef) map[string][]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string][]string)
	for _, p := range in {
		out[p.CommunityID] = append(out[p.CommunityID], p.PostID)
	}
	return out
}

// printRemovalTotals prints the community removal-log line of a command, only when it did anything.
func printRemovalTotals(out io.Writer, tot removalTotals) {
	if tot.communities == 0 && tot.missing == 0 {
		return
	}
	fmt.Fprintf(out, "community removal log: communities=%d entries=%d missing=%d (community feeds list these posts in removed_ids within 60 s)\n", tot.communities, tot.entries, tot.missing)
}
