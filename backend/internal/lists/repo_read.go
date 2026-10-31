package lists

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// readable reports whether the repository can serve reads: they need the client only, not the quota and idempotency stores.
func (r *FirestoreRepo) readable() error {
	if r == nil || r.client == nil {
		return errors.New("lists: repo has no firestore client")
	}
	return nil
}

// Get implements Repo: one point read of lists/{id}, outside any transaction, charged as 1 read whether or not it exists.
func (r *FirestoreRepo) Get(ctx context.Context, id string) (List, error) {
	if err := r.readable(); err != nil {
		return List{}, err
	}
	snap, err := r.ref(id).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return List{}, ErrNotFound
		}
		return List{}, logger.RedactErr(fmt.Errorf("lists: get list: %w", err), id)
	}
	var d listDoc
	if err := snap.DataTo(&d); err != nil {
		return List{}, logger.RedactErr(fmt.Errorf("lists: decode list: %w", err), id)
	}
	return d.list(snap.Ref.ID), nil
}

// ListByOwner implements Repo: `ownerId == owner` ordered by document id on the automatic single-field index (no composite
// index), StartAfter `after`, with a Limit. Never filters on isPrivate or hidden: hidden is absent when false, so an equality
// filter on it would miss most documents, and the owner's lists are capped at LISTS_MAX_PER_USER anyway.
func (r *FirestoreRepo) ListByOwner(ctx context.Context, owner, after string, limit int) ([]List, error) {
	if err := r.readable(); err != nil {
		return nil, err
	}
	q := r.col().Where("ownerId", "==", owner).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.ref(after))
	}
	docs, err := q.Limit(min(max(limit, 1), 51)).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("lists: list by owner: %w", err), owner, after)
	}
	out := make([]List, 0, len(docs))
	for _, s := range docs {
		var d listDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("lists: decode list: %w", err), owner, s.Ref.ID)
		}
		out = append(out, d.list(s.Ref.ID))
	}
	return out, nil
}
