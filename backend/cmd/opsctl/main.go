// Command opsctl is the founder's manual-runbook CLI (ADR-0008 T11): purge-graph deletes one user's social
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
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/fsclient"
)

const (
	// startGate is ADR-0008 D10's wait after users/{uid}.status = DELETING: 2x the 60 s instance-cache TTL, so
	// no instance still sees the user as ACTIVE and can create a new edge mid-purge.
	startGate = 120 * time.Second
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
	profile func(ctx context.Context, uid string) (identity.Profile, error)
	close   func()
}

type opener func(ctx context.Context, project string) (*backends, error)

func main() {
	os.Exit(run(context.Background(), os.Args[1:], os.Stdin, os.Stdout, os.Stderr, openFirestore, time.Now))
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
	return &backends{
		eraser:   graphRepo,
		planner:  graphRepo,
		exporter: graphRepo,
		profile:  identityRepo.GetProfile,
		close:    func() { _ = client.Close() },
	}, nil
}

const usage = `usage:
  opsctl purge-graph  --project P --uid U [--dry-run] [--skip-start-gate]
  opsctl export-graph --project P --uid U [--out FILE]
`

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
	dryRun := fs.Bool("dry-run", false, "purge-graph: print counts, write nothing")
	skipGate := fs.Bool("skip-start-gate", false, "purge-graph: skip the DELETING >= 120 s start gate (ADR-0008 D10)")
	outFile := fs.String("out", "", "export-graph: write JSON to this file instead of stdout")

	switch cmd {
	case "purge-graph", "export-graph":
	default:
		fmt.Fprintf(errOut, "unknown command %q\n%s", cmd, usage)
		return 2
	}
	if err := fs.Parse(rest); err != nil {
		return 2
	}
	if *project == "" {
		fmt.Fprintf(errOut, "--project is required (there is no default project)\n%s", usage)
		return 2
	}
	if *uid == "" {
		fmt.Fprintf(errOut, "--uid is required\n%s", usage)
		return 2
	}
	if !identity.ValidUserID(*uid) {
		fmt.Fprintln(errOut, "--uid is not a valid user id")
		return 2
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
	case "purge-graph":
		err = purge(ctx, b, *uid, *dryRun, *skipGate, out, now)
	default:
		err = export(ctx, b, *uid, *outFile, out)
	}
	if err != nil {
		fmt.Fprintf(errOut, "%s: %v\n", cmd, err)
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

	ctx, counter := budget.WithCounter(ctx)
	cp := graph.Checkpoint{}
	failures := 0
	for calls := 1; calls <= maxPurgeCalls; calls++ {
		cctx, cancel := context.WithTimeout(ctx, callTimeout)
		next, done, err := b.eraser.PurgeUser(cctx, uid, cp)
		cancel()
		if err != nil {
			// A concurrent run can fail a batch's Exists precondition; PurgeUser re-queries on the retry.
			failures++
			fmt.Fprintf(out, "call %d: step=%d offset=%d error: %v\n", calls, cp.Step, cp.Offset, err)
			if failures >= maxConsecutiveErrors {
				return fmt.Errorf("giving up after %d consecutive errors (checkpoint step=%d offset=%d): %w", failures, cp.Step, cp.Offset, err)
			}
			continue
		}
		failures = 0
		fmt.Fprintf(out, "call %d: step=%d offset=%d -> step=%d offset=%d done=%v\n", calls, cp.Step, cp.Offset, next.Step, next.Offset, done)
		if done {
			fmt.Fprintf(out, "purged: reads=%d writes=%d deletes=%d\n", counter.Reads(), counter.Writes(), counter.Deletes())
			return nil
		}
		cp = next
	}
	return errors.New("purge did not finish within the call limit")
}

// checkStartGate enforces ADR-0008 D10: purge only after status = DELETING has been committed >= 120 s.
func checkStartGate(ctx context.Context, b *backends, uid string, now time.Time) error {
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	p, err := b.profile(cctx, uid)
	if err != nil {
		return fmt.Errorf("start gate: cannot read the profile (%w); purge before deleting users/{uid}, or pass --skip-start-gate", err)
	}
	if p.Status != identity.AccountStatusDeleting {
		return errors.New("start gate: the account is not in status DELETING; set it first, or pass --skip-start-gate")
	}
	if wait := startGate - now.Sub(p.UpdatedAt); wait > 0 {
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
	w := out
	if outFile != "" {
		f, err := os.OpenFile(outFile, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return fmt.Errorf("create %s: %w", outFile, err)
		}
		defer f.Close()
		w = f
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(data); err != nil {
		return fmt.Errorf("write export: %w", err)
	}
	return nil
}
