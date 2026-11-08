package outbox

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// firestoreBackend stores items in Collection. Exercised by outbox_integration_test.go.
type firestoreBackend struct{ client *firestore.Client }

func (f firestoreBackend) ref(id string) *firestore.DocumentRef {
	return f.client.Collection(Collection).Doc(id)
}

func (f firestoreBackend) stage(b store.Batch, id string, d itemDoc) { b.Set(f.ref(id), d) }

func decode(s *firestore.DocumentSnapshot) (Item, error) {
	var d itemDoc
	if err := s.DataTo(&d); err != nil {
		return Item{}, fmt.Errorf("decode %s: %w", s.Ref.ID, err)
	}
	return d.item(s.Ref.ID, s.UpdateTime), nil
}

func (f firestoreBackend) get(ctx context.Context, id string) (Item, bool, error) {
	s, err := f.ref(id).Get(ctx)
	if err != nil {
		if store.IsPreconditionFailed(err) { // NotFound
			return Item{}, false, nil
		}
		return Item{}, false, err
	}
	it, err := decode(s)
	return it, err == nil, err
}

func (f firestoreBackend) due(ctx context.Context, now time.Time, limit int) ([]Item, error) {
	iter := f.client.Collection(Collection).
		Where("nextAttemptAt", "<=", now).OrderBy("nextAttemptAt", firestore.Asc).Limit(limit).Documents(ctx)
	defer iter.Stop()
	var out []Item
	for {
		s, err := iter.Next()
		if errors.Is(err, iterator.Done) {
			return out, nil
		}
		if err != nil {
			return nil, err
		}
		it, err := decode(s)
		if err != nil {
			// One undecodable doc must not block the queue: push it back by the max backoff and skip it.
			_, _ = s.Ref.Update(ctx, []firestore.Update{{Path: "nextAttemptAt", Value: now.Add(DefaultMaxBackoff)}}, firestore.LastUpdateTime(s.UpdateTime))
			continue
		}
		out = append(out, it)
	}
}

func (f firestoreBackend) claim(ctx context.Context, it Item, attempts int, next time.Time) (time.Time, bool, error) {
	wr, err := f.ref(it.id).Update(ctx, []firestore.Update{
		{Path: "attempts", Value: attempts}, {Path: "nextAttemptAt", Value: next},
	}, firestore.LastUpdateTime(it.updateTime))
	if err != nil {
		if store.IsPreconditionFailed(err) {
			return time.Time{}, false, nil
		}
		return time.Time{}, false, err
	}
	return wr.UpdateTime, true, nil
}

func (f firestoreBackend) remove(ctx context.Context, id string, ifUpdated *time.Time) error {
	var pre []firestore.Precondition
	if ifUpdated != nil {
		pre = append(pre, firestore.LastUpdateTime(*ifUpdated))
	}
	if _, err := f.ref(id).Delete(ctx, pre...); err != nil && !store.IsPreconditionFailed(err) {
		return err
	}
	return nil
}

func (f firestoreBackend) purgeUID(ctx context.Context, uid string, limit int) (int, error) {
	snaps, err := f.client.Collection(Collection).Where("uid", "==", uid).Limit(limit).Select().Documents(ctx).GetAll()
	if err != nil {
		return 0, err
	}
	if len(snaps) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(f.client)
	for _, s := range snaps {
		b.Delete(s.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return 0, err
	}
	return len(snaps), nil
}
