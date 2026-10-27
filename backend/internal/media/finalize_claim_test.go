package media

import (
	"context"
	"errors"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// W3-22 M-3: concurrent FinalizeUpload calls for one PENDING image must screen it once. Part (a) is a per-instance
// single-flight, part (b) a preconditioned claim write before any Vision spend that decides the race between
// instances. These tests drive both, with a second and third service over the same repo standing in for the other
// Cloud Run instances.

// sibling builds another service over repo that shares this env's buckets and moderator: another Cloud Run
// instance of the same API (its own single-flight group and its own Vision cache).
func (e *env) sibling(t *testing.T, repo Repo) Service {
	t.Helper()
	svc, err := New(Deps{
		Repo: repo, Signer: e.sign, Objects: e.obj, Moderator: e.mod,
		Directory: fakeDirectory{created: testNow.Add(-30 * 24 * time.Hour)}, IDs: &seqIDs{},
		PublicBaseURL: "https://cdn.test/media", MediaPerDay: 20, NewAccountMediaPerDay: 8, NewAccountWindow: 24 * time.Hour,
		VisionMonthlyCap: 100, Now: func() time.Time { return testNow },
	})
	if err != nil {
		t.Fatal(err)
	}
	return svc
}

// raceState is shared by the per-instance raceRepo decorators of one scenario: the load barrier that gives every
// caller the same PENDING snapshot before any claim (the situation a precondition exists for), the claim attempt
// counter, and the number of callers that have been answered.
type raceState struct {
	loads    int32
	gate     chan struct{}
	arrivals atomic.Int32
	attempts atomic.Int32
	answered atomic.Int32
	noClaim  bool // the control run: ClaimScreening succeeds without writing (the pre-fix behaviour)
	// claimMu makes the claim writes of the instances reach Firestore one after the other: the first takes the claim,
	// the rest fail their precondition against it. Observed on the Firestore emulator (2026-10-27): a write that overlaps
	// failed-precondition writes to the same document is answered "Aborted: Transaction lock timeout" after 2 s, whatever
	// the code under test does (a bare Resolve racing bare claims reproduces it). The cause was not investigated; real
	// Firestore serialises such writes. The winner is still decided by the precondition, not by this lock. Do not remove
	// it and read the resulting flake as a product bug.
	claimMu sync.Mutex
}

// raceRepo is one instance's view of the repo: it decorates base with the shared race state and remembers whether
// this instance won the claim.
type raceRepo struct {
	Repo
	st  *raceState
	won atomic.Bool
}

func (r *raceRepo) GetMany(ctx context.Context, ids []string) (map[string]*Doc, error) {
	docs, err := r.Repo.GetMany(ctx, ids)
	if n := r.st.arrivals.Add(1); n <= r.st.loads {
		if n == r.st.loads {
			close(r.st.gate)
		}
		select {
		case <-r.st.gate:
		case <-time.After(10 * time.Second):
		}
	}
	return docs, err
}

func (r *raceRepo) ClaimScreening(ctx context.Context, id string, updateTime, until time.Time) (time.Time, error) {
	r.st.attempts.Add(1)
	if r.st.noClaim {
		r.won.Store(true)
		return updateTime, nil
	}
	r.st.claimMu.Lock()
	t, err := r.Repo.ClaimScreening(ctx, id, updateTime, until)
	r.st.claimMu.Unlock()
	if err == nil {
		r.won.Store(true)
	}
	return t, err
}

// waitUntil polls cond (bounded, so a broken run fails on its assertions instead of hanging).
func waitUntil(cond func() bool) {
	deadline := time.Now().Add(10 * time.Second)
	for !cond() && time.Now().Before(deadline) {
		runtime.Gosched()
	}
}

// raceOutcome is what one concurrent caller received.
type raceOutcome struct {
	res Result
	err error
}

// raceFinalize sends `callers` concurrent FinalizeUpload calls for one image, spread round-robin over `instances`
// services that all share base. All callers load the PENDING document before any of them goes on. The winner's first
// Vision call is then held until every caller outside the winner's own instance has been answered, so the losers
// genuinely overlap with a screening in flight (without a working claim each instance's leader would screen too) and
// no loser still writes while the winner resolves. With the serialised claim writes (raceState.claimMu) this keeps the
// Firestore emulator out of its "Transaction lock timeout" on writes that overlap failed-precondition writes to one
// document. claim=false is the control run.
func raceFinalize(t *testing.T, e *env, base Repo, uid, mediaID string, instances, callers int, claim bool) ([]raceOutcome, *raceState) {
	t.Helper()
	st := &raceState{loads: int32(callers), gate: make(chan struct{}), noClaim: !claim}
	repos := make([]*raceRepo, instances)
	services := make([]Service, instances)
	for i := range services {
		repos[i] = &raceRepo{Repo: base, st: st}
		services[i] = e.sibling(t, repos[i])
	}
	e.mod.mu.Lock()
	e.mod.onCall = func() error {
		if !claim {
			waitUntil(func() bool { return st.attempts.Load() >= int32(instances) })
			return nil
		}
		winnerCallers := 0
		for i, r := range repos {
			if r.won.Load() {
				winnerCallers = (callers - i + instances - 1) / instances
			}
		}
		waitUntil(func() bool { return st.answered.Load() >= int32(callers-winnerCallers) })
		return nil
	}
	e.mod.mu.Unlock()

	out := make([]raceOutcome, callers)
	var wg sync.WaitGroup
	for i := range out {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, err := services[i%instances].FinalizeUpload(context.Background(), uid, []FinalizeItem{{MediaID: mediaID, Blurhash: "LEHV6n"}})
			if err == nil {
				out[i].res = r[0]
			}
			out[i].err = err
			st.answered.Add(1)
		}()
	}
	wg.Wait()
	return out, st
}

// checkRaceOutcomes asserts the claim's contract on the callers' answers: every one is the winner's READY ref or the
// retryable MEDIA_NOT_READY, and at least one is READY.
func checkRaceOutcomes(t *testing.T, out []raceOutcome) (ready int) {
	t.Helper()
	var ref *Ref
	for i, o := range out {
		if o.err != nil {
			var ae *apierr.Error
			if !errors.As(o.err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
				t.Errorf("caller %d: err = %v, want nil or MEDIA_NOT_READY", i, o.err)
			}
			continue
		}
		if o.res.Status != StatusReady || o.res.Ref == nil {
			t.Errorf("caller %d: result = %+v, want READY", i, o.res)
			continue
		}
		if ref != nil && *ref != *o.res.Ref {
			t.Errorf("caller %d: ref %+v differs from %+v", i, *o.res.Ref, *ref)
		}
		ref = o.res.Ref
		ready++
	}
	if ready == 0 {
		t.Error("no caller got READY")
	}
	return ready
}

// Ten concurrent finalizes of one BANNER, spread over three instances that all loaded the PENDING document before
// anyone claimed it, spend exactly the banner's 2 Vision units and publish once.
func TestFinalize_ConcurrentBannerIsScreenedOnce(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.bannerUpload(t, uidA, "a")

	out, st := raceFinalize(t, e, e.repo, uidA, tg.MediaID, 3, 10, true)
	checkRaceOutcomes(t, out)

	if got := len(e.mod.calls); got != BannerVisionUnits {
		t.Errorf("SafeSearch calls = %d (%v), want %d: the full image and the thumbnail, once", got, e.mod.calls, BannerVisionUnits)
	}
	if got := e.repo.vision[monthKey(testNow)]; got != BannerVisionUnits {
		t.Errorf("vision counter = %d, want %d", got, BannerVisionUnits)
	}
	if st.attempts.Load() < 3 {
		t.Errorf("claim attempts = %d, want one per instance leader at least (the race was not exercised)", st.attempts.Load())
	}
	d := e.repo.docs[tg.MediaID]
	if d.Status != string(StatusReady) || d.ScreeningUntil != nil || d.ExpireAt != nil {
		t.Errorf("doc = status %q screeningUntil %v expireAt %v, want READY with no claim and no TTL", d.Status, d.ScreeningUntil, d.ExpireAt)
	}
	if e.obj.publishes != 2 {
		t.Errorf("publishes = %d, want 2 (full + thumb, once)", e.obj.publishes)
	}
}

// The control run: the same scenario with the claim turned into a no-op reproduces the finding, so the scenario
// above is a real regression test and not a schedule that happens to pass.
func TestFinalize_WithoutTheClaimConcurrentInstancesEachScreen(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.bannerUpload(t, uidA, "a")

	_, _ = raceFinalize(t, e, e.repo, uidA, tg.MediaID, 3, 10, false)

	if got := len(e.mod.calls); got <= BannerVisionUnits {
		t.Fatalf("SafeSearch calls = %d, want more than %d without the claim (3 instances x 2): the scenario does not reproduce M-3", got, BannerVisionUnits)
	}
}

// Part (a) alone: callers on one instance share one flight. Followers get the leader's READY (not MEDIA_NOT_READY),
// the claim is written once, Vision is called once, and only the leader's request adds units to the counter.
func TestFinalize_SingleFlightCollapsesCallsOnOneInstance(t *testing.T) {
	const callers = 8
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")

	// Hold the leader inside Vision until every caller has loaded the document (each does exactly one GetMany) and
	// had time to reach the flight.
	e.mod.mu.Lock()
	e.mod.onCall = func() error {
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			e.repo.mu.Lock()
			n := e.repo.getMany
			e.repo.mu.Unlock()
			if n >= callers {
				break
			}
			runtime.Gosched()
		}
		for range 200 {
			runtime.Gosched()
		}
		return nil
	}
	e.mod.mu.Unlock()

	out := make([]raceOutcome, callers)
	var wg sync.WaitGroup
	for i := range out {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err == nil {
				out[i].res = r[0]
			}
			out[i].err = err
		}()
	}
	wg.Wait()

	for i, o := range out {
		if o.err != nil || o.res.Status != StatusReady {
			t.Errorf("caller %d = %+v, %v, want READY (a same-instance follower shares the leader's result)", i, o.res, o.err)
		}
	}
	if len(e.mod.calls) != 1 {
		t.Errorf("SafeSearch calls = %d, want 1", len(e.mod.calls))
	}
	if e.repo.claims != 1 {
		t.Errorf("claim attempts = %d, want 1 (followers never claim)", e.repo.claims)
	}
	if got := e.repo.vision[monthKey(testNow)]; got != 1 {
		t.Errorf("vision counter = %d, want 1: only the leader reports the units it spent", got)
	}
}

// A claim a call holds is visible to every later loader: it answers MEDIA_NOT_READY before verifying, reserving or
// writing anything. The holder is mid-screening (the moderator hook), the second call is a fresh FinalizeUpload on
// another instance.
func TestFinalize_LiveClaimIsHonouredByLaterLoaders(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")
	other := e.sibling(t, e.repo)
	var (
		otherErr    error
		claimsSeen  int
		readsBefore int
	)
	e.mod.onCall = func() error {
		e.repo.mu.Lock()
		claimsSeen, readsBefore = e.repo.claims, e.repo.getMany
		e.repo.mu.Unlock()
		_, otherErr = other.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
		return nil
	}

	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err != nil || res[0].Status != StatusReady {
		t.Fatalf("holder = %+v, %v", res, err)
	}
	_ = wantAPI(t, otherErr, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY)
	if len(e.mod.calls) != 1 {
		t.Errorf("SafeSearch calls = %d, want 1", len(e.mod.calls))
	}
	if e.repo.claims != claimsSeen {
		t.Errorf("claim attempts = %d while the other call ran, want it to stay %d: a live claim is read, never re-taken", e.repo.claims, claimsSeen)
	}
	if reads := e.repo.getMany - readsBefore; reads != 2 {
		t.Errorf("the refused call read the document %d times, want 2 (its load and the one reload)", reads)
	}
}

// A claim is a lease: one that has run out (a call that died holding it) is retaken by the next finalize, and one
// still running is refused.
func TestFinalize_ClaimLeaseExpiry(t *testing.T) {
	tests := []struct {
		name      string
		until     time.Duration // relative to now
		wantReady bool
	}{
		{"running claim is refused", 20 * time.Second, false},
		{"claim about to expire is still refused", time.Second, false},
		{"claim that ran out is retaken", -time.Second, true},
		{"claim that ran out exactly now is retaken", 0, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			tg := e.upload(t, uidA, PurposePost, "a")
			until := testNow.Add(tt.until)
			e.repo.docs[tg.MediaID].ScreeningUntil = &until

			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if !tt.wantReady {
				_ = wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY)
				if len(e.mod.calls) != 0 || e.repo.claims != 0 || e.obj.publishes != 0 {
					t.Fatalf("a refused call spent: SafeSearch %d, claims %d, publishes %d", len(e.mod.calls), e.repo.claims, e.obj.publishes)
				}
				return
			}
			if err != nil || res[0].Status != StatusReady {
				t.Fatalf("res = %+v, %v", res, err)
			}
			if len(e.mod.calls) != 1 || e.repo.claims != 1 {
				t.Fatalf("SafeSearch %d, claims %d, want 1 and 1", len(e.mod.calls), e.repo.claims)
			}
			if e.repo.docs[tg.MediaID].ScreeningUntil != nil {
				t.Fatal("the retaken claim must be cleared by Resolve")
			}
		})
	}
}

// A failed attempt gives the claim back, so the client's retry (the error says "try again") is not answered with
// "the upload is not complete yet" for the next 30 seconds. testNow is fixed, so a lease that was NOT released would
// still be live on the retry.
func TestFinalize_FailedAttemptReleasesTheClaim(t *testing.T) {
	tests := []struct {
		name    string
		fail    func(e *env)
		recover func(e *env)
	}{
		{"vision down", func(e *env) { e.mod.err = errors.New("vision down") }, func(e *env) { e.mod.err = nil }},
		{"publish fails", func(e *env) { e.obj.publishErr = errors.New("gcs down") }, func(e *env) { e.obj.publishErr = nil }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			tg := e.upload(t, uidA, PurposePost, "a")
			tt.fail(e)

			_, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err == nil {
				t.Fatal("the failed attempt must be an error")
			}
			var ae *apierr.Error
			if errors.As(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
				t.Fatalf("err = %v: the first attempt claimed the image, it must not be refused", err)
			}
			if e.repo.claims != 1 || e.repo.releases != 1 {
				t.Fatalf("claims %d releases %d, want 1 and 1", e.repo.claims, e.repo.releases)
			}
			if e.repo.docs[tg.MediaID].ScreeningUntil != nil {
				t.Fatal("the claim must be released after a failed attempt")
			}

			tt.recover(e)
			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil || res[0].Status != StatusReady {
				t.Fatalf("retry = %+v, %v, want READY straight away", res, err)
			}
			if e.repo.claims != 2 {
				t.Fatalf("claims = %d, want 2 (the retry claimed again)", e.repo.claims)
			}
		})
	}
}

// An upload that is not there yet is refused before the claim: finalizing early must not lock the image for the
// retry that follows the client's upload.
func TestFinalize_EarlyFinalizeTakesNoClaim(t *testing.T) {
	e := newEnv(t, envOpts{})
	full, thumb := jpegBytes("Fa"), jpegBytes("Ta")
	tgs, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{item(full, thumb, "image/jpeg")},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tgs[0].MediaID}})
	_ = wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY)
	if e.repo.claims != 0 || e.repo.releases != 0 {
		t.Fatalf("claims %d releases %d, want none before the upload exists", e.repo.claims, e.repo.releases)
	}

	e.put(uidA, tgs[0], full, thumb, "image/jpeg")
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tgs[0].MediaID}})
	if err != nil || res[0].Status != StatusReady {
		t.Fatalf("finalize after the PUT = %+v, %v", res, err)
	}
}

// Every way a claimed image ends clears the claim, and a replay of a finished image never claims again.
func TestFinalize_ResolveClearsTheClaimAndReplaysDoNotClaim(t *testing.T) {
	tests := []struct {
		name string
		set  func(e *env, tg UploadTarget)
		want Status
	}{
		{"ready", func(*env, UploadTarget) {}, StatusReady},
		{"rejected by policy", func(e *env, tg UploadTarget) {
			e.mod.by[uploadObject(uidA, tg.MediaID, "jpg")] = SafeSearch{Adult: LikelihoodVeryLikely}
		}, StatusRejected},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			tg := e.upload(t, uidA, PurposePost, "a")
			tt.set(e, tg)
			for i := range 2 {
				res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
				if err != nil || res[0].Status != tt.want {
					t.Fatalf("call %d = %+v, %v, want %s", i, res, err, tt.want)
				}
			}
			if e.repo.claims != 1 {
				t.Fatalf("claims = %d, want 1: the replay is answered from the resolved document", e.repo.claims)
			}
			if e.repo.docs[tg.MediaID].ScreeningUntil != nil {
				t.Fatal("a resolved document must carry no claim")
			}
		})
	}
}
