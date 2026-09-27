// Package idempotency implements the "idempotency doc" mechanism from ADR-0003 for mutations whose
// entity id must be a Snowflake value (CreatePost, CreateUpload, ...): a doc at
// idempotency/{sha256(uid|rpc|key)} is created in the *same atomic batch/transaction* as the entity, so
// a replay (client retry) either finds nothing (first attempt) or finds the recorded result.
//
// Mutations with a natural-key doc id (users/{uid}, follows/{a}_{b}, likes/{postId}_{uid}, ...) don't
// need this: a Create() AlreadyExists on the entity itself is idempotency for free (ADR-0003 mechanism 1).
package idempotency

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const collection = "idempotency"

// TTL is how long a replay window stays open (ADR-0003: 24h, Firestore TTL field expireAt).
const TTL = 24 * time.Hour

// ErrNotFound is returned by Get when no record exists yet for the key (first attempt: proceed).
var ErrNotFound = errors.New("idempotency: record not found")

// Record is the stored replay state for one (uid, rpc, idempotency_key).
type Record struct {
	UID         string            `firestore:"uid"`
	RPC         string            `firestore:"rpc"`
	RequestHash string            `firestore:"requestHash"`
	Result      map[string]string `firestore:"result"`
	ExpireAt    time.Time         `firestore:"expireAt"`
}

// Store builds idempotency doc refs/keys against one Firestore client.
type Store struct {
	client *firestore.Client
}

func New(client *firestore.Client) *Store {
	return &Store{client: client}
}

// Key derives the deterministic doc id sha256(uid|rpc|key) (ADR-0003).
func Key(uid, rpc, idempotencyKey string) string {
	sum := sha256.Sum256([]byte(uid + "|" + rpc + "|" + idempotencyKey))
	return hex.EncodeToString(sum[:])
}

// HashRequest hashes the canonical, stable representation of a request body so a replay with a
// different body can be rejected (ERROR_REASON_IDEMPOTENCY_KEY_REUSED). Callers should pass a
// deterministic encoding (e.g. sorted field=value pairs), never proto binary (field order/unknown
// fields are not guaranteed stable).
func HashRequest(canonical string) string {
	sum := sha256.Sum256([]byte(canonical))
	return hex.EncodeToString(sum[:])
}

func (s *Store) Ref(key string) *firestore.DocumentRef {
	return s.client.Collection(collection).Doc(key)
}

// Get reads the record for key inside tx (so it's part of the same read-modify-write transaction the
// caller uses to check the entity). Returns ErrNotFound if absent. Counts against ctx's budget.Counter.
func (s *Store) Get(ctx context.Context, tx *firestore.Transaction, key string) (Record, error) {
	snap, err := tx.Get(s.Ref(key))
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Record{}, ErrNotFound
		}
		return Record{}, fmt.Errorf("idempotency: get %s: %w", key, err)
	}
	var rec Record
	if err := snap.DataTo(&rec); err != nil {
		return Record{}, fmt.Errorf("idempotency: decode %s: %w", key, err)
	}
	return rec, nil
}

// Put appends a Create() of the record to b, in the same atomic unit of work as the entity it guards.
func (s *Store) Put(b store.Batch, key string, rec Record) {
	if rec.ExpireAt.IsZero() {
		rec.ExpireAt = time.Now().Add(TTL)
	}
	b.Create(s.Ref(key), rec)
}
