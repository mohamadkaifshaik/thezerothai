package graph

import (
	"context"
	"fmt"
	"slices"
)

// followLookupChunk is how many edge docs one batched read of FollowersAmong fetches.
const followLookupChunk = 25

var _ FollowLookup = (*service)(nil)

// FollowersAmong implements FollowLookup: dedupe, the edge cache, then the misses in chunks of followLookupChunk, each
// chunk cached as soon as it lands (a later chunk's failure keeps the answers already read, so a retry reads only what
// is still missing).
func (s *service) FollowersAmong(ctx context.Context, viewerUID string, candidateUIDs []string) (map[string]bool, error) {
	seen := make(map[string]bool, len(candidateUIDs))
	distinct := make([]string, 0, len(candidateUIDs))
	for _, uid := range candidateUIDs {
		if uid == "" || uid == viewerUID || seen[uid] {
			continue
		}
		seen[uid] = true
		distinct = append(distinct, uid)
	}
	if len(distinct) > MaxFollowLookup {
		return nil, fmt.Errorf("graph: follow lookup of %d users exceeds %d", len(distinct), MaxFollowLookup)
	}
	out := map[string]bool{}
	var misses []string
	for _, uid := range distinct {
		if exists, ok := s.cache.Edge(uid, viewerUID); ok {
			if exists {
				out[uid] = true
			}
			continue
		}
		misses = append(misses, uid)
	}
	if len(misses) == 0 {
		return out, nil
	}
	for chunk := range slices.Chunk(misses, followLookupChunk) {
		found, err := s.repo.FollowEdgesExist(ctx, viewerUID, chunk)
		if err != nil {
			return nil, fmt.Errorf("graph: follow lookup: %w", err)
		}
		for _, uid := range chunk {
			exists := found[uid]
			s.cache.SetEdge(uid, viewerUID, exists)
			if exists {
				out[uid] = true
			}
		}
	}
	return out, nil
}
