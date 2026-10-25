//go:build integration

package posts

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

func errAborted() error { return status.Error(codes.Aborted, "simulated lock conflict") }
func errAlreadyExists() error {
	return status.Error(codes.AlreadyExists, "simulated post id collision")
}

// assertTerminal checks a scheduled doc moved to a terminal state in its single write: the status, the failure reason,
// the cleared draft, and the TTL deadline.
func (e *sweepIT) assertTerminal(it *ScheduledPost, status ScheduledStatus, failure ScheduledFailure) {
	e.t.Helper()
	doc := e.raw(it)
	if doc["status"] != string(status) || doc["draft"] != nil || doc["expireAt"] == nil || doc["postId"] != nil {
		e.t.Errorf("scheduled doc = %v, want %s with the draft cleared and an expireAt", doc, status)
	}
	if got, _ := doc["failure"].(string); got != string(failure) {
		e.t.Errorf("failure = %q, want %q", got, failure)
	}
	if doc["attempts"] != int64(0) {
		e.t.Errorf("attempts = %v, want 0: a permanent outcome is not a transient failure", doc["attempts"])
	}
}

func (e *sweepIT) assertNothingPublished(uid string) {
	e.t.Helper()
	if n := len(e.postsOf(uid)); n != 0 {
		e.t.Errorf("%s has %d posts, want 0", uid, n)
	}
	if e.userExists(uid) && e.postsCount(uid) != 0 {
		e.t.Errorf("%s postsCount = %d, want 0", uid, e.postsCount(uid))
	}
	if e.quotaPosts(uid) != 0 {
		e.t.Errorf("%s quota posts = %d, want 0", uid, e.quotaPosts(uid))
	}
}

func (e *sweepIT) userExists(uid string) bool {
	snap, err := e.client.Collection("users").Doc(uid).Get(context.Background())
	return err == nil && snap.Exists()
}

// TestSweepIT_FailuresCommitInsteadOfRollingBack: every permanent cause found inside the publish transaction stages the
// item's one terminal transition and COMMITS: exactly 1 write, the reads up to that check, and no post, no counter, no
// quota and no media attach.
func TestSweepIT_FailuresCommitInsteadOfRollingBack(t *testing.T) {
	const alice = "uid-alice"
	mediaDraft := func(p *ScheduledPost) {
		p.Draft = &ScheduledDraft{Text: "with image", Media: []MediaRef{{ID: sweepMediaID(1)}}}
	}
	tests := []struct {
		name    string
		prepare func(e *sweepIT)
		mutate  func(p *ScheduledPost)
		status  ScheduledStatus
		failure ScheduledFailure
		reads   int64 // the run's: the due query's 1 plus the transaction's reads up to the failing check
		// loads is how many times the media were read: only the media failures reach them.
		loads int
	}{
		{"SUSPENDED fails ACCOUNT_RESTRICTED", func(e *sweepIT) { e.setUserField(alice, "status", "SUSPENDED") }, mediaDraft, ScheduledFailed, FailureAccountRestricted, 1 + 2, 0},
		{"an unknown status never publishes", func(e *sweepIT) { e.setUserField(alice, "status", "WEIRD") }, nil, ScheduledFailed, FailureAccountRestricted, 1 + 2, 0},
		{"DELETING cancels", func(e *sweepIT) { e.setUserField(alice, "status", "DELETING") }, mediaDraft, ScheduledCancelled, "", 1 + 2, 0},
		{"a missing users doc cancels", func(e *sweepIT) {
			if _, err := e.client.Collection("users").Doc(alice).Delete(context.Background()); err != nil {
				t.Fatal(err)
			}
		}, mediaDraft, ScheduledCancelled, "", 1 + 2, 0},
		{"an image attached elsewhere fails MEDIA_UNAVAILABLE", func(e *sweepIT) {
			e.seedMedia(alice, map[string]any{"postId": "1111111111111111111"}, 1)
		}, mediaDraft, ScheduledFailed, FailureMediaUnavailable, 1 + 4, 1},
		{"an image owned by someone else", func(e *sweepIT) { e.seedMedia("uid-mallory", nil, 1) }, mediaDraft, ScheduledFailed, FailureMediaUnavailable, 1 + 4, 1},
		{"an image that is gone", func(*sweepIT) {}, mediaDraft, ScheduledFailed, FailureMediaUnavailable, 1 + 4, 1},
		{"an image that is not READY", func(e *sweepIT) { e.seedMedia(alice, map[string]any{"status": "PENDING"}, 1) }, mediaDraft, ScheduledFailed, FailureMediaUnavailable, 1 + 4, 1},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newSweepIT(t)
			e.signUp(alice, "alice")
			tc.prepare(e)
			var muts []func(*ScheduledPost)
			if tc.mutate != nil {
				muts = append(muts, tc.mutate)
			}
			it := e.seedDue(alice, 1, muts...)

			res, c := e.sweep()
			if res.Transient != 0 || res.Published != 0 || res.Noop != 0 {
				t.Fatalf("res = %+v", res)
			}
			if tc.status == ScheduledCancelled && res.Cancelled != 1 || tc.status == ScheduledFailed && res.Failed[tc.failure] != 1 {
				t.Errorf("res = %+v, want %s %s counted once", res, tc.status, tc.failure)
			}
			assertCost(t, tc.name, c, tc.reads, 1)
			e.assertTerminal(it, tc.status, tc.failure)
			e.assertNothingPublished(alice)
			if got := e.media.loadCount(); got != tc.loads {
				t.Errorf("media loads = %d, want %d", got, tc.loads)
			}
			if snap, err := e.client.Collection("media").Doc(sweepMediaID(1)).Get(context.Background()); err == nil {
				if pid, _ := snap.Data()["postId"].(string); pid != "" && pid != "1111111111111111111" {
					t.Errorf("media attached to %q by a failed publish", pid)
				}
			}
		})
	}
}

// TestSweepIT_QuotaExhaustedFailsBeforeAnyMediaOrHandleRead: the posts quota is checked right after the account, so an
// item bound to fail costs 3 reads, not 17 (review L-4). The account tier comes from the profile read INSIDE the
// transaction, not from the cached directory.
func TestSweepIT_QuotaExhaustedFailsBeforeAnyMediaOrHandleRead(t *testing.T) {
	setQuota := func(e *sweepIT, uid string, posts int64) {
		if _, err := e.client.Collection("quotas").Doc(uid).Set(context.Background(), quota.Record{Day: quota.Today(), Posts: posts}); err != nil {
			t.Fatal(err)
		}
	}
	// The draft names 2 images and 10 handles: none of them may be read.
	heavy := func(e *sweepIT) func(*ScheduledPost) {
		text := e.signUpFriends(10)
		e.seedMedia("uid-alice", nil, 1, 2)
		return func(p *ScheduledPost) {
			p.Draft = &ScheduledDraft{Text: text, Media: []MediaRef{{ID: sweepMediaID(1)}, {ID: sweepMediaID(2)}}}
		}
	}

	t.Run("a new account is held to the new-account limit", func(t *testing.T) {
		e := newSweepIT(t, func(d *Deps) { d.NewAccountPostsPerDay = 1 })
		e.signUp("uid-alice", "alice")
		it := e.seedDue("uid-alice", 1, heavy(e))
		setQuota(e, "uid-alice", 1)

		res, c := e.sweep()
		if res.Failed[FailureQuotaExceeded] != 1 || res.Published != 0 {
			t.Fatalf("res = %+v", res)
		}
		// due query 1 + scheduled 1 + users 1 + quotas 1; nothing else was read, one write (the scheduled doc).
		assertCost(t, "quota exceeded", c, 1+3, 1)
		if got := e.media.loadCount(); got != 0 {
			t.Errorf("the media were read %d time(s) for an item over its quota", got)
		}
		e.assertTerminal(it, ScheduledFailed, FailureQuotaExceeded)
		if e.quotaPosts("uid-alice") != 1 || e.postsCount("uid-alice") != 0 {
			t.Errorf("quota posts %d (want the untouched 1), postsCount %d (want 0)", e.quotaPosts("uid-alice"), e.postsCount("uid-alice"))
		}
	})
	t.Run("an established account has the higher limit (createdAt read in the transaction)", func(t *testing.T) {
		e := newSweepIT(t, func(d *Deps) { d.NewAccountPostsPerDay = 1 })
		e.signUp("uid-alice", "alice")
		e.setUserField("uid-alice", "createdAt", time.Now().Add(-72*time.Hour).UTC())
		e.seedDue("uid-alice", 1)
		setQuota(e, "uid-alice", 1)

		res, _ := e.sweep()
		if res.Published != 1 || e.quotaPosts("uid-alice") != 2 {
			t.Fatalf("res = %+v quota posts = %d, want published and the quota at 2", res, e.quotaPosts("uid-alice"))
		}
	})
	t.Run("one below the limit still publishes, and reaches it", func(t *testing.T) {
		e := newSweepIT(t, func(d *Deps) { d.NewAccountPostsPerDay = 2 })
		e.signUp("uid-alice", "alice")
		e.seedDue("uid-alice", 1)
		setQuota(e, "uid-alice", 1)
		res, _ := e.sweep()
		if res.Published != 1 || e.quotaPosts("uid-alice") != 2 {
			t.Fatalf("res = %+v quota = %d", res, e.quotaPosts("uid-alice"))
		}
	})
	t.Run("yesterday's counter does not count (the IST day reset)", func(t *testing.T) {
		e := newSweepIT(t, func(d *Deps) { d.NewAccountPostsPerDay = 1 })
		e.signUp("uid-alice", "alice")
		e.seedDue("uid-alice", 1)
		if _, err := e.client.Collection("quotas").Doc("uid-alice").Set(context.Background(), quota.Record{Day: "2001-01-01", Posts: 50}); err != nil {
			t.Fatal(err)
		}
		res, _ := e.sweep()
		if res.Published != 1 || e.quotaPosts("uid-alice") != 1 {
			t.Fatalf("res = %+v quota = %d, want published against a fresh day", res, e.quotaPosts("uid-alice"))
		}
	})
}

func TestSweepIT_ReadyUnscreenedImagesPublish(t *testing.T) {
	e := newSweepIT(t)
	e.signUp("uid-alice", "alice")
	e.seedMedia("uid-alice", map[string]any{"status": "READY_UNSCREENED"}, 1)
	e.seedDue("uid-alice", 1, func(p *ScheduledPost) {
		p.Draft = &ScheduledDraft{Text: "unscreened", Media: []MediaRef{{ID: sweepMediaID(1)}}}
	})
	if res, _ := e.sweep(); res.Published != 1 {
		t.Fatalf("res = %+v, want published (ADR-0005 READY_UNSCREENED handling is kept)", res)
	}
}

// TestSweepIT_ChecksOutsideTheTransactionCostNothingToRead: expiry, UNSUPPORTED and INVALID_CONTENT are decided from the
// query's snapshot: the run's only read is the query, its only write the precondition update. No users doc is needed.
func TestSweepIT_ChecksOutsideTheTransactionCostNothingToRead(t *testing.T) {
	tests := []struct {
		name   string
		mut    func(p *ScheduledPost)
		reason ScheduledFailure
	}{
		{"expired", func(p *ScheduledPost) { p.PublishAt = time.Now().Add(-7 * time.Hour) }, FailureExpired},
		{"unsupported schema", func(p *ScheduledPost) { p.SchemaVersion = 2 }, FailureUnsupported},
		{"text that no longer parses", func(p *ScheduledPost) { p.Draft.Text = "bad\x00text" }, FailureInvalidContent},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newSweepIT(t)
			it := e.seedDue("uid-ghost", 1, tc.mut) // no users/uid-ghost: nothing may read it
			res, c := e.sweep()
			if res.Failed[tc.reason] != 1 {
				t.Fatalf("res = %+v, want FAILED %s", res, tc.reason)
			}
			assertCost(t, tc.name, c, 1, 1)
			e.assertTerminal(it, ScheduledFailed, tc.reason)
		})
	}
}

// TestSweepIT_TransientFailuresCountAttemptsThenRetire: a transaction error that is not a permanent cause bumps
// `attempts` (a precondition update) in runs 1 and 2, and the third run retires the item FAILED INTERNAL and reports it.
// Firestore's error text names a document path; none of it reaches the logs.
func TestSweepIT_TransientFailuresCountAttemptsThenRetire(t *testing.T) {
	e := newSweepIT(t)
	e.signUp("uid-alice", "alice")
	it := e.seedDue("uid-alice", 1)
	e.repo.attemptHook = func(int, string) error {
		return status.Error(codes.Unavailable, "backend overloaded on documents/users/uid-alice/scheduled/"+it.ID)
	}

	for run := 1; run <= 2; run++ {
		res, _ := e.sweep()
		doc := e.raw(it)
		if res.Transient != 1 || doc["status"] != "PENDING" || doc["attempts"] != int64(run) || doc["draft"] == nil {
			t.Fatalf("run %d: res = %+v doc = %v, want PENDING with attempts %d and the draft kept", run, res, doc, run)
		}
	}
	if len(e.logs.lines("ReportedErrorEvent")) != 0 {
		t.Error("an Error Reporting entry was raised before the last attempt")
	}
	res, _ := e.sweep()
	if res.Transient != 1 || res.Failed[FailureInternal] != 1 {
		t.Fatalf("third run: res = %+v, want FAILED INTERNAL", res)
	}
	doc := e.raw(it)
	if doc["status"] != "FAILED" || doc["failure"] != "INTERNAL" || doc["draft"] != nil || doc["attempts"] != int64(2) {
		t.Errorf("doc = %v", doc)
	}
	if len(e.logs.lines("ReportedErrorEvent")) != 1 {
		t.Errorf("want exactly one Error Reporting entry:\n%s", e.logs.String())
	}
	if out := e.logs.String(); strings.Contains(out, "uid-alice") || strings.Contains(out, "documents/users") {
		t.Errorf("a uid or document path reached the logs:\n%s", out)
	}
	e.assertNothingPublished("uid-alice")
}

// TestSweepIT_PanicInsideTheTransactionCallback (review M-2): the media attacher panics INSIDE the publish transaction.
// The callback's recover turns it into an error, so the client rolls the transaction back (it holds no lock afterwards),
// the item is FAILED INTERNAL in this run (attempts untouched), the process survives and the OTHER author publishes.
func TestSweepIT_PanicInsideTheTransactionCallback(t *testing.T) {
	e := newSweepIT(t)
	e.signUp("uid-alice", "alice")
	e.signUp("uid-bob", "bob")
	e.seedMedia("uid-alice", nil, 1)
	poison := e.seedDue("uid-alice", 1, func(p *ScheduledPost) {
		p.Draft = &ScheduledDraft{Text: "poison", Media: []MediaRef{{ID: sweepMediaID(1)}}}
	})
	fine := e.seedDue("uid-bob", 2)
	e.media.panicOnLoad = true

	res, _ := e.sweep() // must not panic
	if res.Published != 1 || res.Failed[FailureInternal] != 1 || res.Transient != 0 {
		t.Fatalf("res = %+v, want bob published and alice FAILED INTERNAL (not transient)", res)
	}
	e.assertTerminal(poison, ScheduledFailed, FailureInternal)
	if got := e.raw(fine)["status"]; got != "PUBLISHED" {
		t.Errorf("the other author's item = %v, want PUBLISHED", got)
	}
	e.assertNothingPublished("uid-alice")
	out := e.logs.String()
	if reports := e.logs.lines("ReportedErrorEvent"); len(reports) != 1 || !strings.Contains(reports[0], "panic of type string") || strings.Contains(out, "attacher exploded") {
		t.Errorf("want one report naming only the panic type:\n%s", out)
	}

	// The rolled-back transaction holds no lock on the author's docs: a write to them completes at once.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := e.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		if _, err := tx.Get(e.client.Collection("users").Doc("uid-alice")); err != nil {
			return err
		}
		return tx.Update(e.client.Collection("users").Doc("uid-alice"), []firestore.Update{{Path: "bio", Value: "free"}})
	})
	if err != nil {
		t.Errorf("a transaction on the author's user doc did not complete after the panic: %v", err)
	}
}

// TestSweepIT_PanicOutsideTheCallbackIsRecoveredPerItem: the second recover site, around each item in its worker. The
// panicking item is FAILED INTERNAL, the same author's NEXT item and every other author still publish.
func TestSweepIT_PanicOutsideTheCallbackIsRecoveredPerItem(t *testing.T) {
	e := newSweepIT(t)
	e.signUp("uid-alice", "alice")
	e.signUp("uid-bob", "bob")
	poison := e.seedDue("uid-alice", 1)
	next := e.seedDue("uid-alice", 2)
	other := e.seedDue("uid-bob", 3)
	e.fault.publishPanic = func(p PublishParams) any {
		if p.ID == poison.ID {
			return "worker exploded for uid-alice"
		}
		return nil
	}

	res, _ := e.sweep()
	if res.Published != 2 || res.Failed[FailureInternal] != 1 {
		t.Fatalf("res = %+v, want 2 published and 1 FAILED INTERNAL", res)
	}
	e.assertTerminal(poison, ScheduledFailed, FailureInternal)
	for _, it := range []*ScheduledPost{next, other} {
		if got := e.raw(it)["status"]; got != "PUBLISHED" {
			t.Errorf("item of %s = %v, want PUBLISHED", it.UID, got)
		}
	}
	if out := e.logs.String(); !strings.Contains(out, "panic of type string") || strings.Contains(out, "worker exploded") {
		t.Errorf("only the panic type may be logged:\n%s", out)
	}
}

// TestSweepIT_WriteAfterTheEraserRecreatesNothing (review L-7): the account eraser deletes the scheduled docs between
// the query and the sweep's writes. A precondition update on a missing doc fails (never Set, never a merge), and the
// publish transaction finds no doc, so nothing is recreated and nothing is published.
func TestSweepIT_WriteAfterTheEraserRecreatesNothing(t *testing.T) {
	e := newSweepIT(t)
	e.signUp("uid-alice", "alice")
	expired := e.seedDue("uid-alice", 1, func(p *ScheduledPost) { p.PublishAt = time.Now().Add(-7 * time.Hour) }) // written outside the txn
	fresh := e.seedDue("uid-alice", 2)                                                                            // goes through the publish txn
	e.fault.afterDue = func() {
		if n, err := e.repo.PurgeScheduledPage(context.Background(), "uid-alice"); err != nil || n != 2 {
			t.Errorf("eraser deleted %d docs, err %v, want 2", n, err)
		}
	}

	res, c := e.sweep()
	if res.Noop != 2 || res.Published != 0 || len(res.Failed) != 0 || res.WriteFailed != 0 {
		t.Fatalf("res = %+v, want both items a quiet no-op", res)
	}
	if e.exists(expired) || e.exists(fresh) {
		t.Fatal("a sweep write recreated a scheduled doc the eraser deleted")
	}
	// The query 2, the eraser's deletes are not reads; the publish transaction read the (missing) scheduled doc once.
	if c.Writes() != 0 {
		t.Errorf("writes = %d, want 0", c.Writes())
	}
	e.assertNothingPublished("uid-alice")
}

// TestSweepIT_StatusChangeBetweenTheQueryAndTheTransaction (review L-7): the account is suspended or starts deleting after
// the query read it. The status is read INSIDE the transaction, uncached, so the publish sees it: no post, and the item
// is FAILED ACCOUNT_RESTRICTED or CANCELLED. A design reading the cached directory profile would publish.
func TestSweepIT_StatusChangeBetweenTheQueryAndTheTransaction(t *testing.T) {
	for _, tc := range []struct {
		name    string
		status  string
		want    ScheduledStatus
		failure ScheduledFailure
	}{
		{"suspended", "SUSPENDED", ScheduledFailed, FailureAccountRestricted},
		{"deleting", "DELETING", ScheduledCancelled, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newSweepIT(t)
			e.signUp("uid-alice", "alice")
			// Warm the cached directory with ACTIVE, exactly what the account-status interceptor would have done.
			if got, err := e.dir.GetProfiles(context.Background(), []string{"uid-alice"}); err != nil || len(got) != 1 {
				t.Fatalf("warm cache: %v %v", got, err)
			}
			it := e.seedDue("uid-alice", 1)
			e.fault.beforePublish = func(PublishParams) { e.setUserField("uid-alice", "status", tc.status) }

			res, _ := e.sweep()
			if tc.want == ScheduledFailed && res.Failed[tc.failure] != 1 || tc.want == ScheduledCancelled && res.Cancelled != 1 {
				t.Fatalf("res = %+v", res)
			}
			e.assertTerminal(it, tc.want, tc.failure)
			e.assertNothingPublished("uid-alice")
		})
	}
}

// TestSweepIT_PathShapeFilter (review L-7): the collection-group query matches any collection named `scheduled`. Results
// that are not exactly users/{uid}/scheduled/{32 hex} are skipped, counted, and never processed or written.
func TestSweepIT_PathShapeFilter(t *testing.T) {
	e := newSweepIT(t)
	e.signUp("uid-alice", "alice")
	good := e.seedDue("uid-alice", 1)

	stray := toScheduledDoc(&ScheduledPost{
		SchemaVersion: 1, Draft: &ScheduledDraft{Text: "not ours"}, PublishAt: time.Now().Add(-time.Hour), Status: ScheduledPending,
		CreatedAt: time.Now(), UpdatedAt: time.Now(),
	})
	hex32 := strings.Repeat("ab", 16)
	for _, ref := range []*firestore.DocumentRef{
		e.client.Collection("teams").Doc("t1").Collection("scheduled").Doc(hex32),                                     // another top-level collection
		e.client.Collection("users").Doc("uid-alice").Collection("other").Doc("x").Collection("scheduled").Doc(hex32), // deeper
		e.client.Collection("users").Doc("uid-alice").Collection("scheduled").Doc("not-a-32-hex-id"),                  // bad id
		e.client.Collection("users").Doc("uid_with_underscore").Collection("scheduled").Doc(hex32),                    // bad uid
	} {
		if _, err := ref.Set(context.Background(), stray); err != nil {
			t.Fatal(err)
		}
	}

	res, c := e.sweep()
	if res.SkippedBadPath != 4 || res.Due != 1 || res.Published != 1 {
		t.Fatalf("res = %+v, want 4 skipped and the one good item published", res)
	}
	// They are billed as reads by the query, every run (the line alerts on them).
	if c.Reads() < 5 {
		t.Errorf("reads = %d, want the 5 query results counted", c.Reads())
	}
	if got := e.raw(good)["status"]; got != "PUBLISHED" {
		t.Errorf("good item = %v", got)
	}
	snap, err := e.client.Collection("teams").Doc("t1").Collection("scheduled").Doc(hex32).Get(context.Background())
	if err != nil || snap.Data()["status"] != "PENDING" {
		t.Errorf("a stray doc was written: %v %v", snap, err)
	}
}

// TestSweepIT_ManyAuthorsAllPublish runs more authors than workers: every item publishes, no author's items overlap.
func TestSweepIT_ManyAuthorsAllPublish(t *testing.T) {
	e := newSweepIT(t, func(d *Deps) { d.Sweep.Limits.Concurrency = 2 })
	const authors = 6
	for a := 0; a < authors; a++ {
		uid := fmt.Sprintf("uid-m%d", a)
		e.signUp(uid, fmt.Sprintf("many%d", a))
		e.seedDue(uid, a*10+1)
		e.seedDue(uid, a*10+2)
	}
	res, _ := e.sweep()
	if res.Published != authors*2 || res.Transient != 0 {
		t.Fatalf("res = %+v, want %d published", res, authors*2)
	}
	for uid, n := range e.fault.maxInflightBy {
		if n != 1 {
			t.Errorf("%s had %d items in flight", uid, n)
		}
	}
}
