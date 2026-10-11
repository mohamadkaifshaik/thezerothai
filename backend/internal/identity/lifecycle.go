// lifecycle.go is the account-lifecycle service (ADR-0011, P8): DeleteAccount, RequestAccountExport and
// GetAccountExport, plus the registry the deletion orchestrator (lifecycle_jobs.go) and the export composer
// (lifecycle_export.go) run from. The orchestrator lives in identity (D-C) and reaches other modules only
// through the consumer-side StepEraser / ExportSection interfaces, registered by apiserver.Build.
package identity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"sync"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

const (
	// StartGateDuration is ADR-0008 D10's wait after DELETING is committed: 2x the 60 s instance-cache TTL, so no
	// instance still sees the user as ACTIVE and can create a new edge mid-purge.
	StartGateDuration = 120 * time.Second
	// defaultWorkBudget is the time one job delivery works before it saves its checkpoint and chains (ADR-0011:
	// 20 s slices inside Cloud Run's 30 s request timeout and Pub/Sub's 30 s ack deadline).
	defaultWorkBudget = 20 * time.Second
	// stepGrace is how long past the soft budget one step call may still run (a call that starts at 19.9 s).
	stepGrace = 5 * time.Second
	// saveReserve is the part of a delivery's handlerBudget that the work never uses: the checkpoint save (2 s deadline
	// share) plus the 5 s-bounded Publish of the continuation, or the status write after a failed export.
	saveReserve = 5 * time.Second
	// deleteRepublishAfter is the no-progress age under which a DeleteAccount replay does not re-publish the current
	// seq (M2): a live job moves progressAt every ~25 s, so a replay inside the window would only start a duplicate
	// slice. Longer than that, the job is stuck or its publish was lost, and the replay is the recovery.
	deleteRepublishAfter = 2 * time.Minute
	// maxStepErrors is opsctl purgeLoop's policy, moved here: after this many consecutive errors on one step the
	// delivery fails (Pub/Sub then retries it with backoff).
	maxStepErrors = 5
	// maxDeliveryAttempts is the `jobs` subscription's dead-letter threshold (ADR-0011: 10). An error on the last
	// attempt is the one that reaches Error Reporting at ERROR; earlier ones are WARN.
	maxDeliveryAttempts = 10

	// exportRPC is the operation name hashed into the export id with the caller's idempotency key.
	exportRPC = "RequestAccountExport"
	// exportFilename is what a downloaded export is called.
	exportFilename = "dzeroth-export.json"
	// Built-in step names (reserved: a registered eraser cannot use them).
	stepAuthDisable = "auth_disable"
	stepIdentity    = "identity"
	stepAuthDelete  = "auth_delete"
	stepUserDoc     = "users_doc"
)

var exportIDPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// StartGate reports how much longer to wait before an eraser may start on p (ADR-0008 D10, ADR-0011): 120 s after
// DELETING was committed, measured from deletionRequestedAt, which checkpoint writes and counter increments never
// move. An account set to DELETING by hand (opsctl) has no deletionRequestedAt, so updatedAt is the fallback. An
// account that is not DELETING is an error: nothing may be erased for it.
func StartGate(p Profile, now time.Time) (time.Duration, error) {
	return gateWait(p, now, StartGateDuration)
}

// gateWait is StartGate with the gate length injected (the Lifecycle's test seam).
func gateWait(p Profile, now time.Time, gate time.Duration) (time.Duration, error) {
	if p.Status != AccountStatusDeleting {
		return 0, errors.New("the account is not in status DELETING")
	}
	since := p.DeletionRequestedAt
	if since.IsZero() {
		since = p.UpdatedAt
	}
	return max(gate-now.Sub(since), 0), nil
}

// LifecycleDeps are the dependencies of NewLifecycle.
type LifecycleDeps struct {
	Repo      LifecycleRepo
	Cache     *Cache
	Publisher JobPublisher
	Auth      AuthClient
	// Objects is the private exports bucket; nil makes RequestAccountExport unavailable.
	Objects ObjectStore
	Log     *slog.Logger
	// ProjectID is only used for the Cloud Trace correlation field of job log lines.
	ProjectID       string
	Now             func() time.Time
	ExportsPerDay   int64
	ExportRetention time.Duration
	ExportURLTTL    time.Duration
	// WorkBudget and StartGate are test seams; zero means the production values (20 s, 120 s).
	WorkBudget time.Duration
	StartGate  time.Duration
	// ExportBudget is a test seam for the export compose budget; zero means 22 s.
	ExportBudget time.Duration
	// RetryBackoff is the first jitter ceiling between retries of a failing step (doubled per retry); zero means 200 ms.
	RetryBackoff time.Duration
}

// Lifecycle implements AccountLifecycle and the job handlers.
type Lifecycle struct {
	repo       LifecycleRepo
	cache      *Cache
	pub        JobPublisher
	auth       *authAdmin
	objects    ObjectStore
	log        *slog.Logger
	projectID  string
	now        func() time.Time
	perDay     int64
	retention  time.Duration
	urlTTL     time.Duration
	workBudget time.Duration
	startGate  time.Duration
	// exportBudget bounds the composing of one export (see defaultExportBudget).
	exportBudget time.Duration
	// retryBackoff is the first jitter ceiling between retries of one failing step.
	retryBackoff time.Duration

	mu          sync.Mutex
	erasers     []StepEraser
	sections    []ExportSection
	jobHandlers map[string]JobHandler
	sealed      bool
}

var _ AccountLifecycle = (*Lifecycle)(nil)

// NewLifecycle validates the dependencies. It does no I/O.
func NewLifecycle(d LifecycleDeps) (*Lifecycle, error) {
	switch {
	case d.Repo == nil || d.Cache == nil || d.Publisher == nil || d.Auth == nil:
		return nil, errors.New("identity: lifecycle needs Repo, Cache, Publisher and Auth")
	case d.ExportRetention <= 0 || d.ExportURLTTL <= 0 || d.ExportsPerDay <= 0:
		return nil, errors.New("identity: lifecycle needs positive ExportRetention, ExportURLTTL and ExportsPerDay")
	}
	l := &Lifecycle{
		repo: d.Repo, cache: d.Cache, pub: d.Publisher, objects: d.Objects, log: d.Log, projectID: d.ProjectID, now: d.Now,
		perDay: d.ExportsPerDay, retention: d.ExportRetention, urlTTL: d.ExportURLTTL,
		workBudget: d.WorkBudget, startGate: d.StartGate, retryBackoff: d.RetryBackoff,
	}
	if l.log == nil {
		l.log = slog.Default()
	}
	if l.now == nil {
		l.now = time.Now
	}
	if l.workBudget <= 0 {
		l.workBudget = defaultWorkBudget
	}
	l.exportBudget = d.ExportBudget
	if l.exportBudget <= 0 {
		l.exportBudget = defaultExportBudget
	}
	if l.retryBackoff <= 0 {
		l.retryBackoff = defaultRetryBackoff
	}
	if l.startGate <= 0 {
		l.startGate = StartGateDuration
	}
	l.auth = newAuthAdmin(d.Auth, l.log)
	return l, nil
}

// RegisterEraser adds a deletion step that runs after the built-in Auth disable and before the identity step, in
// registration order (ADR-0011 Q1: later slices register their Erasers here). AfterIdentity, a duplicate or
// reserved name, or a registration after the first job ran is a startup error.
func (l *Lifecycle) RegisterEraser(pos Position, s StepEraser) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	switch {
	case pos != BeforeIdentity:
		return fmt.Errorf("identity: eraser %q must be registered BeforeIdentity: the identity step, the Auth user and users/{uid} are always last", s.Name())
	case l.sealed:
		return fmt.Errorf("identity: eraser %q registered after the first job ran", s.Name())
	}
	name := s.Name()
	switch name {
	case "", stepAuthDisable, stepIdentity, stepAuthDelete, stepUserDoc:
		return fmt.Errorf("identity: eraser name %q is empty or reserved", name)
	}
	for _, e := range l.erasers {
		if e.Name() == name {
			return fmt.Errorf("identity: eraser %q registered twice", name)
		}
	}
	l.erasers = append(l.erasers, s)
	return nil
}

// RegisterExportSection adds an export section after the built-in account and profile sections, in registration
// order. A duplicate or reserved name, or a registration after the first job ran, is a startup error.
func (l *Lifecycle) RegisterExportSection(s ExportSection) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	name := s.Name()
	switch name {
	case "", "exportVersion", "generatedAt", "account", "profile":
		return fmt.Errorf("identity: export section name %q is empty or reserved", name)
	}
	if l.sealed {
		return fmt.Errorf("identity: export section %q registered after the first job ran", name)
	}
	for _, e := range l.sections {
		if e.Name() == name {
			return fmt.Errorf("identity: export section %q registered twice", name)
		}
	}
	l.sections = append(l.sections, s)
	return nil
}

// RegisterJobHandler routes jobs-topic messages whose `kind` is kind to h (P4: the media module's `post_delete`).
// The built-in account kinds cannot be overridden; a duplicate kind, an empty kind or a registration after the
// first job ran is a startup error.
func (l *Lifecycle) RegisterJobHandler(kind string, h JobHandler) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	switch {
	case kind == "" || kind == JobKindAccountDelete || kind == JobKindAccountExport:
		return fmt.Errorf("identity: job kind %q is empty or reserved", kind)
	case h == nil:
		return fmt.Errorf("identity: job kind %q has no handler", kind)
	case l.sealed:
		return fmt.Errorf("identity: job kind %q registered after the first job ran", kind)
	}
	if _, dup := l.jobHandlers[kind]; dup {
		return fmt.Errorf("identity: job kind %q registered twice", kind)
	}
	if l.jobHandlers == nil {
		l.jobHandlers = map[string]JobHandler{}
	}
	l.jobHandlers[kind] = h
	return nil
}

// jobHandler returns the handler registered for kind and seals the registries (like registered).
func (l *Lifecycle) jobHandler(kind string) (JobHandler, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.sealed = true
	h, ok := l.jobHandlers[kind]
	return h, ok
}

// registered returns copies of the registries and seals them: from the first job on they are read-only.
func (l *Lifecycle) registered() ([]StepEraser, []ExportSection) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.sealed = true
	return append([]StepEraser(nil), l.erasers...), append([]ExportSection(nil), l.sections...)
}

// StepNames lists the deletion steps in execution order. It reads the registry without sealing it. The names are a
// persisted contract (deletionJob.step in users/{uid}): renaming or removing one strands in-flight deletions, so a
// wiring test pins them.
func (l *Lifecycle) StepNames() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	names := []string{stepAuthDisable}
	for _, e := range l.erasers {
		names = append(names, e.Name())
	}
	return append(names, stepIdentity, stepAuthDelete, stepUserDoc)
}

// ExportSectionNames lists the registered export sections (after the built-in account and profile) in order, without
// sealing the registry. They are keys of the export file, a user-visible contract.
func (l *Lifecycle) ExportSectionNames() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	names := make([]string, 0, len(l.sections))
	for _, s := range l.sections {
		names = append(names, s.Name())
	}
	return names
}

// stamp is the current time at Firestore's timestamp precision (microseconds), so a value returned from the call that
// wrote it equals the value a replay later reads back.
func (l *Lifecycle) stamp() time.Time { return l.now().UTC().Truncate(time.Microsecond) }

func (l *Lifecycle) publish(ctx context.Context, msg JobMessage) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("identity: encode job message: %w", err)
	}
	return l.pub.Publish(ctx, data)
}

// DeleteAccount (ADR-0011 D-A): one transaction sets DELETING + the deletion state (first call: 1 read, 1 write; a
// replay 2 reads, 0 writes, 3 with the interceptor's cold profile read), then it publishes the job message. A publish
// failure still returns success (ERROR account_delete_enqueue_failed). A replay re-publishes the current seq only
// when the job has made no progress for deleteRepublishAfter (M2), so a replay storm cannot start duplicate slices;
// the daily backstop covers the rest. The throttle reads deletionJob.progressAt from the profile the replay already
// read, so it adds no Firestore operation. The caller's recent sign-in and the flag are checked by the handler; the
// uid is the token's own, never a request field (IAM control C1).
//
// Rule 4 deviation (ADR-0011 amendment 2026-10-09): idempotency_key is validated but not stored. DELETING is itself
// the idempotency record: a second call, with any key, is a replay of the same one-way transition.
func (l *Lifecycle) DeleteAccount(ctx context.Context, uid, idempotencyKey string) (time.Time, error) {
	logger.SetRequestField(ctx, "account_op", "delete_request")
	if idempotencyKeyIssue(idempotencyKey) {
		logger.SetRequestField(ctx, "outcome", "rejected:validation")
		return time.Time{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	start, err := l.repo.BeginDeletion(ctx, uid, l.stamp())
	if err != nil {
		if isNotFound(err) {
			logger.SetRequestField(ctx, "outcome", "rejected:not_found")
			return time.Time{}, notFoundErr()
		}
		return time.Time{}, logger.RedactErr(fmt.Errorf("identity: begin deletion: %w", err), uid)
	}
	// Reject this uid on this instance at once, from the data just written (no re-read).
	l.cache.SetProfile(start.Profile)
	outcome := "accepted"
	if start.Replay {
		outcome = "replay"
	}
	logger.SetRequestField(ctx, "outcome", outcome)
	job := start.Profile.DeletionJob
	if !start.Replay || l.now().Sub(job.ProgressAt) >= deleteRepublishAfter {
		if err := l.publish(ctx, JobMessage{Kind: JobKindAccountDelete, UID: uid, Seq: job.Seq}); err != nil {
			mw.ReportError(ctx, l.log, "account_delete_enqueue_failed", logger.RedactErr(fmt.Errorf("account_delete_enqueue_failed: %w", err), uid))
		}
	}
	return start.Profile.DeletionRequestedAt, nil
}

func exportNotFound() error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "export not found")
}

// RequestAccountExport: reads 1 (first call: +1 quotas), writes 2 (exports + quotas); a replay with the same key
// reads 2 (quotas, then the exports doc) and writes nothing. The export id is hash(uid, key), so a replay returns the same export. A publish
// failure still returns success (ERROR account_export_enqueue_failed). A replay re-publishes only a PENDING export
// older than exportRepublishAfter (L-4: a lost publish is recovered by the client's retry, without a replay storm
// re-composing the export); the daily backstop covers the rest. The throttle reads createdAt from the doc the replay
// already read, so it adds no Firestore operation.
func (l *Lifecycle) RequestAccountExport(ctx context.Context, uid, idempotencyKey string) (ExportView, error) {
	logger.SetRequestField(ctx, "account_op", "export_request")
	if idempotencyKeyIssue(idempotencyKey) {
		logger.SetRequestField(ctx, "outcome", "rejected:validation")
		return ExportView{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if l.objects == nil {
		logger.SetRequestField(ctx, "outcome", "rejected:unavailable")
		return ExportView{}, apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "data export is not available right now")
	}
	id := idempotency.Key(uid, exportRPC, idempotencyKey)
	doc, replay, err := l.repo.CreateExport(ctx, CreateExportParams{
		ID: id, UID: uid, ObjectPath: id + ".json", Now: l.stamp(), Retention: l.retention, ExportsPerDay: l.perDay,
	})
	if err != nil {
		var ae *apierr.Error
		if errors.As(err, &ae) {
			logger.SetRequestField(ctx, "outcome", "rejected:quota")
			return ExportView{}, err
		}
		return ExportView{}, logger.RedactErr(fmt.Errorf("identity: create export: %w", err), uid)
	}
	outcome := "accepted"
	if replay {
		outcome = "replay"
	}
	logger.SetRequestField(ctx, "outcome", outcome)
	logger.SetRequestField(ctx, "export_status", string(doc.Status))
	if !replay || (doc.Status == ExportPending && l.now().Sub(doc.CreatedAt) >= exportRepublishAfter) {
		if err := l.publish(ctx, JobMessage{Kind: JobKindAccountExport, ExportID: id}); err != nil {
			mw.ReportError(ctx, l.log, "account_export_enqueue_failed", logger.RedactErr(fmt.Errorf("account_export_enqueue_failed: %w", err), uid))
		}
	}
	return ExportView{ID: doc.ID, Status: doc.Status, ExpiresAt: doc.ExpireAt}, nil
}

// GetAccountExport: 1 read (fresh), 0 writes. An unknown id, another user's id, a malformed id and an expired
// export all give the same NOT_FOUND, bytes included (ADR-0011 Q6). READY gets a fresh signed GET URL per call
// that is never stored or logged.
func (l *Lifecycle) GetAccountExport(ctx context.Context, uid, exportID string) (ExportView, error) {
	logger.SetRequestField(ctx, "account_op", "export_get")
	now := l.now().UTC()
	if !exportIDPattern.MatchString(exportID) {
		logger.SetRequestField(ctx, "outcome", "not_found")
		return ExportView{}, exportNotFound()
	}
	doc, err := l.repo.GetExport(ctx, exportID)
	if err != nil {
		if isNotFound(err) {
			logger.SetRequestField(ctx, "outcome", "not_found")
			return ExportView{}, exportNotFound()
		}
		return ExportView{}, logger.RedactErr(fmt.Errorf("identity: get export: %w", err), uid)
	}
	if doc.UID != uid || !now.Before(doc.ExpireAt) {
		logger.SetRequestField(ctx, "outcome", "not_found")
		return ExportView{}, exportNotFound()
	}
	logger.SetRequestField(ctx, "export_status", string(doc.Status))
	logger.SetRequestField(ctx, "outcome", "ok")
	view := ExportView{ID: doc.ID, Status: doc.Status, ExpiresAt: doc.ExpireAt}
	if doc.Status != ExportReady {
		return view, nil
	}
	if l.objects == nil {
		return ExportView{}, errors.New("identity: export is READY but no export bucket is configured")
	}
	u, err := l.objects.SignedGetURL(ctx, doc.ObjectPath, exportFilename, l.urlTTL, now)
	if err != nil {
		return ExportView{}, fmt.Errorf("identity: sign export url: %w", err)
	}
	view.DownloadURL = u
	view.URLExpiresAt = now.Add(l.urlTTL)
	return view, nil
}
