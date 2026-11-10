// orphan_sweep.go deletes published images that nothing ever attached: an upload that reached READY in an abandoned
// composer (or one finished by a request already in flight when the session switched) and was never posted, scheduled,
// put on an article draft or set as an avatar or banner. PENDING and REJECTED documents already expire through expireAt;
// without this sweep a READY one would keep its document and its public objects forever.
//
// Candidates. FinalizeUpload writes orphanCheckAt = readyAt + OrphanAfter on every READY document and Claim.Attach
// deletes it in the CreatePost transaction (CreatePost, the scheduled publish and the article publish all attach through
// it), so only unattached images are ever due. Documents published before this existed get the field from
// `opsctl backfill-media-orphans`. DueOrphans is one range query on that field (automatic single-field index).
//
// Holders that do not write the media document are checked from fresh reads at sweep time, grouped by owner:
//
//	POST            a PENDING scheduled post's draft, an unpublished article draft's cover   DraftHolds
//	AVATAR, BANNER  the image users/{uid} shows now                                          ProfileImages
//
// A POST image a draft holds is "held": checked again OrphanAfter later. A profile image the profile shows is attached:
// the field is removed and the profile_media_retired step owns it from then on. A profile image the profile does not show
// is deleted only when PROFILE_MEDIA_RETIRE allows its purpose (the switch that decides whether replaced profile images,
// which post author snapshots may still name, are deleted); otherwise it is "kept": the fields are removed (it leaves the
// queue) and a rerun of `opsctl backfill-media-orphans` after the switch is turned on enrolls it again.
//
// Two phases, so that an attach can never lose to a delete:
//
//	phase 1 (mark)    held by nothing: orphanedAt = now, orphanCheckAt = now + OrphanGrace, LastUpdateTime precondition.
//	                  From this write on LoadForPost (inside the attaching transaction), the avatar and banner resolvers
//	                  and the article cover preview refuse the document. An attach that committed first moved the
//	                  UpdateTime, so the mark fails (ErrConflict) and the attach wins; a mark that committed first makes
//	                  the attaching transaction read it and refuse (the two serialize on the document).
//	phase 2 (delete)  a later run (>= OrphanGrace after the mark, far above any request deadline, so an UpdateProfile or a
//	                  schedule that read the image before the mark has committed) checks the holders again. Held: the
//	                  mark is removed. Still free: a claim write (orphanCheckAt = now + OrphanGrace, precondition) so a
//	                  concurrent run cannot act on the same snapshot, then every object the document may own (the
//	                  eraser's deleteObjects: public names in both shapes and the private upload leftovers; a missing object
//	                  is success), then the document (precondition on the claim's UpdateTime).
//
// Every step is idempotent: a crash after the claim leaves a marked document that is due again after OrphanGrace and
// repeats phase 2 (deleting missing objects succeeds); a crash after the objects leaves the document, which still names
// them. The account eraser deletes every document whatever its sweep fields; a sweep write that arrives after it fails its
// precondition and recreates nothing. No new collection: right-to-delete and the export already cover media/{id}.
//
// Cost per run (limit n): reads n (the due query) + per owner in the page, POST candidates: the PENDING scheduled drafts
// (<= SCHEDULED_MAX_PENDING) and one article query per 30 ids; profile candidates: users/{uid} (1). Writes: 1 per
// candidate (mark, hold, keep, attach) or 2 per deleted document (claim, delete). GCS: up to 6 free deletes per deleted
// document (2 public, 2 old-shape public for a suffixed document, 2 private).
package media

import (
	"context"
	"errors"
	"fmt"
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
	// OrphanSweepPage is the default page of one sweep run (the opsPage bound shared with the purge).
	OrphanSweepPage = opsPage
	// orphanSweepWorkers bounds the owners swept concurrently within one page.
	orphanSweepWorkers = 4
)

// DraftHolds reports which of uid's POST image ids something other than a post still holds: a PENDING scheduled post's
// draft or an unpublished article draft's cover. It reads fresh (no cache). When it cannot tell (more holders than it
// reads) it reports the id held, never free. Implemented by a consumer-side adapter in apiserver over posts and articles.
type DraftHolds interface {
	HeldByDrafts(ctx context.Context, uid string, ids []string) (map[string]bool, error)
}

// OrphanSweepDeps are the sweep's collaborators.
type OrphanSweepDeps struct {
	Repo     OrphanRepo
	Objects  Objects
	Drafts   DraftHolds
	Profiles ProfileImages
	// RetireMode is PROFILE_MEDIA_RETIRE: a profile image the profile does not show is deleted only when it allows the purpose.
	RetireMode config.ProfileMediaRetire
}

// OrphanSweeper runs the sweep.
type OrphanSweeper struct{ d OrphanSweepDeps }

// NewOrphanSweeper checks the deps.
func NewOrphanSweeper(d OrphanSweepDeps) (*OrphanSweeper, error) {
	if d.Repo == nil || d.Objects == nil || d.Drafts == nil || d.Profiles == nil {
		return nil, errors.New("media: orphan sweep: missing dependency")
	}
	return &OrphanSweeper{d: d}, nil
}

// OrphanSweepResult counts one run. Due = Marked + Deleted + Held + Kept + Attached + Restored + Waiting + Conflicts +
// Failed + Skipped.
type OrphanSweepResult struct {
	// Due is the number of candidates the query returned; More is true when the page was full.
	Due  int
	More bool
	// Marked: phase 1 done. Deleted: phase 2 done (objects and document).
	Marked, Deleted int
	// Held: a draft holds it. Kept: a profile image PROFILE_MEDIA_RETIRE does not let the sweep delete (or a purpose the sweep
	// does not know); its fields are removed. Attached: no longer
	// a candidate (attached to a post, shown by the profile, retired or not published); its fields are removed.
	// Restored: a marked document something holds after all; the mark is removed.
	Held, Kept, Attached, Restored int
	// Waiting: a marked document due before its grace ended (only after a clock change); pushed to the end of the grace.
	Waiting int
	// Conflicts: the document changed since the query read it (an attach, a concurrent run, the eraser); left for the next run.
	Conflicts int
	// Failed: an error (holder read, write or object delete); left for the next run. Skipped: not reached before the deadline.
	Failed, Skipped int
}

func (r *OrphanSweepResult) add(o OrphanSweepResult) {
	r.Marked += o.Marked
	r.Deleted += o.Deleted
	r.Held += o.Held
	r.Kept += o.Kept
	r.Attached += o.Attached
	r.Restored += o.Restored
	r.Waiting += o.Waiting
	r.Conflicts += o.Conflicts
	r.Failed += o.Failed
	r.Skipped += o.Skipped
}

// Sweep runs one page: at most limit due documents, owners in parallel (bounded). It returns the first error after the
// whole page ran; every outcome, failures included, is counted. An owner not started before ctx ends is Skipped.
func (s *OrphanSweeper) Sweep(ctx context.Context, now time.Time, limit int) (OrphanSweepResult, error) {
	now = now.UTC()
	docs, err := s.d.Repo.DueOrphans(ctx, now, limit)
	if err != nil {
		return OrphanSweepResult{}, err
	}
	res := OrphanSweepResult{Due: len(docs), More: len(docs) == limit}
	var (
		order  []string
		owners = map[string][]*Doc{}
	)
	for _, d := range docs {
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
)

// candidate reports whether a document can still be an orphan at all.
func candidate(d *Doc) bool { return d.Published() && d.PostID == "" && d.RetiredAt == nil }

func isProfilePurpose(p string) bool { return p == string(PurposeAvatar) || p == string(PurposeBanner) }

// sweepOwner reads the holders of one owner's due documents once, then handles each document. A holder read error fails
// the whole group with no write (an unknown hold is never read as free).
func (s *OrphanSweeper) sweepOwner(ctx context.Context, now time.Time, uid string, docs []*Doc) (out OrphanSweepResult, err error) {
	defer func() {
		if v := recover(); v != nil {
			out = OrphanSweepResult{Failed: len(docs)}
			err = fmt.Errorf("media: orphan sweep: panic of type %T", v)
		}
	}()
	var postIDs []string
	needProfile := false
	for _, d := range docs {
		switch {
		case !candidate(d):
		case d.Purpose == string(PurposePost):
			postIDs = append(postIDs, d.ID)
		case isProfilePurpose(d.Purpose):
			needProfile = true
		}
	}
	var drafts map[string]bool
	if len(postIDs) > 0 {
		if drafts, err = s.d.Drafts.HeldByDrafts(ctx, uid, postIDs); err != nil {
			return OrphanSweepResult{Failed: len(docs)}, logger.RedactErr(fmt.Errorf("media: orphan sweep: draft holders: %w", err), uid)
		}
	}
	shown := map[string]bool{}
	if needProfile {
		urls, _, err := s.d.Profiles.ProfileImageURLs(ctx, uid)
		if err != nil {
			return OrphanSweepResult{Failed: len(docs)}, logger.RedactErr(fmt.Errorf("media: orphan sweep: profile: %w", err), uid)
		}
		for _, u := range urls {
			if o, ok := ParseImageURL(u); ok {
				shown[o.ID] = true
			}
		}
	}
	var firstErr error
	for _, d := range docs {
		if ctx.Err() != nil {
			out.Skipped++
			continue
		}
		v := s.verdictOf(d, drafts, shown)
		if err := s.handle(ctx, now, d, v, &out); err != nil {
			out.Failed++
			if firstErr == nil {
				firstErr = logger.RedactErr(err, uid)
			}
		}
	}
	return out, firstErr
}

func (s *OrphanSweeper) verdictOf(d *Doc, drafts, shown map[string]bool) verdict {
	switch {
	case !candidate(d):
		return verdictAttached
	case d.Purpose == string(PurposePost):
		if drafts[d.ID] {
			return verdictHeld
		}
		return verdictFree
	case isProfilePurpose(d.Purpose):
		if shown[d.ID] {
			return verdictAttached
		}
		if !s.d.RetireMode.Allows(d.Purpose) {
			return verdictKept
		}
		return verdictFree
	}
	return verdictKept // a purpose this sweep does not know is never deleted
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
		if d.Orphaned() {
			count = &out.Restored
		}
	case verdictKept:
		// Both fields removed, like an attach: a profile image PROFILE_MEDIA_RETIRE keeps would otherwise come back every N
		// forever and crowd real orphans out of the page. Rerunning `opsctl backfill-media-orphans` after the switch is
		// turned on makes these candidates again (needsOrphanCheck).
		count = &out.Kept
		if d.Orphaned() {
			count = &out.Restored
		}
	case verdictFree:
		if !d.Orphaned() {
			st = OrphanState{CheckAt: now.Add(OrphanGrace), OrphanedAt: now}
			count = &out.Marked
			break
		}
		if graceEnd := d.OrphanedAt.Add(OrphanGrace); now.Before(graceEnd) {
			st = OrphanState{CheckAt: graceEnd, OrphanedAt: *d.OrphanedAt}
			count = &out.Waiting
			break
		}
		return s.deleteOrphan(ctx, now, d, out)
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

// deleteOrphan is phase 2 for a document still held by nothing: claim, objects, document.
func (s *OrphanSweeper) deleteOrphan(ctx context.Context, now time.Time, d *Doc, out *OrphanSweepResult) error {
	claimed, err := s.d.Repo.SetOrphanState(ctx, d.ID, d.UpdateTime, OrphanState{CheckAt: now.Add(OrphanGrace), OrphanedAt: *d.OrphanedAt})
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
