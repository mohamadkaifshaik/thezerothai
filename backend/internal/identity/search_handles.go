package identity

import (
	"context"
	"fmt"
	"strings"
	"unicode/utf8"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// Handle-prefix reader limits (ADR-0028 D11: limit clamped 1..20).
const (
	MinSearchHandlesLimit = 1
	MaxSearchHandlesLimit = 20
)

// prefixSucc returns the exclusive upper bound of the range of strings that start with p: p with its last
// character replaced by the next code point (ADR-0028 D1 rule 6; the handle class is ASCII, so `_` -> "`",
// `z` -> "{", `9` -> ":" and it never overflows). ok is false for an empty prefix or a last rune that has no
// successor (utf8.MaxRune or an invalid byte), which the caller treats as "no match", never as an open range.
func prefixSucc(p string) (string, bool) {
	r, size := utf8.DecodeLastRuneInString(p)
	if p == "" || r == utf8.RuneError || r >= utf8.MaxRune {
		return "", false
	}
	return p[:len(p)-size] + string(r+1), true
}

// SearchHandles implements Directory: users whose handleLower starts with the lower-cased prefix, in handleLower
// order (an exact match sorts first), raw profiles including status (filtering is the caller's job).
// Firestore: reads = len(result), minimum 1 (an empty query bills 1), at most MaxSearchHandlesLimit (20);
// writes 0. Query: handleLower >= p AND handleLower < succ(p) ORDER BY handleLower LIMIT n on the automatic
// single-field index. No cache: the search module caches by (prefix, limit) for 60 s. An empty prefix returns
// nothing with 0 reads.
func (s *service) SearchHandles(ctx context.Context, prefix string, limit int) ([]Profile, error) {
	prefix = strings.ToLower(prefix)
	if _, ok := prefixSucc(prefix); !ok {
		return nil, nil
	}
	limit = min(max(limit, MinSearchHandlesLimit), MaxSearchHandlesLimit)
	return s.repo.SearchHandles(ctx, prefix, limit)
}

// SearchHandles: one range query on users.handleLower, Limit(limit) (the service clamps to 1..20). Reads =
// len(result), minimum 1.
func (r *FirestoreRepo) SearchHandles(ctx context.Context, prefix string, limit int) ([]Profile, error) {
	upper, ok := prefixSucc(prefix)
	if !ok {
		return nil, nil
	}
	it := r.client.Collection(usersCollection).
		Where("handleLower", ">=", prefix).
		Where("handleLower", "<", upper).
		OrderBy("handleLower", firestore.Asc).
		Limit(limit).
		Documents(ctx)
	defer it.Stop()
	out := make([]Profile, 0, limit)
	for {
		snap, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			budget.FromContext(ctx).AddReads(int64(max(len(out), 1)))
			return nil, fmt.Errorf("identity: search handles: %w", err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			budget.FromContext(ctx).AddReads(int64(max(len(out)+1, 1)))
			return nil, fmt.Errorf("identity: decode profile %s: %w", snap.Ref.ID, err)
		}
		out = append(out, d.toProfile(snap.Ref.ID))
	}
	budget.FromContext(ctx).AddReads(int64(max(len(out), 1)))
	return out, nil
}
