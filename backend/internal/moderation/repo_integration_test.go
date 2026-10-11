//go:build integration

package moderation

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

func newTestClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int64()))
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

func counted() (context.Context, *budget.Counter) {
	return budget.WithCounter(context.Background())
}

func sampleReport(reporterID string, tt TargetType, target, owner string, at time.Time) Report {
	r := Report{
		ID: ReportID(reporterID, tt, target), ReporterID: reporterID, TargetType: tt, TargetID: target,
		TargetOwnerID: owner, Reason: ReasonSpam, Note: "n", Status: StatusOpen, CreatedAt: at.UTC(),
	}
	if tt == TargetPost {
		r.Evidence = &Evidence{Text: "evidence text", AuthorHandle: "bob", PostCreatedAt: at.UTC()}
	}
	return r
}

func quotaReports(t *testing.T, c *firestore.Client, uid string) int64 {
	t.Helper()
	snap, err := c.Collection("quotas").Doc(uid).Get(context.Background())
	if err != nil {
		return 0
	}
	n, _ := snap.DataAt("reports")
	v, _ := n.(int64)
	return v
}

func TestRepo_CreateBudgetsDuplicateAndQuota(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client, quota.New(client))
	now := time.Now()

	ctx, c := counted()
	res, err := repo.Create(ctx, CreateParams{Report: sampleReport("u-rep", TargetPost, pidN(1), "u-bob", now), QuotaLimit: 2})
	if err != nil || res.Existing {
		t.Fatalf("create: res=%+v err=%v", res, err)
	}
	budgettest.Assert(t, "Create", c, budgettest.Budget{Reads: 2, Writes: 2})
	if got := quotaReports(t, client, "u-rep"); got != 1 {
		t.Fatalf("quota reports = %d, want 1", got)
	}

	// A repeat: 1 read, 0 writes, not charged.
	ctx, c = counted()
	res, err = repo.Create(ctx, CreateParams{Report: sampleReport("u-rep", TargetPost, pidN(1), "u-bob", now), QuotaLimit: 2})
	if err != nil || !res.Existing {
		t.Fatalf("duplicate: res=%+v err=%v", res, err)
	}
	budgettest.Assert(t, "Create duplicate", c, budgettest.Budget{Reads: 1})
	if got := quotaReports(t, client, "u-rep"); got != 1 {
		t.Fatalf("quota after duplicate = %d, want 1", got)
	}

	// Second distinct target uses the last unit; the third is over the limit: 0 writes, no doc.
	if _, err := repo.Create(context.Background(), CreateParams{Report: sampleReport("u-rep", TargetAccount, "u-bob", "u-bob", now), QuotaLimit: 2}); err != nil {
		t.Fatal(err)
	}
	ctx, c = counted()
	third := sampleReport("u-rep", TargetPost, pidN(2), "u-bob", now)
	_, err = repo.Create(ctx, CreateParams{Report: third, QuotaLimit: 2})
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeResourceExhausted {
		t.Fatalf("over quota: err = %v", err)
	}
	budgettest.Assert(t, "Create over quota", c, budgettest.Budget{Reads: 2})
	if _, err := client.Collection("reports").Doc(third.ID).Get(context.Background()); err == nil {
		t.Fatal("report written past the quota")
	}
}

func TestOps_ListResolveAndRetention(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client, quota.New(client))
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	var ids []string
	for i := 0; i < 3; i++ {
		r := sampleReport(fmt.Sprintf("u-r%d", i), TargetPost, pidN(10), "u-bob", base.Add(time.Duration(i)*time.Hour))
		ids = append(ids, r.ID)
		if _, err := repo.Create(context.Background(), CreateParams{Report: r, QuotaLimit: 20}); err != nil {
			t.Fatal(err)
		}
	}

	ctx, c := counted()
	open, err := repo.List(ctx, StatusOpen, 2)
	if err != nil || len(open) != 2 || open[0].ID != ids[0] || open[1].ID != ids[1] {
		t.Fatalf("list = %+v err=%v, want the two oldest in order", open, err)
	}
	budgettest.Assert(t, "List 2", c, budgettest.Budget{Reads: 2})

	resolvedAt := base.Add(48 * time.Hour)
	ctx, c = counted()
	got, err := repo.Resolve(ctx, ids[0], ResolutionTakedown, "removed", resolvedAt)
	if err != nil || got.Status != StatusResolved || !got.ExpireAt.Equal(resolvedAt.Add(90*24*time.Hour)) {
		t.Fatalf("resolve = %+v err=%v", got, err)
	}
	budgettest.Assert(t, "Resolve", c, budgettest.Budget{Reads: 1, Writes: 1})

	// Stored TTL field is a timestamp 90 days after resolution (Firestore TTL deletes it).
	snap, err := client.Collection("reports").Doc(ids[0]).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	exp, err := snap.DataAt("expireAt")
	if err != nil {
		t.Fatalf("expireAt missing: %v", err)
	}
	if ts, ok := exp.(time.Time); !ok || !ts.Equal(resolvedAt.Add(90*24*time.Hour)) {
		t.Fatalf("expireAt = %v", exp)
	}
	// An OPEN report has no expireAt (never TTL-deleted).
	open1, _ := client.Collection("reports").Doc(ids[1]).Get(context.Background())
	if _, err := open1.DataAt("expireAt"); err == nil {
		t.Fatal("an open report must not carry expireAt")
	}

	// Resolving again: 1 read, 0 writes, unchanged.
	ctx, c = counted()
	again, err := repo.Resolve(ctx, ids[0], ResolutionDismissed, "later", resolvedAt.Add(time.Hour))
	if err != nil || again.Resolution != ResolutionTakedown {
		t.Fatalf("second resolve = %+v err=%v", again, err)
	}
	budgettest.Assert(t, "Resolve again", c, budgettest.Budget{Reads: 1})

	open, _ = repo.List(context.Background(), StatusOpen, 50)
	resolved, _ := repo.List(context.Background(), StatusResolved, 50)
	if len(open) != 2 || len(resolved) != 1 {
		t.Fatalf("open=%d resolved=%d", len(open), len(resolved))
	}
	if _, err := repo.Get(context.Background(), "nope"); err != ErrNotFound {
		t.Fatalf("Get missing = %v", err)
	}
}

func TestEraserAndExport_ReporterOnly(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client, quota.New(client))
	now := time.Now()
	for i := 0; i < 3; i++ {
		if _, err := repo.Create(context.Background(), CreateParams{Report: sampleReport("u-gone", TargetPost, pidN(20+i), "u-bob", now), QuotaLimit: 20}); err != nil {
			t.Fatal(err)
		}
	}
	// A report ABOUT u-gone by someone else, and an unrelated report by u-other.
	about := sampleReport("u-other", TargetAccount, "u-gone", "u-gone", now)
	if _, err := repo.Create(context.Background(), CreateParams{Report: about, QuotaLimit: 20}); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	if err := repo.ExportUser(context.Background(), "u-gone", &buf); err != nil {
		t.Fatal(err)
	}
	var exp struct {
		UserID  string           `json:"userId"`
		Reports []map[string]any `json:"reports"`
	}
	if err := json.Unmarshal(buf.Bytes(), &exp); err != nil || exp.UserID != "u-gone" || len(exp.Reports) != 3 {
		t.Fatalf("export = %s err=%v", buf.String(), err)
	}
	for _, r := range exp.Reports {
		if _, leaks := r["evidence"]; leaks || r["reporterId"] != nil {
			t.Errorf("export entry carries evidence or reporterId: %v", r)
		}
	}

	ctx, c := counted()
	next, done, err := repo.PurgeReporter(ctx, "u-gone", Checkpoint{})
	if err != nil || !done || next.Cleared != 3 {
		t.Fatalf("purge: next=%+v done=%v err=%v", next, done, err)
	}
	budgettest.Assert(t, "PurgeReporter", c, budgettest.Budget{Reads: 3, Writes: 3})

	// Idempotent / resumable: a second call finds nothing and writes nothing.
	ctx, c = counted()
	_, done, err = repo.PurgeReporter(ctx, "u-gone", next)
	if err != nil || !done {
		t.Fatalf("second purge: done=%v err=%v", done, err)
	}
	budgettest.Assert(t, "PurgeReporter replay", c, budgettest.Budget{Reads: 1})

	// The reports stay (evidence), anonymised; the report about u-gone is retained untouched.
	for i := 0; i < 3; i++ {
		got, err := repo.Get(context.Background(), ReportID("u-gone", TargetPost, pidN(20+i)))
		if err != nil || got.ReporterID != "" || got.Evidence == nil {
			t.Fatalf("anonymised report = %+v err=%v", got, err)
		}
	}
	kept, err := repo.Get(context.Background(), about.ID)
	if err != nil || kept.ReporterID != "u-other" || kept.TargetOwnerID != "u-gone" {
		t.Fatalf("report about the user = %+v err=%v", kept, err)
	}
	buf.Reset()
	if err := repo.ExportUser(context.Background(), "u-gone", &buf); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(buf.Bytes(), &exp); err != nil || len(exp.Reports) != 0 {
		t.Fatalf("export after purge = %s", buf.String())
	}
}

// TestReportContent_EndToEndBudgetsAndHiddenTargets drives the real moderation.Service over real posts and
// identity services (cold instance) and pins the ReportContent budget, then proves a taken-down post is the same
// NOT_FOUND as a missing one.
func TestReportContent_EndToEndBudgetsAndHiddenTargets(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	identityRepo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)
	graphSvc := graph.New(graph.Deps{Repo: graphRepo, Cache: graph.NewCache(time.Minute), Flags: allOn{}, NewAccountWindow: time.Nanosecond})
	idSvc := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour)
	graphSvc.SetDirectory(idSvc.(identity.Directory))
	for uid, h := range map[string]string{"uid-alice": "alice", "uid-bob": "bob"} {
		if _, err := idSvc.CreateProfile(context.Background(), uid, "0123456789abcdef", h, "N"); err != nil {
			t.Fatal(err)
		}
	}
	postsRepo := posts.NewFirestoreRepo(client)
	postID := pidN(777)
	if _, err := client.Collection("posts").Doc(postID).Set(context.Background(), map[string]any{
		"authorId": "uid-bob", "author": map[string]any{"userId": "uid-bob", "handle": "bob", "displayName": "N"},
		"kind": "POST", "isReply": false, "text": "report me", "conversationId": postID, "hashtags": []string{},
		"visibility": "PUBLIC", "createdAt": time.Now().Add(-time.Hour).UTC(),
	}); err != nil {
		t.Fatal(err)
	}

	// A cold instance every time: new caches over the same data.
	newSvc := func() Service {
		g := graph.New(graph.Deps{Repo: graphRepo, Cache: graph.NewCache(time.Minute), Flags: allOn{}, NewAccountWindow: time.Nanosecond})
		i := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour)
		g.SetDirectory(i.(identity.Directory))
		ps := posts.New(posts.Deps{Repo: postsRepo, Cache: posts.NewCache(time.Minute, 0, 0), Directory: i.(identity.Directory), Graph: g,
			PostsPerDay: 100, NewAccountPostsPerDay: 20, NewAccountWindow: time.Nanosecond})
		return New(Deps{
			Repo: NewFirestoreRepo(client, quota.New(client)), Posts: ps.(PostViewer), Accounts: i, Directory: i.(identity.Directory),
			ReportsPerDay: 20, NewAccountReportsPerDay: 5, NewAccountWindow: time.Nanosecond,
		})
	}
	claims := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-alice", SignInProvider: authn.SignInProviderGoogle})
	in := ReportInput{IdempotencyKey: "0123456789abcdef", TargetType: TargetPost, TargetID: postID, Reason: ReasonHarassment, Note: "rude"}

	ctx, c := budget.WithCounter(claims)
	res, err := newSvc().Report(ctx, "uid-alice", in)
	if err != nil || res.AlreadyReported {
		t.Fatalf("report: res=%+v err=%v", res, err)
	}
	// ADR-0016 cost line: reporter users 1, post 1, author 1, caller graph 1, report doc 1, quotas 1 (cold) = 6; writes 2.
	budgettest.Assert(t, "ReportContent cold", c, budgettest.Budget{Reads: 6, Writes: 2})

	ctx, c = budget.WithCounter(claims)
	res, err = newSvc().Report(ctx, "uid-alice", in)
	if err != nil || !res.AlreadyReported {
		t.Fatalf("duplicate: res=%+v err=%v", res, err)
	}
	budgettest.Assert(t, "ReportContent duplicate", c, budgettest.Budget{Reads: 6})

	// The reporter's identity is not part of what the reported user can see: the stored doc keeps it, the RPC
	// response carries only report_id/already_reported (type-checked by ReportResult).
	stored, err := NewFirestoreRepo(client, nil).Get(context.Background(), res.ReportID)
	if err != nil || stored.Evidence == nil || stored.Evidence.Text != "report me" || stored.TargetOwnerID != "uid-bob" {
		t.Fatalf("stored = %+v err=%v", stored, err)
	}

	// Takedown: a different reporter now gets the same NOT_FOUND as for a missing post, 0 report writes.
	if _, err := idSvc.CreateProfile(context.Background(), "uid-carol", "0123456789abcdef", "carol", "N"); err != nil {
		t.Fatal(err)
	}
	if _, err := postsRepo.Takedown(context.Background(), postID, time.Now()); err != nil {
		t.Fatal(err)
	}
	carol := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-carol", SignInProvider: authn.SignInProviderGoogle})
	_, hiddenErr := newSvc().Report(carol, "uid-carol", in)
	missing := in
	missing.TargetID = pidN(778)
	_, missingErr := newSvc().Report(carol, "uid-carol", missing)
	if hiddenErr == nil || missingErr == nil || hiddenErr.Error() != missingErr.Error() {
		t.Fatalf("hidden = %v, missing = %v: must be the same answer", hiddenErr, missingErr)
	}
	if _, err := client.Collection("reports").Doc(ReportID("uid-carol", TargetPost, postID)).Get(context.Background()); err == nil {
		t.Fatal("a report was written for a hidden post")
	}
}

type allOn struct{}

func (allOn) Enabled(string, string) bool { return true }

func pidN(n int) string { return fmt.Sprintf("%019d", n) }
