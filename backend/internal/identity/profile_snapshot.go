// profile_snapshot.go is the identity side of the profile-snapshot-refresh job (P2, ADR-0003 "Author snapshot
// refresh"): a profile edit that changes what posts copy about their author (display name, handle) bumps
// users/{uid}.snapshotVersion in the same write, and after the commit a best-effort `profile_snapshot_refresh`
// message goes to the shared `jobs` topic (ADR-0011). The job handler (lifecycle_jobs.go dispatch) re-reads the
// profile and asks the posts module, through SnapshotWriter, to rewrite `author` on the newest posts.
//
// Gated by FEATURE_PROFILE_SNAPSHOT (wire name `profile_snapshot`): off means no quota reservation, no message,
// and a delivered message is acked without work. The version bump itself is unconditional (it rides the same
// write), so turning the flag on later heals posts at the next edit.
package identity

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// ProfileSnapshotFlag is the wire name of FEATURE_PROFILE_SNAPSHOT.
const ProfileSnapshotFlag = "profile_snapshot"

// JobKindProfileSnapshot is the JobMessage.Kind of a snapshot refresh.
const JobKindProfileSnapshot = "profile_snapshot_refresh"

// SnapshotRefreshPosts is how many of an author's newest posts one refresh rewrites (ADR-0003: older posts keep
// the old snapshot at Stage 0).
const SnapshotRefreshPosts = 100

// publishTimeout bounds the best-effort enqueue so a slow Pub/Sub never holds the RPC response.
const publishTimeout = 2 * time.Second

// SnapshotFields is the author data posts copy (posts.AuthorSnapshot, without the user id).
type SnapshotFields struct {
	Handle      string
	DisplayName string
	AvatarURL   string
	Verified    bool
}

// SnapshotWriter is the consumer-side seam the job uses to rewrite `author` on the user's newest posts (the
// BlockChecker / StepEraser pattern: identity cannot import posts). Idempotent: documents whose snapshotVersion
// is already >= version are left alone. updated is the number of posts rewritten.
type SnapshotWriter interface {
	RefreshAuthor(ctx context.Context, uid string, fields SnapshotFields, version int64) (updated int, err error)
}

// SnapshotQuota reserves one snapshot-affecting edit of uid's daily allowance (quota.SnapshotEdits). It returns
// the QUOTA_EXCEEDED apierr when the allowance is used up.
type SnapshotQuota interface {
	Reserve(ctx context.Context, uid string, perDay int64) error
}

// ProfileSnapshotDeps wires the P2 refresh into identity.New (WithProfileSnapshots).
type ProfileSnapshotDeps struct {
	Publisher JobPublisher
	Flags     FlagChecker
	Quota     SnapshotQuota
	PerDay    int64
	Log       *slog.Logger
}

type profileSnapshots struct {
	pub    JobPublisher
	flags  FlagChecker
	quota  SnapshotQuota
	perDay int64
	log    *slog.Logger
}

// WithProfileSnapshots enables the snapshot-refresh trigger in UpdateProfile and ChangeHandle. Without it (the
// default) identity behaves as before P2 apart from the unconditional snapshotVersion bump.
func WithProfileSnapshots(d ProfileSnapshotDeps) Option {
	return func(s *service) {
		if d.Publisher == nil || d.Flags == nil {
			return
		}
		log := d.Log
		if log == nil {
			log = slog.Default()
		}
		s.snap = &profileSnapshots{pub: d.Publisher, flags: d.Flags, quota: d.Quota, perDay: d.PerDay, log: log}
	}
}

func (s *service) snapshotsOn(uid string) bool {
	return s.snap != nil && s.snap.flags.Enabled(uid, ProfileSnapshotFlag)
}

// reserveSnapshotEdit spends one of the caller's daily snapshot edits (1 read, 1 write on quotas/{uid}).
func (s *service) reserveSnapshotEdit(ctx context.Context, uid string) error {
	if s.snap.quota == nil {
		return nil
	}
	return s.snap.quota.Reserve(ctx, uid, s.snap.perDay)
}

// enqueueSnapshotRefresh publishes the job message after the profile write committed. Best effort: a failure
// is logged and never reaches the caller (the posts keep the old snapshot until the next edit).
func (s *service) enqueueSnapshotRefresh(ctx context.Context, uid string, version int64) {
	data, err := json.Marshal(JobMessage{Kind: JobKindProfileSnapshot, UID: uid, SnapshotVersion: version})
	if err == nil {
		pctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), publishTimeout)
		defer cancel()
		err = s.snap.pub.Publish(pctx, data)
	}
	if err != nil {
		s.snap.log.WarnContext(ctx, "profile_snapshot_enqueue_failed",
			"uid_hash", logger.HashUID(uid), "error", logger.ScrubErr(err, uid).Error())
	}
}

// FirestoreSnapshotQuota implements SnapshotQuota on quotas/{uid}.
type FirestoreSnapshotQuota struct{ client *firestore.Client }

// NewSnapshotQuota builds the Firestore-backed SnapshotQuota.
func NewSnapshotQuota(client *firestore.Client) *FirestoreSnapshotQuota {
	return &FirestoreSnapshotQuota{client: client}
}

// Reserve: 1 read, 1 write (a rejected reservation writes nothing).
func (q *FirestoreSnapshotQuota) Reserve(ctx context.Context, uid string, perDay int64) error {
	qs := quota.New(q.client)
	_, err := store.RunTransaction(ctx, q.client, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		rec, err := qs.Get(ctx, tx, uid)
		if err != nil {
			return fmt.Errorf("identity: snapshot quota: %w", err)
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		if err := quota.CheckAndReserve(b, qs.Ref(uid), rec, quota.SnapshotEdits, perDay); err != nil {
			return err
		}
		return b.Err()
	})
	return err
}

// runProfileSnapshot handles one {profile_snapshot_refresh} delivery: 1 read (users/{uid}) plus the posts
// module's refresh (<= SnapshotRefreshPosts reads and writes, one atomic batch). The message only names the uid:
// the job always writes the profile's CURRENT fields and version, so a stale or replayed message is harmless.
func (l *Lifecycle) runProfileSnapshot(ctx context.Context, msg JobMessage, res jobResult) jobResult {
	if l.snapshots == nil || l.flags == nil || !l.flags.Enabled(msg.UID, ProfileSnapshotFlag) {
		return ack(res, "dropped:disabled")
	}
	p, _, err := l.repo.GetJobState(ctx, msg.UID)
	switch {
	case isNotFound(err):
		return ack(res, "duplicate") // the account is gone
	case err != nil:
		return retry(res, "error", logger.RedactErr(fmt.Errorf("identity: read profile for snapshot: %w", err), msg.UID))
	case p.Status != AccountStatusActive:
		return ack(res, "refused") // DELETING or suspended accounts are not touched
	}
	updated, err := l.snapshots.RefreshAuthor(ctx, msg.UID, SnapshotFields{
		Handle: p.Handle, DisplayName: p.DisplayName, AvatarURL: p.AvatarURL, Verified: p.Verified,
	}, p.SnapshotVersion)
	res.updated = updated
	if err != nil {
		return retry(res, "error", logger.RedactErr(fmt.Errorf("identity: refresh author snapshot: %w", err), msg.UID))
	}
	if updated == 0 {
		return ack(res, "duplicate")
	}
	return ack(res, "refreshed")
}
