package search

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	// defaultPeopleLimit and maxPeopleLimit are SearchPeople's limit: 0 means 10, above 20 is clamped (D1 step 9).
	defaultPeopleLimit = 10
	maxPeopleLimit     = 20
	// prefixCacheTTL is the staleness bound of a prefix entry (ADR-0028 D4): a new handle, a rename or a status change
	// shows within 60 s on this instance.
	prefixCacheTTL = 60 * time.Second
	// defaultPrefixEntries is the cache size when the wiring gives none (CACHE_SEARCH_PREFIX_ENTRIES' default).
	defaultPrefixEntries = 2000
)

// HandleDirectory is the one identity seam people search needs (identity.Directory satisfies it): the handle-prefix
// reader, at most 20 reads, raw profiles including status.
type HandleDirectory interface {
	SearchHandles(ctx context.Context, prefix string, limit int) ([]identity.Profile, error)
}

// PeopleDeps wires SearchPeople (WithPeople).
type PeopleDeps struct {
	// Directory fills the prefix cache (identity owns users/*; search never queries it).
	Directory HandleDirectory
	// Graph answers the caller's social context from its 60 s snapshot cache.
	Graph graph.Reader
	// PrefixEntries is CACHE_SEARCH_PREFIX_ENTRIES; <= 0 means the default 2,000.
	PrefixEntries int
}

// prefixKey is the cache key: the lower-cased prefix and the limit the directory was asked for. Never viewer scoped.
type prefixKey struct {
	prefix string
	limit  int
}

// people holds the SearchPeople dependencies and the shared prefix cache.
type people struct {
	dir   HandleDirectory
	graph graph.Reader
	// entries caches the RAW directory answer per (prefix, limit), shared by every viewer (ADR-0028 D2, D4).
	// Staleness bound: prefixCacheTTL (60 s) from the fill, per instance. The entry holds profiles with their status
	// and is filtered per viewer after the read, so no block, mute, follow or status of any viewer is ever cached in it
	// and an entry can safely serve two viewers who see different rows. The cached slices are read-only.
	entries *cache.LRU[prefixKey, []identity.Profile]
}

func newPeople(d PeopleDeps) *people {
	n := d.PrefixEntries
	if n <= 0 {
		n = defaultPrefixEntries
	}
	return &people{dir: d.Directory, graph: d.Graph, entries: cache.New[prefixKey, []identity.Profile](n, prefixCacheTTL)}
}

// peopleLimit applies D1 step 9: negative is VALIDATION `limit`, 0 means 10, above 20 is clamped.
func peopleLimit(limit int32) (int, error) {
	switch {
	case limit < 0:
		return 0, apierr.Validation("limit", "limit must not be negative")
	case limit == 0:
		return defaultPeopleLimit, nil
	case limit > maxPeopleLimit:
		return maxPeopleLimit, nil
	}
	return int(limit), nil
}

// dropped counts the rows removed from one answer, by cause (logged as dropped_*, never the handles).
type dropped struct{ status, blockedBy, overflow int }

// People is SearchPeople. Flag: search, checked before anything else (0 reads when off).
//
// Rules (ADR-0028 D1, D2): the query is validated and classified with 0 reads (a bad or 1-character query is VALIDATION
// `query`; a `#` sigil or a rest that is not a 2 to 15 character handle prefix answers empty with unsupported_query =
// true); the raw profiles come from the shared 60 s prefix cache or one identity.Directory.SearchHandles; each row is
// then filtered for THIS viewer from graph.Reader.Snapshot: users who are not ACTIVE and users who blocked the viewer
// are dropped (the answer is then what a missing user's would be: no row, no flag), users the viewer blocks or mutes
// stay with relationship.blocking / muting set, protected accounts stay with user.is_private set, and the viewer's own
// row stays. With blockedBy overflowed (ADR-0008 D2) a blocker cannot be ruled out at 0 reads, so only the viewer and
// accounts the viewer follows are kept. At most limit rows (0 means 10, max 20), handle order, no token.
//
// Worst-case Firestore cost (the interceptor's account-status read included): cold 1 + 1 + limit = 22 reads at limit 20
// (7 at limit 5: interceptor 1, caller graph 1, SearchHandles = len(result), minimum 1); prefix entry warm with the
// snapshot cold 2; both warm 0 to 1 (the interceptor's profile is usually cached); an empty entry skips the graph
// read; a rejected or unsupported query costs the interceptor's read only; writes 0.
func (s *service) People(ctx context.Context, uid, query string, limit int32) (*searchv1.SearchPeopleResponse, error) {
	if err := s.guard(ctx, uid, FlagSearch); err != nil {
		return nil, err
	}
	if s.people == nil {
		return nil, errNotImplemented()
	}
	n, err := peopleLimit(limit)
	if err != nil {
		return nil, err
	}
	// The raw query is never logged (D10): only its kind and length.
	logger.SetRequestField(ctx, "query_len", len(query))
	res, prefix := parsePeopleQuery(query)
	switch res {
	case peopleInvalid:
		return nil, apierr.Validation("query", "query is empty, longer than 50 characters or holds a control character")
	case peopleTooShort:
		return nil, apierr.Validation("query", "query too short: type at least 2 characters")
	case peopleUnsupported:
		logger.SetRequestField(ctx, "query_kind", "unsupported")
		logger.SetRequestField(ctx, "results", 0)
		return &searchv1.SearchPeopleResponse{UnsupportedQuery: true}, nil
	}
	logger.SetRequestField(ctx, "query_kind", "handle")
	return s.people.search(ctx, uid, prefix, n)
}

// search is the cached read plus the per-viewer filter for a validated prefix.
func (p *people) search(ctx context.Context, uid, prefix string, limit int) (*searchv1.SearchPeopleResponse, error) {
	key := prefixKey{prefix: prefix, limit: limit}
	profiles, hit := p.entries.Get(key)
	if !hit {
		var err error
		if profiles, err = p.dir.SearchHandles(ctx, prefix, limit); err != nil {
			return nil, mapErr("search handles", err, uid)
		}
		p.entries.Set(key, profiles)
	}
	logger.SetRequestField(ctx, "cache_hit", hit)
	if len(profiles) == 0 { // nothing to filter: no graph read
		logger.SetRequestField(ctx, "results", 0)
		return &searchv1.SearchPeopleResponse{}, nil
	}
	snap, err := p.graph.Snapshot(ctx, uid)
	if err != nil {
		return nil, mapErr("caller snapshot", err, uid)
	}
	items, drop := filterPeople(uid, snap, profiles, limit)
	logger.SetRequestField(ctx, "results", len(items))
	logger.SetRequestField(ctx, "dropped_status", drop.status)
	logger.SetRequestField(ctx, "dropped_blocked_by", drop.blockedBy)
	logger.SetRequestField(ctx, "dropped_overflow", drop.overflow)
	return &searchv1.SearchPeopleResponse{Users: graph.ListItemsToProto(items)}, nil
}

// filterPeople applies the viewer's view to the shared raw rows (ADR-0028 D2 steps 3 to 6). It never edits profiles
// (they are shared with the cache) and returns at most limit rows in the input (handle) order.
func filterPeople(uid string, snap graph.Snapshot, profiles []identity.Profile, limit int) ([]graph.ListItem, dropped) {
	var d dropped
	items := make([]graph.ListItem, 0, min(len(profiles), limit))
	for _, pr := range profiles {
		if len(items) == limit {
			break
		}
		switch {
		case pr.Status != identity.AccountStatusActive:
			d.status++
			continue
		case pr.UserID != uid && snap.BlockedBy[pr.UserID]:
			d.blockedBy++
			continue
		case pr.UserID != uid && snap.BlockedByOverflow && !snap.Following[pr.UserID]:
			d.overflow++
			continue
		}
		items = append(items, graph.ListItem{User: pr, Relationship: graph.RelationshipFor(snap, pr.UserID)})
	}
	return slices.Clip(items), d
}

// mapErr turns a dependency error into the handler's error: a client disconnect or deadline is not a server fault
// (no INTERNAL, no ERROR line); anything else is wrapped with the caller's uid redacted, because the error is logged
// at ERROR with its whole cause chain and Firestore's text embeds document paths.
func mapErr(op string, err error, uid string) error {
	switch {
	case errors.Is(err, context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(err, context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	}
	return logger.RedactErr(fmt.Errorf("search: %s: %w", op, err), uid)
}
