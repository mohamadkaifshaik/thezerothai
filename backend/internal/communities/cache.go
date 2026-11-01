package communities

import (
	"slices"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// cacheTTL is the staleness bound of every cached community and member doc (ADR-0031 D12): a write updates the writing instance at
// once, the other instances within 60 s. A suspension therefore reaches every read path within 60 s, and a rename or a changed
// owner within 60 s. Behind the cache.LRU seam, so Memorystore can replace it by ADR.
const cacheTTL = 60 * time.Second

// negativeTTL is the staleness bound of a negative community entry (an id whose point read found no document), the lists precedent
// (ADR-0030 W5-45 L-1): a repeat probe of a missing id then costs 0 reads and answers as fast as a cached one, so latency tells the
// two apart no better than the byte-identical NOT_FOUND does.
const negativeTTL = 60 * time.Second

// docCache holds the per-instance community docs (CACHE_COMMUNITIES_ENTRIES, 60 s) and member docs (CACHE_COMMUNITY_MEMBERS_ENTRIES,
// 60 s on read paths; posting reads the member doc fresh in its transaction, W5-26). A member entry also records absence (MemberNone):
// without that every outsider would pay a read on each call. Entries are copies, so a caller cannot change a cached slice.
type docCache struct {
	communities *cache.LRU[string, Community]
	miss        *cache.LRU[string, struct{}]
	members     *cache.LRU[string, MemberState]
}

func newDocCache(communityEntries, memberEntries int) *docCache {
	n, m := max(communityEntries, 1), max(memberEntries, 1)
	return &docCache{
		communities: cache.New[string, Community](n, cacheTTL),
		miss:        cache.New[string, struct{}](n, negativeTTL),
		members:     cache.New[string, MemberState](m, cacheTTL),
	}
}

func clone(c Community) Community {
	c.Rules = slices.Clone(c.Rules)
	c.ModeratorIDs = slices.Clone(c.ModeratorIDs)
	c.RecentRemovals = slices.Clone(c.RecentRemovals)
	c.Modlog = slices.Clone(c.Modlog)
	return c
}

// put stores a copy of c under its id and clears any negative entry.
func (c *docCache) put(com Community) {
	c.miss.Delete(com.ID)
	c.communities.Set(com.ID, clone(com))
}

// get returns a copy of the cached community, if any and not older than cacheTTL.
func (c *docCache) get(id string) (Community, bool) {
	com, ok := c.communities.Get(id)
	if ok {
		com = clone(com)
	}
	return com, ok
}

func (c *docCache) putMissing(id string) { c.miss.Set(id, struct{}{}) }

func (c *docCache) isMissing(id string) bool {
	_, ok := c.miss.Get(id)
	return ok
}

func memberKey(cid, uid string) string { return cid + "|" + uid }

func (c *docCache) putMember(cid, uid string, s MemberState) { c.members.Set(memberKey(cid, uid), s) }

func (c *docCache) getMember(cid, uid string) (MemberState, bool) {
	return c.members.Get(memberKey(cid, uid))
}
