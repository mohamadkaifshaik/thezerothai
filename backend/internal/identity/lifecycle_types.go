// lifecycle_types.go declares the account-lifecycle seams (ADR-0011): the deletion/export job state stored on
// users/{uid} and exports/{id}, the consumer-side interfaces other modules' adapters implement (StepEraser,
// ExportSection, the D-C pattern also used by BlockChecker), and the infrastructure seams (job publisher, export
// object store, Firebase Auth client). identity imports nothing from graph or posts.
package identity

import (
	"context"
	"errors"
	"io"
	"time"

	fbauth "firebase.google.com/go/v4/auth"
)

// Job kinds carried in JobMessage.Kind on the shared `jobs` Pub/Sub topic (push path /internal/pubsub/jobs).
const (
	JobKindAccountDelete = "account_delete"
	JobKindAccountExport = "account_export"
)

// JobMessage is the payload of a job message. The uid / export id in it is only a lookup key: a job never acts on
// a message's word alone (ADR-0011 IAM control C1), it re-reads the document and checks its state.
type JobMessage struct {
	Kind string `json:"kind"`
	// UID and Seq are set for account_delete. Seq has no omitempty: seq 0 is the first message.
	UID string `json:"uid,omitempty"`
	Seq int64  `json:"seq"`
	// ExportID is set for account_export.
	ExportID string `json:"exportId,omitempty"`
	// SnapshotVersion is set for profile_snapshot_refresh (P2): the users.snapshotVersion the edit produced. It
	// is informational: the job always rewrites the profile's current version.
	SnapshotVersion int64 `json:"snapshotVersion,omitempty"`
}

// DeletionJob is the deletion state on users/{uid}.deletionJob (ADR-0011): Seq dedupes deliveries, Step is the
// step to resume at ("" = the first), Checkpoint is that step's opaque resume token, ProgressAt the last save.
type DeletionJob struct {
	Seq        int64
	Step       string
	Checkpoint []byte
	ProgressAt time.Time
}

type deletionJobDoc struct {
	Seq        int64     `firestore:"seq"`
	Step       string    `firestore:"step"`
	Checkpoint []byte    `firestore:"checkpoint"`
	ProgressAt time.Time `firestore:"progressAt"`
}

func (d *deletionJobDoc) toDomain() *DeletionJob {
	if d == nil {
		return nil
	}
	return &DeletionJob{Seq: d.Seq, Step: d.Step, Checkpoint: d.Checkpoint, ProgressAt: d.ProgressAt}
}

func deletionJobToDoc(j *DeletionJob) *deletionJobDoc {
	if j == nil {
		return nil
	}
	return &deletionJobDoc{Seq: j.Seq, Step: j.Step, Checkpoint: j.Checkpoint, ProgressAt: j.ProgressAt}
}

func ptrTime(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func derefTime(t *time.Time) time.Time {
	if t == nil {
		return time.Time{}
	}
	return *t
}

// ExportStatus is the exports/{id}.status value.
type ExportStatus string

const (
	ExportPending ExportStatus = "PENDING"
	ExportReady   ExportStatus = "READY"
	ExportFailed  ExportStatus = "FAILED"
)

// ExportDoc is exports/{id} (ADR-0003, ADR-0011): the export's job state. UpdateTime is Firestore's, for the
// status-change precondition.
type ExportDoc struct {
	ID         string
	UID        string
	Status     ExportStatus
	ObjectPath string
	CreatedAt  time.Time
	ExpireAt   time.Time
	// LeaseUntil is the export job's lease (L-4): while now < LeaseUntil one delivery is composing the export and
	// others back off. Zero = never claimed. The status stays PENDING while leased, so every PENDING-based query,
	// the status mapping and the backstop are unchanged, and a crashed run is simply a PENDING doc with an expired lease.
	LeaseUntil time.Time
	UpdateTime time.Time
}

// BackstopCursor is the position of a backstop page: the progress timestamp and document id of the last document
// returned. The zero value starts from the oldest document.
type BackstopCursor struct {
	At time.Time
	ID string
}

// IsZero reports the start-of-scan cursor.
func (c BackstopCursor) IsZero() bool { return c.At.IsZero() && c.ID == "" }

// Errors of the lifecycle repo.
var (
	// ErrJobConflict means a state write lost its precondition: another delivery or instance changed the document
	// since it was read. The caller re-reads and decides; it is never fatal.
	ErrJobConflict = errors.New("identity: job state changed concurrently")
	// ErrAuthAdminRefused is returned by the Firebase Auth wrapper when the document it was asked to act for is
	// not in the state that justifies the call (IAM control C1). It is always logged at ERROR.
	ErrAuthAdminRefused = errors.New("identity: auth admin operation refused")
)

// StepEraser is one resumable step of the deletion job (ADR-0011 D-C). Run does at most a bounded amount of work
// per call and returns the opaque checkpoint to resume from; done reports that the step has nothing left.
// Implementations must be idempotent: a crash after any call re-runs it from the last saved checkpoint, and two
// deliveries may run it concurrently (their Erasers use Exists preconditions, so counters are never decremented
// twice). Implemented by consumer-side adapters in internal/apiserver over graph.Eraser and posts.Eraser, which
// is why identity does not import those packages.
type StepEraser interface {
	Name() string
	Run(ctx context.Context, uid string, checkpoint []byte) (next []byte, done bool, err error)
}

// ExportSection writes one section of the account export (ADR-0011 D-D): WriteSection writes exactly one JSON
// value (it may end with whitespace) for uid to w, streaming, with every query limited.
type ExportSection interface {
	Name() string
	WriteSection(ctx context.Context, uid string, w io.Writer) error
}

// Position constrains where a registered step runs. Only BeforeIdentity is allowed: the identity step, the Auth
// user deletion and the final users/{uid} delete always come last (ADR-0011 Q1).
type Position int

const (
	// BeforeIdentity runs the step after the built-in Auth disable and before the identity step.
	BeforeIdentity Position = iota + 1
	// AfterIdentity is not allowed: RegisterEraser rejects it at startup.
	AfterIdentity
)

// JobPublisher publishes one message to the shared `jobs` topic. *pubsubpublish.Publisher implements it.
type JobPublisher interface {
	Publish(ctx context.Context, data []byte) error
}

// ObjectStore is the private exports bucket. *objstore.Store implements it.
type ObjectStore interface {
	Put(ctx context.Context, object, contentType string, write func(io.Writer) error) error
	Delete(ctx context.Context, object string) error
	SignedGetURL(ctx context.Context, object, filename string, ttl time.Duration, now time.Time) (string, error)
}

// AuthClient is the four-method slice of the Firebase Admin Auth client identity needs (ADR-0011 IAM control C2).
// *fbauth.Client implements it. It is built in apiserver.Build and handed only to identity's constructor; the
// unexported authAdmin wrapper (authadmin.go) is the only caller, and a CI test forbids every other file (except
// cmd/opsctl and tests), including other files of this package, from calling these methods on the interface or on
// the SDK client (M3).
type AuthClient interface {
	GetUser(ctx context.Context, uid string) (*fbauth.UserRecord, error)
	UpdateUser(ctx context.Context, uid string, user *fbauth.UserToUpdate) (*fbauth.UserRecord, error)
	RevokeRefreshTokens(ctx context.Context, uid string) error
	DeleteUser(ctx context.Context, uid string) error
}

var _ AuthClient = (*fbauth.Client)(nil)

// DeletionStart is BeginDeletion's result: the profile as written (status DELETING, deletion state set) and
// whether the call was a replay (0 writes).
type DeletionStart struct {
	Profile Profile
	Replay  bool
}

// HandleOutcome is DeleteHandleIfOwned's result.
type HandleOutcome int

const (
	// HandleAbsent: handles/{h} did not exist.
	HandleAbsent HandleOutcome = iota
	// HandleDeleted: handles/{h} was owned by the uid and is deleted.
	HandleDeleted
	// HandleOwnerMismatch: handles/{h} belongs to another uid (corrupt data); left alone.
	HandleOwnerMismatch
)

// CreateExportParams is the input of LifecycleRepo.CreateExport.
type CreateExportParams struct {
	ID         string
	UID        string
	ObjectPath string
	Now        time.Time
	Retention  time.Duration
	// ExportsPerDay is the daily `exports` quota (quota.Exports).
	ExportsPerDay int64
}

// LifecycleRepo is the storage seam of the account lifecycle; repo_lifecycle_firestore.go implements it and the
// unit tests use an in-memory fake with the same precondition semantics. Every method documents its Firestore
// cost; the callers charge them to the request's budget.Counter.
type LifecycleRepo interface {
	// BeginDeletion (DeleteAccount): one transaction reads users/{uid} fresh (1 read) and, unless the account is
	// already DELETING with job state, sets status DELETING, updatedAt, deletionRequestedAt and deletionJob{seq 0}
	// in 1 write. A replay writes nothing. ErrNotFound when the profile is absent.
	BeginDeletion(ctx context.Context, uid string, now time.Time) (DeletionStart, error)
	// GetJobState reads users/{uid} fresh (1 read) with its Firestore update time. ErrNotFound when absent.
	GetJobState(ctx context.Context, uid string) (Profile, time.Time, error)
	// SaveJobState writes users/{uid}.deletionJob (not updatedAt, not deletionRequestedAt) with a LastUpdateTime
	// precondition (1 write). ErrJobConflict when the doc changed since updateTime or no longer exists (Firestore
	// reports a missing document as a failed precondition); callers re-read to tell the two apart.
	SaveJobState(ctx context.Context, uid string, updateTime time.Time, job DeletionJob) error

	// CreateExport (RequestAccountExport): reads quotas/{uid} (1 read) and creates the PENDING doc and the
	// incremented quota atomically (2 writes). A replay of the same id returns the existing doc with 0 writes
	// (2 reads: quotas + the doc); over the daily quota with a different id is the quota package's
	// RESOURCE_EXHAUSTED + QUOTA_EXCEEDED error.
	CreateExport(ctx context.Context, p CreateExportParams) (doc ExportDoc, replay bool, err error)
	// GetExport reads exports/{id} fresh (1 read). ErrNotFound when absent.
	GetExport(ctx context.Context, id string) (ExportDoc, error)
	// SetExportStatus sets exports/{id}.status with a LastUpdateTime precondition (1 write). ErrJobConflict on a
	// lost precondition, which is also what a missing doc reports; callers re-read to tell the two apart.
	SetExportStatus(ctx context.Context, id string, status ExportStatus, updateTime time.Time) error
	// ClaimExport sets exports/{id}.leaseUntil with a LastUpdateTime precondition (1 write, status unchanged) and
	// returns the document's new update time, which the claimant uses for its later SetExportStatus. ErrJobConflict
	// when another delivery claimed or changed the doc since updateTime (a missing doc reports the same).
	ClaimExport(ctx context.Context, id string, updateTime, leaseUntil time.Time) (time.Time, error)

	// Identity-step operations (ADR-0011 Q1 step 5), each idempotent.
	// ListExports lists the uid's exports docs, Limit(limit) (reads = docs returned, minimum 1).
	ListExports(ctx context.Context, uid string, limit int) ([]ExportDoc, error)
	// DeleteExportDocs deletes the docs in one batch (deletes = len(ids)); a missing doc is not an error.
	DeleteExportDocs(ctx context.Context, ids []string) error
	// DeletePrivate deletes up to limit docs of users/{uid}/private (reads = docs, minimum 1) and returns the count.
	DeletePrivate(ctx context.Context, uid string, limit int) (int, error)
	// DeleteHandleIfOwned deletes handles/{handleLower} only when it points at uid (1 read, 1 delete).
	DeleteHandleIfOwned(ctx context.Context, handleLower, uid string) (HandleOutcome, error)
	// DeleteQuotas deletes quotas/{uid} (1 delete); a missing doc is success.
	DeleteQuotas(ctx context.Context, uid string) error
	// DeleteUserDoc deletes users/{uid} in one transaction (1 read, 1 delete) only while it is still DELETING with
	// deletionJob.seq == seq; a missing doc is success; anything else is ErrJobConflict and nothing is deleted.
	// Always the last step.
	DeleteUserDoc(ctx context.Context, uid string, seq int64) error

	// Backstop queries (daily-maintenance), every one limited.
	// ListDeleting returns up to limit DELETING accounts whose deletionJob.progressAt <= noProgressSince, oldest
	// progress first, strictly after cursor (reads = docs returned, minimum 1; L-6). Accounts without job state are
	// not returned. Needs the composite index users(status, deletionJob.progressAt).
	ListDeleting(ctx context.Context, noProgressSince time.Time, after BackstopCursor, limit int) ([]Profile, error)
	// ListPendingExports returns up to limit PENDING exports with createdAt <= createdBefore, oldest first, strictly
	// after cursor (reads = docs returned, minimum 1; L-6). A leased (RUNNING in spirit) export is still PENDING, so
	// a crashed run is included once it is old enough. Needs the composite index exports(status, createdAt).
	ListPendingExports(ctx context.Context, createdBefore time.Time, after BackstopCursor, limit int) ([]ExportDoc, error)

	// GetProfile is Repo.GetProfile (1 read), used by the export job for the profile section and the DELETING check.
	GetProfile(ctx context.Context, uid string) (Profile, error)
}

// AccountLifecycle is what the Connect handler needs for the three account-lifecycle RPCs (flag, recent sign-in
// and proto conversion stay in server.go). *Lifecycle implements it.
type AccountLifecycle interface {
	// DeleteAccount starts (or replays) the deletion of uid's own account and returns deletion_requested_at.
	DeleteAccount(ctx context.Context, uid, idempotencyKey string) (time.Time, error)
	// RequestAccountExport starts (or replays) an export of uid's own data.
	RequestAccountExport(ctx context.Context, uid, idempotencyKey string) (ExportView, error)
	// GetAccountExport returns the status of uid's export; NOT_FOUND for anything else.
	GetAccountExport(ctx context.Context, uid, exportID string) (ExportView, error)
}

// ExportView is the client-facing view of an export.
type ExportView struct {
	ID     string
	Status ExportStatus
	// DownloadURL and URLExpiresAt are set only when Status is READY.
	DownloadURL  string
	URLExpiresAt time.Time
	ExpiresAt    time.Time
}
