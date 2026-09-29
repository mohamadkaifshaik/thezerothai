// purge.go implements graph.Eraser (ADR-0008 D10): the resumable delete cascade for one user's social graph.
// One PurgeUser call does one bounded unit of work (one atomic batch of <= 500 ops) and returns the next
// checkpoint; callers loop until done (opsctl purge-graph today, the account-lifecycle job later).
//
// The orchestrator owns the start gate: run only after users/{uid}.status = DELETING has been committed for
// >= 120 s, so no instance can still see the user as ACTIVE and create a new edge (D10).
package graph

import (
	"context"
	"fmt"
	"log/slog"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Purge steps (Checkpoint.Step), in execution order.
const (
	purgeStepOutgoing = 1 // follows where followerId == uid
	purgeStepIncoming = 2 // follows where followeeId == uid
	purgeStepBlocked  = 3 // graph/uid.blocked  -> ArrayRemove(uid) from graph/b.blockedBy
	purgeStepBlockers = 4 // graph/uid.blockedBy -> ArrayRemove(uid) from graph/b.blocked
	purgeStepFinish   = 5 // re-check edges, delete graph/uid
)

// Page sizes keep every batch <= 500 ops: 2 ops per outgoing edge (delete + followee counter), 3 per
// incoming edge (delete + follower's following[] + follower's counter).
const (
	purgeOutgoingPage = 250
	purgeIncomingPage = 160
	purgeArrayChunk   = 500
	profileGetAllCap  = 50
	planCountCap      = 100_000
)

// ProfileReader is the identity read used to find counterpart users that no longer exist (all account
// statuses, missing ones omitted). identity.Repo and identity.Directory-shaped types both satisfy it.
type ProfileReader interface {
	GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error)
}

// SetProfiles wires the ProfileReader PurgeUser falls back to when a batch hits a missing counterpart.
func (r *FirestoreRepo) SetProfiles(p ProfileReader) { r.profiles = p }

var _ Eraser = (*FirestoreRepo)(nil)

// PurgeUser implements Eraser. Steps 1-2 are self-resuming (processed edges no longer match the query);
// steps 3-4 are idempotent ArrayRemoves whose checkpoint offset only avoids redoing work; step 5 re-checks
// steps 1-2 and deletes graph/{uid}. Edge deletes carry an Exists precondition and their counter decrement
// rides in the same batch, so a crash or a concurrent run can never decrement twice.
func (r *FirestoreRepo) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	if cp.Step == 0 {
		cp.Step = purgeStepOutgoing
	}
	switch cp.Step {
	case purgeStepOutgoing:
		return r.purgeEdges(ctx, uid, true)
	case purgeStepIncoming:
		return r.purgeEdges(ctx, uid, false)
	case purgeStepBlocked:
		return r.purgeArray(ctx, uid, cp, "blockedBy")
	case purgeStepBlockers:
		return r.purgeArray(ctx, uid, cp, "blocked")
	case purgeStepFinish:
		return r.purgeFinish(ctx, uid)
	default:
		return Checkpoint{}, false, fmt.Errorf("graph: purge %s: unknown checkpoint step %d", logger.HashUID(uid), cp.Step)
	}
}

// queryEdges reads up to limit edges on one side of uid. Unordered by design: purge only needs "some
// remaining edges", and every processed edge disappears from the result.
func (r *FirestoreRepo) queryEdges(ctx context.Context, uid string, outgoing bool, limit int) ([]Edge, error) {
	field := "followeeId"
	if outgoing {
		field = "followerId"
	}
	docs, err := r.client.Collection(followsCollection).Where(field, "==", uid).Limit(limit).Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return nil, fmt.Errorf("graph: purge query %s: %w", field, err)
	}
	out := make([]Edge, 0, len(docs))
	for _, d := range docs {
		var f followDoc
		if err := d.DataTo(&f); err != nil {
			return nil, fmt.Errorf("graph: purge decode follow %s: %w", d.Ref.ID, err)
		}
		out = append(out, Edge{DocID: d.Ref.ID, FollowerID: f.FollowerID, FolloweeID: f.FolloweeID, CreatedAt: f.CreatedAt})
	}
	return out, nil
}

func (r *FirestoreRepo) purgeEdges(ctx context.Context, uid string, outgoing bool) (Checkpoint, bool, error) {
	step, page := purgeStepOutgoing, purgeOutgoingPage
	if !outgoing {
		step, page = purgeStepIncoming, purgeIncomingPage
	}
	edges, err := r.queryEdges(ctx, uid, outgoing, page)
	if err != nil {
		return Checkpoint{}, false, err
	}
	if len(edges) == 0 {
		return Checkpoint{Step: step + 1}, false, nil
	}

	skipped, err := r.deleteEdges(ctx, uid, edges, outgoing, false)
	if err != nil {
		if !isPreconditionFailed(err) {
			return Checkpoint{}, false, err
		}
		// Either a counterpart doc is missing (its owner was purged) or another run already deleted an
		// edge. Re-query for the current truth and retry once, this time skipping missing counterparts.
		if edges, err = r.queryEdges(ctx, uid, outgoing, page); err != nil {
			return Checkpoint{}, false, err
		}
		if len(edges) == 0 {
			return Checkpoint{Step: step}, false, nil
		}
		if skipped, err = r.deleteEdges(ctx, uid, edges, outgoing, true); err != nil {
			return Checkpoint{}, false, err
		}
	}
	slog.Info("graph_purge_batch", "uid_hash", logger.HashUID(uid), "step", step, "edges", len(edges), "skipped_counterparts", skipped)

	if len(edges) < page {
		return Checkpoint{Step: step + 1}, false, nil
	}
	return Checkpoint{Step: step}, false, nil
}

// deleteEdges commits one atomic batch for edges. checkCounterparts=false is the fast path (0 extra reads);
// true first reads which counterpart docs exist and skips the ones that do not, so a purged counterpart can
// never fail the batch (and is never resurrected: only Update/Delete, never Set). Returns the number of
// skipped counterparts.
func (r *FirestoreRepo) deleteEdges(ctx context.Context, uid string, edges []Edge, outgoing, checkCounterparts bool) (int, error) {
	others := make([]string, len(edges))
	for i, e := range edges {
		others[i] = e.otherUID(!outgoing)
	}
	var userOK, graphOK map[string]bool
	if checkCounterparts {
		var err error
		if userOK, graphOK, err = r.existingCounterparts(ctx, others, !outgoing); err != nil {
			return 0, err
		}
	}

	var scratch budget.Counter
	b := store.NewFirestoreBatch(r.client, &scratch)
	skipped := 0
	for i, e := range edges {
		other := others[i]
		b.Delete(r.followRef(e.FollowerID, e.FolloweeID), firestore.Exists)
		if checkCounterparts && !userOK[other] && (outgoing || !graphOK[other]) {
			skipped++
			slog.Warn("purge_missing_counterpart", "uid_hash", logger.HashUID(uid), "counterpart_hash", logger.HashUID(other))
			continue
		}
		if outgoing {
			// The followee loses a follower.
			if !checkCounterparts || userOK[other] {
				r.counters.AddFollowersCount(b, other, -1)
			}
			continue
		}
		// Incoming: the follower stops following uid.
		if !checkCounterparts || graphOK[other] {
			b.Update(r.graphRef(other), []firestore.Update{{Path: "following", Value: firestore.ArrayRemove(uid)}})
		}
		if !checkCounterparts || userOK[other] {
			r.counters.AddFollowingCount(b, other, -1)
		}
	}
	if err := b.Commit(ctx); err != nil {
		return 0, fmt.Errorf("graph: purge edges: %w", err)
	}
	counter := budget.FromContext(ctx)
	counter.AddWrites(scratch.Writes())
	counter.AddDeletes(scratch.Deletes())
	return skipped, nil
}

// existingCounterparts reports which counterpart users/graph docs exist. users/* is only read through the
// identity ProfileReader (graph never touches that collection directly).
func (r *FirestoreRepo) existingCounterparts(ctx context.Context, others []string, needGraph bool) (userOK, graphOK map[string]bool, err error) {
	userOK = make(map[string]bool, len(others))
	graphOK = make(map[string]bool, len(others))
	if r.profiles == nil {
		return nil, nil, fmt.Errorf("graph: purge: ProfileReader not wired (SetProfiles)")
	}
	for start := 0; start < len(others); start += profileGetAllCap {
		end := min(start+profileGetAllCap, len(others))
		got, err := r.profiles.GetProfiles(ctx, others[start:end])
		if err != nil {
			return nil, nil, fmt.Errorf("graph: purge: counterpart profiles: %w", err)
		}
		for uid := range got {
			userOK[uid] = true
		}
	}
	if needGraph {
		refs := make([]*firestore.DocumentRef, len(others))
		for i, o := range others {
			refs[i] = r.graphRef(o)
		}
		snaps, err := r.client.GetAll(ctx, refs)
		budget.FromContext(ctx).AddReads(int64(len(refs)))
		if err != nil {
			return nil, nil, fmt.Errorf("graph: purge: counterpart graphs: %w", err)
		}
		for i, s := range snaps {
			graphOK[others[i]] = s.Exists()
		}
	}
	return userOK, graphOK, nil
}

// purgeArray handles steps 3 and 4: for each b in graph/uid.<own array>, ArrayRemove(uid) from
// graph/b.<counterField>. cp.Offset counts entries already processed.
func (r *FirestoreRepo) purgeArray(ctx context.Context, uid string, cp Checkpoint, counterField string) (Checkpoint, bool, error) {
	d, err := r.getGraph(ctx, uid)
	if err != nil {
		return Checkpoint{}, false, err
	}
	list := d.Blocked
	if cp.Step == purgeStepBlockers {
		list = d.BlockedBy
	}
	if cp.Offset >= len(list) {
		return Checkpoint{Step: cp.Step + 1}, false, nil
	}
	chunk := list[cp.Offset:min(cp.Offset+purgeArrayChunk, len(list))]

	skipped, err := r.removeFromCounterparts(ctx, uid, chunk, counterField, false)
	if err != nil {
		if !isPreconditionFailed(err) {
			return Checkpoint{}, false, err
		}
		if skipped, err = r.removeFromCounterparts(ctx, uid, chunk, counterField, true); err != nil {
			return Checkpoint{}, false, err
		}
	}
	slog.Info("graph_purge_batch", "uid_hash", logger.HashUID(uid), "step", cp.Step, "entries", len(chunk), "skipped_counterparts", skipped)

	next := Checkpoint{Step: cp.Step, Offset: cp.Offset + len(chunk)}
	if next.Offset >= len(list) {
		next = Checkpoint{Step: cp.Step + 1}
	}
	return next, false, nil
}

func (r *FirestoreRepo) removeFromCounterparts(ctx context.Context, uid string, chunk []string, field string, checkExists bool) (int, error) {
	var exists map[string]bool
	if checkExists {
		refs := make([]*firestore.DocumentRef, len(chunk))
		for i, o := range chunk {
			refs[i] = r.graphRef(o)
		}
		snaps, err := r.client.GetAll(ctx, refs)
		budget.FromContext(ctx).AddReads(int64(len(refs)))
		if err != nil {
			return 0, fmt.Errorf("graph: purge: counterpart graphs: %w", err)
		}
		exists = make(map[string]bool, len(chunk))
		for i, s := range snaps {
			exists[chunk[i]] = s.Exists()
		}
	}
	var scratch budget.Counter
	b := store.NewFirestoreBatch(r.client, &scratch)
	skipped := 0
	for _, other := range chunk {
		if checkExists && !exists[other] {
			skipped++
			slog.Warn("purge_missing_counterpart", "uid_hash", logger.HashUID(uid), "counterpart_hash", logger.HashUID(other))
			continue
		}
		b.Update(r.graphRef(other), []firestore.Update{{Path: field, Value: firestore.ArrayRemove(uid)}})
	}
	if err := b.Commit(ctx); err != nil {
		return 0, fmt.Errorf("graph: purge array: %w", err)
	}
	budget.FromContext(ctx).AddWrites(scratch.Writes())
	return skipped, nil
}

// purgeFinish re-runs the step 1-2 queries (1 read each when empty); if a racing edge slipped in, go back to
// step 1. Otherwise delete graph/{uid} (Delete on a missing doc succeeds, so a replay is a no-op).
func (r *FirestoreRepo) purgeFinish(ctx context.Context, uid string) (Checkpoint, bool, error) {
	for _, outgoing := range []bool{true, false} {
		edges, err := r.queryEdges(ctx, uid, outgoing, 1)
		if err != nil {
			return Checkpoint{}, false, err
		}
		if len(edges) > 0 {
			return Checkpoint{Step: purgeStepOutgoing}, false, nil
		}
	}
	if _, err := r.graphRef(uid).Delete(ctx); err != nil {
		return Checkpoint{}, false, fmt.Errorf("graph: purge delete graph doc: %w", err)
	}
	budget.FromContext(ctx).AddDeletes(1)
	slog.Info("graph_purge_batch", "uid_hash", logger.HashUID(uid), "step", purgeStepFinish, "graph_doc_deleted", true)
	return Checkpoint{}, true, nil
}

// PurgePlan is a read-only preview of what PurgeUser would touch (opsctl purge-graph --dry-run). Edge counts
// come from count() aggregations (about 1 read per 1,000 edges).
type PurgePlan struct {
	OutgoingEdges int64
	IncomingEdges int64
	Blocked       int
	BlockedBy     int
}

// PlanPurge counts the work PurgeUser would do without writing anything.
func (r *FirestoreRepo) PlanPurge(ctx context.Context, uid string) (PurgePlan, error) {
	var plan PurgePlan
	for _, side := range []struct {
		field string
		dst   *int64
	}{{"followerId", &plan.OutgoingEdges}, {"followeeId", &plan.IncomingEdges}} {
		// Limit bounds the count() cost (rule 5); a dry run reports at most planCountCap edges per side.
		q := r.client.Collection(followsCollection).Where(side.field, "==", uid).Limit(planCountCap)
		res, err := q.NewAggregationQuery().WithCount("count").Get(ctx)
		budget.FromContext(ctx).AddReads(1)
		if err != nil {
			return PurgePlan{}, fmt.Errorf("graph: plan purge count %s: %w", side.field, err)
		}
		var out struct {
			Count int64 `firestore:"count"`
		}
		if err := res.DataTo(&out); err != nil {
			return PurgePlan{}, fmt.Errorf("graph: plan purge decode %s: %w", side.field, err)
		}
		*side.dst = out.Count
	}
	d, err := r.getGraph(ctx, uid)
	if err != nil {
		return PurgePlan{}, err
	}
	plan.Blocked, plan.BlockedBy = len(d.Blocked), len(d.BlockedBy)
	return plan, nil
}
