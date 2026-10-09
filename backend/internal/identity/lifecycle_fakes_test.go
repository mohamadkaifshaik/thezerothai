package identity

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	fbauth "firebase.google.com/go/v4/auth"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// opLog is one ordered log of every side effect the fakes see, so a test can assert an order across the repo,
// Auth, object store, publisher and steps (for example "users/{uid} is deleted after the Auth user").
type opLog struct {
	mu  sync.Mutex
	ops []string
	// crashAt, when > 0, makes the add that brings the log to exactly that many ops panic with errCrash (once):
	// the side effect has happened, the caller never sees it return. It simulates a Cloud Run instance dying after
	// any single step call (lifecycle_crash_test.go).
	crashAt int
	// fired is set when the injected crash panicked; the job handlers recover panics into a 500, so the harness
	// reads this instead of seeing the panic.
	fired bool
}

// errCrash is the panic value of an injected crash.
var errCrash = errors.New("injected crash")

func (o *opLog) add(op string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.ops = append(o.ops, op)
	if o.crashAt > 0 && len(o.ops) == o.crashAt {
		o.crashAt = 0
		o.fired = true
		panic(errCrash)
	}
}

func (o *opLog) all() []string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]string(nil), o.ops...)
}

func (o *opLog) index(op string) int {
	for i, s := range o.all() {
		if s == op {
			return i
		}
	}
	return -1
}

func (o *opLog) count(prefix string) int {
	n := 0
	for _, s := range o.all() {
		if strings.HasPrefix(s, prefix) {
			n++
		}
	}
	return n
}

// fakeClock is a settable clock.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// syncBuffer is a goroutine-safe log sink.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// records returns the JSON log lines whose "msg" equals msg.
func (b *syncBuffer) records(msg string) []map[string]any {
	var out []map[string]any
	for _, line := range strings.Split(b.String(), "\n") {
		if line == "" {
			continue
		}
		var m map[string]any
		if json.Unmarshal([]byte(line), &m) == nil && m["msg"] == msg {
			out = append(out, m)
		}
	}
	return out
}

// fakeLCRepo is an in-memory LifecycleRepo with Firestore's precondition semantics: every write to a user or
// export doc bumps its version, which is its UpdateTime.
type fakeLCRepo struct {
	mu      sync.Mutex
	log     *opLog
	users   map[string]*fakeUser
	exports map[string]*ExportDoc
	handles map[string]string
	quotas  map[string]int64
	private map[string]int
	// failOnce injects one error for the named method (consumed on use).
	failOnce map[string]error
	// failFor makes an injected error repeat that many times instead of once.
	failFor map[string]int
	reads   int
	writes  int
	deletes int
	calls   map[string]int
}

type fakeUser struct {
	p   Profile
	ver int64
}

func newFakeLCRepo(log *opLog) *fakeLCRepo {
	return &fakeLCRepo{
		log: log, users: map[string]*fakeUser{}, exports: map[string]*ExportDoc{}, handles: map[string]string{},
		quotas: map[string]int64{}, private: map[string]int{}, failOnce: map[string]error{}, failFor: map[string]int{}, calls: map[string]int{},
	}
}

func utOf(ver int64) time.Time { return time.Unix(1_700_000_000+ver, 0).UTC() }

func (f *fakeLCRepo) enter(name string) error {
	f.calls[name]++
	if err, ok := f.failOnce[name]; ok {
		if n := f.failFor[name]; n > 1 {
			f.failFor[name] = n - 1
		} else {
			delete(f.failOnce, name)
			delete(f.failFor, name)
		}
		return err
	}
	return nil
}

func (f *fakeLCRepo) seed(p Profile) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.users[p.UserID] = &fakeUser{p: p}
	if p.HandleLower != "" {
		f.handles[p.HandleLower] = p.UserID
	}
}

// touch simulates an unrelated write to users/{uid} (another account's purge decrementing a counter).
func (f *fakeLCRepo) touch(uid string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if u := f.users[uid]; u != nil {
		u.ver++
	}
}

func (f *fakeLCRepo) user(uid string) (Profile, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	u := f.users[uid]
	if u == nil {
		return Profile{}, false
	}
	return copyProfile(u.p), true
}

func copyProfile(p Profile) Profile {
	if p.DeletionJob != nil {
		j := *p.DeletionJob
		j.Checkpoint = append([]byte(nil), j.Checkpoint...)
		p.DeletionJob = &j
	}
	return p
}

func (f *fakeLCRepo) BeginDeletion(_ context.Context, uid string, now time.Time) (DeletionStart, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("BeginDeletion"); err != nil {
		return DeletionStart{}, err
	}
	f.reads++
	u := f.users[uid]
	if u == nil {
		return DeletionStart{}, ErrNotFound
	}
	if u.p.Status == AccountStatusDeleting && !u.p.DeletionRequestedAt.IsZero() && u.p.DeletionJob != nil {
		return DeletionStart{Profile: copyProfile(u.p), Replay: true}, nil
	}
	u.p.Status = AccountStatusDeleting
	u.p.UpdatedAt = now
	u.p.DeletionRequestedAt = now
	u.p.DeletionJob = &DeletionJob{ProgressAt: now}
	u.ver++
	f.writes++
	f.log.add("repo.BeginDeletion")
	return DeletionStart{Profile: copyProfile(u.p)}, nil
}

func (f *fakeLCRepo) GetJobState(_ context.Context, uid string) (Profile, time.Time, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("GetJobState"); err != nil {
		return Profile{}, time.Time{}, err
	}
	f.reads++
	u := f.users[uid]
	if u == nil {
		return Profile{}, time.Time{}, ErrNotFound
	}
	return copyProfile(u.p), utOf(u.ver), nil
}

func (f *fakeLCRepo) SaveJobState(_ context.Context, uid string, updateTime time.Time, job DeletionJob) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("SaveJobState"); err != nil {
		return err
	}
	u := f.users[uid]
	if u == nil || !utOf(u.ver).Equal(updateTime) {
		return ErrJobConflict // like Firestore: a missing doc is a failed LastUpdateTime precondition
	}
	j := job
	j.Checkpoint = append([]byte(nil), job.Checkpoint...)
	u.p.DeletionJob = &j
	u.ver++
	f.writes++
	f.log.add(fmt.Sprintf("repo.SaveJobState seq=%d step=%s", job.Seq, job.Step))
	return nil
}

func (f *fakeLCRepo) CreateExport(_ context.Context, p CreateExportParams) (ExportDoc, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("CreateExport"); err != nil {
		return ExportDoc{}, false, err
	}
	f.reads++ // quotas/{uid}
	if e := f.exports[p.ID]; e != nil {
		if f.quotas[p.UID] >= p.ExportsPerDay {
			f.reads++ // the exports probe of an over-quota call
		} else {
			f.reads++ // the read after the AlreadyExists rollback
		}
		return *e, true, nil
	}
	if f.quotas[p.UID] >= p.ExportsPerDay {
		f.reads++ // the exports probe finds nothing
		return ExportDoc{}, false, apierr.New(connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "daily limit reached, please try again tomorrow").WithMeta("quota", "exports")
	}
	f.quotas[p.UID]++
	e := &ExportDoc{ID: p.ID, UID: p.UID, Status: ExportPending, ObjectPath: p.ObjectPath, CreatedAt: p.Now, ExpireAt: p.Now.Add(p.Retention), UpdateTime: utOf(1)}
	f.exports[p.ID] = e
	f.writes += 2
	f.log.add("repo.CreateExport")
	return *e, false, nil
}

func (f *fakeLCRepo) GetExport(_ context.Context, id string) (ExportDoc, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("GetExport"); err != nil {
		return ExportDoc{}, err
	}
	f.reads++
	e := f.exports[id]
	if e == nil {
		return ExportDoc{}, ErrNotFound
	}
	return *e, nil
}

func (f *fakeLCRepo) SetExportStatus(_ context.Context, id string, st ExportStatus, updateTime time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("SetExportStatus"); err != nil {
		return err
	}
	e := f.exports[id]
	if e == nil || !e.UpdateTime.Equal(updateTime) {
		return ErrJobConflict // like Firestore: a missing doc is a failed LastUpdateTime precondition
	}
	e.Status = st
	e.UpdateTime = e.UpdateTime.Add(time.Second)
	f.writes++
	f.log.add("repo.SetExportStatus " + string(st))
	return nil
}

func (f *fakeLCRepo) ClaimExport(_ context.Context, id string, updateTime, leaseUntil time.Time) (time.Time, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("ClaimExport"); err != nil {
		return time.Time{}, err
	}
	e := f.exports[id]
	if e == nil || !e.UpdateTime.Equal(updateTime) {
		return time.Time{}, ErrJobConflict
	}
	e.LeaseUntil = leaseUntil
	e.UpdateTime = e.UpdateTime.Add(time.Second)
	f.writes++
	f.log.add("repo.ClaimExport")
	return e.UpdateTime, nil
}

func (f *fakeLCRepo) ListExports(_ context.Context, uid string, limit int) ([]ExportDoc, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("ListExports"); err != nil {
		return nil, err
	}
	var out []ExportDoc
	for _, e := range f.exports {
		if e.UID == uid && len(out) < limit {
			out = append(out, *e)
		}
	}
	f.reads += max(len(out), 1)
	return out, nil
}

func (f *fakeLCRepo) DeleteExportDocs(_ context.Context, ids []string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("DeleteExportDocs"); err != nil {
		return err
	}
	for _, id := range ids {
		delete(f.exports, id)
		f.deletes++
	}
	f.log.add(fmt.Sprintf("repo.DeleteExportDocs n=%d", len(ids)))
	return nil
}

func (f *fakeLCRepo) DeletePrivate(_ context.Context, uid string, limit int) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("DeletePrivate"); err != nil {
		return 0, err
	}
	n := min(f.private[uid], limit)
	f.private[uid] -= n
	f.reads += max(n, 1)
	f.deletes += n
	f.log.add(fmt.Sprintf("repo.DeletePrivate n=%d", n))
	return n, nil
}

func (f *fakeLCRepo) DeleteHandleIfOwned(_ context.Context, handleLower, uid string) (HandleOutcome, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("DeleteHandleIfOwned"); err != nil {
		return HandleAbsent, err
	}
	f.reads++
	owner, ok := f.handles[handleLower]
	switch {
	case !ok:
		return HandleAbsent, nil
	case owner != uid:
		return HandleOwnerMismatch, nil
	}
	delete(f.handles, handleLower)
	f.deletes++
	f.log.add("repo.DeleteHandle")
	return HandleDeleted, nil
}

func (f *fakeLCRepo) DeleteQuotas(_ context.Context, uid string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("DeleteQuotas"); err != nil {
		return err
	}
	delete(f.quotas, uid)
	f.deletes++
	f.log.add("repo.DeleteQuotas")
	return nil
}

func (f *fakeLCRepo) DeleteUserDoc(_ context.Context, uid string, seq int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("DeleteUserDoc"); err != nil {
		return err
	}
	f.reads++
	u := f.users[uid]
	if u == nil {
		return nil
	}
	if u.p.Status != AccountStatusDeleting || u.p.DeletionJob == nil || u.p.DeletionJob.Seq != seq {
		return ErrJobConflict
	}
	delete(f.users, uid)
	f.deletes++
	f.log.add("repo.DeleteUserDoc")
	return nil
}

// ListDeleting mimics the Firestore query: DELETING with deletionJob state and progressAt <= noProgressSince,
// ordered by (progressAt, uid), strictly after the cursor, limited.
func (f *fakeLCRepo) ListDeleting(_ context.Context, noProgressSince time.Time, after BackstopCursor, limit int) ([]Profile, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("ListDeleting"); err != nil {
		return nil, err
	}
	var all []Profile
	for _, u := range f.users {
		if u.p.Status == AccountStatusDeleting && u.p.DeletionJob != nil && !u.p.DeletionJob.ProgressAt.After(noProgressSince) {
			all = append(all, copyProfile(u.p))
		}
	}
	sort.Slice(all, func(i, j int) bool {
		a, b := all[i], all[j]
		if !a.DeletionJob.ProgressAt.Equal(b.DeletionJob.ProgressAt) {
			return a.DeletionJob.ProgressAt.Before(b.DeletionJob.ProgressAt)
		}
		return a.UserID < b.UserID
	})
	var out []Profile
	for _, p := range all {
		if !after.IsZero() && !cursorBefore(after, p.DeletionJob.ProgressAt, p.UserID) {
			continue
		}
		if len(out) < limit {
			out = append(out, p)
		}
	}
	f.reads += max(len(out), 1)
	return out, nil
}

// cursorBefore reports whether (at, id) sorts strictly after the cursor.
func cursorBefore(c BackstopCursor, at time.Time, id string) bool {
	if !at.Equal(c.At) {
		return at.After(c.At)
	}
	return id > c.ID
}

func (f *fakeLCRepo) ListPendingExports(_ context.Context, createdBefore time.Time, after BackstopCursor, limit int) ([]ExportDoc, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("ListPendingExports"); err != nil {
		return nil, err
	}
	var all []ExportDoc
	for _, e := range f.exports {
		if e.Status == ExportPending && !e.CreatedAt.After(createdBefore) {
			all = append(all, *e)
		}
	}
	sort.Slice(all, func(i, j int) bool {
		if !all[i].CreatedAt.Equal(all[j].CreatedAt) {
			return all[i].CreatedAt.Before(all[j].CreatedAt)
		}
		return all[i].ID < all[j].ID
	})
	var out []ExportDoc
	for _, e := range all {
		if !after.IsZero() && !cursorBefore(after, e.CreatedAt, e.ID) {
			continue
		}
		if len(out) < limit {
			out = append(out, e)
		}
	}
	f.reads += max(len(out), 1)
	return out, nil
}

func (f *fakeLCRepo) GetProfile(_ context.Context, uid string) (Profile, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter("GetProfile"); err != nil {
		return Profile{}, err
	}
	f.reads++
	u := f.users[uid]
	if u == nil {
		return Profile{}, ErrNotFound
	}
	return copyProfile(u.p), nil
}

// fakeAuthClient records Firebase Auth admin calls.
type fakeAuthClient struct {
	mu      sync.Mutex
	log     *opLog
	users   map[string]*fbauth.UserRecord
	err     map[string]error // by method
	missing bool             // every call reports "user not found"
}

var errFakeUserNotFound = errors.New("fake: user not found")

func newFakeAuthClient(log *opLog) *fakeAuthClient {
	return &fakeAuthClient{log: log, users: map[string]*fbauth.UserRecord{}, err: map[string]error{}}
}

func (a *fakeAuthClient) call(method, uid string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.log.add("auth." + method)
	if a.missing {
		return errFakeUserNotFound
	}
	return a.err[method]
}

func (a *fakeAuthClient) GetUser(_ context.Context, uid string) (*fbauth.UserRecord, error) {
	if err := a.call("GetUser", uid); err != nil {
		return nil, err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if rec := a.users[uid]; rec != nil {
		return rec, nil
	}
	return &fbauth.UserRecord{UserInfo: &fbauth.UserInfo{UID: uid}}, nil
}

func (a *fakeAuthClient) UpdateUser(_ context.Context, uid string, _ *fbauth.UserToUpdate) (*fbauth.UserRecord, error) {
	return nil, a.call("UpdateUser", uid)
}

func (a *fakeAuthClient) RevokeRefreshTokens(_ context.Context, uid string) error {
	return a.call("RevokeRefreshTokens", uid)
}

func (a *fakeAuthClient) DeleteUser(_ context.Context, uid string) error {
	return a.call("DeleteUser", uid)
}

// fakePublisher records published job messages and can fail.
type fakePublisher struct {
	mu   sync.Mutex
	log  *opLog
	msgs []JobMessage
	err  error
}

func (p *fakePublisher) Publish(_ context.Context, data []byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.err != nil {
		return p.err
	}
	var m JobMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}
	p.msgs = append(p.msgs, m)
	p.log.add(fmt.Sprintf("pub %s seq=%d", m.Kind, m.Seq))
	return nil
}

func (p *fakePublisher) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.msgs)
}

func (p *fakePublisher) pop() (JobMessage, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.msgs) == 0 {
		return JobMessage{}, false
	}
	m := p.msgs[0]
	p.msgs = p.msgs[1:]
	return m, true
}

// fakeObjects is an in-memory ObjectStore.
type fakeObjects struct {
	mu      sync.Mutex
	log     *opLog
	objects map[string][]byte
	putErr  error
	delErr  error
	signErr error
	signed  []string
}

func newFakeObjects(log *opLog) *fakeObjects {
	return &fakeObjects{log: log, objects: map[string][]byte{}}
}

func (o *fakeObjects) Put(_ context.Context, object, _ string, write func(io.Writer) error) error {
	var buf bytes.Buffer
	if err := write(&buf); err != nil {
		return err // aborted: nothing stored
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.putErr != nil {
		return o.putErr
	}
	o.objects[object] = buf.Bytes()
	o.log.add("obj.Put")
	return nil
}

func (o *fakeObjects) Delete(_ context.Context, object string) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.delErr != nil {
		return o.delErr
	}
	delete(o.objects, object)
	o.log.add("obj.Delete")
	return nil
}

func (o *fakeObjects) SignedGetURL(_ context.Context, object, _ string, ttl time.Duration, now time.Time) (string, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.signErr != nil {
		return "", o.signErr
	}
	o.signed = append(o.signed, object)
	return "https://signed.example/" + object + "?exp=" + strconv.FormatInt(now.Add(ttl).Unix(), 10), nil
}

func (o *fakeObjects) get(object string) ([]byte, bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	b, ok := o.objects[object]
	return b, ok
}

// fakeStep is a StepEraser needing `need` calls; each call advances the clock by tick and records itself.
type fakeStep struct {
	name  string
	need  int
	clock *fakeClock
	tick  time.Duration
	log   *opLog
	// errs maps a 1-based call number to the error that call returns.
	errs map[int]error
	// gate, if set, is called at the start of Run (concurrency tests).
	gate func()

	mu     sync.Mutex
	calls  int
	cpSeen [][]byte
}

func (s *fakeStep) Name() string { return s.name }

func (s *fakeStep) Run(_ context.Context, _ string, cp []byte) ([]byte, bool, error) {
	if s.gate != nil {
		s.gate()
	}
	s.mu.Lock()
	s.calls++
	n := s.calls
	s.cpSeen = append(s.cpSeen, append([]byte(nil), cp...))
	s.mu.Unlock()
	s.log.add(fmt.Sprintf("step.%s call=%d", s.name, n))
	if s.clock != nil {
		s.clock.Advance(s.tick)
	}
	if err := s.errs[n]; err != nil {
		return nil, false, err
	}
	done := 0
	if len(cp) > 0 {
		done, _ = strconv.Atoi(string(cp))
	}
	done++
	if done >= s.need {
		return nil, true, nil
	}
	return []byte(strconv.Itoa(done)), false, nil
}

// fakeSection is an ExportSection writing a fixed JSON value (or failing).
type fakeSection struct {
	name string
	json string
	err  error
	// hook runs while the section is being written (a concurrent change during composing).
	hook func()
}

func (s fakeSection) Name() string { return s.name }

func (s fakeSection) WriteSection(_ context.Context, _ string, w io.Writer) error {
	if s.hook != nil {
		s.hook()
	}
	if s.err != nil {
		return s.err
	}
	_, err := io.WriteString(w, s.json)
	return err
}

// harness wires a Lifecycle over the fakes with a fake clock and a captured log.
type harness struct {
	t     *testing.T
	l     *Lifecycle
	repo  *fakeLCRepo
	auth  *fakeAuthClient
	pub   *fakePublisher
	objs  *fakeObjects
	clock *fakeClock
	log   *opLog
	logs  *syncBuffer
	cache *Cache
}

type harnessOpt func(*LifecycleDeps)

func newHarness(t *testing.T, opts ...harnessOpt) *harness {
	t.Helper()
	log := &opLog{}
	clock := &fakeClock{t: time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)}
	logs := &syncBuffer{}
	h := &harness{
		t: t, repo: newFakeLCRepo(log), auth: newFakeAuthClient(log), pub: &fakePublisher{log: log},
		objs: newFakeObjects(log), clock: clock, log: log, logs: logs, cache: NewCache(time.Minute),
	}
	deps := LifecycleDeps{
		Repo: h.repo, Cache: h.cache, Publisher: h.pub, Auth: h.auth, Objects: h.objs,
		Log: slog.New(slog.NewJSONHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug})), ProjectID: "demo-p",
		Now: clock.Now, RetryBackoff: time.Microsecond, ExportsPerDay: 1, ExportRetention: 7 * 24 * time.Hour, ExportURLTTL: 15 * time.Minute,
	}
	for _, o := range opts {
		o(&deps)
	}
	l, err := NewLifecycle(deps)
	if err != nil {
		t.Fatalf("NewLifecycle: %v", err)
	}
	l.auth.notFound = func(err error) bool { return errors.Is(err, errFakeUserNotFound) }
	h.l = l
	return h
}

// seedActive seeds an ACTIVE user with a handle.
func (h *harness) seedActive(uid, handle string) Profile {
	h.t.Helper()
	p := Profile{
		UserID: uid, Handle: handle, HandleLower: strings.ToLower(handle), DisplayName: "Name " + uid,
		Status: AccountStatusActive, CreatedAt: h.clock.Now().Add(-48 * time.Hour), UpdatedAt: h.clock.Now().Add(-48 * time.Hour),
	}
	h.repo.seed(p)
	return p
}

// seedDeleting seeds a user in the DELETING state DeleteAccount leaves (job seq 0), requested `ago` ago.
func (h *harness) seedDeleting(uid, handle string, ago time.Duration) Profile {
	h.t.Helper()
	p := h.seedActive(uid, handle)
	p.Status = AccountStatusDeleting
	p.DeletionRequestedAt = h.clock.Now().Add(-ago)
	p.UpdatedAt = p.DeletionRequestedAt
	p.DeletionJob = &DeletionJob{ProgressAt: p.DeletionRequestedAt}
	h.repo.seed(p)
	return p
}

// envelope builds the Pub/Sub push body for msg.
func envelope(msg any, attempt int) string {
	data, _ := json.Marshal(msg)
	env := map[string]any{"message": map[string]any{"data": base64.StdEncoding.EncodeToString(data), "messageId": "m-1"}, "subscription": "s"}
	if attempt > 0 {
		env["deliveryAttempt"] = attempt
	}
	b, _ := json.Marshal(env)
	return string(b)
}

// deliver posts one push delivery of msg to the jobs handler and returns the HTTP status.
func (h *harness) deliver(msg JobMessage, attempt int) int {
	h.t.Helper()
	return h.deliverRaw(envelope(msg, attempt))
}

func (h *harness) deliverRaw(body string) int {
	h.t.Helper()
	rec := httptest.NewRecorder()
	h.l.JobsHandler().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/internal/pubsub/jobs", strings.NewReader(body)))
	return rec.Code
}

// drain delivers every queued message until the queue is empty, redelivering a gated (429) message after the
// subscription's 60 s backoff, as Pub/Sub does. It returns how many deliveries were gated.
func (h *harness) drain(maxDeliveries int) (gated int) {
	h.t.Helper()
	for i := 0; i < maxDeliveries; i++ {
		msg, ok := h.pub.pop()
		if !ok {
			return gated
		}
		for {
			code := h.deliver(msg, 1)
			if code == http.StatusTooManyRequests {
				gated++
				h.clock.Advance(61 * time.Second)
				continue
			}
			if code != http.StatusNoContent {
				h.t.Fatalf("delivery of %+v = HTTP %d, want 204", msg, code)
			}
			break
		}
	}
	h.t.Fatalf("queue not drained after %d deliveries", maxDeliveries)
	return gated
}

func newRecorder() *httptest.ResponseRecorder { return httptest.NewRecorder() }

func newRequest(method string) *http.Request {
	return httptest.NewRequest(method, "/internal/x", strings.NewReader(""))
}
