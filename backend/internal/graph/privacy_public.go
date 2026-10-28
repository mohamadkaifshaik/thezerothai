// privacy_public.go is the `privacy_public` job (ADR-0025 D8, AQ1, W3-28b): when an account switches from protected to
// public, every pending follow request addressed to it is accepted. identity only says "this account went public"
// (identity.PrivacyListener, implemented by PrivacyListener below, which publishes to the shared `jobs` topic); graph owns
// the requests, so graph owns the job (the ADR-0024 A4 media retire split). The accept itself is the W3-28a code
// (classifyAccept, queueAccept) run by FirestoreRepo.AcceptPendingPage for a page of requests; this file pages, keeps the
// caches honest and reports.
package graph

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"golang.org/x/sync/errgroup"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// JobKindPrivacyPublic is the JobMessage.Kind of this job on the shared `jobs` topic.
const JobKindPrivacyPublic = "privacy_public"

const (
	// privacyPublicPage is the page size: a page is at most 401 writes and deletes (4 per request + the counter), under
	// Firestore's 500 per transaction.
	privacyPublicPage = 100
	// privacyPublicMaxPages bounds one delivery (5,000 requests; the handler budget is 27 s). More pending than that nacks
	// the message: the accepted ones have dropped out, so the redelivery continues. Reaching it is a runbook entry.
	privacyPublicMaxPages = 50
	// privacyPublicEmitFanout bounds the concurrent post-commit notification emits of one page.
	privacyPublicEmitFanout = 8
	// privacyPublicPublishTimeout bounds the enqueue of the job message (identity also gives BecamePublic a short
	// detached deadline).
	privacyPublicPublishTimeout = 2 * time.Second
)

// ErrPrivacyPublicMore is returned by a run that hit privacyPublicMaxPages with requests left after accepting at least one: the delivery is nacked (a run that accepted none acks as "stuck").
var ErrPrivacyPublicMore = errors.New("graph: privacy_public: more pending requests than one delivery handles")

// PrivacyPublicMessage is the payload of a privacy_public job. Only the uid matters: the job acts on what Firestore says
// now, never on the message's word.
type PrivacyPublicMessage struct {
	Kind string    `json:"kind"`
	UID  string    `json:"uid"`
	At   time.Time `json:"at"`
}

// JobPublisher publishes one message to the shared `jobs` topic. *pubsubpublish.Publisher implements it.
type JobPublisher interface {
	Publish(ctx context.Context, data []byte) error
}

// PrivacyListener implements identity.PrivacyListener by publishing {kind: privacy_public, uid} to the jobs topic.
type PrivacyListener struct{ pub JobPublisher }

// NewPrivacyListener builds the listener identity.WithPrivacyListener takes.
func NewPrivacyListener(pub JobPublisher) PrivacyListener { return PrivacyListener{pub: pub} }

var _ identity.PrivacyListener = PrivacyListener{}

// BecamePublic publishes the job. 0 Firestore reads and writes, one Pub/Sub publish. A duplicate message is harmless.
func (l PrivacyListener) BecamePublic(ctx context.Context, uid string, at time.Time) error {
	if l.pub == nil {
		return errors.New("graph: no job publisher configured")
	}
	data, err := json.Marshal(PrivacyPublicMessage{Kind: JobKindPrivacyPublic, UID: uid, At: at.UTC()})
	if err != nil {
		return fmt.Errorf("graph: encode privacy_public job: %w", err)
	}
	pctx, cancel := context.WithTimeout(ctx, privacyPublicPublishTimeout)
	defer cancel()
	return l.pub.Publish(pctx, data)
}

// PendingAccepter is the repo side of the job (*FirestoreRepo).
type PendingAccepter interface {
	AcceptPendingPage(ctx context.Context, a PendingPageArgs) (PendingPageResult, error)
}

var _ PendingAccepter = (*FirestoreRepo)(nil)

// PrivacyPublicJob is the identity.JobHandler of the privacy_public kind. Never gated by a flag or DEGRADED_MODE.
type PrivacyPublicJob struct {
	s    *service
	repo PendingAccepter
	log  *slog.Logger
	page int
}

// PrivacyPublicJob builds the handler apiserver registers with identity.Lifecycle.RegisterJobHandler. Call it after
// SetDirectory. A nil log means slog.Default().
func (s *service) PrivacyPublicJob(repo PendingAccepter, log *slog.Logger) *PrivacyPublicJob {
	if log == nil {
		log = slog.Default()
	}
	return &PrivacyPublicJob{s: s, repo: repo, log: log, page: privacyPublicPage}
}

// Handle decodes one delivery and runs Run. A malformed or invalid message is acknowledged and dropped (the DLQ, not a
// retry storm, holds poison); a Firestore error nacks so Pub/Sub redelivers.
func (j *PrivacyPublicJob) Handle(ctx context.Context, data []byte) (string, error) {
	var m PrivacyPublicMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return "dropped:malformed_message", nil
	}
	if m.Kind != JobKindPrivacyPublic || !ids.ValidUID(m.UID) {
		return "dropped:invalid_message", nil
	}
	return j.Run(ctx, m.UID)
}

// Run accepts uid's pending requests, one transaction per page of 100, until a short page. Outcomes: "done" (every
// request answered, or none), "stopped:protected" (the account is protected again; the job accepts nothing from then on),
// "stopped:target_gone", "stopped:target_inactive", "stuck" (the whole delivery, every page up to the cap, accepted nothing and dropped nothing: acked,
// never nacked, because a redelivery would scan the same skipped requests; W3-40b O-1). A delivery that accepted at least one
// request and still has more returns ErrPrivacyPublicMore (nack), so the next delivery continues. Idempotent: an accepted request has dropped out of the query, a
// redelivery re-reads only what is left, and a crash between pages loses nothing and doubles nothing, because the
// followersCount increment is in the same transaction as the edges it counts.
//
// Firestore, per page: 1 read (users) + 2 per request (the request inside the transaction, the requester's graph) + the
// cache-first Directory lookup of the requesters; per accepted request 3 writes (edge, requester graph, requester
// followingCount) + 1 delete, plus 1 write per page (target followersCount += n). 500 pending: about 1,005 reads (+ the
// Directory's cold lookups), 1,505 writes, 500 deletes. Notifications (FollowRequestAccepted) are emitted after each page
// commits.
func (j *PrivacyPublicJob) Run(ctx context.Context, uid string) (string, error) {
	var cur *PendingCursor
	var tot runTotals
	for page := 1; page <= privacyPublicMaxPages; page++ {
		now := j.s.now()
		res, err := j.repo.AcceptPendingPage(ctx, PendingPageArgs{
			TargetUID: uid, After: cur, Limit: j.page, Now: now, Active: j.s.activeAmong,
		})
		if err != nil {
			err = logger.RedactErr(fmt.Errorf("graph: privacy_public page %d: %w", page, err), uid)
			j.log.WarnContext(ctx, "privacy_public", append([]any{
				"uid_hash", logger.HashUID(uid), "page", page, "outcome", "error", "error", logger.CauseChain(err),
			}, logger.TraceAttrs(ctx)...)...)
			return "", err
		}
		outcome := "page"
		switch {
		case res.Stop != "":
			outcome = "stopped:" + res.Stop
		case res.Scanned < j.page:
			outcome = "done"
		}
		j.log.InfoContext(ctx, "privacy_public", append([]any{
			"uid_hash", logger.HashUID(uid), "page", page, "scanned", res.Scanned, "accepted", len(res.Accepted),
			"skipped_inactive", res.SkippedInactive, "skipped_cap", res.SkippedCap, "drift", res.Drift, "outcome", outcome,
		}, logger.TraceAttrs(ctx)...)...)
		tot.add(res)
		j.afterCommit(ctx, uid, res.Accepted, now)
		if outcome != "page" {
			return outcome, nil
		}
		cur = res.Last
	}
	if tot.accepted+tot.skippedInactive == 0 { // a dropped (inactive) request is progress too: it leaves the query
		// O-1 (W3-35b): every page up to the cap was skipped (requesters at the 5,000 following cap, or not ACTIVE), so a
		// redelivery would only repeat the same scan until the DLQ. Ack with counts only; the owner declines the requests or
		// the requesters unfollow someone (docs/runbooks/private-accounts.md section 6).
		j.log.WarnContext(ctx, "privacy_public", append([]any{
			"uid_hash", logger.HashUID(uid), "pages", privacyPublicMaxPages, "scanned", tot.scanned,
			"skipped_cap", tot.skippedCap, "skipped_inactive", tot.skippedInactive, "outcome", "stuck",
		}, logger.TraceAttrs(ctx)...)...)
		return "stuck", nil
	}
	return "", ErrPrivacyPublicMore
}

// runTotals sums one delivery's pages for the stuck decision.
type runTotals struct{ accepted, scanned, skippedCap, skippedInactive int }

func (t *runTotals) add(r PendingPageResult) {
	t.accepted += len(r.Accepted)
	t.scanned += r.Scanned
	t.skippedCap += r.SkippedCap
	t.skippedInactive += r.SkippedInactive
}

// afterCommit drops this instance's cached copies the page changed and emits FollowRequestAccepted per accepted request.
// Other instances' copies expire within CACHE_TTL like after any follow. The emit is best effort (the notifications
// emitter logs its own failures); a crash between commit and emit loses at most that page's notifications.
func (j *PrivacyPublicJob) afterCommit(ctx context.Context, uid string, accepted []string, at time.Time) {
	if len(accepted) == 0 {
		return
	}
	for _, r := range accepted {
		j.s.cache.Invalidate(r)
		j.s.cache.ForgetEdge(r, uid)
		j.s.directory.Forget(r) // followingCount moved
		j.s.dropSuggested(r, uid)
	}
	j.s.directory.Forget(uid) // followersCount moved
	j.s.cache.Invalidate(uid)
	var g errgroup.Group
	g.SetLimit(privacyPublicEmitFanout)
	for _, r := range accepted {
		g.Go(func() error {
			j.s.events.FollowRequestAccepted(ctx, uid, r, at)
			return nil
		})
	}
	_ = g.Wait()
}

// activeAmong answers which of uids are ACTIVE through the identity Directory (it drops every other account), cache-first.
func (s *service) activeAmong(ctx context.Context, uids []string) (map[string]bool, error) {
	if len(uids) == 0 {
		return nil, nil
	}
	profiles, err := s.directory.GetProfiles(ctx, uids)
	if err != nil {
		return nil, err
	}
	out := make(map[string]bool, len(profiles))
	for u := range profiles {
		out[u] = true
	}
	return out, nil
}
