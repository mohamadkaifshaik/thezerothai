// Package store is the unit-of-work seam for atomic, cross-module Firestore writes.
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
)

// Batch is the write-only unit-of-work interface modules depend on. Each method mutates the batch in
// place and returns it so calls can be chained; it never issues a read and never commits.
type Batch interface {
	Set(ref *firestore.DocumentRef, data interface{}, opts ...firestore.SetOption) Batch
	Create(ref *firestore.DocumentRef, data interface{}) Batch
	Update(ref *firestore.DocumentRef, updates []firestore.Update, preconditions ...firestore.Precondition) Batch
	// Delete's variadic preconditions let a caller require firestore.Exists so
	// a whole atomic batch/transaction fails (nothing is written) instead of silently deleting nothing when the
	// document is already gone — Unfollow's blind-batch replay safety and the purge cascade's
	// two-concurrent-runs safety both depend on this. Existing callers passing no preconditions are
	// unaffected (backward compatible).
	Delete(ref *firestore.DocumentRef, preconditions ...firestore.Precondition) Batch
}

// FirestoreBatch adapts *firestore.WriteBatch to Batch and owns committing it.
type FirestoreBatch struct {
	wb *firestore.WriteBatch //nolint:staticcheck // SA1019: still the only atomic, non-transactional multi-doc write; BulkWriter is non-atomic (unit of work)
}

// NewFirestoreBatch starts a new atomic batch (<= 500 writes; Firestore's own limit).
func NewFirestoreBatch(client *firestore.Client) *FirestoreBatch {
	return &FirestoreBatch{wb: client.Batch()} //nolint:staticcheck // SA1019: see FirestoreBatch.wb
}

func (b *FirestoreBatch) Set(ref *firestore.DocumentRef, data interface{}, opts ...firestore.SetOption) Batch {
	b.wb.Set(ref, data, opts...)
	return b
}

func (b *FirestoreBatch) Create(ref *firestore.DocumentRef, data interface{}) Batch {
	b.wb.Create(ref, data)
	return b
}

func (b *FirestoreBatch) Update(ref *firestore.DocumentRef, updates []firestore.Update, preconditions ...firestore.Precondition) Batch {
	b.wb.Update(ref, updates, preconditions...)
	return b
}

func (b *FirestoreBatch) Delete(ref *firestore.DocumentRef, preconditions ...firestore.Precondition) Batch {
	b.wb.Delete(ref, preconditions...)
	return b
}

// Commit atomically applies every write appended to the batch. Call exactly once, from the module that
// opened the batch ("the owning module appends its writes to the batch, the caller commits once").
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
	firstErr error
}

// NewFirestoreTxBatch wraps an in-flight transaction. The transaction's own reads must go through tx.Get
// directly (Batch has no read methods by design).
func NewFirestoreTxBatch(tx *firestore.Transaction) *FirestoreTxBatch {
	return &FirestoreTxBatch{tx: tx}
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
	return b
}

func (b *FirestoreTxBatch) Create(ref *firestore.DocumentRef, data interface{}) Batch {
	b.noteErr(b.tx.Create(ref, data))
	return b
}

func (b *FirestoreTxBatch) Update(ref *firestore.DocumentRef, updates []firestore.Update, preconditions ...firestore.Precondition) Batch {
	b.noteErr(b.tx.Update(ref, updates, preconditions...))
	return b
}

func (b *FirestoreTxBatch) Delete(ref *firestore.DocumentRef, preconditions ...firestore.Precondition) Batch {
	b.noteErr(b.tx.Delete(ref, preconditions...))
	return b
}
