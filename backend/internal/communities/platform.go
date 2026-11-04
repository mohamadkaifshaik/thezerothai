// platform.go is the platform's side of communities: the writes behind `opsctl community suspend|restore|archive`
// and the removal-log appends of `opsctl takedown-post` and `suspend-user`. They run in the operator's process, never in the API, so they
// touch no instance cache: a serving instance converges within the 60 s community cache (D12). Every write is a field-level Update inside a
// transaction (never a Set), so a community deleted meanwhile is never recreated. The methods need only the Firestore client: opsctl
// builds the repository without an idempotency or quota store.
package communities

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Errors of the platform levers.
var (
	// ErrSuspendedArchive is `community archive` on a SUSPENDED community: archiving would quietly lift the suspension (ARCHIVED is
	// readable), so the operator restores it first.
	ErrSuspendedArchive = errors.New("communities: the community is SUSPENDED; restore it before archiving")
)

// Platform is the operator surface behind `opsctl community` (D14). *FirestoreRepo implements it.
type Platform interface {
	// Get reads communities/{id} (1 read, charged when missing too). ErrNotFound for a missing document; the SUSPENDED rule is not applied.
	Get(ctx context.Context, id string) (Community, error)
	// SetSuspended suspends (suspend=true) or restores a community: one transaction, 1 read, and 1 write (a field-level Update of status
	// and updatedAt) only when the status changes. Suspend of a SUSPENDED community and restore of one that is not SUSPENDED write 0
	// (changed=false). Restore sets ACTIVE when ownerId is non-empty and ARCHIVED otherwise. before is the status found. ErrNotFound for a
	// missing document.
	SetSuspended(ctx context.Context, id string, suspend bool, now time.Time) (changed bool, before, after Status, err error)
	// Archive is the owner's support request (F12): one transaction, 3 reads (the community, the owner's memberships, the owner's member
	// document), and 2 writes (the community: status ARCHIVED, ownerId "", an OWNER_HANDOVER log entry with an empty target, modlogSeq,
	// updatedAt; the owner's memberships: owned -= id, modlogged += id). The former owner stays a member. A community with no owner
	// writes 0 (changed=false, the second read and third are skipped: 1 read). ErrSuspendedArchive for a SUSPENDED one, ErrNotFound for a
	// missing one.
	Archive(ctx context.Context, id string, now time.Time, modlogMax int) (ArchiveResult, error)
}

// ArchiveResult is what Platform.Archive found and did.
type ArchiveResult struct {
	// Changed is false for a community that already has no owner.
	Changed bool
	// OwnerMember is the former owner's member state after the call (MemberJoined is the expected one); MemberNone when nothing was read.
	OwnerMember MemberState
}

// PlatformRemovals appends platform removals to a community's recentRemovals (D14, A3): a takedown of a community post and the hide loop
// of suspend-user. It is a batch form of the designed Append(ctx, cid, postID, at): suspend-user appends once per community per page, and a
// page can hold several posts of one community (as-built note N10).
type PlatformRemovals interface {
	// Append adds the posts as the newest recentRemovals entries of cid at `at`: one transaction, 1 read, and 1 write (a field-level Update
	// of recentRemovals, removalsTruncatedAt when the cap drops an entry, updatedAt) only when at least one id is missing from the log. A
	// post already listed is left as it is, so a re-run writes 0. appended is the number of entries added; ErrNotFound for a missing
	// community (the status does not matter: a SUSPENDED community still keeps its log). limit <= 0 reads as COMMUNITY_RECENT_REMOVALS_MAX's
	// default (50).
	Append(ctx context.Context, cid string, postIDs []string, at time.Time, limit int) (appended int, err error)
}

var (
	_ Platform         = (*FirestoreRepo)(nil)
	_ PlatformRemovals = (*FirestoreRepo)(nil)
)

func (r *FirestoreRepo) needClient() error {
	if r == nil || r.client == nil {
		return errors.New("communities: repo has no Firestore client")
	}
	return nil
}

// SetSuspended implements Platform.
func (r *FirestoreRepo) SetSuspended(ctx context.Context, id string, suspend bool, now time.Time) (changed bool, before, after Status, err error) {
	if err := r.needClient(); err != nil {
		return false, "", "", err
	}
	_, err = r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		changed, before, after = false, "", ""
		c, err := r.getInTx(ctx, tx, id)
		if err != nil {
			return err
		}
		before, after = c.Status, c.Status
		var next Status
		switch {
		case suspend && c.Status != StatusSuspended:
			next = StatusSuspended
		case !suspend && c.Status == StatusSuspended:
			next = StatusActive
			if c.OwnerID == "" {
				next = StatusArchived
			}
		default:
			return nil
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		b.Update(r.ref(id), []firestore.Update{{Path: "status", Value: string(next)}, {Path: "updatedAt", Value: now.UTC()}})
		if err := b.Err(); err != nil {
			return err
		}
		changed, after = true, next
		return nil
	})
	return changed, before, after, err
}

// Archive implements Platform.
func (r *FirestoreRepo) Archive(ctx context.Context, id string, now time.Time, modlogMax int) (ArchiveResult, error) {
	if err := r.needClient(); err != nil {
		return ArchiveResult{}, err
	}
	var res ArchiveResult
	_, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = ArchiveResult{}
		c, err := r.getInTx(ctx, tx, id)
		if err != nil {
			return err
		}
		if c.Status == StatusSuspended {
			return ErrSuspendedArchive
		}
		if c.OwnerID == "" {
			return nil // already ownerless (ARCHIVED): nothing to do
		}
		ms, exists, err := r.membershipsInTx(ctx, tx, c.OwnerID)
		if err != nil {
			return err
		}
		st, err := r.memberInTx(ctx, tx, id, c.OwnerID)
		if err != nil {
			return err
		}
		now = now.UTC()
		next := c
		next.Status, next.OwnerID = StatusArchived, ""
		log, seq := appendLog(c, LogEntry{At: now, Actor: c.OwnerID, Action: ActionOwnerHandover}, modlogMax)
		ups := append([]firestore.Update{{Path: "status", Value: string(StatusArchived)}, {Path: "ownerId", Value: ""}}, logUpdates(&next, now, log, seq)...)
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		b.Update(r.ref(id), ups)
		// I-M: the community leaves the former owner's owned; I-L: it joins their modlogged (the new entry names them as the actor).
		r.stageModlogged(b, c.OwnerID, id, ms, exists, now, firestore.Update{Path: "owned", Value: firestore.ArrayRemove(id)})
		if err := b.Err(); err != nil {
			return err
		}
		res = ArchiveResult{Changed: true, OwnerMember: st}
		return nil
	})
	return res, err
}

// Append implements PlatformRemovals.
func (r *FirestoreRepo) Append(ctx context.Context, cid string, postIDs []string, at time.Time, limit int) (int, error) {
	if err := r.needClient(); err != nil {
		return 0, err
	}
	if len(postIDs) == 0 {
		return 0, nil
	}
	appended := 0
	_, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		appended = 0
		c, err := r.getInTx(ctx, tx, cid)
		if err != nil {
			return err
		}
		next := c
		for _, p := range postIDs {
			if slices.ContainsFunc(next.RecentRemovals, func(e Removal) bool { return e.PostID == p }) {
				continue
			}
			next.RecentRemovals, next.RemovalsTruncatedAt = removalsAfter(next, p, false, at.UTC(), limit)
			appended++
		}
		if appended == 0 {
			return nil
		}
		ups := []firestore.Update{{Path: "recentRemovals", Value: removalDocs(next.RecentRemovals)}, {Path: "updatedAt", Value: at.UTC()}}
		if !next.RemovalsTruncatedAt.Equal(c.RemovalsTruncatedAt) {
			ups = append(ups, firestore.Update{Path: "removalsTruncatedAt", Value: next.RemovalsTruncatedAt})
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		b.Update(r.ref(cid), ups)
		return b.Err()
	})
	if err != nil {
		return 0, fmt.Errorf("communities: append removals: %w", err)
	}
	return appended, nil
}
