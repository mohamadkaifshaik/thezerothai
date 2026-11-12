// orphan_sweep.go deletes published images that nothing ever attached: an upload that reached READY in an abandoned
// composer (or one finished by a request already in flight when the session switched) and was never posted, scheduled,
// put on an article draft or set as an avatar. PENDING and REJECTED documents already expire through expireAt;
// without this sweep a READY one would keep its document and its public objects forever.
//
// Kill switch. MEDIA_ORPHAN_SWEEP (config.MediaOrphanSweep, default off) is enforced here, not only by the caller: off
// reads and writes nothing; mark runs phase 1 and the restore paths but never claims or deletes (a marked image past its
// grace, and a claimed one, are deferred by another grace with the mark kept); delete runs both phases. FinalizeUpload
// writes orphanCheckAt whatever the switch says: nothing but this sweep reads the field, so while the switch is off it is
// an inert timestamp (one automatic index entry) and the documents are due the day the switch is raised.
//
// Candidates. FinalizeUpload writes orphanCheckAt = readyAt + OrphanAfter on every READY document and Claim.Attach
// deletes it in the CreatePost transaction (CreatePost, the scheduled publish and the article publish all attach through
// it), so only unattached images are ever due. Documents published before this existed get the field from
// `opsctl backfill-media-orphans`. DueOrphans is one range query on that field (automatic single-field index); a document
// it cannot decode is skipped and logged by id, never fails the page.
//
// Holders that do not write the media document are checked from fresh reads at sweep time, grouped by owner:
//
//	POST            a PENDING scheduled post's draft, an unpublished article draft's cover   DraftHolds
//	AVATAR          the image users/{uid} shows now                                          ProfileImages
//	other           a purpose the sweep does not know (the removed BANNER): kept, never deleted here (the
//	                2026-11-12 banner purge erased every legacy banner)
//
// A POST image a draft holds is "held": checked again OrphanAfter later. A profile image the profile shows is attached:
// the field is removed and the profile_media_retired step owns it from then on. A profile image the profile does not show
// is deleted only when PROFILE_MEDIA_RETIRE allows its purpose (the switch that decides whether replaced profile images,
// which post author snapshots may still name, are deleted); otherwise it is "kept": the fields are removed (it leaves the
// queue) and a rerun of `opsctl backfill-media-orphans` after the switch is turned on enrolls it again (an owner decision:
// that deletes historic replaced profile images without the retire step's customTime grace, including ones old posts'
// author snapshots still name). A holder that
// cannot be read is never taken as free: that owner's documents move orphanHolderRetry forward, the mark untouched.
//
// Clock sanity. A document is marked or deleted only when its own createdAt (the server's clock at CreateUpload) is at least
// OrphanAfter before the sweep's clock; a younger one moves to createdAt + OrphanAfter. A workstation running opsctl with a
// clock far ahead can therefore not mark a fresh upload.
//
// Two phases, so that an attach can never lose to a delete:
//
//	phase 1 (mark)    held by nothing: orphanedAt = now, orphanCheckAt = now + OrphanGrace, LastUpdateTime precondition.
//	                  From this write on LoadForPost (inside the attaching transaction), the avatar resolver
//	                  and the article cover preview refuse the document. An attach that committed first moved the
//	                  UpdateTime, so the mark fails (ErrConflict) and the attach wins; a mark that committed first makes
//	                  the attaching transaction read it and refuse (the two serialize on the document).
//	phase 2 (delete)  a later run (>= OrphanGrace after the mark, far above any request deadline, so an UpdateProfile or a
//	                  schedule that read the image before the mark has committed) checks the holders again. Held: the
//	                  mark is removed. Still free: a claim write (orphanDeletingAt = now, permanent, and orphanCheckAt =
//	                  now + OrphanGrace, precondition) so a concurrent run cannot act on the same snapshot, then every
//	                  object the document may own (the eraser's deleteObjects: public names in both shapes and the private
//	                  upload leftovers; a missing object is success), then the document (precondition on the claim).
//
// A claimed document is past the point of no return: its objects may already be gone, so no later run restores it
// whatever the holders say (they are not even read for it), and LoadForPost and the resolvers refuse it. Every later run in
// delete mode finishes the delete. Every step is idempotent: a crash after the claim leaves a claimed document that is due
// again after OrphanGrace; deleting missing objects succeeds. The account eraser deletes every document whatever its sweep
// fields; a sweep write that arrives after it fails its precondition and recreates nothing. No new collection:
// right-to-delete and the export already cover media/{id}.
//
// Cost per page (limit n): reads n (the due query) + per owner in the page, POST candidates: the PENDING scheduled drafts
// (<= SCHEDULED_MAX_PENDING) and one article query per 30 ids; profile candidates: users/{uid} (1). Writes: 1 per
// candidate (mark, hold, keep, attach, defer, postpone) or 2 per deleted document (claim, delete). GCS: up to 6 free deletes
// per deleted document (2 public, 2 old-shape public for a suffixed document, 2 private). A dry run reads the same and
// writes nothing.
package media

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	// OrphanAfter (N) is how long a READY image may stay unattached and unheld before the sweep marks it, and how long a
	// held or kept image waits for its next check. It must exceed the longest gap between FinalizeUpload and an attach in
	// which nothing holds the id: the composer session that uploaded it, plus the 23 h client send-key window and the 24 h
	// server idempotency window of a retried CreatePost. Composer drafts never keep media (drafts_repository.dart), and the
	// holders that do keep ids for days (scheduled posts, up to SCHEDULED_HORIZON and re-editable; article drafts, with no
	// expiry) are checked above instead of being waited out. 7 days is that gap with a wide margin.
	OrphanAfter = 7 * 24 * time.Hour
	// OrphanGrace is the least time between the mark and the delete. It only has to exceed a request deadline (30 s) so that
	// a holder that read the image before the mark has committed by phase 2; 12 h also lets the daily run delete what the
	// previous day's run marked.
	OrphanGrace = 12 * time.Hour
	// OrphanSweepPage is the default page of one Sweep call (the opsPage bound shared with the purge).
	OrphanSweepPage = opsPage
	// orphanSweepWorkers bounds the owners swept concurrently within one page.
	orphanSweepWorkers = 4
	// orphanHolderRetry is how far a document moves when its owner's holders could not be read: never marked, but out of
	// the head of the queue until the next day's run.
	orphanHolderRetry = 24 * time.Hour
)

// DraftHolds reports which of uid's POST image ids something other than a post still holds: a PENDING scheduled post's
// draft or an unpublished article draft's cover. It reads fresh (no cache). When it cannot tell (more holders than it
// reads) it reports the id held, never free. NewDraftHolds builds it over posts and articles (apiserver and opsctl).
type DraftHolds interface {
	HeldByDrafts(ctx context.Context, uid string, ids []string) (map[string]bool, error)
}

// ScheduledMediaHolds is the posts read NewDraftHolds consumes (posts.ScheduledMediaHolds in posts' api.go).
type ScheduledMediaHolds interface {
	PendingScheduledMediaHolds(ctx context.Context, uid string, ids []string) (map[string]bool, error)
}

// ArticleCoverHolds is the articles read NewDraftHolds consumes (articles.CoverHolds in articles' api.go).
type ArticleCoverHolds interface {
	DraftCoverHolds(ctx context.Context, uid string, ids []string) (map[string]bool, error)
}

// NewDraftHolds is the one DraftHolds the daily step and opsctl share: an image either holder names is held, and either
// holder's error is the answer (never "free"). media imports neither module; both satisfy these consumer-side interfaces.
func NewDraftHolds(scheduled ScheduledMediaHolds, covers ArticleCoverHolds) DraftHolds {
	return draftHolds{scheduled: scheduled, covers: covers}
}

type draftHolds struct {
	scheduled ScheduledMediaHolds
	covers    ArticleCoverHolds
}

func (h draftHolds) HeldByDrafts(ctx context.Context, uid string, ids []string) (map[string]bool, error) {
	held, err := h.scheduled.PendingScheduledMediaHolds(ctx, uid, ids)
	if err != nil {
		return nil, err
	}
	covers, err := h.covers.DraftCoverHolds(ctx, uid, ids)
	if err != nil {
		return nil, err
	}
	out := make(map[string]bool, len(held)+len(covers))
	for _, m := range []map[string]bool{held, covers} {
		for id, ok := range m {
			if ok {
				out[id] = true
			}
		}
	}
	return out, nil
}

// OrphanSweepDeps are the sweep's collaborators and its switches.
type OrphanSweepDeps struct {
	Repo     OrphanRepo
	Objects  Objects
	Drafts   DraftHolds
	Profiles ProfileImages
	// RetireMode is PROFILE_MEDIA_RETIRE: a profile image the profile does not show is deleted only when it allows the purpose.
	RetireMode config.ProfileMediaRetire
	// Mode is MEDIA_ORPHAN_SWEEP: off does nothing, mark never claims or deletes, delete runs both phases. The zero value is off.
	Mode config.MediaOrphanSweep
	// DryRun computes and counts every verdict as Mode would and writes or deletes nothing (opsctl --dry-run).
	DryRun bool
	// Log receives the ids of documents the due query could not decode (media ids only, no owner). Nil discards.
	Log *slog.Logger
}

// OrphanSweeper runs the sweep.
type OrphanSweeper struct{ d OrphanSweepDeps }

// NewOrphanSweeper checks the deps.
func NewOrphanSweeper(d OrphanSweepDeps) (*OrphanSweeper, error) {
	if d.Repo == nil || d.Objects == nil || d.Drafts == nil || d.Profiles == nil {
		return nil, errors.New("media: orphan sweep: missing dependency")
	}
	if d.Log == nil {
		d.Log = slog.New(slog.DiscardHandler)
	}
	return &OrphanSweeper{d: d}, nil
}

// OrphanSweepResult counts one page. Due = Marked + Deleted + Held + Kept + Attached + Restored + Waiting + Deferred +
// Young + Conflicts + Failed + Skipped. In a dry run every count is what the run would have done.
type OrphanSweepResult struct {
	// Due is the number of candidates the query returned and decoded; More is true when the page was full (undecodable
	// documents included), so a caller pages on.
	Due  int
	More bool
	// Marked: phase 1 done. Deleted: phase 2 done (objects and document).
	Marked, Deleted int
	// Held: a draft holds it. Kept: a profile image PROFILE_MEDIA_RETIRE does not let the sweep delete (or a purpose the sweep
	// does not know); its fields are removed. Attached: no longer
	// a candidate (attached to a post, shown by the profile, retired or not published); its fields are removed.
	// Restored: a marked (never a claimed) document something holds after all; the mark is removed.
	Held, Kept, Attached, Restored int
	// Waiting: a marked document due before its grace ended (only after a clock change); pushed to the end of the grace.
	Waiting int
	// Deferred: mark mode met a document phase 2 would claim or finish; its check moves one grace on, the mark (and any
	// claim) kept. Young: a document whose createdAt is less than OrphanAfter before the sweep's clock (clock sanity); its
	// check moves to createdAt + OrphanAfter, never marked or deleted.
	Deferred, Young int
	// Conflicts: the document changed since the query read it (an attach, a concurrent run, the eraser); left for the next run.
	Conflicts int
	// Failed: an error (holder read, write or object delete); left for the next run (a holder-read failure also moves the
	// document orphanHolderRetry on). Skipped: not finished before the run's own deadline; redone by the next run.
	Failed, Skipped int
	// Undecodable: documents the due query returned but could not decode; skipped and logged by id, not part of Due.
	Undecodable int
}

func (r *OrphanSweepResult) add(o OrphanSweepResult) {
	r.Marked += o.Marked
	r.Deleted += o.Deleted
	r.Held += o.Held
	r.Kept += o.Kept
	r.Attached += o.Attached
	r.Restored += o.Restored
	r.Waiting += o.Waiting
	r.Deferred += o.Deferred
	r.Young += o.Young
	r.Conflicts += o.Conflicts
	r.Failed += o.Failed
	r.Skipped += o.Skipped
}

// Add sums another page into r, for callers that run several pages: every count and Due add up; More is the last page's.
func (r *OrphanSweepResult) Add(o OrphanSweepResult) {
	r.add(o)
	r.Due += o.Due
	r.Undecodable += o.Undecodable
	r.More = o.More
}

// Progressed is the number of documents the page moved out of the due window (or, in a dry run, would have). A page with
// none would be read again unchanged, so a caller stops paging.
func (r OrphanSweepResult) Progressed() int {
	return r.Marked + r.Deleted + r.Held + r.Kept + r.Attached + r.Restored + r.Waiting + r.Deferred + r.Young
}

// Sweep runs one page: at most limit due documents, owners in parallel (bounded). It returns the first error after the
// whole page ran; every outcome, failures included, is counted. An owner not started (or a write not finished) before ctx
// ends is Skipped. With the switch off it reads and writes nothing.
func (s *OrphanSweeper) Sweep(ctx context.Context, now time.Time, limit int) (OrphanSweepResult, error) {
	if !s.d.Mode.Runs() {
		return OrphanSweepResult{}, nil
	}
	now = now.UTC()
	page, err := s.d.Repo.DueOrphans(ctx, now, limit)
	if err != nil {
		return OrphanSweepResult{}, err
	}
	for _, id := range page.Undecodable {
		s.d.Log.WarnContext(ctx, "media_orphan_undecodable", "media_id", id)
	}
	res := OrphanSweepResult{Due: len(page.Docs), More: page.Read >= limit, Undecodable: len(page.Undecodable)}
	var (
		order  []string
		owners = map[string][]*Doc{}
	)
	for _, d := range page.Docs {
		if _, ok := owners[d.OwnerID]; !ok {
			order = append(order, d.OwnerID)
		}
		owners[d.OwnerID] = append(owners[d.OwnerID], d)
	}
	var (
		mu       sync.Mutex
		wg       sync.WaitGroup
		firstErr error
		sem      = make(chan struct{}, orphanSweepWorkers)
	)
	record := func(o OrphanSweepResult, err error) {
		mu.Lock()
		defer mu.Unlock()
		res.add(o)
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}
	for _, uid := range order {
		group := owners[uid]
		if ctx.Err() != nil { // checked first: a select with both cases ready picks one at random
			record(OrphanSweepResult{Skipped: len(group)}, nil)
			continue
		}
		select {
		case <-ctx.Done():
			record(OrphanSweepResult{Skipped: len(group)}, nil)
			continue
		case sem <- struct{}{}:
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			o, err := s.sweepOwner(ctx, now, uid, group)
			record(o, err)
		}()
	}
	wg.Wait()
	if firstErr == nil && ctx.Err() != nil && res.Skipped > 0 {
		firstErr = fmt.Errorf("media: orphan sweep: %w", ctx.Err())
	}
	return res, firstErr
}

// verdict is what the holders say about one candidate.
type verdict int

const (
	verdictFree     verdict = iota // nothing holds it: mark, or delete when marked and the grace is over
	verdictHeld                    // a draft holds it: check again later
	verdictKept                    // a profile image PROFILE_MEDIA_RETIRE keeps (or an unknown purpose): leave the queue
	verdictAttached                // not a candidate any more: remove the fields
	verdictUnknown                 // the holder that decides it could not be read: postpone, never mark
	verdictDeleting                // claimed: finish the delete (delete mode) or defer (mark mode); never restored
)

// candidate reports whether a document can still be an orphan at all.
func candidate(d *Doc) bool { return d.Published() && d.PostID == "" && d.RetiredAt == nil }

func isProfilePurpose(p string) bool { return p == string(PurposeAvatar) }

// holderReads is what one owner's holders said; an error means that holder could not be read.
type holderReads struct {
	drafts, shown         map[string]bool
	draftsErr, profileErr error
}

// readHolders reads, once per owner, the holders its due documents need. A claimed document needs none.
func (s *OrphanSweeper) readHolders(ctx context.Context, uid string, docs []*Doc) (h holderReads, firstErr error) {
	var postIDs []string
	needProfile := false
	for _, d := range docs {
		switch {
		case d.Deleting(), !candidate(d):
		case d.Purpose == string(PurposePost):
			postIDs = append(postIDs, d.ID)
		case isProfilePurpose(d.Purpose):
			needProfile = true
		}
	}
	if len(postIDs) > 0 {
		if h.drafts, h.draftsErr = s.d.Drafts.HeldByDrafts(ctx, uid, postIDs); h.draftsErr != nil {
			firstErr = logger.RedactErr(fmt.Errorf("media: orphan sweep: draft holders: %w", h.draftsErr), uid)
		}
	}
	h.shown = map[string]bool{}
	if needProfile {
		urls, _, err := s.d.Profiles.ProfileImageURLs(ctx, uid)
		if err != nil {
			h.profileErr = err
			if firstErr == nil {
				firstErr = logger.RedactErr(fmt.Errorf("media: orphan sweep: profile: %w", err), uid)
			}
		}
		for _, u := range urls {
			if o, ok := ParseImageURL(u); ok {
				h.shown[o.ID] = true
			}
		}
	}
	return h, firstErr
}

// sweepOwner reads the holders of one owner's due documents once, then handles each document. A holder read error is
// never read as free: the documents that holder decides are postponed (counted Failed) and the first error is returned.
func (s *OrphanSweeper) sweepOwner(ctx context.Context, now time.Time, uid string, docs []*Doc) (out OrphanSweepResult, err error) {
	defer func() {
		if v := recover(); v != nil {
			out = OrphanSweepResult{Failed: len(docs)}
			err = fmt.Errorf("media: orphan sweep: panic of type %T", v)
		}
	}()
	h, firstErr := s.readHolders(ctx, uid, docs)
	if firstErr != nil && ctx.Err() != nil {
		// The run's own deadline ended the holder read: nothing was decided, the next run redoes this owner.
		return OrphanSweepResult{Skipped: len(docs)}, nil
	}
	for _, d := range docs {
		if ctx.Err() != nil {
			out.Skipped++
			continue
		}
		v := s.verdictOf(d, h)
		if v == verdictUnknown {
			out.Failed++
			if err := s.postpone(ctx, now, d); err != nil && !errors.Is(err, ErrConflict) && firstErr == nil {
				firstErr = logger.RedactErr(err, uid)
			}
			continue
		}
		if err := s.handle(ctx, now, d, v, &out); err != nil {
			if ctx.Err() != nil {
				out.Skipped++
				continue
			}
			out.Failed++
			if firstErr == nil {
				firstErr = logger.RedactErr(err, uid)
			}
		}
	}
	return out, firstErr
}

func (s *OrphanSweeper) verdictOf(d *Doc, h holderReads) verdict {
	switch {
	case d.Deleting():
		return verdictDeleting
	case !candidate(d):
		return verdictAttached
	case d.Purpose == string(PurposePost):
		if h.draftsErr != nil {
			return verdictUnknown
		}
		if h.drafts[d.ID] {
			return verdictHeld
		}
		return verdictFree
	case isProfilePurpose(d.Purpose):
		if h.profileErr != nil {
			return verdictUnknown
		}
		if h.shown[d.ID] {
			return verdictAttached
		}
		if !s.d.RetireMode.Allows(d.Purpose) {
			return verdictKept
		}
		return verdictFree
	}
	return verdictKept // a purpose this sweep does not know is never deleted
}

// keptMark is d's mark as it stands (zero when unmarked), for writes that must leave it unchanged.
func keptMark(d *Doc) time.Time {
	if d.OrphanedAt == nil {
		return time.Time{}
	}
	return *d.OrphanedAt
}

// postpone moves a document whose holders could not be read orphanHolderRetry forward, its mark unchanged (precondition
// on the UpdateTime the query read). Nothing in a dry run.
func (s *OrphanSweeper) postpone(ctx context.Context, now time.Time, d *Doc) error {
	if s.d.DryRun {
		return nil
	}
	_, err := s.d.Repo.SetOrphanState(ctx, d.ID, d.UpdateTime, OrphanState{CheckAt: now.Add(orphanHolderRetry), OrphanedAt: keptMark(d)})
	return err
}

// oldEnough is the clock sanity check: the document's own createdAt is at least OrphanAfter before now.
func oldEnough(d *Doc, now time.Time) bool { return !now.Before(d.CreatedAt.Add(OrphanAfter)) }

// freeState is the write for a document nothing holds; del reports that phase 2 should claim and delete it instead.
func (s *OrphanSweeper) freeState(d *Doc, now time.Time, out *OrphanSweepResult) (st OrphanState, count *int, del bool) {
	switch {
	case !oldEnough(d, now):
		return OrphanState{CheckAt: d.CreatedAt.UTC().Add(OrphanAfter), OrphanedAt: keptMark(d)}, &out.Young, false
	case d.OrphanedAt == nil:
		return OrphanState{CheckAt: now.Add(OrphanGrace), OrphanedAt: now}, &out.Marked, false
	case now.Before(d.OrphanedAt.Add(OrphanGrace)):
		return OrphanState{CheckAt: d.OrphanedAt.Add(OrphanGrace), OrphanedAt: *d.OrphanedAt}, &out.Waiting, false
	case !s.d.Mode.Deletes():
		return OrphanState{CheckAt: now.Add(OrphanGrace), OrphanedAt: *d.OrphanedAt}, &out.Deferred, false
	}
	return OrphanState{}, nil, true
}

// handle applies a verdict to one document. ErrConflict is counted, not returned.
func (s *OrphanSweeper) handle(ctx context.Context, now time.Time, d *Doc, v verdict, out *OrphanSweepResult) error {
	var (
		st    OrphanState
		count *int
	)
	switch v {
	case verdictAttached:
		count = &out.Attached
	case verdictHeld:
		st.CheckAt = now.Add(OrphanAfter) // and the mark, if any, is removed
		count = &out.Held
		if d.OrphanedAt != nil {
			count = &out.Restored
		}
	case verdictKept:
		// Both fields removed, like an attach: a profile image PROFILE_MEDIA_RETIRE keeps would otherwise come back every N
		// forever and crowd real orphans out of the page. Rerunning `opsctl backfill-media-orphans` after the switch is
		// turned on makes these candidates again (needsOrphanCheck).
		count = &out.Kept
		if d.OrphanedAt != nil {
			count = &out.Restored
		}
	case verdictDeleting:
		if s.d.Mode.Deletes() {
			return s.deleteOrphan(ctx, now, d, out)
		}
		st, count = OrphanState{CheckAt: now.Add(OrphanGrace), OrphanedAt: keptMark(d)}, &out.Deferred
	case verdictFree:
		var del bool
		if st, count, del = s.freeState(d, now, out); del {
			return s.deleteOrphan(ctx, now, d, out)
		}
	default:
		return fmt.Errorf("media: orphan sweep: verdict %d", v)
	}
	if s.d.DryRun {
		*count++
		return nil
	}
	_, err := s.d.Repo.SetOrphanState(ctx, d.ID, d.UpdateTime, st)
	switch {
	case errors.Is(err, ErrConflict):
		out.Conflicts++
		return nil
	case err != nil:
		return err
	}
	*count++
	return nil
}

// deleteOrphan is phase 2 (delete mode only) for a document still held by nothing, or one already claimed: the claim (the
// permanent orphanDeletingAt, kept as it is on a re-claim), the objects, the document.
func (s *OrphanSweeper) deleteOrphan(ctx context.Context, now time.Time, d *Doc, out *OrphanSweepResult) error {
	if s.d.DryRun {
		out.Deleted++
		return nil
	}
	deletingAt := now
	if d.OrphanDeletingAt != nil {
		deletingAt = *d.OrphanDeletingAt
	}
	claimed, err := s.d.Repo.ClaimOrphan(ctx, d.ID, d.UpdateTime, now.Add(OrphanGrace), deletingAt)
	switch {
	case errors.Is(err, ErrConflict):
		out.Conflicts++
		return nil
	case err != nil:
		return err
	}
	if err := deleteObjects(ctx, s.d.Objects, d); err != nil {
		return fmt.Errorf("media: orphan sweep: objects: %w", err)
	}
	err = s.d.Repo.DeleteOrphan(ctx, d.ID, claimed)
	switch {
	case errors.Is(err, ErrConflict):
		out.Conflicts++
		return nil
	case err != nil:
		return err
	}
	out.Deleted++
	return nil
}
