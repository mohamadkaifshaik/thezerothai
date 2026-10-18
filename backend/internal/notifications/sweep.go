// sweep.go is the opsctl seam over purge step 2 (security audit N-4, ADR-0016 amendment 2026-10-18 (b)): suspend-user
// removes the notification rows other users hold about the suspended actor, so spam likes and follows leave their
// lists. It reuses purgeActorRows unchanged (same query, same preconditions, same retry); it adds no behaviour.
package notifications

import "context"

// SweepActorRows runs one page of purge step 2 for uid: up to 500 rows in other users' lists that name uid in actorIds
// are deleted (uid the only actor) or unfolded (other actors remain; the displayed actor is repointed through the
// Directory when one is wired, otherwise the row is deleted). Self-resuming: handled rows leave the query, so the
// caller loops until done. Reads one per row returned (1 for an empty page) plus any GetProfiles cache misses;
// deletes or writes one per row. It needs the notifications.actorIds COLLECTION_GROUP index (already deployed).
func (r *FirestoreRepo) SweepActorRows(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	return r.withRaceRetry(ctx, uid, cp, r.purgeActorRows)
}
