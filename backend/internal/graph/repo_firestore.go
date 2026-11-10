// repo_firestore.go is the Firestore implementation of Repo (graph/{uid}, follows/{a}_{b}; BlockedBy/blockedByOverflow).
// InitGraph is the one seam identity depends on
// (identity.GraphInitializer) to create the empty graph/{uid} doc inside CreateProfile's transaction; the
// rest of this file backs the full GraphService.
package graph

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Unfollow's bounded retry on a lost lock race (D1).
const (
	unfollowMaxAttempts  = 6
	unfollowRetryBackoff = 25 * time.Millisecond // ceiling doubled per retry: 25..400 ms; full jitter picks [0, ceiling)
)

const (
	graphCollection   = "graph"
	followsCollection = "follows"
)

// Caps (document-size budget: following 5,000 + blocked 2,000 + muted 2,000 + requested
// 500 + blockedBy 10,000 ~= 566 KB, safely under Firestore's 1 MiB doc limit).
const (
	maxFollowing = 5_000
	maxBlocked   = 2_000
	maxMuted     = 2_000
	maxBlockedBy = 10_000
)

// doc is the graph/{uid} shape. Arrays are exempt from indexing.
// blockedByOverflow stays indexed (a tiny bool; it lets moderation query overflowed accounts).
type doc struct {
	Following         []string  `firestore:"following"`
	Blocked           []string  `firestore:"blocked"`
	Muted             []string  `firestore:"muted"`
	Requested         []string  `firestore:"requested"`
	BlockedBy         []string  `firestore:"blockedBy"`
	BlockedByOverflow bool      `firestore:"blockedByOverflow"`
	UpdatedAt         time.Time `firestore:"updatedAt"`
}

func toSet(vals []string) map[string]bool {
	if len(vals) == 0 {
		return map[string]bool{}
	}
	m := make(map[string]bool, len(vals))
	for _, v := range vals {
		m[v] = true
	}
	return m
}

// recentFollowingMax is how many of the newest followees a Snapshot keeps in order (Snapshot.RecentFollowing): the
// most SUGGESTIONS_SAMPLE_FOLLOWEES can be (config.Load rejects more than 30, the Firestore `in` limit).
const recentFollowingMax = 30

// newestFirst returns the last n entries of following (the array is in follow order, oldest first) reversed, so the
// newest is first. A fresh slice: the snapshot never aliases the decoded document array.
func newestFirst(following []string, n int) []string {
	if n > len(following) {
		n = len(following)
	}
	if n == 0 {
		return nil
	}
	out := make([]string, n)
	for i := range out {
		out[i] = following[len(following)-1-i]
	}
	return out
}

func (d doc) toSnapshot() Snapshot {
	return Snapshot{
		Following:         toSet(d.Following),
		RecentFollowing:   newestFirst(d.Following, recentFollowingMax),
		Blocked:           toSet(d.Blocked),
		Muted:             toSet(d.Muted),
		Requested:         toSet(d.Requested),
		BlockedBy:         toSet(d.BlockedBy),
		BlockedByOverflow: d.BlockedByOverflow,
	}
}

func (d doc) hasFollowing(uid string) bool { return containsStr(d.Following, uid) }
func (d doc) hasBlocked(uid string) bool   { return containsStr(d.Blocked, uid) }
func (d doc) hasMuted(uid string) bool     { return containsStr(d.Muted, uid) }
func (d doc) hasBlockedBy(uid string) bool { return containsStr(d.BlockedBy, uid) }
func (d doc) hasRequested(uid string) bool { return containsStr(d.Requested, uid) }

func containsStr(vals []string, target string) bool {
	for _, v := range vals {
		if v == target {
			return true
		}
	}
	return false
}

// followDoc is the follows/{followerId}_{followeeId} shape, used only for list pages.
type followDoc struct {
	FollowerID string    `firestore:"followerId"`
	FolloweeID string    `firestore:"followeeId"`
	CreatedAt  time.Time `firestore:"createdAt"`
}

// FirestoreRepo implements Repo (and identity.GraphInitializer) against the shared Firestore client.
type FirestoreRepo struct {
	client   *firestore.Client
	counters identity.Counters
	profiles ProfileReader
	// txProfiles reads the Follow target's users doc inside the Follow transaction.
	txProfiles identity.TxProfiles
	hooks      followHooks

	// Test seams for Unfollow's retry loop; nil means production behaviour (real commit, jittered timer).
	commitBatch func(ctx context.Context, b *store.FirestoreBatch) error
	backoff     func(ctx context.Context, ceiling time.Duration) error // see store.RetryConfig
}

// NewFirestoreRepo builds a FirestoreRepo. Unchanged signature from the Phase 0 bootstrap so every existing
// call site (identity's GraphInitializer wiring, and every InitGraph-only test) keeps compiling. Call
// SetCounters once identity.Counters is available (required before any Follow/Unfollow/Block/Mute call).
func NewFirestoreRepo(client *firestore.Client) *FirestoreRepo {
	return &FirestoreRepo{client: client}
}

// SetCounters wires identity.Counters (users/{uid} followers/following count increments). The counter
// writes must land in the exact same transaction/batch as the edge change, which is why this
// lives on the repo rather than being called by service.go with its own separate batch.
func (r *FirestoreRepo) SetCounters(c identity.Counters) {
	r.counters = c
	// identity's FirestoreRepo is both the Counters and the TxProfiles implementation; take the second role from the
	// same object unless SetTxProfiles names another, so every existing wiring keeps working.
	if tp, ok := c.(identity.TxProfiles); ok && r.txProfiles == nil {
		r.txProfiles = tp
	}
}

// SetTxProfiles wires the transaction-scoped target read Follow needs. apiserver and opsctl call it
// explicitly; SetCounters also picks it up when its argument implements it.
func (r *FirestoreRepo) SetTxProfiles(p identity.TxProfiles) { r.txProfiles = p }

// txProfilesReader returns the wired TxProfiles or an error (never a panic on a request path).
func (r *FirestoreRepo) txProfilesReader() (identity.TxProfiles, error) {
	if r.txProfiles == nil {
		return nil, errors.New("graph: TxProfiles not wired (SetTxProfiles)")
	}
	return r.txProfiles, nil
}

func (r *FirestoreRepo) graphRef(uid string) *firestore.DocumentRef {
	return r.client.Collection(graphCollection).Doc(uid)
}

// edgeID is the ONLY place a follows doc id is built: `{followerId}_{followeeId}`. It refuses a uid containing
// the `_` separator, which would make `a_b_c` ambiguous between a_b -> c and a -> b_c. Uid
// validation (authn caller check, ids.ValidUID on targets) rejects `_` long before this, so an error here
// means a validation bug and surfaces as INTERNAL.
func edgeID(followerUID, followeeUID string) (string, error) {
	if strings.Contains(followerUID, "_") || strings.Contains(followeeUID, "_") {
		return "", errors.New("graph: uid contains reserved '_' (edge id would be ambiguous)")
	}
	return followerUID + "_" + followeeUID, nil
}

func (r *FirestoreRepo) followRef(followerUID, followeeUID string) (*firestore.DocumentRef, error) {
	id, err := edgeID(followerUID, followeeUID)
	if err != nil {
		return nil, err
	}
	return r.client.Collection(followsCollection).Doc(id), nil
}

// InitGraph appends a Create() of an empty graph/{uid} doc to b. Idempotent: if the doc already exists, the
// Create() fails the whole atomic write — an existing graph doc must never be silently reset.
func (r *FirestoreRepo) InitGraph(b store.Batch, uid string, now time.Time) {
	b.Create(r.graphRef(uid), doc{
		Following: []string{},
		Blocked:   []string{},
		Muted:     []string{},
		Requested: []string{},
		BlockedBy: []string{},
		UpdatedAt: now,
	})
}

// getGraph reads graph/{uid} outside a transaction (used by GetSnapshot on a cache miss, and by Reader
// callers who accept the 60s staleness budget). A missing doc decodes as an empty Snapshot,
// not an error — defensive: every ACTIVE profile has one from CreateProfile, but a missing doc must never
// crash a request.
func (r *FirestoreRepo) getGraph(ctx context.Context, uid string) (doc, error) {
	snap, err := r.graphRef(uid).Get(ctx)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return doc{}, nil
		}
		return doc{}, fmt.Errorf("graph: get %s: %w", uid, err)
	}
	var d doc
	if err := snap.DataTo(&d); err != nil {
		return doc{}, fmt.Errorf("graph: decode %s: %w", uid, err)
	}
	return d, nil
}

// getGraphTx is getGraph's transactional counterpart ("mutations read fresh inside their transaction").
// It also returns the doc's Firestore CreateTime (zero if the doc doesn't exist).
func (r *FirestoreRepo) getGraphTx(ctx context.Context, tx *firestore.Transaction, uid string) (doc, time.Time, error) {
	snap, err := tx.Get(r.graphRef(uid))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return doc{}, time.Time{}, nil
		}
		return doc{}, time.Time{}, fmt.Errorf("graph: get %s: %w", uid, err)
	}
	var d doc
	if err := snap.DataTo(&d); err != nil {
		return doc{}, time.Time{}, fmt.Errorf("graph: decode %s: %w", uid, err)
	}
	return d, snap.CreateTime, nil
}

// getGraphTxExists is getGraphTx plus an explicit existence flag, used where "the graph doc doesn't exist"
// itself means "unknown user" (Block/Mute, which — unlike Follow — don't otherwise consult
// identity.Directory, so this is their only existence signal; the "unknown user => NOT_FOUND" for
// Block costs 0 extra reads this way).
func (r *FirestoreRepo) getGraphTxExists(ctx context.Context, tx *firestore.Transaction, uid string) (doc, bool, error) {
	snap, err := tx.Get(r.graphRef(uid))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return doc{}, false, nil
		}
		return doc{}, false, fmt.Errorf("graph: get %s: %w", uid, err)
	}
	var d doc
	if err := snap.DataTo(&d); err != nil {
		return doc{}, false, fmt.Errorf("graph: decode %s: %w", uid, err)
	}
	return d, true, nil
}

func followStateOf(d doc, uid string) FollowState {
	if d.hasFollowing(uid) {
		return FollowStateFollowing
	}
	if d.hasRequested(uid) {
		return FollowStateRequested
	}
	return FollowStateNone
}

// GetSnapshot implements Repo for Reader.Snapshot's cache-miss path.
func (r *FirestoreRepo) GetSnapshot(ctx context.Context, uid string) (Snapshot, error) {
	d, err := r.getGraph(ctx, uid)
	if err != nil {
		return Snapshot{}, err
	}
	return d.toSnapshot(), nil
}

// GetSnapshots implements Repo: one batched GetAll of graph/{uid} for every distinct uid. A missing doc is an empty
// Snapshot. Errors carry no uid (a Firestore error text would name the document path; only the count is kept).
func (r *FirestoreRepo) GetSnapshots(ctx context.Context, uids []string) (map[string]Snapshot, error) {
	out := make(map[string]Snapshot, len(uids))
	refs := make([]*firestore.DocumentRef, 0, len(uids))
	for _, uid := range uids {
		if _, dup := out[uid]; dup {
			continue
		}
		out[uid] = Snapshot{}
		refs = append(refs, r.graphRef(uid))
	}
	if len(refs) == 0 {
		return out, nil
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, fmt.Errorf("graph: batch read of %d graph docs: %w", len(refs), err)
	}
	for _, s := range snaps {
		if !s.Exists() {
			continue
		}
		var d doc
		if err := s.DataTo(&d); err != nil {
			return nil, errors.New("graph: decode graph doc in batch read")
		}
		out[s.Ref.ID] = d.toSnapshot()
	}
	return out, nil
}

var _ TxReader = (*FirestoreRepo)(nil)

// SnapshotInTx implements TxReader : graph/{uid} read through tx, no cache involved. A
// missing document is an empty Snapshot. Errors carry no uid (a Firestore error text would name the document path).
func (r *FirestoreRepo) SnapshotInTx(ctx context.Context, tx *firestore.Transaction, uid string) (Snapshot, error) {
	snap, err := tx.Get(r.graphRef(uid))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Snapshot{}, nil
		}
		return Snapshot{}, fmt.Errorf("graph: read snapshot in transaction: %w", err)
	}
	var d doc
	if err := snap.DataTo(&d); err != nil {
		return Snapshot{}, errors.New("graph: decode snapshot in transaction")
	}
	return d.toSnapshot(), nil
}

// maxRequested is the cap of graph/{uid}.requested, the caller's outgoing pending follow requests.
const maxRequested = 500

// followHooks are the test seams of Follow's transaction. Production leaves them nil.
type followHooks struct {
	// afterTargetRead runs inside the transaction body right after the target's users doc was read, once per attempt
	// (the follow-vs-protect race test commits a separate write here on the first attempt).
	afterTargetRead func(ctx context.Context, attempt int)
}

// Follow runs the whole Follow transaction. The target's users doc is read INSIDE the
// transaction (identity.TxProfiles.ProfileInTx, never the 60 s cache) so a protect that commits while a Follow is in
// flight conflicts with it and the retry sees isPrivate: no Follow can slip past a just-committed protect. Precedence:
// target missing or not ACTIVE / blocked-by (incl. the D2 overflow fallback) -> caller-blocks-target -> already
// following (replay, before any request logic: I-X) -> protected target: request replay -> requested cap ->
// request; public target: following-cap -> edge. A public target that is still in the caller's `requested`
// (the privacy_public job has not run yet) takes the edge path and also deletes the request.
//
// It reads the target users doc and the caller graph, plus the target graph only for an overflowed caller.
// It writes either the edge (follows doc, caller graph, 2 counters) or a request (followRequests Create,
// caller graph `requested` ArrayUnion), and nothing on any replay. It deletes a leftover request only on the
// AQ4 path. The outcome tells the caller which of the three it was (Relationship.FollowState: FOLLOWING vs REQUESTED).
func (r *FirestoreRepo) Follow(ctx context.Context, callerUID, targetUID string, now time.Time) (Relationship, MutationOutcome, error) {
	profiles, err := r.txProfilesReader()
	if err != nil {
		return Relationship{}, "", err
	}
	var rel Relationship
	outcome := OutcomeCreated
	attempt := 0
	requestPath := false
	err = r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		attempt++
		requestPath = false

		// The target first: a missing or non-ACTIVE account is NOT_FOUND before anything else is read, exactly as the
		// cached Directory lookup it replaces answered (identity.Directory drops non-ACTIVE accounts).
		target, err := profiles.ProfileInTx(ctx, tx, targetUID)
		switch {
		case errors.Is(err, identity.ErrNotFound):
			return ErrNotFoundOrBlocked
		case err != nil:
			return err
		case target.Status != identity.AccountStatusActive:
			return ErrNotFoundOrBlocked
		}
		if r.hooks.afterTargetRead != nil {
			r.hooks.afterTargetRead(ctx, attempt)
		}

		callerDoc, _, err := r.getGraphTx(ctx, tx, callerUID)
		if err != nil {
			return err
		}

		blockedByTarget := callerDoc.hasBlockedBy(targetUID)
		if !blockedByTarget && callerDoc.BlockedByOverflow {
			targetDoc, _, err := r.getGraphTx(ctx, tx, targetUID)
			if err != nil {
				return err
			}
			blockedByTarget = targetDoc.hasBlocked(callerUID)
		}
		if blockedByTarget {
			return ErrNotFoundOrBlocked
		}
		if callerDoc.hasBlocked(targetUID) {
			return ErrCallerBlocksTarget
		}

		muting := callerDoc.hasMuted(targetUID)
		if callerDoc.hasFollowing(targetUID) { // I-X: an edge wins over any request, protected target or not
			outcome = OutcomeReplay
			rel = Relationship{UserID: targetUID, FollowState: FollowStateFollowing, Muting: muting}
			return nil
		}

		b := store.NewFirestoreTxBatch(tx)
		requestRef, err := r.requestRef(callerUID, targetUID)
		if err != nil {
			return err
		}
		inRequested := callerDoc.hasRequested(targetUID)

		if target.IsPrivate {
			if inRequested {
				outcome = OutcomeReplay
				rel = Relationship{UserID: targetUID, FollowState: FollowStateRequested, Muting: muting}
				return nil
			}
			if len(callerDoc.Requested) >= maxRequested {
				return &LimitReachedError{Limit: "follow_requests"}
			}
			requestPath = true
			b.Create(requestRef, requestDoc{FollowerID: callerUID, FolloweeID: targetUID, CreatedAt: now})
			b.Update(r.graphRef(callerUID), []firestore.Update{
				{Path: "requested", Value: firestore.ArrayUnion(targetUID)},
				{Path: "updatedAt", Value: now},
			})
			if b.Err() != nil {
				return b.Err()
			}
			outcome = OutcomeCreated
			rel = Relationship{UserID: targetUID, FollowState: FollowStateRequested, Muting: muting}
			return nil
		}

		if len(callerDoc.Following) >= maxFollowing {
			return &LimitReachedError{Limit: "following"}
		}
		edgeRef, err := r.followRef(callerUID, targetUID)
		if err != nil {
			return err
		}
		b.Create(edgeRef, followDoc{FollowerID: callerUID, FolloweeID: targetUID, CreatedAt: now})
		callerUpdates := []firestore.Update{
			{Path: "following", Value: firestore.ArrayUnion(targetUID)},
			{Path: "updatedAt", Value: now},
		}
		if inRequested {
			// The target went public and its request is still pending. Plain Delete (no Exists), so a
			// drifted entry cannot fail the Follow; the entry leaves `requested` in the write already made. I-R, I-X.
			callerUpdates = append(callerUpdates, firestore.Update{Path: "requested", Value: firestore.ArrayRemove(targetUID)})
			b.Delete(requestRef)
		}
		b.Update(r.graphRef(callerUID), callerUpdates)
		r.counters.AddFollowingCount(b, callerUID, 1)
		r.counters.AddFollowersCount(b, targetUID, 1)
		if b.Err() != nil {
			return b.Err()
		}

		outcome = OutcomeCreated
		rel = Relationship{UserID: targetUID, FollowState: FollowStateFollowing, Muting: muting}
		return nil
	})
	if requestPath && status.Code(err) == codes.AlreadyExists {
		// The request doc is there although the caller's `requested` lacked the entry (a concurrent Follow, or drift
		// from a failed hand-over): the commit wrote nothing, and the answer is the replay's.
		return rel, OutcomeReplay, nil
	}
	if err != nil {
		return Relationship{}, "", err
	}
	return rel, outcome, nil
}

// Unfollow is a blind batch: delete the follows doc with an Exists precondition, so a
// replay (already unfollowed, or never followed) fails the whole batch atomically and writes nothing — the
// precondition also makes this safe to race against Block, which deletes the same edge with the same
// precondition (invariant #1: "follows/{a}_{b} exists <=> b in graph/{a}.following").
//
// Invariant: for an ACTIVE caller, the edge exists <=> the target is in the caller's following
// <=> both users docs exist. So a failed precondition means there is nothing to undo, and Unfollow returns
// (false, nil) without revealing why (never followed, already unfollowed, or target gone).
func (r *FirestoreRepo) Unfollow(ctx context.Context, callerUID, targetUID string, now time.Time) (bool, error) {
	// D1: unlike RunTransaction, a bare batch commit is not retried by the SDK when it loses a lock race with a
	// Follow/Block transaction on the same docs (Aborted). Retry a bounded number of times with a short
	// backoff; a failed attempt writes nothing.
	edgeRef, err := r.followRef(callerUID, targetUID)
	if err != nil {
		return false, err
	}
	res, err := store.CommitWithRetry(ctx,
		func() *store.FirestoreBatch { return store.NewFirestoreBatch(r.client) },
		store.RetryConfig{MaxAttempts: unfollowMaxAttempts, Backoff: unfollowRetryBackoff, Commit: r.commitBatch, Sleep: r.backoff},
		func(b store.Batch) {
			b.Delete(edgeRef, firestore.Exists)
			b.Update(r.graphRef(callerUID), []firestore.Update{
				{Path: "following", Value: firestore.ArrayRemove(targetUID)},
				{Path: "updatedAt", Value: now},
			})
			r.counters.AddFollowingCount(b, callerUID, -1)
			r.counters.AddFollowersCount(b, targetUID, -1)
		})
	noteTxnAttempts(ctx, res.Attempts)
	switch {
	case errors.Is(err, store.ErrContended):
		return false, fmt.Errorf("%w: %v", ErrContention, err)
	case err != nil:
		return false, fmt.Errorf("graph: unfollow: %w", err)
	}
	// !Committed with nil error: a failed Exists precondition is a no-op that performs (and bills) no writes.
	// For an ACTIVE caller, edge <=> following entry <=> both users docs exist, so this is a
	// correct no-op; (false, nil) deliberately does not reveal which case it was.
	return res.Committed, nil
}

// WithdrawRequest is the second blind batch of Unfollow: the edge batch failed its precondition, so the
// caller either had no edge or had a pending request. It deletes followRequests/{caller}_{target} with an Exists
// precondition and removes the target from graph/{caller}.requested in the same batch (I-R). A failed precondition is
// (false, nil): nothing to withdraw. It reads nothing; the same bounded contention retry as Unfollow.
//
// the reasoning carries over: with I-R, the request doc exists exactly when the target is in `requested`, so a
// missing doc means there is nothing to remove from the array either. Undo is never gated (no private_accounts check).
func (r *FirestoreRepo) WithdrawRequest(ctx context.Context, callerUID, targetUID string, now time.Time) (bool, error) {
	reqRef, err := r.requestRef(callerUID, targetUID)
	if err != nil {
		return false, err
	}
	res, err := store.CommitWithRetry(ctx,
		func() *store.FirestoreBatch { return store.NewFirestoreBatch(r.client) },
		store.RetryConfig{MaxAttempts: unfollowMaxAttempts, Backoff: unfollowRetryBackoff, Commit: r.commitBatch, Sleep: r.backoff},
		func(b store.Batch) {
			b.Delete(reqRef, firestore.Exists)
			b.Update(r.graphRef(callerUID), []firestore.Update{
				{Path: "requested", Value: firestore.ArrayRemove(targetUID)},
				{Path: "updatedAt", Value: now},
			})
		})
	noteTxnAttempts(ctx, res.Attempts)
	switch {
	case errors.Is(err, store.ErrContended):
		return false, fmt.Errorf("%w: %v", ErrContention, err)
	case err != nil:
		return false, fmt.Errorf("graph: withdraw follow request: %w", err)
	}
	return res.Committed, nil
}

// runTx is client.RunTransaction plus the contention signal: it counts how many times the
// callback ran (the SDK retries Aborted transactions internally) and records txn_attempts on the request
// log line. More than txnWarnAttempts attempts also emits one WARN, the measurement that decides whether
// to shard the counter. A callback re-run costs reads again (counted); its queued writes are counted only for the attempt that commits.
func (r *FirestoreRepo) runTx(ctx context.Context, fn func(context.Context, *firestore.Transaction) error) error {
	attempts, err := store.RunTransaction(ctx, r.client, fn)
	noteTxnAttempts(ctx, attempts)
	return err
}
