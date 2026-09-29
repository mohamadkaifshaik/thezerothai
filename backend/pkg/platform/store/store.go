// Package store is the unit-of-work seam for atomic, cross-module Firestore writes (ADR-0002).
// A caller such as posts.CreatePost opens a Batch, passes it into other modules' interface methods
// (e.g. identity.Counters.AddPostsCount(b, uid, 1)) so they can append their own writes, then commits
// once. No module ever builds a document path it does not own — Batch only carries writes, never paths.
//
// The Firestore implementation wraps an atomic *firestore.WriteBatch, or a *firestore.Transaction when
// the caller also needs reads (e.g. handle-uniqueness checks) — never BulkWriter, which is not atomic.
package store

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// Batch is the write-only unit-of-work interface modules depend on. Each method mutates the batch in
// place and returns it so calls can be chained; it never issues a read and never commits.
type Batch interface {
	Set(ref *firestore.DocumentRef, data interface{}, opts ...firestore.SetOption) Batch
	Create(ref *firestore.DocumentRef, data interface{}) Batch
	Update(ref *firestore.DocumentRef, updates []firestore.Update) Batch
	// Delete's variadic preconditions (added for ADR-0008 T7/D10) let a caller require firestore.Exists so
	// a whole atomic batch/transaction fails (0 writes) instead of silently deleting nothing when the
	// document is already gone — Unfollow's blind-batch replay safety and the purge cascade's
	// two-concurrent-runs safety both depend on this. Existing callers passing no preconditions are
	// unaffected (backward compatible).
	Delete(ref *firestore.DocumentRef, preconditions ...firestore.Precondition) Batch
}

// FirestoreBatch adapts *firestore.WriteBatch to Batch and owns committing it.
type FirestoreBatch struct {
	wb      *firestore.WriteBatch //nolint:staticcheck // SA1019: still the only atomic, non-transactional multi-doc write; BulkWriter is non-atomic (ADR-0002 unit of work)
	counter *budget.Counter
}

// NewFirestoreBatch starts a new atomic batch (<= 500 writes; Firestore's own limit).
func NewFirestoreBatch(client *firestore.Client, counter *budget.Counter) *FirestoreBatch {
	return &FirestoreBatch{wb: client.Batch(), counter: counter} //nolint:staticcheck // SA1019: see FirestoreBatch.wb
}

func (b *FirestoreBatch) Set(ref *firestore.DocumentRef, data interface{}, opts ...firestore.SetOption) Batch {
	b.wb.Set(ref, data, opts...)
	b.counter.AddWrites(1)
	return b
}

func (b *FirestoreBatch) Create(ref *firestore.DocumentRef, data interface{}) Batch {
	b.wb.Create(ref, data)
	b.counter.AddWrites(1)
	return b
}

func (b *FirestoreBatch) Update(ref *firestore.DocumentRef, updates []firestore.Update) Batch {
	b.wb.Update(ref, updates)
	b.counter.AddWrites(1)
	return b
}

func (b *FirestoreBatch) Delete(ref *firestore.DocumentRef, preconditions ...firestore.Precondition) Batch {
	b.wb.Delete(ref, preconditions...)
	b.counter.AddDeletes(1)
	return b
}

// Commit atomically applies every write appended to the batch. Call exactly once, from the module that
// opened the batch (ADR-0002: "the owning module appends its writes to the batch, the caller commits once").
func (b *FirestoreBatch) Commit(ctx context.Context) error {
	if _, err := b.wb.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit batch: %w", err)
	}
	return nil
}

// FirestoreTxBatch adapts a *firestore.Transaction to Batch for use inside a RunTransaction callback,
// so the same cross-module interface methods work whether or not the caller needs a read first.
//
// Unlike WriteBatch, Transaction's Set/Create/Update/Delete return an error immediately (e.g. an empty
// updates list). Batch's chaining API has no room for that, so the first such error is captured and
// must be checked with Err() before the transaction callback returns nil.
type FirestoreTxBatch struct {
	tx       *firestore.Transaction
	counter  *budget.Counter
	firstErr error
}

// NewFirestoreTxBatch wraps an in-flight transaction. The transaction's own reads must go through tx.Get
// directly (Batch has no read methods by design); repo code should count those reads on the same counter.
func NewFirestoreTxBatch(tx *firestore.Transaction, counter *budget.Counter) *FirestoreTxBatch {
	return &FirestoreTxBatch{tx: tx, counter: counter}
}

// Err returns the first error, if any, raised by a Set/Create/Update/Delete call. Repo code must check
// this before returning nil from the RunTransaction callback.
func (b *FirestoreTxBatch) Err() error { return b.firstErr }

func (b *FirestoreTxBatch) noteErr(err error) {
	if err != nil && b.firstErr == nil {
		b.firstErr = fmt.Errorf("store: transaction write: %w", err)
	}
}

func (b *FirestoreTxBatch) Set(ref *firestore.DocumentRef, data interface{}, opts ...firestore.SetOption) Batch {
	b.noteErr(b.tx.Set(ref, data, opts...))
	b.counter.AddWrites(1)
	return b
}

func (b *FirestoreTxBatch) Create(ref *firestore.DocumentRef, data interface{}) Batch {
	b.noteErr(b.tx.Create(ref, data))
	b.counter.AddWrites(1)
	return b
}

func (b *FirestoreTxBatch) Update(ref *firestore.DocumentRef, updates []firestore.Update) Batch {
	b.noteErr(b.tx.Update(ref, updates))
	b.counter.AddWrites(1)
	return b
}

func (b *FirestoreTxBatch) Delete(ref *firestore.DocumentRef, preconditions ...firestore.Precondition) Batch {
	b.noteErr(b.tx.Delete(ref, preconditions...))
	b.counter.AddDeletes(1)
	return b
}
