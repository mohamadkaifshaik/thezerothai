// lifecycle_export.go is the export job and composer (ADR-0011 D-B, D-D): one delivery of {account_export, id}
// streams a single JSON object to the private exports bucket and sets exports/{id} READY. The envelope is
// {"exportVersion":1,"generatedAt":...,"account":...,"profile":...,<registered sections: graph, posts, ...>}.
// The object path is deterministic, so a retry overwrites the same object; the Writer is aborted on error, so a
// crash or failure never leaves a truncated object. A DELETING or missing user gets FAILED and no object.
package identity

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// defaultExportBudget bounds the composing of one export (the bucket Put) inside the 27 s handlerBudget, which is
// itself inside the 30 s Pub/Sub ack deadline and Cloud Run request timeout. It leaves saveReserve (5 s) for the
// status write and object clean-up that follow, including the too_large failure path.
const defaultExportBudget = 22 * time.Second

const (
	// exportLease is how long a claimed export is protected from other deliveries (L-4). It exceeds handlerBudget
	// (27 s), so a live run has finished or been cancelled before its lease lapses; it is shorter than the
	// subscription's 60 s minimum backoff, so a nacked or crashed delivery finds the lease expired when Pub/Sub
	// redelivers it.
	exportLease = 35 * time.Second
	// exportRepublishAfter is the age under which RequestAccountExport does not re-publish a PENDING export on replay.
	exportRepublishAfter = 2 * time.Minute
)

// countingWriter counts the bytes written through it and the sections composeExport reports.
type countingWriter struct {
	w        io.Writer
	n        int64
	sections int
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

// exportVersion is the envelope's schema version; bump it with any incompatible change to a built-in section.
const exportVersion = 1

// errPermanent marks an export failure that a retry cannot fix.
var errPermanent = errors.New("permanent export failure")

// exportProfile is the profile section: user-facing fields only. By construction it has no status,
// snapshotVersion, deletionJob or any other internal field (runbook 3a, ADR-0011 D-D).
type exportProfile struct {
	UserID         string    `json:"userId"`
	Handle         string    `json:"handle"`
	DisplayName    string    `json:"displayName"`
	Bio            string    `json:"bio"`
	AvatarURL      string    `json:"avatarUrl,omitempty"`
	IsPrivate      bool      `json:"isPrivate"`
	Verified       bool      `json:"verified"`
	FollowersCount int64     `json:"followersCount"`
	FollowingCount int64     `json:"followingCount"`
	PostsCount     int64     `json:"postsCount"`
	CreatedAt      time.Time `json:"createdAt"`
}

func profileSection(p Profile) exportProfile {
	return exportProfile{
		UserID: p.UserID, Handle: p.Handle, DisplayName: p.DisplayName, Bio: p.Bio, AvatarURL: p.AvatarURL,
		IsPrivate: p.IsPrivate, Verified: p.Verified, FollowersCount: p.FollowersCount, FollowingCount: p.FollowingCount,
		PostsCount: p.PostsCount, CreatedAt: p.CreatedAt.UTC(),
	}
}

// runExport handles one {account_export} delivery. Reads 1 (the exports doc, also the job state) + 1 (users) + the
// sections' own; writes 2 (the lease claim, then the status). A delivery that finds a live lease costs 1 read, 0
// writes; one that loses the claim race costs 2 reads, 0 writes. Both answer 429, a nack Pub/Sub redelivers after
// its 60 s backoff, when the lease has expired or the export is done. Only the claimant composes: concurrent or
// replayed deliveries no longer each stream the whole export (L-4).
func (l *Lifecycle) runExport(ctx context.Context, msg JobMessage, res jobResult) jobResult {
	doc, err := l.repo.GetExport(ctx, msg.ExportID)
	switch {
	case isNotFound(err):
		return ack(res, "duplicate")
	case err != nil:
		return retry(res, "error", fmt.Errorf("identity: read export: %w", err))
	case doc.Status != ExportPending:
		return ack(res, "duplicate") // already READY or FAILED: a redelivery costs 1 read
	case l.now().Before(doc.LeaseUntil):
		return leased(res) // another delivery is composing: 1 read, 0 writes
	}
	res.uid = doc.UID
	target, err := l.auth.exportTarget(ctx, doc)
	if err != nil {
		return ack(res, "refused")
	}
	if l.objects == nil {
		return retry(res, "error", errors.New("identity: no export bucket configured"))
	}
	if !l.now().Before(doc.ExpireAt) {
		return l.failExport(ctx, res, doc, "expired")
	}
	profile, err := l.repo.GetProfile(ctx, doc.UID)
	switch {
	case isNotFound(err):
		return l.failExport(ctx, res, doc, "user_gone")
	case err != nil:
		return retry(res, "error", logger.RedactErr(fmt.Errorf("identity: read profile for export: %w", err), doc.UID))
	case profile.Status == AccountStatusDeleting:
		return l.failExport(ctx, res, doc, "user_deleting")
	}

	// Claim: only the delivery whose precondition holds composes. The status stays PENDING; a crash leaves an
	// expired lease that the redelivery (or the backstop) takes over.
	updateTime, err := l.repo.ClaimExport(ctx, doc.ID, doc.UpdateTime, l.now().Add(exportLease))
	switch {
	case errors.Is(err, ErrJobConflict):
		return leased(res)
	case err != nil:
		return retry(res, "error", fmt.Errorf("identity: claim export: %w", err))
	}
	doc.UpdateTime = updateTime

	cw := &countingWriter{}
	cctx, ccancel := context.WithTimeout(ctx, l.exportBudget)
	defer ccancel()
	err = l.objects.Put(cctx, doc.ObjectPath, "application/json", func(w io.Writer) error {
		*cw = countingWriter{w: w} // a retried Put restarts the object
		return l.composeExport(cctx, cw, profile, target)
	})
	res.sections, res.bytes = cw.sections, cw.n
	switch {
	case errors.Is(err, errPermanent):
		return l.failExport(ctx, res, doc, "permanent")
	case err != nil && ctx.Err() == nil && (errors.Is(err, context.DeadlineExceeded) || cctx.Err() != nil):
		// The export outgrew the compose budget. A redelivery would re-read everything it reached in that time (up to
		// 10 deliveries, and again from the backstop), so this is a permanent failure: FAILED, ERROR for Error
		// Reporting, runbook "Export fails with too_large". ctx (the handler's) still has the reserve to record it.
		mw.ReportError(ctx, l.log.With(logger.TraceAttrs(ctx)...), "jobs/account_export_too_large",
			logger.ScrubErr(fmt.Errorf("account_export_too_large: sections=%d bytes=%d: %w", cw.sections, cw.n, err), doc.UID))
		return l.failExport(ctx, res, doc, "too_large")
	case err != nil:
		return retry(res, "error", logger.RedactErr(fmt.Errorf("identity: compose export: %w", err), doc.UID))
	}
	switch err := l.repo.SetExportStatus(ctx, doc.ID, ExportReady, doc.UpdateTime); {
	case err == nil:
		return ack(res, "done")
	case errors.Is(err, ErrJobConflict), isNotFound(err):
		// Firestore reports a missing doc as a lost precondition too, so read to tell the cases apart: another
		// delivery that finished first wrote the same object path (keep it); an erased doc (account deletion while
		// composing) leaves an object nobody can reach, which is removed.
		if _, gerr := l.repo.GetExport(ctx, doc.ID); isNotFound(gerr) {
			if derr := l.objects.Delete(ctx, doc.ObjectPath); derr != nil {
				return retry(res, "error", derr)
			}
		} else if gerr != nil {
			return retry(res, "error", fmt.Errorf("identity: re-read export: %w", gerr))
		}
		return ack(res, "duplicate")
	default:
		return retry(res, "error", fmt.Errorf("identity: set export READY: %w", err))
	}
}

// leased answers a delivery that must not compose now: 429 nacks it without counting as a server error, and Pub/Sub
// redelivers it after its backoff (the same pattern as the deletion start gate).
func leased(r jobResult) jobResult {
	r.status, r.outcome = http.StatusTooManyRequests, "leased"
	return r
}

// failExport sets the export FAILED (no object is left behind: the Writer is aborted on error and a DELETING or
// missing user never started one) and acks.
func (l *Lifecycle) failExport(ctx context.Context, res jobResult, doc ExportDoc, why string) jobResult {
	if err := l.objects.Delete(ctx, doc.ObjectPath); err != nil {
		return retry(res, "error", err)
	}
	switch err := l.repo.SetExportStatus(ctx, doc.ID, ExportFailed, doc.UpdateTime); {
	case err == nil, errors.Is(err, ErrJobConflict), isNotFound(err):
		return ack(res, "failed:"+why)
	default:
		return retry(res, "error", fmt.Errorf("identity: set export FAILED: %w", err))
	}
}

// composeExport streams the envelope to w. Sections are written in registration order after account and profile.
func (l *Lifecycle) composeExport(ctx context.Context, w io.Writer, p Profile, t exportTarget) error {
	_, sections := l.registered()
	account, err := l.auth.getUserRecord(ctx, t)
	if err != nil {
		return err
	}
	bw := bufio.NewWriter(w)
	generatedAt, err := json.Marshal(l.now().UTC())
	if err != nil {
		return fmt.Errorf("%w: %w", errPermanent, err)
	}
	fmt.Fprintf(bw, `{"exportVersion":%d,"generatedAt":%s`, exportVersion, generatedAt)
	for _, v := range []struct {
		name string
		val  any
	}{{"account", account}, {"profile", profileSection(p)}} {
		raw, err := json.Marshal(v.val)
		if err != nil {
			return fmt.Errorf("%w: encode %s: %w", errPermanent, v.name, err)
		}
		fmt.Fprintf(bw, `,%q:%s`, v.name, raw)
	}
	if cw, ok := w.(*countingWriter); ok {
		cw.sections = 2 + len(sections) // account and profile, then the registered ones
	}
	for _, s := range sections {
		fmt.Fprintf(bw, `,%q:`, s.Name())
		if err := s.WriteSection(ctx, p.UserID, bw); err != nil {
			return fmt.Errorf("identity: export section %s: %w", s.Name(), err)
		}
	}
	if _, err := bw.WriteString("}\n"); err != nil {
		return fmt.Errorf("identity: write export: %w", err)
	}
	if err := bw.Flush(); err != nil {
		return fmt.Errorf("identity: flush export: %w", err)
	}
	return nil
}
