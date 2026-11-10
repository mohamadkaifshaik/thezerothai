// Command opsctl is the founder's manual operations CLI: purge-graph deletes one user's social
// graph (the graph.Eraser cascade) and export-graph writes their graph data as JSON. It runs on the
// founder's machine with Application Default Credentials (or against the emulator via
// FIRESTORE_EMULATOR_HOST); it is never deployed. Every command requires an explicit --project, and a
// production project asks for typed confirmation.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/articles"
	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/internal/search"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/fsclient"
)

const (
	// callTimeout bounds every PurgeUser call / export (every outbound call has a deadline).
	callTimeout = 2 * time.Minute
	// maxConsecutiveErrors stops a purge that keeps failing instead of looping forever.
	maxConsecutiveErrors = 5
	maxPurgeCalls        = 100_000
)

// backends is everything a command needs; a struct of interfaces so tests can substitute fakes.
type backends struct {
	eraser  graph.Eraser
	planner interface {
		PlanPurge(ctx context.Context, uid string) (graph.PurgePlan, error)
	}
	exporter interface {
		ExportUser(ctx context.Context, uid string) (graph.Export, error)
	}
	// posts: the Eraser/Exporter seams and the dry-run counter.
	postsEraser  posts.Eraser
	postsPlanner interface {
		PlanPurge(ctx context.Context, uid string) (posts.PurgePlan, error)
	}
	postsExporter posts.Exporter
	profile       func(ctx context.Context, uid string) (identity.Profile, error)
	// moderation: report list/show/resolve, post takedown, and the account status change.
	reports   moderation.Ops
	moderator posts.Moderator
	// messages takes one direct message down (`opsctl messages takedown`).
	messages messaging.Moderator
	// placeholder serves `messages migrate-placeholder` (L-2): the dev-only rewrite of the legacy erased-user placeholder.
	placeholder messaging.PlaceholderMigrator
	// cleanup removes the REPOSTs and tombstones the quote embeds of a taken-down post.
	cleanup posts.Cleanup
	// copied lists the suspended author's posts that have copies, for suspend-user's copy cleanup (#151).
	copied posts.CopiedLister
	// backfiller serves backfill-has-media: the posts repo helper that owns the hasMedia rule.
	backfiller posts.HasMediaBackfiller
	accounts   accountStatusSetter
	// profiles serves clear-profile-fields: identity's field-level clear of users/{uid}.
	profiles profileClearer
	// retire is the A4 retire step clear-profile-fields runs in process for a cleared banner or avatar (media.Jobs); nil
	// means it never runs. retireMode is PROFILE_MEDIA_RETIRE read from the operator's shell (unset = off), and retireErr
	// is its parse error, which clear-profile-fields reports before writing anything when an image is among the fields.
	retire     profileRetirer
	retireMode config.ProfileMediaRetire
	retireErr  error
	// actorSweeper removes the notification rows other users hold about a suspended actor (security audit N-4);
	// nil skips the sweep.
	actorSweeper notifications.ActorSweeper
	// sleep replaces the real wait of suspend-user's settle pass in tests (nil = real timer).
	sleep func(ctx context.Context, d time.Duration) error
	// trends serves `trends hide|unhide|list`: search's store of trends/hidden.
	trends search.TrendsStore
	// lists serves `lists hide|restore` (security review M-4): the lists module's platform hide of one list.
	lists lists.Moderator
	// beacons hides and restores one beacon (`opsctl beacon hide|restore`, the only platform hide lever for beacons).
	beacons beacons.Moderator
	// beaconStats is the read-only pilot counts (`opsctl beacon counts`); the same repo as beacons.
	beaconStats beacons.Stats
	// communities serves `community suspend|restore|archive` and removals is the recentRemovals append of takedown-post and suspend-user.
	communities communities.Platform
	removals    communities.PlatformRemovals
	// hidden serves `community hidden|restore-hidden`.
	hidden communities.HiddenRecovery
	// listAuthUsers and usersExist serve check-t26 (read-only).
	listAuthUsers authLister
	usersExist    usersExistFn
	// mediaBackfill serves backfill-media-orphans and newMediaSweeper media-orphan-sweep (media's orphan sweep, in process,
	// built per run from the explicit --profile-retire and --dry-run).
	mediaBackfill   mediaOrphanBackfiller
	newMediaSweeper mediaSweeperFactory
	close           func()
}

type opener func(ctx context.Context, project string) (*backends, error)

func main() {
	// Ctrl-C cancels the context so a long suspend-user wait ends with the re-run hint instead of a hard kill.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	code := run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr, openFirestore, time.Now)
	stop()
	os.Exit(code)
}

func openFirestore(ctx context.Context, project string) (*backends, error) {
	client, err := fsclient.New(ctx, project)
	if err != nil {
		return nil, err
	}
	graphRepo := graph.NewFirestoreRepo(client)
	identityRepo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)
	graphRepo.SetTxProfiles(identityRepo)
	postsRepo := posts.NewFirestoreRepo(client)
	// Takedown and the purge copy phase drive posts' clean-up: counters and the reposts-doc delete.
	postsRepo.SetWriters(posts.WriteDeps{Counters: identityRepo})
	postsRepo.SetRepostLinks(engagement.NewFirestoreRepo(client, engagement.WriteDeps{}))
	moderationRepo := moderation.NewFirestoreRepo(client, nil)
	communitiesRepo := communities.NewFirestoreRepo(client, nil)         // the platform levers need no idempotency or quota store
	msgRepo := messaging.NewFirestoreRepo(client, nil)                   // takedown and the placeholder migration: no quota store needed
	beaconRepo := beacons.NewFirestoreRepo(client, nil, nil)             // SetHidden, Get and Counts need no quota or idempotency store
	communitiesRepo.WithHiddenPosts(posts.NewCommunityModerator(client)) // the platform recovery of hidden posts
	lister, err := newAuthLister(ctx, project)
	if err != nil {
		_ = client.Close()
		return nil, err
	}
	// The retire step clear-profile-fields runs in process. The switch is the operator's shell
	// PROFILE_MEDIA_RETIRE (an opsctl run has no Cloud Run environment); unset is off. NewBuckets and the storage client do
	// no I/O until the first object call.
	retireMode, retireErr := config.ParseProfileMediaRetire(os.Getenv("PROFILE_MEDIA_RETIRE"))
	buckets, err := media.NewBuckets(project+"-media-upload", project+"-media")
	if err != nil {
		_ = client.Close()
		return nil, err
	}
	mediaRepo := media.NewFirestoreRepo(client, media.WriteDeps{})
	var retire profileRetirer
	if retireErr == nil {
		// No PostGone and no publisher: only Retire runs here, never the post_delete handler.
		retire = media.NewJobs(mediaRepo, buckets, nil, nil).
			WithProfileRetire(media.RetireDeps{Mode: retireMode, Users: identityRepo, Tagger: buckets})
	}
	// The orphan sweep with the same holders as the daily step, in delete mode, under the operator's explicit
	// --profile-retire (never the shell's PROFILE_MEDIA_RETIRE) and --dry-run.
	newMediaSweeper := func(retire config.ProfileMediaRetire, dryRun bool) (mediaOrphanSweeper, error) {
		return media.NewOrphanSweeper(media.OrphanSweepDeps{
			Repo: mediaRepo, Objects: buckets, Profiles: identityRepo, RetireMode: retire,
			Mode: config.MediaOrphanSweepDelete, DryRun: dryRun,
			Drafts: media.NewDraftHolds(postsRepo, articles.NewMediaHolds(client)),
		})
	}
	return &backends{
		eraser:          graphRepo,
		planner:         graphRepo,
		exporter:        graphRepo,
		postsEraser:     postsRepo,
		postsPlanner:    postsRepo,
		postsExporter:   postsRepo,
		profile:         identityRepo.GetProfile,
		reports:         moderationRepo,
		messages:        msgRepo,
		placeholder:     msgRepo,
		moderator:       postsRepo,
		cleanup:         postsRepo,
		copied:          postsRepo,
		backfiller:      postsRepo,
		accounts:        identityRepo,
		profiles:        identityRepo,
		trends:          search.NewTrendsRepo(client),
		lists:           lists.NewFirestoreRepo(client, nil, nil), // SetHidden and Get need no quota or idempotency store
		beacons:         beaconRepo,
		beaconStats:     beaconRepo,
		communities:     communitiesRepo,
		removals:        communitiesRepo,
		hidden:          communitiesRepo,
		retire:          retire,
		retireMode:      retireMode,
		retireErr:       retireErr,
		actorSweeper:    notifications.NewFirestoreRepo(client).WithDirectory(newProfileDirectory(identityRepo)),
		listAuthUsers:   lister,
		usersExist:      newUsersExist(client),
		mediaBackfill:   mediaRepo,
		newMediaSweeper: newMediaSweeper,
		close:           func() { _ = client.Close() },
	}, nil
}

const usage = `usage:
  opsctl purge-graph  --project P --uid U [--dry-run] [--skip-start-gate]
  opsctl export-graph --project P --uid U [--out FILE]
  opsctl purge-posts  --project P --uid U [--dry-run] [--skip-start-gate]   (run before purge-graph)
  opsctl export-posts --project P --uid U [--out FILE]
  opsctl check-t26    --project P   (read-only; prints aggregate counts only)
  opsctl backfill-has-media --project P [--dry-run] [--after POST_ID]   (one-off per project; <= 5,000 writes per run)
  opsctl clear-profile-fields --project P --uid U --fields website,location,banner,avatar,bio [--report R] [--note N] [--dry-run]
                          (clears the named fields of one profile, skips empty ones;
                          A cleared banner or avatar is scheduled for deletion in 24-48 h when PROFILE_MEDIA_RETIRE=banner|all
                          is set in this shell to the project's value; unset = off, delete the printed objects by hand)
  opsctl backfill-media-orphans --project P [--dry-run] [--after MEDIA_ID]   (one-off per project; <= 5,000 writes per run:
                          published, unattached media predating the orphan sweep become candidates in 7 days)
  opsctl media-orphan-sweep --project P --profile-retire off|banner|all [--dry-run]   (drains the daily orphan sweep's
                          backlog in delete mode whatever MEDIA_ORPHAN_SWEEP says; --profile-retire has no default and the
                          shell's PROFILE_MEDIA_RETIRE is not read; --dry-run computes one page and writes nothing)
` + modUsage + trendsUsage + listsUsage + beaconUsage + communityUsage + communityHiddenUsage

// run returns the process exit code: 0 ok, 1 runtime failure, 2 usage error.
func run(ctx context.Context, args []string, in io.Reader, out, errOut io.Writer, open opener, now func() time.Time) int {
	if len(args) == 0 {
		fmt.Fprint(errOut, usage)
		return 2
	}
	cmd, rest := args[0], args[1:]
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(errOut)
	project := fs.String("project", "", "GCP project id (required)")
	uid := fs.String("uid", "", "user id (required)")
	dryRun := fs.Bool("dry-run", false, "purge-graph, purge-posts, backfill-has-media, backfill-media-orphans, media-orphan-sweep, suspend-user, unsuspend-user, clear-profile-fields, messages takedown, lists hide|restore, beacon hide|restore, community suspend|restore|archive: print counts|restore: print counts or the plan, write nothing (other commands reject it)")
	skipGate := fs.Bool("skip-start-gate", false, "purge-graph, purge-posts: skip the DELETING >= 120 s start gate (ADR-0008 D10)")
	outFile := fs.String("out", "", "export-graph, export-posts: write JSON to this file instead of stdout")
	after := fs.String("after", "", "backfill-has-media, backfill-media-orphans: resume after this post or media id (the checkpoint a capped run printed)")
	profileRetire := fs.String("profile-retire", "", "media-orphan-sweep (required, no default): off|banner|all, which unshown profile images the sweep may delete")
	var ma modArgs
	fs.StringVar(&ma.id, "id", "", "reports show|resolve: report id")
	fs.StringVar(&ma.post, "post", "", "takedown-post, restore-post: post id")
	fs.StringVar(&ma.report, "report", "", "takedown-post, suspend-user, clear-profile-fields, messages takedown, lists hide, beacon hide, community suspend: also resolve this report id")
	fs.StringVar(&ma.status, "status", "", "reports list: OPEN (default) or RESOLVED")
	fs.StringVar(&ma.resolution, "resolution", "", "reports resolve: NO_ACTION or DISMISSED")
	fs.StringVar(&ma.note, "note", "", "reports resolve, takedown-post, suspend-user, clear-profile-fields, messages takedown, lists hide, beacon hide, community suspend: resolution note")
	fs.StringVar(&ma.fields, "fields", "", "clear-profile-fields: comma-separated list of website, location, banner, avatar, bio")
	fs.IntVar(&ma.limit, "limit", 0, "reports list: at most N reports (default 20, max 50)")
	fs.StringVar(&ma.since, "since", "", "community restore-hidden: restore only posts hidden at or after this RFC 3339 time")
	fs.StringVar(&ma.pageToken, "page-token", "", "community hidden, restore-hidden: resume after the token a previous page printed")

	switch cmd {
	case "purge-graph", "export-graph", "purge-posts", "export-posts", "check-t26",
		"reports", "takedown-post", "restore-post", "suspend-user", "unsuspend-user", "backfill-has-media", "clear-profile-fields",
		"messages", "trends", "polls", "lists", "beacon", "community", "backfill-media-orphans", "media-orphan-sweep":
	default:
		fmt.Fprintf(errOut, "unknown command %q\n%s", cmd, usage)
		return 2
	}
	// `opsctl reports <list|show|resolve> [flags]` and `opsctl messages takedown <convId:msgId> [flags]`: the sub-command (and
	// the message to take down) are the first positional arguments. They come off before the flags are parsed, so --project
	// and --dry-run may follow them.
	sub, msgTarget := "", ""
	if (cmd == "reports" || cmd == "messages" || cmd == "trends" || cmd == "polls" || cmd == "lists" || cmd == "beacon" || cmd == "community") && len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
		sub, rest = rest[0], rest[1:]
	}
	if cmd == "polls" {
		// `opsctl polls loghash POST_ID`: no Firestore, no project; the keyed post_hash of the VotePoll request line (needs CURSOR_HMAC_KEY).
		if sub != "loghash" || len(rest) != 1 || strings.HasPrefix(rest[0], "-") {
			fmt.Fprintf(errOut, "usage: opsctl polls loghash POST_ID\n%s", usage)
			return 2
		}
		if err := postLogHash(rest[0], os.Getenv(cursorKeyEnv), out); err != nil {
			fmt.Fprintln(errOut, err)
			return 2
		}
		return 0
	}
	if cmd == "community" && sub == "loghash" {
		// `opsctl community loghash [--community CID] [--post ID] [--user UID]`: no Firestore, no project (needs CURSOR_HMAC_KEY).
		if err := communityLogHash(rest, os.Getenv(cursorKeyEnv), out, errOut); err != nil {
			fmt.Fprintln(errOut, err)
			return 2
		}
		return 0
	}
	if cmd == "messages" && (sub == "takedown" || sub == "loghash") && len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
		msgTarget, rest = rest[0], rest[1:]
	}
	var trendTag string
	if cmd == "trends" && (sub == "hide" || sub == "unhide") && len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
		trendTag, rest = rest[0], rest[1:]
	}
	var listID string
	if cmd == "lists" && (sub == "hide" || sub == "restore") && len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
		listID, rest = rest[0], rest[1:]
	}
	var beaconID string
	if cmd == "beacon" && (sub == "hide" || sub == "restore") && len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
		beaconID, rest = rest[0], rest[1:]
	}
	var communityID string
	if cmd == "community" && (sub == "suspend" || sub == "restore" || sub == "archive" || isHiddenSub(sub)) && len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
		communityID, rest = rest[0], rest[1:]
	}
	if cmd == "messages" && sub != "takedown" && sub != "loghash" && sub != "migrate-placeholder" { // before the flags: a stray positional would otherwise be reported instead
		fmt.Fprintf(errOut, "messages needs a sub-command: takedown, loghash or migrate-placeholder\n%s", usage)
		return 2
	}
	if err := fs.Parse(rest); err != nil {
		return 2
	}
	// flag.Parse stops at the first non-flag argument. Without this check an unquoted multi-word --note would
	// swallow every flag after it (--dry-run, --report) and the command would run as if they were absent.
	if fs.NArg() > 0 {
		fmt.Fprintf(errOut, "unexpected argument %q (quote --note values)\n%s", fs.Arg(0), usage)
		return 2
	}
	ma.dryRun = *dryRun
	if (ma.since != "" || ma.pageToken != "") && (cmd != "community" || !isHiddenSub(sub)) {
		fmt.Fprintf(errOut, "--since and --page-token are for community hidden and restore-hidden only\n%s", usage)
		return 2
	}
	// --dry-run is honoured only where there is a dry-run path; accepting it elsewhere would WRITE after the
	// moderator asked for a preview.
	if *dryRun && cmd != "purge-graph" && cmd != "purge-posts" && cmd != "backfill-has-media" && cmd != "backfill-media-orphans" && cmd != "media-orphan-sweep" && cmd != "suspend-user" && cmd != "unsuspend-user" && cmd != "clear-profile-fields" && cmd != "messages" && cmd != "lists" && cmd != "beacon" && cmd != "community" {
		fmt.Fprintf(errOut, "--dry-run is not supported by %s\n%s", cmd, usage)
		return 2
	}
	// --after resumes a capped backfill; on any other command it would be silently ignored.
	if *after != "" && cmd != "backfill-has-media" && cmd != "backfill-media-orphans" {
		fmt.Fprintf(errOut, "--after is not supported by %s\n%s", cmd, usage)
		return 2
	}
	// media-orphan-sweep deletes profile images only as --profile-retire says; there is no default, and nothing else takes it.
	var sweepRetire config.ProfileMediaRetire
	if cmd == "media-orphan-sweep" {
		var err error
		if sweepRetire, err = config.ParseProfileMediaRetire(*profileRetire); err != nil || *profileRetire == "" {
			fmt.Fprintf(errOut, "media-orphan-sweep needs --profile-retire off|banner|all (no default)\n%s", usage)
			return 2
		}
	} else if *profileRetire != "" {
		fmt.Fprintf(errOut, "--profile-retire is not supported by %s\n%s", cmd, usage)
		return 2
	}
	if !validBackfillAfter(*after) {
		fmt.Fprintf(errOut, "--after must be a post id (no \"/\")\n%s", usage)
		return 2
	}
	// clear-profile-fields validates its own flags here, before anything is opened or confirmed; --fields on any other
	// command would be silently ignored.
	var clearFields []identity.ProfileField
	if cmd == "clear-profile-fields" {
		var err error
		if clearFields, err = parseClearArgs(ma); err != nil {
			fmt.Fprintf(errOut, "%v\n%s", err, usage)
			return 2
		}
	} else if ma.fields != "" {
		fmt.Fprintf(errOut, "--fields is not supported by %s\n%s", cmd, usage)
		return 2
	}
	if cmd == "reports" && sub == "" {
		fmt.Fprintf(errOut, "reports needs a sub-command: list, show or resolve\n%s", usage)
		return 2
	}
	if cmd == "trends" {
		if err := parseTrendsArgs(sub, trendTag); err != nil {
			fmt.Fprintf(errOut, "%v\n%s", err, usage)
			return 2
		}
	}
	if cmd == "lists" {
		if err := parseListsArgs(sub, listID, ma); err != nil {
			fmt.Fprintf(errOut, "%v\n%s", err, usage)
			return 2
		}
	}
	if cmd == "beacon" {
		if err := parseBeaconArgs(sub, beaconID, ma); err != nil {
			fmt.Fprintf(errOut, "%v\n%s", err, usage)
			return 2
		}
	}
	if cmd == "community" {
		parse := parseCommunityArgs
		if isHiddenSub(sub) {
			parse = parseHiddenArgs
		}
		if err := parse(sub, communityID, ma); err != nil {
			fmt.Fprintf(errOut, "%v\n%s", err, usage)
			return 2
		}
	}
	var msgConvID, msgID string
	if cmd == "messages" {
		var err error
		switch sub {
		case "loghash":
			// No Firestore, no project: the keyed hash the request logs carry for this conversation.
			if err := logHash(msgTarget, os.Getenv("CURSOR_HMAC_KEY"), out); err != nil {
				fmt.Fprintln(errOut, err)
				return 2
			}
			return 0
		case "migrate-placeholder":
			if isProd(*project) {
				fmt.Fprintln(errOut, "messages migrate-placeholder is dev only: messaging was never on in prod, and the command refuses a -prod project")
				return 2
			}
		default:
			if msgConvID, msgID, err = parseTakedownMessageArgs(sub, msgTarget, ma); err != nil {
				fmt.Fprintf(errOut, "%v\n%s", err, usage)
				return 2
			}
		}
	}
	if *project == "" {
		fmt.Fprintf(errOut, "--project is required (there is no default project)\n%s", usage)
		return 2
	}
	// check-t26 scans every Auth user, backfill-has-media every post; the report and post moderation commands address a
	// report or post id.
	needUID := cmd != "check-t26" && cmd != "backfill-has-media" && cmd != "backfill-media-orphans" && cmd != "media-orphan-sweep" && cmd != "reports" && cmd != "takedown-post" && cmd != "restore-post" && cmd != "messages" && cmd != "trends" && cmd != "lists" && cmd != "beacon" && cmd != "community"
	if needUID && *uid == "" {
		fmt.Fprintf(errOut, "--uid is required\n%s", usage)
		return 2
	}
	if needUID && !identity.ValidUserID(*uid) {
		fmt.Fprintln(errOut, "--uid is not a valid user id")
		return 2
	}
	if cmd == "media-orphan-sweep" {
		// Printed before the prod prompt, so the operator confirms while reading the effective switches and clock.
		fmt.Fprint(out, mediaOrphanSweepHeader(*project, sweepRetire, *dryRun, now()))
	}
	if isProd(*project) && !confirmed(in, out, *project) {
		fmt.Fprintln(errOut, "aborted: confirmation did not match")
		return 1
	}

	b, err := open(ctx, *project)
	if err != nil {
		fmt.Fprintf(errOut, "open backends: %v\n", err)
		return 1
	}
	defer b.close()

	switch cmd {
	case "check-t26":
		err = checkT26(ctx, b, out)
	case "backfill-has-media":
		err = backfillHasMedia(ctx, b, *after, *dryRun, out)
	case "backfill-media-orphans":
		err = backfillMediaOrphans(ctx, b, *after, *dryRun, out, now)
	case "media-orphan-sweep":
		err = mediaOrphanSweep(ctx, b, sweepRetire, *dryRun, out, now)
	case "purge-graph":
		err = purge(ctx, b, *uid, *dryRun, *skipGate, out, now)
	case "purge-posts":
		err = purgePosts(ctx, b, *uid, *dryRun, *skipGate, out, now)
	case "export-posts":
		err = exportPosts(ctx, b, *uid, *outFile, out)
	case "messages":
		if sub == "migrate-placeholder" {
			err = migratePlaceholder(ctx, b, *project, ma.dryRun, out)
		} else {
			err = takedownMessage(ctx, b, *project, msgConvID, msgID, ma, out, now)
		}
	case "trends":
		err = trendsCommand(ctx, b, *project, sub, trendTag, out, now)
	case "lists":
		err = listsCommand(ctx, b, *project, sub, listID, ma, out, now)
	case "beacon":
		if sub == "counts" {
			err = beaconCounts(ctx, b.beaconStats, out)
		} else {
			err = beaconCommand(ctx, b, *project, sub, beaconID, ma, out, now)
		}
	case "community":
		if isHiddenSub(sub) {
			err = hiddenCommand(ctx, b, *project, sub, communityID, ma, out, now)
		} else {
			err = communityCommand(ctx, b, *project, sub, communityID, ma, out, now)
		}
	case "reports":
		err = reportsCommand(ctx, b, sub, ma, out, now)
	case "takedown-post":
		err = takedownPost(ctx, b, ma, out, now)
	case "restore-post":
		err = restorePost(ctx, b, ma, out, now)
	case "suspend-user":
		err = suspendUser(ctx, b, *uid, ma, out, now)
	case "unsuspend-user":
		err = unsuspendUser(ctx, b, *uid, ma.dryRun, out, now)
	case "clear-profile-fields":
		err = clearProfileFields(ctx, b, *project, *uid, clearFields, ma, out, now)
	default:
		err = export(ctx, b, *uid, *outFile, out)
	}
	if err != nil {
		fmt.Fprintf(errOut, "%s: %v\n", cmd, err)
		var ue *usageError
		if errors.As(err, &ue) {
			return 2
		}
		return 1
	}
	return 0
}

// isProd treats any project id ending in "-prod" as production.
func isProd(project string) bool { return strings.HasSuffix(project, "-prod") }

func confirmed(in io.Reader, out io.Writer, project string) bool {
	fmt.Fprintf(out, "PRODUCTION project %q. Type the project id to continue: ", project)
	line, _ := bufio.NewReader(in).ReadString('\n')
	return strings.TrimSpace(line) == project
}

func purge(ctx context.Context, b *backends, uid string, dryRun, skipGate bool, out io.Writer, now func() time.Time) error {
	if dryRun {
		cctx, cancel := context.WithTimeout(ctx, callTimeout)
		defer cancel()
		plan, err := b.planner.PlanPurge(cctx, uid)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "dry-run: outgoing_edges=%d incoming_edges=%d blocked=%d blocked_by=%d (nothing written)\n",
			plan.OutgoingEdges, plan.IncomingEdges, plan.Blocked, plan.BlockedBy)
		return nil
	}

	if !skipGate {
		if err := checkStartGate(ctx, b, uid, now()); err != nil {
			return err
		}
	}

	return purgeLoop(ctx, out, graph.Checkpoint{},
		func(ctx context.Context, cp graph.Checkpoint) (graph.Checkpoint, bool, error) {
			return b.eraser.PurgeUser(ctx, uid, cp)
		},
		func(cp graph.Checkpoint) string { return fmt.Sprintf("step=%d offset=%d", cp.Step, cp.Offset) })
}

// purgeLoop drives one resumable purge to completion: call step with the last checkpoint until it reports done,
// retrying a failed call (a concurrent run can fail a batch precondition; the purge re-queries) and giving up
// after maxConsecutiveErrors. One policy for purge-graph and purge-posts. Prints a final done line.
func purgeLoop[C any](ctx context.Context, out io.Writer, cp C,
	step func(context.Context, C) (C, bool, error), describe func(C) string,
) error {
	return driveLoop(ctx, out, cp, step, describe, "purged")
}

// driveLoop is purgeLoop with the label of the final line ("purged", "hidden"...).
func driveLoop[C any](ctx context.Context, out io.Writer, cp C,
	step func(context.Context, C) (C, bool, error), describe func(C) string, label string,
) error {
	failures := 0
	for calls := 1; calls <= maxPurgeCalls; calls++ {
		cctx, cancel := context.WithTimeout(ctx, callTimeout)
		next, done, err := step(cctx, cp)
		cancel()
		if err != nil {
			failures++
			fmt.Fprintf(out, "call %d: %s error: %v\n", calls, describe(cp), err)
			if failures >= maxConsecutiveErrors {
				return fmt.Errorf("giving up after %d consecutive errors (checkpoint %s): %w", failures, describe(cp), err)
			}
			continue
		}
		failures = 0
		fmt.Fprintf(out, "call %d: %s -> %s done=%v\n", calls, describe(cp), describe(next), done)
		if done {
			fmt.Fprintf(out, "%s: done\n", label)
			return nil
		}
		cp = next
	}
	return errors.New("purge did not finish within the call limit")
}

// purgePosts is purge-posts: the same dry-run and start-gate guards as purge-graph, then the posts
// Eraser. Run it BEFORE purge-graph and before users/{uid} is deleted.
func purgePosts(ctx context.Context, b *backends, uid string, dryRun, skipGate bool, out io.Writer, now func() time.Time) error {
	if dryRun {
		cctx, cancel := context.WithTimeout(ctx, callTimeout)
		defer cancel()
		plan, err := b.postsPlanner.PlanPurge(cctx, uid)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "dry-run: posts=%d (nothing written)\n", plan.Posts)
		return nil
	}
	if !skipGate {
		if err := checkStartGate(ctx, b, uid, now()); err != nil {
			return err
		}
	}
	return purgeLoop(ctx, out, posts.Checkpoint{},
		func(ctx context.Context, cp posts.Checkpoint) (posts.Checkpoint, bool, error) {
			return b.postsEraser.PurgeUser(ctx, uid, cp)
		},
		func(cp posts.Checkpoint) string { return fmt.Sprintf("deleted=%d", cp.Deleted) })
}

// checkStartGate enforces: purge only after status = DELETING has been committed >= 120 s.
func checkStartGate(ctx context.Context, b *backends, uid string, now time.Time) error {
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	p, err := b.profile(cctx, uid)
	if err != nil {
		return fmt.Errorf("start gate: cannot read the profile (%w); purge before deleting users/{uid}, or pass --skip-start-gate", err)
	}
	// identity.StartGate is the one gate: 120 s from deletionRequestedAt, updatedAt for an
	// account set to DELETING by hand.
	wait, err := identity.StartGate(p, now)
	if err != nil {
		return errors.New("start gate: the account is not in status DELETING; set it first, or pass --skip-start-gate")
	}
	if wait > 0 {
		return fmt.Errorf("start gate: wait another %s after DELETING was set (ADR-0008 D10), or pass --skip-start-gate", wait.Round(time.Second))
	}
	return nil
}

func export(ctx context.Context, b *backends, uid, outFile string, out io.Writer) error {
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	data, err := b.exporter.ExportUser(cctx, uid)
	if err != nil {
		return err
	}
	return writeOut(outFile, out, func(w io.Writer) error {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		if err := enc.Encode(data); err != nil {
			return fmt.Errorf("write export: %w", err)
		}
		return nil
	})
}

// exportPosts is export-posts: the posts exporter streams its JSON straight to --out (or stdout).
func exportPosts(ctx context.Context, b *backends, uid, outFile string, out io.Writer) error {
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	return writeOut(outFile, out, func(w io.Writer) error { return b.postsExporter.ExportUser(cctx, uid, w) })
}

// writeOut runs write against --out FILE (created 0600, never overwritten) or, without it, stdout. If write (or
// the final close) fails, the partial file is removed: a truncated export must not be mistaken for a complete
// one. The file is removed only after this call created it (O_EXCL), never a pre-existing one.
func writeOut(outFile string, stdout io.Writer, write func(io.Writer) error) (err error) {
	if outFile == "" {
		return write(stdout)
	}
	// outFile is an operator-supplied CLI path (founder ADC tool); O_EXCL refuses to overwrite, 0600 perms.
	f, err := os.OpenFile(outFile, //nolint:gosec // G703: intentional operator-chosen path
		os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("create %s: %w", outFile, err)
	}
	defer func() {
		if cerr := f.Close(); err == nil && cerr != nil {
			err = fmt.Errorf("close %s: %w", outFile, cerr)
		}
		if err != nil {
			_ = os.Remove(outFile) //nolint:gosec // G703: the file this call just created
		}
	}()
	return write(f)
}
