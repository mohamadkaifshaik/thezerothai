package identity

// KnownInactive reports which of uids the profile cache ALREADY knows cannot be shown: a cached profile whose status is
// not ACTIVE (SUSPENDED, DELETING) or a uid confirmed to have no users/{uid} document in the last notFoundTTL. It is
// cache-only: 0 Firestore reads, no loading, no cache refresh, and a uid the cache has not seen, or whose entry has
// expired, is simply absent from the result ("unknown", never "active"). So it can only ever remove work for a
// caller that tolerates a miss; it must not be used as a permission check.
//
// It is NOT part of the Directory interface: widening Directory would break every fake in every module. A consumer
// asserts it as an optional extension on the value it already holds (graph's friends-of-friends suggester skips
// sampled followees this reports, W3-22 L-5). Safe for concurrent use.
func (s *service) KnownInactive(uids []string) map[string]bool {
	var out map[string]bool
	for _, uid := range uids {
		if p, ok := s.cache.GetProfile(uid); ok {
			if p.Status != AccountStatusActive {
				if out == nil {
					out = make(map[string]bool)
				}
				out[uid] = true
			}
			continue
		}
		if s.cache.GetNotFound(uid) {
			if out == nil {
				out = make(map[string]bool)
			}
			out[uid] = true
		}
	}
	return out
}
