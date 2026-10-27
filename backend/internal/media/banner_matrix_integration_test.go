//go:build integration

package media

// W3-20: the banner moderation path (ADR-0024 D1) against the REAL Firestore repo on the emulator, with the fake object
// store and the scripted SafeSearch of the unit tests. The cells that banner_test.go (fakes) and
// TestIntegration_BannerBudgetsAndResolver / _BannerErasureAndExport (real repo, happy path) leave open:
//   - the Racy rule table on each of the two images, for a BANNER, an AVATAR and a POST, with the Vision calls made and
//     the units recorded in the real monthly counter (banner 2, avatar 1, post 1 while VISION_SCREEN_THUMB is off);
//   - the exhausted-cap paths on the real counter: 2 units left, 1 unit left (a banner needs 2), at the cap, with the
//     "established" policy for an old account, a 6-day-old account and a 7-day-old one, and the "reject" policy;
//   - concurrent FinalizeUpload of one banner on ONE instance (W3-22 M-3, fixed in #351): all callers get READY, one
//     screening is paid (exactly 2 units, 2 SafeSearch calls); a claim held by another instance answers the retryable
//     MEDIA_NOT_READY at 0 writes and 0 Vision units, an expired claim is taken over, and a failed screening releases
//     its claim so the client's retry is not locked out (the cross-instance race itself is main's
//     TestIntegration_ConcurrentBannerFinalizeScreensOnce);
//   - the FinalizeUpload BANNER budget through the real repo (reads <= 2, writes exactly 3: claim, resolve, counter);
//   - purge coverage: every status a banner can be in, PENDING included, with its objects, and nobody else's.
//
// Names carry the w320 prefix so a symbol added by a W3-22 fix branch cannot collide.

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// w320MediaEnv is newIntEnv with the cap, the exhausted policy and the account age under the test's control.
type w320MediaEnv struct {
	*env
	client *firestore.Client
	real   *FirestoreRepo
	lib    *Library
}

func newW320MediaEnv(t *testing.T, cap int64, policy config.VisionExhaustedPolicy, accountAge time.Duration) *w320MediaEnv {
	t.Helper()
	client := newIntegrationClient(t)
	real := NewFirestoreRepo(client, WriteDeps{Idempotency: idempotency.New(client), Quotas: quota.New(client)})
	e := newEnv(t, envOpts{})
	svc, err := New(Deps{
		Repo: real, Signer: e.sign, Objects: e.obj, Moderator: e.mod,
		Directory: fakeDirectory{created: testNow.Add(-accountAge)}, IDs: &seqIDs{n: rand.IntN(1 << 30)},
		PublicBaseURL: "https://cdn.test/media", MediaPerDay: 20, NewAccountMediaPerDay: 8, NewAccountWindow: 24 * time.Hour,
		VisionMonthlyCap: cap, Policy: policy, ScreenThumb: false, Now: func() time.Time { return testNow },
	})
	if err != nil {
		t.Fatal(err)
	}
	e.svc = svc
	return &w320MediaEnv{env: e, client: client, real: real, lib: NewLibrary(real, "https://cdn.test/media")}
}

func (e *w320MediaEnv) w320Used(t *testing.T) int64 {
	t.Helper()
	n, err := e.real.VisionUsed(context.Background(), monthKey(testNow))
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// w320Finalize finalizes one media id and returns its result.
func (e *w320MediaEnv) w320Finalize(t *testing.T, uid, id string) Result {
	t.Helper()
	res, err := e.svc.FinalizeUpload(context.Background(), uid, []FinalizeItem{{MediaID: id, Blurhash: "LEHV6n"}})
	if err != nil {
		t.Fatalf("FinalizeUpload: %v", err)
	}
	return res[0]
}

// w320Upload creates and "uploads" one image of purpose (banner: 1500x500 WebP; avatar and post: the 1200x800 JPEG).
func (e *w320MediaEnv) w320Upload(t *testing.T, uid string, p Purpose, tag string) UploadTarget {
	t.Helper()
	if p == PurposeBanner {
		return e.bannerUpload(t, uid, tag)
	}
	return e.upload(t, uid, p, tag)
}

func (e *w320MediaEnv) w320Objects(id string, p Purpose, uid string) (full, thumb string) {
	ext := "jpg"
	if p == PurposeBanner {
		ext = "webp"
	}
	return uploadObject(uid, id, ext), uploadThumbObject(uid, id, ext)
}

func TestW320Banner_RacyRuleAndUnitsOnTheRealRepo(t *testing.T) {
	type onImage int
	const (
		none onImage = iota
		full
		thumbOnly
		both
	)
	likely, very, possible := LikelihoodLikely, LikelihoodVeryLikely, LikelihoodPossible
	tests := []struct {
		name  string
		ss    SafeSearch
		where onImage
		// verdict per purpose
		banner, avatar, post Status
	}{
		{"clean image", SafeSearch{}, both, StatusReady, StatusReady, StatusReady},
		{"racy LIKELY on the full image", SafeSearch{Racy: likely}, full, StatusRejected, StatusRejected, StatusReady},
		{"racy VERY_LIKELY on the thumbnail only", SafeSearch{Racy: very}, thumbOnly, StatusRejected, StatusReady /* avatar thumb is not screened */, StatusReady},
		{"racy POSSIBLE on both", SafeSearch{Racy: possible}, both, StatusReady, StatusReady, StatusReady},
		{"adult LIKELY on the thumbnail only", SafeSearch{Adult: likely}, thumbOnly, StatusRejected, StatusReady, StatusReady},
		{"adult LIKELY on the full image", SafeSearch{Adult: likely}, full, StatusRejected, StatusRejected, StatusRejected},
		{"violence VERY_LIKELY on the full image", SafeSearch{Violence: very}, full, StatusRejected, StatusRejected, StatusRejected},
		{"violence POSSIBLE", SafeSearch{Violence: possible}, both, StatusReady, StatusReady, StatusReady},
	}
	for _, p := range []struct {
		purpose Purpose
		units   int64
		calls   int
		pick    func(banner, avatar, post Status) Status
	}{
		{PurposeBanner, BannerVisionUnits, 2, func(b, _, _ Status) Status { return b }},
		{PurposeAvatar, 1, 1, func(_, a, _ Status) Status { return a }},
		{PurposePost, 1, 1, func(_, _, po Status) Status { return po }},
	} {
		for _, tt := range tests {
			t.Run(fmt.Sprintf("%s: %s", p.purpose, tt.name), func(t *testing.T) {
				e := newW320MediaEnv(t, 1000, config.VisionPolicyEstablished, 30*24*time.Hour)
				tg := e.w320Upload(t, uidA, p.purpose, "r")
				fullObj, thumbObj := e.w320Objects(tg.MediaID, p.purpose, uidA)
				if tt.where == full || tt.where == both {
					e.mod.by[fullObj] = tt.ss
				}
				if tt.where == thumbOnly || tt.where == both {
					e.mod.by[thumbObj] = tt.ss
				}
				res := e.w320Finalize(t, uidA, tg.MediaID)
				want := p.pick(tt.banner, tt.avatar, tt.post)
				if res.Status != want {
					t.Fatalf("status = %s (%s), want %s", res.Status, res.RejectionReason, want)
				}
				if len(e.mod.calls) != p.calls {
					t.Errorf("SafeSearch calls = %v, want %d (a banner screens both images, an avatar or post only the full one)", e.mod.calls, p.calls)
				}
				if got := e.w320Used(t); got != p.units {
					t.Errorf("Vision units recorded = %d, want %d", got, p.units)
				}
				doc := e.real // the stored document agrees with the answer
				docs, err := doc.GetMany(context.Background(), []string{tg.MediaID})
				if err != nil || docs[tg.MediaID] == nil || docs[tg.MediaID].Status != string(want) {
					t.Fatalf("stored status = %v, %v; want %s", docs[tg.MediaID], err, want)
				}
				if want == StatusRejected {
					if res.RejectionReason != reasonPolicy || res.Ref != nil {
						t.Errorf("result = %+v, want the policy rejection and no media ref", res)
					}
					if len(e.obj.public) != 0 || len(e.obj.upload) != 0 {
						t.Errorf("objects left after a rejection: public=%v private=%v", e.obj.public, e.obj.upload)
					}
					if p.purpose == PurposeBanner {
						if _, err := e.lib.ResolveBanner(context.Background(), uidA, tg.MediaID); !IsNotReady(err) {
							t.Errorf("a rejected banner resolved: %v", err)
						}
					}
				} else if p.purpose == PurposeBanner {
					if ref, err := e.lib.ResolveBanner(context.Background(), uidA, tg.MediaID); err != nil || ref.Width != 1500 || ref.Height != 500 {
						t.Errorf("a published banner did not resolve: %+v, %v", ref, err)
					}
				}
			})
		}
	}
}

// TestW320Banner_VisionCapPathsOnTheRealCounter: the exhausted path of ADR-0024 D1 on the real monthly counter doc. A
// banner needs 2 units, so with 1 unit left it is already "exhausted" (the avatar next to it still fits). Under the
// established policy an account of 7 days or more publishes UNSCREENED (the counter does not move, SafeSearch is not
// called) and a younger one is REJECTED with the capacity reason; under the reject policy nobody publishes unscreened.
func TestW320Banner_VisionCapPathsOnTheRealCounter(t *testing.T) {
	const (
		day = 24 * time.Hour
	)
	tests := []struct {
		name    string
		purpose Purpose
		used    int64
		policy  config.VisionExhaustedPolicy
		age     time.Duration
		status  Status
		reason  string
		calls   int
		after   int64
	}{
		{"banner, 2 units left: screened", PurposeBanner, 8, config.VisionPolicyEstablished, 30 * day, StatusReady, "", 2, 10},
		{"banner, 1 unit left, established account: unscreened", PurposeBanner, 9, config.VisionPolicyEstablished, 30 * day, StatusReadyUnscreened, "", 0, 9},
		{"banner, 1 unit left, 6-day-old account: rejected for capacity", PurposeBanner, 9, config.VisionPolicyEstablished, 6*day + 23*time.Hour, StatusRejected, reasonCapacity, 0, 9},
		{"banner, 1 unit left, exactly 7-day-old account: unscreened", PurposeBanner, 9, config.VisionPolicyEstablished, 7 * day, StatusReadyUnscreened, "", 0, 9},
		{"banner, at the cap, established account: unscreened", PurposeBanner, 10, config.VisionPolicyEstablished, 30 * day, StatusReadyUnscreened, "", 0, 10},
		{"banner, at the cap, reject policy: rejected for capacity", PurposeBanner, 10, config.VisionPolicyReject, 30 * day, StatusRejected, reasonCapacity, 0, 10},
		{"banner, 1 unit left, reject policy: rejected for capacity", PurposeBanner, 9, config.VisionPolicyReject, 30 * day, StatusRejected, reasonCapacity, 0, 9},
		{"avatar, 1 unit left: still screened (1 unit)", PurposeAvatar, 9, config.VisionPolicyEstablished, 30 * day, StatusReady, "", 1, 10},
		{"post image, 1 unit left: still screened", PurposePost, 9, config.VisionPolicyEstablished, 30 * day, StatusReady, "", 1, 10},
		{"post image, at the cap, new account: rejected for capacity", PurposePost, 10, config.VisionPolicyEstablished, day, StatusRejected, reasonCapacity, 0, 10},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newW320MediaEnv(t, 10, tt.policy, tt.age)
			if tt.used > 0 {
				if err := e.real.AddVisionUnits(context.Background(), monthKey(testNow), tt.used); err != nil {
					t.Fatal(err)
				}
			}
			tg := e.w320Upload(t, uidA, tt.purpose, "c")
			res := e.w320Finalize(t, uidA, tg.MediaID)
			if res.Status != tt.status || res.RejectionReason != tt.reason {
				t.Fatalf("result = %s / %q, want %s / %q", res.Status, res.RejectionReason, tt.status, tt.reason)
			}
			if len(e.mod.calls) != tt.calls {
				t.Errorf("SafeSearch calls = %d, want %d", len(e.mod.calls), tt.calls)
			}
			if got := e.w320Used(t); got != tt.after {
				t.Errorf("counter = %d, want %d", got, tt.after)
			}
			if tt.purpose == PurposeBanner && tt.status == StatusReadyUnscreened {
				// An unscreened banner is a usable banner (ResolveBanner accepts READY_UNSCREENED) - the exposure I-5 names.
				if _, err := e.lib.ResolveBanner(context.Background(), uidA, tg.MediaID); err != nil {
					t.Errorf("an unscreened banner did not resolve: %v", err)
				}
			}
			if tt.status == StatusRejected {
				if _, err := e.lib.ResolveBanner(context.Background(), uidA, tg.MediaID); !IsNotReady(err) {
					t.Errorf("a rejected image resolved as a banner: %v", err)
				}
			}
		})
	}
}

// TestW320Banner_ConcurrentFinalizeUnits: 8 concurrent FinalizeUpload calls for one PENDING banner on ONE instance
// (W3-22 M-3 part a, fixed in #351). The per-instance single flight collapses them: every call is answered READY (no
// MEDIA_NOT_READY for the losers, no error), the banner is published once, and exactly one screening is paid: 2 Vision
// units and 2 SafeSearch calls (the full image and the thumbnail), not one screening per caller.
func TestW320Banner_ConcurrentFinalizeUnits(t *testing.T) {
	e := newW320MediaEnv(t, 1000, config.VisionPolicyEstablished, 30*24*time.Hour)
	tg := e.bannerUpload(t, uidA, "cc")
	const callers = 8
	results := make([]Result, callers)
	errs := make([]error, callers)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := range callers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID, Blurhash: "LEHV6n"}})
			if err == nil {
				results[i] = res[0]
			}
			errs[i] = err
		}()
	}
	close(start)
	wg.Wait()
	for i := range results {
		if errs[i] != nil {
			t.Errorf("caller %d: %v, want READY (the single flight answers every caller on this instance)", i, errs[i])
			continue
		}
		if results[i].Status != StatusReady {
			t.Errorf("caller %d: status %s (%s), want READY", i, results[i].Status, results[i].RejectionReason)
		}
	}
	docs, err := e.real.GetMany(context.Background(), []string{tg.MediaID})
	if err != nil || docs[tg.MediaID].Status != string(StatusReady) || docs[tg.MediaID].ScreeningUntil != nil {
		t.Fatalf("stored banner = %+v, %v; want READY with no claim left", docs[tg.MediaID], err)
	}
	units := e.w320Used(t)
	t.Logf("W320 observed: %d concurrent finalizes of one banner recorded %d Vision units and %d SafeSearch calls", callers, units, len(e.mod.calls))
	if units != BannerVisionUnits {
		t.Errorf("units = %d, want exactly %d (one screening)", units, BannerVisionUnits)
	}
	if len(e.mod.calls) != 2 {
		t.Errorf("SafeSearch calls = %v, want exactly 2 (full image and thumbnail, once)", e.mod.calls)
	}
}

// TestW320Banner_ClaimHeldElsewhereAndFailureRelease: the screening claim on the real repo (W3-22 M-3 part b). (a) A claim
// held by another instance (stamped straight onto the PENDING document) makes FinalizeUpload answer the retryable
// MEDIA_NOT_READY after reading only, with 0 writes, 0 SafeSearch calls and 0 Vision units, and leaves the claim alone.
// (b) Once the claim has expired the next call takes the image over and publishes it (units 2, claim cleared by the
// resolve). (c) A failed screening (Vision down) answers UNAVAILABLE and RELEASES its claim, so the client's immediate
// retry is not locked out for the 30 s of the claim.
func TestW320Banner_ClaimHeldElsewhereAndFailureRelease(t *testing.T) {
	ctx := context.Background()
	e := newW320MediaEnv(t, 1000, config.VisionPolicyEstablished, 30*24*time.Hour)
	load := func(id string) *Doc {
		t.Helper()
		docs, err := e.real.GetMany(ctx, []string{id})
		if err != nil || docs[id] == nil {
			t.Fatalf("load %s: %v", id, err)
		}
		return docs[id]
	}
	finalize := func(id string) ([]Result, *budget.Counter, error) {
		t.Helper()
		cctx, c := budget.WithCounter(ctx)
		res, err := e.svc.FinalizeUpload(cctx, uidA, []FinalizeItem{{MediaID: id, Blurhash: "LEHV6n"}})
		return res, c, err
	}

	tg := e.bannerUpload(t, uidA, "claim")
	held := load(tg.MediaID)
	if _, err := e.real.ClaimScreening(ctx, held.ID, held.UpdateTime, testNow.Add(20*time.Second)); err != nil {
		t.Fatal(err)
	}
	_, c, err := finalize(tg.MediaID)
	_ = wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY) // retryable: the other instance is screening
	if c.Writes() != 0 || c.Deletes() != 0 || c.Reads() > 3 {
		t.Errorf("a refused finalize cost %d reads / %d writes / %d deletes, want <= 3 / 0 / 0 (it reads, never writes)", c.Reads(), c.Writes(), c.Deletes())
	}
	t.Logf("W320BUDGET rpc=%q case=%q reads=%d writes=%d deletes=%d ceil_reads=%d ceil_writes=%d", "MediaService.FinalizeUpload", "BANNER, claim held by another instance", c.Reads(), c.Writes(), c.Deletes(), 3, 0)
	if len(e.mod.calls) != 0 || e.w320Used(t) != 0 {
		t.Errorf("a refused finalize spent SafeSearch calls=%v units=%d, want none", e.mod.calls, e.w320Used(t))
	}
	if d := load(tg.MediaID); d.Status != string(StatusPending) || d.ScreeningUntil == nil {
		t.Errorf("doc = %+v, want PENDING with the other instance's claim untouched", d)
	}

	// (b) The claim expires (its holder died): the next call takes over.
	d := load(tg.MediaID)
	if _, err := e.real.ClaimScreening(ctx, d.ID, d.UpdateTime, testNow.Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	res, c, err := finalize(tg.MediaID)
	if err != nil || res[0].Status != StatusReady {
		t.Fatalf("after the claim expired: %v, %v; want READY", res, err)
	}
	budgettest.Assert(t, "FinalizeUpload BANNER cold (claim, screen, resolve)", c, budgettest.Budget{Reads: 2, Writes: 3})
	if c.Writes() != 3 {
		t.Errorf("writes = %d, want exactly 3 (claim, resolve, Vision counter)", c.Writes())
	}
	t.Logf("W320BUDGET rpc=%q case=%q reads=%d writes=%d deletes=%d ceil_reads=%d ceil_writes=%d", "MediaService.FinalizeUpload", "BANNER, expired claim taken over", c.Reads(), c.Writes(), c.Deletes(), 2, 3)
	if d := load(tg.MediaID); d.Status != string(StatusReady) || d.ScreeningUntil != nil {
		t.Errorf("doc = %+v, want READY with the claim cleared by the resolve", d)
	}
	if got := e.w320Used(t); got != BannerVisionUnits {
		t.Errorf("units = %d, want %d", got, BannerVisionUnits)
	}

	// (c) A failed screening releases the claim.
	tg2 := e.bannerUpload(t, uidA, "release")
	e.mod.mu.Lock()
	e.mod.err = errors.New("vision down")
	e.mod.mu.Unlock()
	_, c, err = finalize(tg2.MediaID)
	_ = wantAPI(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if d := load(tg2.MediaID); d.Status != string(StatusPending) || d.ScreeningUntil != nil {
		t.Errorf("doc after a failed screening = %+v, want PENDING with NO claim (released)", d)
	}
	if c.Writes() != 2 {
		t.Errorf("a failed attempt wrote %d, want 2 (claim, release)", c.Writes())
	}
	e.mod.mu.Lock()
	e.mod.err = nil
	e.mod.mu.Unlock()
	if res, _, err := finalize(tg2.MediaID); err != nil || res[0].Status != StatusReady {
		t.Errorf("the immediate retry after a failed attempt: %v, %v; want READY (the claim was released)", res, err)
	}
}

// TestW320Banner_PurgeCoversEveryStatus: right to delete (rule 10) for banners in every state - PENDING (never finalized),
// READY, READY_UNSCREENED and REJECTED - next to an avatar and a post image, with their public and private objects. Another
// user's banner and its objects survive.
func TestW320Banner_PurgeCoversEveryStatus(t *testing.T) {
	ctx := context.Background()
	e := newW320MediaEnv(t, 1000, config.VisionPolicyEstablished, 30*24*time.Hour)
	var mine []UploadTarget
	for _, tag := range []string{"pending", "ready", "unscreened", "rejected"} {
		mine = append(mine, e.bannerUpload(t, uidA, tag))
	}
	mine = append(mine, e.upload(t, uidA, PurposeAvatar, "av"), e.upload(t, uidA, PurposePost, "po"))
	bob := e.bannerUpload(t, uidB, "bob")
	// Drive the states: finalize (ready), then force the others on the stored documents.
	if r := e.w320Finalize(t, uidA, mine[1].MediaID); r.Status != StatusReady {
		t.Fatalf("finalize = %+v", r)
	}
	if r := e.w320Finalize(t, uidB, bob.MediaID); r.Status != StatusReady {
		t.Fatalf("finalize bob = %+v", r)
	}
	for i, st := range map[int]Status{2: StatusReadyUnscreened, 3: StatusRejected} {
		if _, err := e.client.Collection(mediaCollection).Doc(mine[i].MediaID).Update(ctx, []firestore.Update{{Path: "status", Value: string(st)}}); err != nil {
			t.Fatal(err)
		}
	}
	// Public copies exist for the published ones, as after a real finalize; the PENDING and unscreened docs keep private objects.
	for _, tg := range []UploadTarget{mine[1], mine[2], bob} {
		e.obj.public["m/"+tg.MediaID+".webp"] = "image/webp"
		e.obj.public["m/"+tg.MediaID+"_t.webp"] = "image/webp"
	}
	before := len(e.obj.public) + len(e.obj.upload)

	p := NewPurger(e.real, e.obj, "https://cdn.test/media")
	cp, done, err := p.PurgeUser(ctx, uidA, Checkpoint{})
	if err != nil || !done || cp.Deleted != len(mine) {
		t.Fatalf("purge = %+v done=%v err=%v, want all %d documents", cp, done, err, len(mine))
	}
	ids := make([]string, 0, len(mine)+1)
	for _, tg := range mine {
		ids = append(ids, tg.MediaID)
	}
	docs, err := e.real.GetMany(ctx, append(ids, bob.MediaID))
	if err != nil || len(docs) != 1 || docs[bob.MediaID] == nil {
		t.Fatalf("documents left = %v, %v: only the other user's banner may remain", docs, err)
	}
	for obj := range e.obj.public {
		if obj != "m/"+bob.MediaID+".webp" && obj != "m/"+bob.MediaID+"_t.webp" {
			t.Errorf("a public object of the purged user is left: %s", obj)
		}
	}
	for obj := range e.obj.upload {
		t.Errorf("a private upload object of the purged user is left: %s", obj)
	}
	t.Logf("objects before the purge: %d; public left: %d (the other user's two)", before, len(e.obj.public))
}
