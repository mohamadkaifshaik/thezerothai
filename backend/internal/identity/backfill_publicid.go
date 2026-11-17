package identity

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The public id backfill (`opsctl backfill-public-ids`): every account that can appear on the wire gets a public id
// before the API exposes them, whatever FEATURE_PUBLIC_IDS says (the API mints by itself, at signup and on GetMe, only
// while the flag is not globally off, and only ACTIVE accounts). It walks users by document id and, for each document:
//
//   - DELETING: never touched (the erase pipeline may already have passed its lookup deletion), counted as skipped.
//   - status other than ACTIVE or SUSPENDED (unset, unknown): never touched, counted as skipped.
//   - no publicId: mint (ACTIVE and SUSPENDED alike; a suspended account can come back).
//   - publicId whose publicIds/{id} names this uid: already ok.
//   - publicId whose lookup is missing (a manual restore of a DELETING account): repair, the SAME id re-created
//     create-only (an id is immutable, never redrawn).
//   - publicId whose lookup names another uid, or a stored publicId that is not well formed: a conflict, nothing written.
//
// Every write is a transaction that re-reads users/{uid} and re-checks the status, so an account that turned DELETING
// after the page read is skipped. Re-running is idempotent: a finished walk finds every account ok or skipped.

// PublicIDBackfillPage is the number of users documents one page of the walk reads.
const PublicIDBackfillPage = 200

// PublicIDScanRow is one users document as the walk sees it: its stored publicId and status, whether its
// publicIds/{publicId} lookup exists (false when PublicID is empty or not well formed) and the uid it names ("" when
// absent or undecodable; an undecodable lookup is a conflict, never repaired).
type PublicIDScanRow struct {
	UID          string
	PublicID     string
	Status       AccountStatus
	LookupExists bool
	LookupOwner  string
}

// PublicIDTxResult is what one backfill transaction found (and did).
type PublicIDTxResult int

// The transaction outcomes.
const (
	// PublicIDTxWrote: it minted (mint) or re-created the lookup (repair).
	PublicIDTxWrote PublicIDTxResult = iota + 1
	// PublicIDTxAlreadyOK: the fresh read found the work done (mint: the account has an id now; repair: the lookup exists
	// and names this uid).
	PublicIDTxAlreadyOK
	// PublicIDTxDeleting: the account is DELETING; nothing written.
	PublicIDTxDeleting
	// PublicIDTxOtherStatus: the account is neither ACTIVE nor SUSPENDED (nor DELETING); nothing written.
	PublicIDTxOtherStatus
	// PublicIDTxGone: users/{uid} is gone, or (repair) it no longer carries the id the page read; nothing written.
	PublicIDTxGone
	// PublicIDTxForeign: (repair) the lookup exists and names another uid; nothing written.
	PublicIDTxForeign
)

// PublicIDBackfillStore is the Firestore seam of the backfill (*FirestoreRepo implements it). Errors never name a uid
// or an id in their own text; Firestore's text (document paths) is scrubbed by BackfillPublicIDsPage.
type PublicIDBackfillStore interface {
	// ScanPublicIDs reads up to limit users documents after the document id `after` ("" = from the start), in document
	// id order, plus one GetAll of the publicIds lookups of the well-formed stored ids.
	ScanPublicIDs(ctx context.Context, after string, limit int) ([]PublicIDScanRow, error)
	// MintPublicIDForBackfill is one transaction: re-read users/{uid}; only an ACTIVE or SUSPENDED account without
	// publicId gets publicIds/{publicID} (create-only) and users/{uid}.publicId (field-level update). A taken lookup is
	// ErrPublicIDCollision with nothing written.
	MintPublicIDForBackfill(ctx context.Context, uid, publicID string, now time.Time) (PublicIDTxResult, error)
	// RepairPublicIDLookup is one transaction: re-read users/{uid} (still ACTIVE or SUSPENDED, still carrying publicID)
	// and publicIds/{publicID}; only an absent lookup is re-created (create-only) with the same id.
	RepairPublicIDLookup(ctx context.Context, uid, publicID string, now time.Time) (PublicIDTxResult, error)
}

// PublicIDBackfillOptions configure one page.
type PublicIDBackfillOptions struct {
	// DryRun classifies only: no transaction, nothing written.
	DryRun bool
	// Now stamps createdAt of new lookups (nil = time.Now).
	Now func() time.Time
	// NewID draws a public id (nil = NewPublicID); tests force collisions with it.
	NewID func() (string, error)
	// Limit is the page size (0 = PublicIDBackfillPage).
	Limit int
	// CallTimeout bounds each store call (the scan, each transaction) on its own; 0 = only ctx's deadline.
	CallTimeout time.Duration
}

// PublicIDBackfillCounts are the per-account outcomes. In a dry run Minted and Repaired are "would mint" and "would
// repair". Scanned = AlreadyOK + Minted + Repaired + SkippedDeleting + SkippedStatus + Gone + Conflicts.
type PublicIDBackfillCounts struct {
	Scanned, AlreadyOK, Minted, Repaired, SkippedDeleting, SkippedStatus, Gone, Conflicts int
	// Collisions counts drawn ids that were already taken (each redrawn; not an account outcome).
	Collisions int
}

// Add sums two counts.
func (c PublicIDBackfillCounts) Add(o PublicIDBackfillCounts) PublicIDBackfillCounts {
	return PublicIDBackfillCounts{
		Scanned: c.Scanned + o.Scanned, AlreadyOK: c.AlreadyOK + o.AlreadyOK, Minted: c.Minted + o.Minted,
		Repaired: c.Repaired + o.Repaired, SkippedDeleting: c.SkippedDeleting + o.SkippedDeleting,
		SkippedStatus: c.SkippedStatus + o.SkippedStatus, Gone: c.Gone + o.Gone, Conflicts: c.Conflicts + o.Conflicts,
		Collisions: c.Collisions + o.Collisions,
	}
}

// Writes is the number of transactions that wrote.
func (c PublicIDBackfillCounts) Writes() int { return c.Minted + c.Repaired }

// The conflict reasons.
const (
	PublicIDConflictForeignLookup = "foreign_lookup"
	PublicIDConflictInvalidID     = "invalid_public_id"
)

// PublicIDConflict is one account left alone for a human. The ids are RAW: the caller prints only their keyed hashes.
type PublicIDConflict struct {
	Reason   string
	UID      string
	PublicID string
	// Owner is the uid the lookup names (foreign_lookup only).
	Owner string
}

// PublicIDBackfillResult is one page's outcome.
type PublicIDBackfillResult struct {
	Counts       PublicIDBackfillCounts
	ConflictList []PublicIDConflict
	// Last is the last users document id fully handled ("" when none): the next page starts after it. On an error it is
	// the last one before the failing account.
	Last string
	// More reports a full page: there may be more documents after Last.
	More bool
}

// BackfillPublicIDsPage handles one page of the walk after `after` ("" = from the start). A failure stops the page and
// returns the counts so far, Last set to the account before the failing one, and an error scrubbed of every uid and id.
func BackfillPublicIDsPage(ctx context.Context, st PublicIDBackfillStore, after string, opts PublicIDBackfillOptions) (PublicIDBackfillResult, error) {
	limit := opts.Limit
	if limit <= 0 {
		limit = PublicIDBackfillPage
	}
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	newID := opts.NewID
	if newID == nil {
		newID = NewPublicID
	}
	if opts.CallTimeout > 0 {
		st = timedBackfillStore{st: st, d: opts.CallTimeout}
	}
	res := PublicIDBackfillResult{Last: after}
	rows, err := st.ScanPublicIDs(ctx, after, limit)
	if err != nil {
		return res, logger.ScrubErr(fmt.Errorf("identity: scan users for public ids: %w", err), after)
	}
	res.More = len(rows) >= limit
	for _, row := range rows {
		if err := ctx.Err(); err != nil {
			return res, fmt.Errorf("identity: public id backfill interrupted: %w", err)
		}
		if err := backfillOne(ctx, st, row, opts.DryRun, now, newID, &res); err != nil {
			return res, err
		}
		res.Counts.Scanned++
		res.Last = row.UID
	}
	return res, nil
}

// backfillOne classifies one row and, unless dryRun, runs its transaction. It counts the outcome in res (not Scanned).
func backfillOne(ctx context.Context, st PublicIDBackfillStore, row PublicIDScanRow, dryRun bool, now func() time.Time, newID func() (string, error), res *PublicIDBackfillResult) error {
	c := &res.Counts
	switch {
	case row.Status == AccountStatusDeleting:
		c.SkippedDeleting++
		return nil
	case row.Status != AccountStatusActive && row.Status != AccountStatusSuspended:
		c.SkippedStatus++
		return nil
	case row.PublicID == "":
		if dryRun {
			c.Minted++
			return nil
		}
		return mintOne(ctx, st, row.UID, now, newID, res)
	case !ValidPublicID(row.PublicID):
		c.Conflicts++
		res.ConflictList = append(res.ConflictList, PublicIDConflict{Reason: PublicIDConflictInvalidID, UID: row.UID, PublicID: row.PublicID})
		return nil
	case row.LookupExists && row.LookupOwner == row.UID:
		c.AlreadyOK++
		return nil
	case row.LookupExists:
		c.Conflicts++
		res.ConflictList = append(res.ConflictList, PublicIDConflict{Reason: PublicIDConflictForeignLookup, UID: row.UID, PublicID: row.PublicID, Owner: row.LookupOwner})
		return nil
	}
	// A stored id with no lookup: repair with the same id.
	if dryRun {
		c.Repaired++
		return nil
	}
	got, err := st.RepairPublicIDLookup(ctx, row.UID, row.PublicID, now().UTC())
	if err != nil {
		return logger.ScrubErr(fmt.Errorf("identity: repair public id lookup: %w", err), row.UID, row.PublicID)
	}
	if got == PublicIDTxForeign {
		// The lookup appeared between the page read and the transaction, naming another account (its owner is unknown
		// here: the transaction does not return it).
		c.Conflicts++
		res.ConflictList = append(res.ConflictList, PublicIDConflict{Reason: PublicIDConflictForeignLookup, UID: row.UID, PublicID: row.PublicID})
		return nil
	}
	countTx(c, got, &c.Repaired)
	return nil
}

// mintOne draws an id and runs the mint transaction, redrawing on a collision (at most maxPublicIDAttempts draws).
func mintOne(ctx context.Context, st PublicIDBackfillStore, uid string, now func() time.Time, newID func() (string, error), res *PublicIDBackfillResult) error {
	c := &res.Counts
	for range maxPublicIDAttempts {
		publicID, err := newID()
		if err != nil {
			return fmt.Errorf("identity: draw public id: %w", err)
		}
		got, err := st.MintPublicIDForBackfill(ctx, uid, publicID, now().UTC())
		if errors.Is(err, ErrPublicIDCollision) {
			c.Collisions++
			continue
		}
		if err != nil {
			return logger.ScrubErr(fmt.Errorf("identity: mint public id: %w", err), uid, publicID)
		}
		countTx(c, got, &c.Minted)
		return nil
	}
	return fmt.Errorf("identity: public id still colliding after %d draws: %w", maxPublicIDAttempts, ErrPublicIDCollision)
}

// countTx counts a transaction outcome; wrote is the counter of PublicIDTxWrote.
func countTx(c *PublicIDBackfillCounts, got PublicIDTxResult, wrote *int) {
	switch got {
	case PublicIDTxWrote:
		*wrote++
	case PublicIDTxAlreadyOK:
		c.AlreadyOK++
	case PublicIDTxDeleting:
		c.SkippedDeleting++
	case PublicIDTxOtherStatus:
		c.SkippedStatus++
	default: // PublicIDTxGone (PublicIDTxForeign is handled by the repair caller)
		c.Gone++
	}
}

// timedBackfillStore gives every store call its own deadline, so a page of 200 transactions is not bounded by one.
type timedBackfillStore struct {
	st PublicIDBackfillStore
	d  time.Duration
}

func (t timedBackfillStore) ScanPublicIDs(ctx context.Context, after string, limit int) ([]PublicIDScanRow, error) {
	ctx, cancel := context.WithTimeout(ctx, t.d)
	defer cancel()
	return t.st.ScanPublicIDs(ctx, after, limit)
}

func (t timedBackfillStore) MintPublicIDForBackfill(ctx context.Context, uid, publicID string, now time.Time) (PublicIDTxResult, error) {
	ctx, cancel := context.WithTimeout(ctx, t.d)
	defer cancel()
	return t.st.MintPublicIDForBackfill(ctx, uid, publicID, now)
}

func (t timedBackfillStore) RepairPublicIDLookup(ctx context.Context, uid, publicID string, now time.Time) (PublicIDTxResult, error) {
	ctx, cancel := context.WithTimeout(ctx, t.d)
	defer cancel()
	return t.st.RepairPublicIDLookup(ctx, uid, publicID, now)
}
