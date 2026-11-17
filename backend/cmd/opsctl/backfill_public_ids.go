package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// backfillPublicIDsUsage documents `opsctl backfill-public-ids`.
const backfillPublicIDsUsage = `  opsctl backfill-public-ids --project P [--dry-run] [--checkpoint FILE] [--resume | --force]
                          (gives every ACTIVE and SUSPENDED account without one a public id, and re-creates a missing
                          publicIds lookup with the account's SAME id; never touches a DELETING account; a lookup naming
                          another account, or a malformed stored id, is reported as a conflict and left alone. Runs whatever
                          FEATURE_PUBLIC_IDS says (the API mints by itself only while the flag is not globally off, and only
                          ACTIVE accounts). Pages of 200 users by document id; one transaction per written account; at most
                          5,000 writes per run. Idempotent: a rerun writes nothing for an account that is done. Prints counts
                          and keyed hashes only (set CURSOR_HMAC_KEY, else the hashes print as unavailable), never a uid or a
                          public id: the resume point lives in the checkpoint file (default
                          ./backfill-public-ids.checkpoint.json, 0600, written after every page); --resume continues it, an
                          existing file is never overwritten without --resume or --force (start over). --dry-run reads the
                          same documents, writes nothing (no checkpoint either) and prints would_mint / would_repair)
`

const (
	// defaultPublicIDsCheckpoint is the checkpoint file in the working directory.
	defaultPublicIDsCheckpoint = "backfill-public-ids.checkpoint.json"
	// publicIDsCheckpointVersion is the checkpoint file format.
	publicIDsCheckpointVersion = 1
	// publicIDBackfillMaxWrites caps one run's writing transactions, like the other backfills.
	publicIDBackfillMaxWrites = 5000
)

// publicIDsCheckpointFile is the --checkpoint file. After is a raw uid: the file is the only place it is written (0600,
// in the operator's working directory); the screen shows its hash.
type publicIDsCheckpointFile struct {
	Version int    `json:"version"`
	Command string `json:"command"`
	Project string `json:"project"`
	// After is the last users document id handled ("" = the start).
	After string `json:"after"`
	// State is running, complete, write-cap, interrupted or failed.
	State   string `json:"state"`
	SavedAt string `json:"saved_at"`
}

// publicIDsArgs is a validated backfill-public-ids invocation.
type publicIDsArgs struct {
	project, checkpoint, after string
	dryRun, resumed            bool
}

// parsePublicIDsArgs validates the flags and the checkpoint file before anything is opened or confirmed (usage errors).
func parsePublicIDsArgs(project, checkpoint string, resume, force, dryRun bool) (publicIDsArgs, error) {
	if resume && force {
		return publicIDsArgs{}, usageErr("--resume and --force are exclusive (--force starts over)")
	}
	a := publicIDsArgs{project: project, dryRun: dryRun}
	if dryRun {
		if checkpoint != "" || resume || force {
			return publicIDsArgs{}, usageErr("backfill-public-ids --dry-run reads every user and writes nothing, not even a checkpoint: drop --checkpoint, --resume and --force")
		}
		return a, nil
	}
	a.checkpoint = checkpoint
	if a.checkpoint == "" {
		a.checkpoint = defaultPublicIDsCheckpoint
	}
	if resume {
		cp, err := loadPublicIDsCheckpoint(a.checkpoint)
		if err != nil {
			return publicIDsArgs{}, usageErr(fmt.Sprintf("--resume: %v", err))
		}
		if cp.Version != publicIDsCheckpointVersion || cp.Command != "backfill-public-ids" {
			return publicIDsArgs{}, usageErr(fmt.Sprintf("--resume: %s is not a backfill-public-ids v%d checkpoint", a.checkpoint, publicIDsCheckpointVersion))
		}
		if cp.Project != project {
			return publicIDsArgs{}, usageErr(fmt.Sprintf("--resume: the checkpoint is for project %q, not %q", cp.Project, project))
		}
		if cp.After != "" && !identity.ValidUserID(cp.After) {
			return publicIDsArgs{}, usageErr("--resume: the checkpoint's resume point is not a user id")
		}
		a.after, a.resumed = cp.After, true
		return a, nil
	}
	if !force {
		if _, err := os.Stat(a.checkpoint); err == nil {
			return publicIDsArgs{}, usageErr(fmt.Sprintf("checkpoint %s exists: pass --resume to continue it or --force to start over", a.checkpoint))
		} else if !errors.Is(err, os.ErrNotExist) {
			return publicIDsArgs{}, usageErr(fmt.Sprintf("checkpoint %s: %v", a.checkpoint, err))
		}
	}
	return a, nil
}

func loadPublicIDsCheckpoint(path string) (publicIDsCheckpointFile, error) {
	var c publicIDsCheckpointFile
	data, err := os.ReadFile(path) //nolint:gosec // G304: the operator-chosen checkpoint path
	if err != nil {
		return c, fmt.Errorf("read checkpoint: %w", err)
	}
	if err := json.Unmarshal(data, &c); err != nil {
		return c, fmt.Errorf("decode checkpoint %s: %w", path, err)
	}
	return c, nil
}

// hashOrDash is uidHashForAudit, or "-" for an empty id.
func hashOrDash(id string) string {
	if id == "" {
		return "-"
	}
	return uidHashForAudit(id)
}

// publicIDsHeader is the line backfill-public-ids prints before anything runs (and before the prod prompt).
func publicIDsHeader(a publicIDsArgs) string {
	mode, cp := "write", a.checkpoint
	if a.dryRun {
		mode, cp = "dry-run", "-"
	}
	h := fmt.Sprintf("backfill-public-ids: project=%s mode=%s page=%d max_writes=%d checkpoint=%s resume_after_hash=%s\n"+
		"backfill-public-ids: FEATURE_PUBLIC_IDS is not read: this run mints and repairs whatever the flag says (the API mints by itself only while it is not globally off)\n",
		a.project, mode, identity.PublicIDBackfillPage, publicIDBackfillMaxWrites, cp, hashOrDash(a.after))
	if os.Getenv(cursorKeyEnv) == "" {
		h += "backfill-public-ids: warning: " + cursorKeyEnv + " is not set: conflict hashes print as unavailable\n"
	}
	return h
}

// publicIDCounts renders counts; a dry run says would_mint and would_repair.
func publicIDCounts(c identity.PublicIDBackfillCounts, dryRun bool) string {
	mint, repair := "minted", "repaired"
	if dryRun {
		mint, repair = "would_mint", "would_repair"
	}
	return fmt.Sprintf("scanned=%d already_ok=%d %s=%d %s=%d skipped_deleting=%d skipped_status=%d gone=%d conflicts=%d collisions=%d",
		c.Scanned, c.AlreadyOK, mint, c.Minted, repair, c.Repaired, c.SkippedDeleting, c.SkippedStatus, c.Gone, c.Conflicts, c.Collisions)
}

// backfillPublicIDs is `opsctl backfill-public-ids` (identity.BackfillPublicIDsPage does the per-account work).
func backfillPublicIDs(ctx context.Context, b *backends, a publicIDsArgs, out io.Writer, now func() time.Time) error {
	if b.publicIDBackfill == nil {
		return errors.New("backfill-public-ids: no identity repo configured")
	}
	after := a.after
	save := func(state string) error {
		if a.dryRun {
			return nil
		}
		return writeCheckpointFile(a.checkpoint, publicIDsCheckpointFile{
			Version: publicIDsCheckpointVersion, Command: "backfill-public-ids", Project: a.project,
			After: after, State: state, SavedAt: now().UTC().Format(time.RFC3339),
		})
	}
	var total identity.PublicIDBackfillCounts
	for page := 1; page <= maxPurgeCalls; page++ {
		if err := ctx.Err(); err != nil {
			return publicIDsStop(save, a.dryRun, "interrupted", after, err)
		}
		// The deadline is per store call (the scan, each transaction), not per page of up to 200 transactions.
		res, err := identity.BackfillPublicIDsPage(ctx, b.publicIDBackfill, after,
			identity.PublicIDBackfillOptions{DryRun: a.dryRun, Now: now, CallTimeout: callTimeout})
		total, after = total.Add(res.Counts), res.Last
		for _, c := range res.ConflictList {
			fmt.Fprintf(out, "conflict: reason=%s uid_hash=%s public_id_hash=%s owner_hash=%s\n",
				c.Reason, hashOrDash(c.UID), hashOrDash(c.PublicID), hashOrDash(c.Owner))
		}
		fmt.Fprintf(out, "page %d: %s checkpoint_hash=%s\n", page, publicIDCounts(total, a.dryRun), hashOrDash(after))
		if err != nil {
			return publicIDsStop(save, a.dryRun, "failed", after, err)
		}
		if !res.More {
			break
		}
		if err := save("running"); err != nil {
			return fmt.Errorf("checkpoint %s not saved: %w", a.checkpoint, err)
		}
		if !a.dryRun && total.Writes() >= publicIDBackfillMaxWrites {
			if err := save("write-cap"); err != nil {
				return fmt.Errorf("checkpoint %s not saved: %w", a.checkpoint, err)
			}
			fmt.Fprintf(out, "backfill-public-ids: write cap of %d reached: %s; rerun with --resume\n", publicIDBackfillMaxWrites, publicIDCounts(total, false))
			return nil
		}
	}
	if err := save("complete"); err != nil {
		return fmt.Errorf("checkpoint %s not saved: %w", a.checkpoint, err)
	}
	if a.dryRun {
		fmt.Fprintf(out, "dry-run: %s (nothing written)\n", publicIDCounts(total, true))
		return nil
	}
	fmt.Fprintf(out, "backfill-public-ids: complete: %s\n", publicIDCounts(total, false))
	if total.Conflicts > 0 {
		fmt.Fprintln(out, "backfill-public-ids: conflicts were left alone (see the conflict lines); a rerun reports them again")
	}
	return nil
}

// publicIDsStop saves the checkpoint with state and returns err with the resume hint (err is already scrubbed of ids).
func publicIDsStop(save func(string) error, dryRun bool, state, after string, err error) error {
	if dryRun {
		return fmt.Errorf("%s at checkpoint_hash=%s (dry run: nothing written, nothing saved): %w", state, hashOrDash(after), err)
	}
	if serr := save(state); serr != nil {
		return fmt.Errorf("%s at checkpoint_hash=%s, and the checkpoint was not saved (%v): %w", state, hashOrDash(after), serr, err)
	}
	return fmt.Errorf("%s at checkpoint_hash=%s: checkpoint saved, rerun with --resume: %w", state, hashOrDash(after), err)
}
