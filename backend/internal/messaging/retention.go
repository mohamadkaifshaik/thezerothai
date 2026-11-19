package messaging

// retention.go is the ciphertext retention sweep (proto header, "Retention"): 30 days after an encrypted message was sent
// (its ctExpireAt = createdAt + CiphertextRetention) the server blanks its ciphertext and commitment. The record stays:
// id, state (VISIBLE stays VISIBLE), sender, times, mlsGen, mlsEpoch and mlsKey are kept, so the message remains in its
// epoch's completeness set (ListEpochMessages) and reads as ciphertext_removed = true (setEncrypted). ctExpireAt is only
// the trigger of this sweep: it must never get a Firestore TTL policy (that would delete whole messages).
//
// The daily-maintenance cron runs it (apiserver/ciphertext_sweep.go). It is not behind a flag: like the poll vote sweep it
// keeps a retention promise for documents that outlive any flag.

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	// CiphertextSweepPage is the page of one SweepCiphertext call (the step's limit).
	CiphertextSweepPage = 300
	// ciphertextSweepWorkers bounds the concurrent field updates of one page: one sequential update per document would
	// clear only a few hundred documents inside the step's budget.
	ciphertextSweepWorkers = 16
)

// CiphertextSweepResult is what one SweepCiphertext call did (counts only).
type CiphertextSweepResult struct {
	// Due is how many documents the query returned.
	Due int
	// Swept is how many were blanked.
	Swept int
	// Skipped is how many changed or went between the query and the update (a takedown, a tombstone, another write, a
	// deleted tree): left for the next page or run, which sees the new state.
	Skipped int
	// More is true when the page was full, so more may be due.
	More bool
}

// Add sums b into r (More is the last page's).
func (r *CiphertextSweepResult) Add(b CiphertextSweepResult) {
	r.Due += b.Due
	r.Swept += b.Swept
	r.Skipped += b.Skipped
	r.More = b.More
}

// CiphertextSweeper blanks the ciphertext of encrypted messages past their ctExpireAt (*FirestoreRepo implements it).
type CiphertextSweeper interface {
	SweepCiphertext(ctx context.Context, now time.Time, limit int) (CiphertextSweepResult, error)
}

var _ CiphertextSweeper = (*FirestoreRepo)(nil)

// SweepCiphertext runs one bounded page: the collection-group query `messages WHERE ctExpireAt <= now ORDER BY ctExpireAt
// LIMIT limit` (the COLLECTION_GROUP ascending single-field index on messages.ctExpireAt, firebase/firestore.indexes.json;
// Select with no fields, so no ciphertext is read), then one field-level Update per hit with the fields of
// ciphertextRemoval (the same as a takedown's and the eraser's tombstone) and a LastUpdateTime precondition equal to the
// snapshot's: a message taken down, tombstoned or otherwise changed after the query is not rewritten but counted as
// Skipped (FailedPrecondition), as is one deleted meanwhile (NotFound: Update never recreates it). It writes nothing else:
// no conversation or entry, no rev, no push. Every blanked document loses ctExpireAt, so the query shrinks by what it
// swept, and a takedown or tombstone (which delete ctExpireAt too) never comes back to it.
//
// A query error (FAILED_PRECONDITION when the index is not deployed) is returned as is; an update error other than the
// skips above is returned after the page's other updates finished (the counts are still right). Errors name no ids.
func (r *FirestoreRepo) SweepCiphertext(ctx context.Context, now time.Time, limit int) (CiphertextSweepResult, error) {
	var res CiphertextSweepResult
	if limit <= 0 { // Limit(0) would mean no limit
		return res, nil
	}
	docs, err := r.client.CollectionGroup(messagesCollection).Where("ctExpireAt", "<=", now).OrderBy("ctExpireAt", firestore.Asc).
		Select().Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return res, fmt.Errorf("messaging: ciphertext sweep query: %w", err)
	}
	res.Due, res.More = len(docs), len(docs) == limit
	r.hooks.ciphertextSweepRead()

	var (
		mu       sync.Mutex
		wg       sync.WaitGroup
		firstErr error
		sem      = make(chan struct{}, ciphertextSweepWorkers)
	)
	for _, d := range docs {
		sem <- struct{}{}
		wg.Add(1)
		go func(d *firestore.DocumentSnapshot) {
			defer wg.Done()
			defer func() { <-sem }()
			// A panic in a worker would escape the step's recover (another goroutine) and end the process: record it instead.
			defer func() {
				if v := recover(); v != nil {
					mu.Lock()
					if firstErr == nil {
						firstErr = errors.New("messaging: ciphertext sweep update panicked")
					}
					mu.Unlock()
				}
			}()
			_, uerr := d.Ref.Update(ctx, ciphertextRemoval(), firestore.LastUpdateTime(d.UpdateTime))
			mu.Lock()
			defer mu.Unlock()
			switch status.Code(uerr) {
			case codes.OK:
				res.Swept++
			case codes.FailedPrecondition, codes.NotFound, codes.Aborted:
				res.Skipped++ // changed or gone since the query
			default:
				if firstErr == nil {
					firstErr = redactErr(fmt.Errorf("messaging: ciphertext sweep update: %w", uerr), convIDOf(d.Ref), d.Ref.ID)
				}
			}
		}(d)
	}
	wg.Wait()
	return res, firstErr
}

// convIDOf is the conversation id of a message reference (conversations/{convId}/messages/{msgId}), "" for anything else.
func convIDOf(ref *firestore.DocumentRef) string {
	if ref.Parent == nil || ref.Parent.Parent == nil {
		return ""
	}
	return ref.Parent.Parent.ID
}
