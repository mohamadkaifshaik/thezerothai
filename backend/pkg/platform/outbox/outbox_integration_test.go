//go:build integration

package outbox

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Each test uses its own random project id, so the emulator state of other tests and shards never leaks in.
func outboxTestClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-outbox-%d", rand.Int64()))
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

func stageCommit(t *testing.T, client *firestore.Client, o *Outbox, e Entry) {
	t.Helper()
	b := store.NewFirestoreBatch(client)
	if err := o.Stage(b, e); err != nil {
		t.Fatal(err)
	}
	if err := b.Commit(context.Background()); err != nil {
		t.Fatalf("commit: %v", err)
	}
}

func docExists(t *testing.T, client *firestore.Client, id string) bool {
	t.Helper()
	_, err := client.Collection(Collection).Doc(id).Get(context.Background())
	if err == nil {
		return true
	}
	if store.IsPreconditionFailed(err) {
		return false
	}
	t.Fatalf("get %s: %v", id, err)
	return false
}

// The whole protocol against the emulator: stage in a batch (and in a transaction), not due during the initial delay,
// a failing handler keeps the item with attempts and backoff, a succeeding one removes it, a second sweep is a no-op,
// Done removes, and PurgeUser deletes only the user's items.
func TestOutbox_Integration_StageSweepDonePurge(t *testing.T) {
	ctx := context.Background()
	client := outboxTestClient(t)
	clock := &testClock{t: time.Now().UTC().Truncate(time.Millisecond)}
	o := New(client, Config{Now: clock.now})
	var ran []string
	fail := errors.New("pubsub down")
	if err := o.Handle("post_delete", func(_ context.Context, it Item) error {
		ran = append(ran, it.Key)
		return fail
	}); err != nil {
		t.Fatal(err)
	}

	e := entry("0000000000000000101")
	stageCommit(t, client, o, e)
	// The transaction form (Task 10's CancelBeacon) writes the same doc.
	e2 := entry("0000000000000000102")
	if _, err := store.RunTransaction(ctx, client, func(ctx context.Context, tx *firestore.Transaction) error {
		b := store.NewFirestoreTxBatch(tx)
		if err := o.Stage(b, e2); err != nil {
			return err
		}
		return b.Err()
	}); err != nil {
		t.Fatalf("tx stage: %v", err)
	}
	if !docExists(t, client, e.ID()) || !docExists(t, client, e2.ID()) {
		t.Fatal("staged items missing")
	}
	if err := o.Done(ctx, e2); err != nil || docExists(t, client, e2.ID()) {
		t.Fatalf("Done = %v, exists %v", err, docExists(t, client, e2.ID()))
	}

	if res, err := o.Sweep(ctx); err != nil || res.Due != 0 {
		t.Fatalf("sweep inside the initial delay = %+v, %v", res, err)
	}
	clock.advance(DefaultInitialDelay)
	res, err := o.Sweep(ctx)
	if err != nil || res.Due != 1 || res.Failed != 1 {
		t.Fatalf("failing sweep = %+v, %v", res, err)
	}
	snap, err := client.Collection(Collection).Doc(e.ID()).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var d itemDoc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	if d.Attempts != 1 || !d.NextAttemptAt.Equal(clock.t.Add(time.Minute)) || d.UID != uidA || string(d.Payload) != string(e.Payload) {
		t.Fatalf("after failure: %+v", d)
	}
	if !d.ExpireAt.Equal(d.CreatedAt.Add(DefaultTTL)) {
		t.Fatalf("expireAt %v, createdAt %v", d.ExpireAt, d.CreatedAt)
	}

	clock.advance(time.Minute)
	fail = nil
	if res, err := o.Sweep(ctx); err != nil || res.Done != 1 {
		t.Fatalf("succeeding sweep = %+v, %v", res, err)
	}
	if docExists(t, client, e.ID()) {
		t.Fatal("delivered item left behind")
	}
	if res, err := o.Sweep(ctx); err != nil || res.Due != 0 || len(ran) != 2 {
		t.Fatalf("double sweep = %+v, %v, ran %v", res, err, ran)
	}

	// A claim whose precondition is stale (someone else claimed) is skipped.
	stageCommit(t, client, o, e)
	clock.advance(DefaultInitialDelay)
	items, err := firestoreBackend{client}.due(ctx, clock.t, 10)
	if err != nil || len(items) != 1 {
		t.Fatalf("due = %v, %v", items, err)
	}
	if _, ok, err := (firestoreBackend{client}).claim(ctx, items[0], 1, clock.t); err != nil || !ok {
		t.Fatalf("first claim ok=%v err=%v", ok, err)
	}
	if _, ok, err := (firestoreBackend{client}).claim(ctx, items[0], 1, clock.t); err != nil || ok {
		t.Fatalf("stale claim ok=%v err=%v, want skipped", ok, err)
	}

	// RunNow runs a present item even when it is not due.
	found, err := o.RunNow(ctx, e)
	if err != nil || !found || docExists(t, client, e.ID()) {
		t.Fatalf("RunNow found=%v err=%v", found, err)
	}

	// PurgeUser removes only the user's items.
	other := "uidBBBBBBBBBBBBBBBBBBBBBBBB2"
	stageCommit(t, client, o, entry("1"))
	stageCommit(t, client, o, entry("2"))
	stageCommit(t, client, o, Entry{Kind: "post_delete", Key: "3", UID: other})
	cp, done, err := o.PurgeUser(ctx, uidA, Checkpoint{})
	if err != nil || !done || cp.Deleted != 2 {
		t.Fatalf("purge cp=%+v done=%v err=%v", cp, done, err)
	}
	if docExists(t, client, entry("1").ID()) || !docExists(t, client, Entry{Kind: "post_delete", Key: "3"}.ID()) {
		t.Fatal("purge removed the wrong items")
	}
}
