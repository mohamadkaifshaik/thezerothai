package identity

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	fbauth "firebase.google.com/go/v4/auth"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

const (
	expKey1 = "export-key-000001"
	expKey2 = "export-key-000002"
)

func expID(uid, key string) string { return idempotency.Key(uid, exportRPC, key) }

func apiErr(t *testing.T, err error) *apierr.Error {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want *apierr.Error", err)
	}
	return ae
}

func TestRequestAccountExport(t *testing.T) {
	t.Run("first request: PENDING, 2 writes, 1 read (quotas), one publish", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		v, err := h.l.RequestAccountExport(context.Background(), "u1", expKey1)
		if err != nil {
			t.Fatal(err)
		}
		if v.ID != expID("u1", expKey1) || v.Status != ExportPending || v.DownloadURL != "" {
			t.Errorf("view = %+v", v)
		}
		if h.repo.reads != 1 || h.repo.writes != 2 {
			t.Errorf("reads/writes = %d/%d, want 1/2 (the interceptor's read comes on top: proto 2/1 and 2 writes)", h.repo.reads, h.repo.writes)
		}
		want := JobMessage{Kind: JobKindAccountExport, ExportID: v.ID}
		if h.pub.count() != 1 || h.pub.msgs[0] != want {
			t.Errorf("published %+v, want %+v", h.pub.msgs, want)
		}
		doc := h.repo.exports[v.ID]
		if doc.UID != "u1" || doc.ObjectPath != v.ID+".json" || !doc.ExpireAt.Equal(doc.CreatedAt.Add(7*24*time.Hour)) {
			t.Errorf("doc = %+v", doc)
		}
	})
	t.Run("replay within 2 minutes does not re-publish (L-4)", func(t *testing.T) {
		h := newHarness(t)
		first, _ := h.l.RequestAccountExport(context.Background(), "u1", expKey1)
		for range 5 {
			h.clock.Advance(20 * time.Second) // 100 s in total, still under 2 minutes
			if _, err := h.l.RequestAccountExport(context.Background(), "u1", expKey1); err != nil {
				t.Fatal(err)
			}
		}
		if h.pub.count() != 1 {
			t.Errorf("publishes = %d, want 1: replays inside the window must not re-publish", h.pub.count())
		}
		if h.repo.exports[first.ID].Status != ExportPending {
			t.Error("status changed")
		}
	})
	t.Run("replay with the same key: same id, 0 writes, 2 reads, a PENDING one older than 2 minutes re-publishes", func(t *testing.T) {
		h := newHarness(t)
		first, _ := h.l.RequestAccountExport(context.Background(), "u1", expKey1)
		h.clock.Advance(exportRepublishAfter)
		reads, writes := h.repo.reads, h.repo.writes
		again, err := h.l.RequestAccountExport(context.Background(), "u1", expKey1)
		if err != nil || again.ID != first.ID {
			t.Fatalf("replay = %+v, %v", again, err)
		}
		if h.repo.writes != writes || h.repo.reads != reads+2 {
			t.Errorf("replay reads/writes = +%d/+%d, want +2/+0 (proto: replay 3 with the interceptor)", h.repo.reads-reads, h.repo.writes-writes)
		}
		if h.pub.count() != 2 {
			t.Errorf("publishes = %d, want 2 (a PENDING replay recovers a lost publish)", h.pub.count())
		}
	})
	t.Run("replay of a READY export does not publish again", func(t *testing.T) {
		h := newHarness(t)
		first, _ := h.l.RequestAccountExport(context.Background(), "u1", expKey1)
		h.repo.exports[first.ID].Status = ExportReady
		n := h.pub.count()
		again, err := h.l.RequestAccountExport(context.Background(), "u1", expKey1)
		if err != nil || again.Status != ExportReady || h.pub.count() != n {
			t.Errorf("replay = %+v, %v, publishes %d -> %d", again, err, n, h.pub.count())
		}
	})
	t.Run("a second request with a new key the same day is QUOTA_EXCEEDED", func(t *testing.T) {
		h := newHarness(t)
		if _, err := h.l.RequestAccountExport(context.Background(), "u1", expKey1); err != nil {
			t.Fatal(err)
		}
		writes := h.repo.writes
		_, err := h.l.RequestAccountExport(context.Background(), "u1", expKey2)
		ae := apiErr(t, err)
		if ae.Code != connect.CodeResourceExhausted || ae.Reason != commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED || ae.Metadata["quota"] != "exports" {
			t.Errorf("err = %+v", ae)
		}
		if h.repo.writes != writes {
			t.Error("a rejected request wrote")
		}
	})
	t.Run("one user's key does not collide with another's", func(t *testing.T) {
		h := newHarness(t)
		a, _ := h.l.RequestAccountExport(context.Background(), "u1", expKey1)
		b, err := h.l.RequestAccountExport(context.Background(), "u2", expKey1)
		if err != nil || a.ID == b.ID {
			t.Errorf("ids %q %q err %v", a.ID, b.ID, err)
		}
	})
	t.Run("bad key, no bucket", func(t *testing.T) {
		h := newHarness(t)
		if _, err := h.l.RequestAccountExport(context.Background(), "u1", "x"); apiErr(t, err).Code != connect.CodeInvalidArgument {
			t.Error("bad key accepted")
		}
		h2 := newHarness(t, func(d *LifecycleDeps) { d.Objects = nil })
		_, err := h2.l.RequestAccountExport(context.Background(), "u1", expKey1)
		if apiErr(t, err).Code != connect.CodeUnavailable || h2.repo.writes != 0 {
			t.Errorf("no bucket: err = %v writes = %d", err, h2.repo.writes)
		}
	})
	t.Run("publish failure still succeeds", func(t *testing.T) {
		h := newHarness(t)
		h.pub.err = errors.New("down")
		if _, err := h.l.RequestAccountExport(context.Background(), "u1", expKey1); err != nil {
			t.Fatalf("err = %v", err)
		}
		if !strings.Contains(h.logs.String(), "account_export_enqueue_failed") {
			t.Error("no ERROR account_export_enqueue_failed")
		}
	})
	t.Run("repo failure is internal", func(t *testing.T) {
		h := newHarness(t)
		h.repo.failOnce["CreateExport"] = errors.New("boom secret-uid")
		_, err := h.l.RequestAccountExport(context.Background(), "secret-uid", expKey1)
		if err == nil || strings.Contains(err.Error(), "secret-uid") {
			t.Errorf("err = %v", err)
		}
	})
}

func TestGetAccountExport(t *testing.T) {
	newReady := func(h *harness) string {
		id := expID("u1", expKey1)
		now := h.clock.Now()
		h.repo.exports[id] = &ExportDoc{ID: id, UID: "u1", Status: ExportReady, ObjectPath: id + ".json", CreatedAt: now, ExpireAt: now.Add(7 * 24 * time.Hour), UpdateTime: utOf(1)}
		return id
	}

	t.Run("READY: a fresh 15-minute URL per call and expires_at", func(t *testing.T) {
		h := newHarness(t)
		id := newReady(h)
		v, err := h.l.GetAccountExport(context.Background(), "u1", id)
		if err != nil {
			t.Fatal(err)
		}
		now := h.clock.Now().UTC()
		if v.Status != ExportReady || !strings.HasPrefix(v.DownloadURL, "https://signed.example/"+id+".json") || !v.URLExpiresAt.Equal(now.Add(15*time.Minute)) || !v.ExpiresAt.Equal(now.Add(7*24*time.Hour)) {
			t.Errorf("view = %+v", v)
		}
		if h.repo.reads != 1 || h.repo.writes != 0 {
			t.Errorf("reads/writes = %d/%d, want 1/0", h.repo.reads, h.repo.writes)
		}
		h.clock.Advance(time.Minute)
		v2, _ := h.l.GetAccountExport(context.Background(), "u1", id)
		if v2.DownloadURL == v.DownloadURL {
			t.Error("two calls returned the same URL; it must be signed per call")
		}
	})
	t.Run("PENDING and FAILED carry no URL", func(t *testing.T) {
		h := newHarness(t)
		id := newReady(h)
		for _, st := range []ExportStatus{ExportPending, ExportFailed} {
			h.repo.exports[id].Status = st
			v, err := h.l.GetAccountExport(context.Background(), "u1", id)
			if err != nil || v.Status != st || v.DownloadURL != "" || !v.URLExpiresAt.IsZero() {
				t.Errorf("%s: view = %+v, err = %v", st, v, err)
			}
		}
		if len(h.objs.signed) != 0 {
			t.Error("signed a URL for a non-READY export")
		}
	})
	t.Run("every NOT_FOUND is byte-identical (Q6)", func(t *testing.T) {
		h := newHarness(t)
		id := newReady(h)
		expired := expID("u1", expKey2)
		h.repo.exports[expired] = &ExportDoc{ID: expired, UID: "u1", Status: ExportReady, ObjectPath: expired + ".json", ExpireAt: h.clock.Now().Add(-time.Second)}
		atBoundary := expID("u1", "export-key-000003")
		h.repo.exports[atBoundary] = &ExportDoc{ID: atBoundary, UID: "u1", Status: ExportReady, ExpireAt: h.clock.Now()}
		cases := map[string]struct{ uid, id string }{
			"unknown id":                 {"u1", strings.Repeat("a", 64)},
			"another user's export":      {"u2", id},
			"malformed id":               {"u1", "not-hex"},
			"empty id":                   {"u1", ""},
			"path-ish id":                {"u1", "../" + id},
			"past expires_at, doc still": {"u1", expired},
			"exactly at expires_at":      {"u1", atBoundary},
		}
		var first *apierr.Error
		for name, c := range cases {
			_, err := h.l.GetAccountExport(context.Background(), c.uid, c.id)
			ae := apiErr(t, err)
			if ae.Code != connect.CodeNotFound {
				t.Errorf("%s: code = %v", name, ae.Code)
			}
			if first == nil {
				first = ae
			} else if ae.Message != first.Message || ae.Code != first.Code || ae.Reason != first.Reason || len(ae.Metadata) != len(first.Metadata) {
				t.Errorf("%s: %+v differs from %+v", name, ae, first)
			}
		}
		if len(h.objs.signed) != 0 {
			t.Error("a URL was signed for a request that is NOT_FOUND")
		}
	})
	t.Run("signing and repo failures are internal errors", func(t *testing.T) {
		h := newHarness(t)
		id := newReady(h)
		h.objs.signErr = errors.New("no signer")
		if _, err := h.l.GetAccountExport(context.Background(), "u1", id); err == nil {
			t.Error("sign error swallowed")
		}
		h.repo.failOnce["GetExport"] = errors.New("boom")
		if _, err := h.l.GetAccountExport(context.Background(), "u1", id); err == nil {
			t.Error("repo error swallowed")
		}
	})
}

// exportEnv is the parsed export file.
type exportEnv struct {
	ExportVersion int            `json:"exportVersion"`
	GeneratedAt   time.Time      `json:"generatedAt"`
	Account       map[string]any `json:"account"`
	Profile       map[string]any `json:"profile"`
	Raw           map[string]json.RawMessage
}

func parseExport(t *testing.T, raw []byte) exportEnv {
	t.Helper()
	var e exportEnv
	if err := json.Unmarshal(raw, &e); err != nil {
		t.Fatalf("export is not valid JSON: %v\n%s", err, raw)
	}
	if err := json.Unmarshal(raw, &e.Raw); err != nil {
		t.Fatal(err)
	}
	return e
}

func newPendingExport(h *harness, uid string) ExportDoc {
	now := h.clock.Now()
	id := expID(uid, expKey1)
	doc := ExportDoc{ID: id, UID: uid, Status: ExportPending, ObjectPath: id + ".json", CreatedAt: now, ExpireAt: now.Add(7 * 24 * time.Hour), UpdateTime: utOf(1)}
	h.repo.exports[id] = &doc
	return doc
}

func TestExportJob(t *testing.T) {
	t.Run("composes the envelope with every section and sets READY", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedActive("u1", "Alice")
		p.Bio, p.FollowersCount, p.SnapshotVersion = "hello", 3, 9
		h.repo.seed(p)
		h.auth.users["u1"] = &fbauth.UserRecord{
			UserInfo: &fbauth.UserInfo{UID: "u1", Email: "alice@example.com"}, EmailVerified: true,
			ProviderUserInfo: []*fbauth.UserInfo{{ProviderID: "google.com"}},
			UserMetadata:     &fbauth.UserMetadata{CreationTimestamp: 1_700_000_000_000},
		}
		_ = h.l.RegisterExportSection(fakeSection{name: "graph", json: `{"following":[{"userId":"u2","handle":"bob"}]}` + "\n"})
		_ = h.l.RegisterExportSection(fakeSection{name: "posts", json: `{"posts":[]}`})
		doc := newPendingExport(h, "u1")

		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusNoContent {
			t.Fatalf("status = %d", code)
		}
		raw, ok := h.objs.get(doc.ObjectPath)
		if !ok {
			t.Fatal("no object written")
		}
		e := parseExport(t, raw)
		if e.ExportVersion != 1 || !e.GeneratedAt.Equal(h.clock.Now().UTC()) {
			t.Errorf("envelope = %d %v", e.ExportVersion, e.GeneratedAt)
		}
		if e.Account["email"] != "alice@example.com" || e.Account["providers"].([]any)[0] != "google.com" {
			t.Errorf("account = %v", e.Account)
		}
		if e.Profile["handle"] != "Alice" || e.Profile["bio"] != "hello" || e.Profile["followersCount"] != float64(3) {
			t.Errorf("profile = %v", e.Profile)
		}
		for _, internal := range []string{"status", "snapshotVersion", "deletionJob", "deletionRequestedAt", "handleLower", "updatedAt"} {
			if _, has := e.Profile[internal]; has {
				t.Errorf("profile section leaks internal field %q", internal)
			}
		}
		keys := []string{"exportVersion", "generatedAt", "account", "profile", "graph", "posts"}
		for _, k := range keys {
			if _, has := e.Raw[k]; !has {
				t.Errorf("section %q missing from %s", k, raw)
			}
		}
		if len(e.Raw) != len(keys) {
			t.Errorf("unexpected keys: %v", e.Raw)
		}
		// Sections come in registration order after account and profile.
		order := []string{`"account"`, `"profile"`, `"graph"`, `"posts"`}
		last := -1
		for _, k := range order {
			i := strings.Index(string(raw), k)
			if i < last {
				t.Errorf("section %s out of order in %s", k, raw)
			}
			last = i
		}
		if h.repo.exports[doc.ID].Status != ExportReady {
			t.Errorf("status = %s, want READY", h.repo.exports[doc.ID].Status)
		}
		if h.repo.writes != 2 || h.log.count("repo.ClaimExport") != 1 {
			t.Errorf("writes = %d, want 2 (the lease claim, then the status)", h.repo.writes)
		}
		if h.log.count("auth.GetUser") != 1 {
			t.Errorf("GetUser calls = %d, want 1 (exportTarget from the exports doc)", h.log.count("auth.GetUser"))
		}
	})

	t.Run("a DELETING user gets FAILED and no object", func(t *testing.T) {
		h := newHarness(t)
		h.seedDeleting("u1", "Alice", time.Minute)
		doc := newPendingExport(h, "u1")
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusNoContent {
			t.Fatalf("status = %d", code)
		}
		if h.repo.exports[doc.ID].Status != ExportFailed || len(h.objs.objects) != 0 || h.log.count("obj.Put") != 0 {
			t.Errorf("status %s objects %v", h.repo.exports[doc.ID].Status, h.objs.objects)
		}
		if h.log.count("auth.") != 0 {
			t.Error("a DELETING user's export called Firebase Auth")
		}
	})

	t.Run("a vanished user and an expired export fail cleanly", func(t *testing.T) {
		h := newHarness(t)
		doc := newPendingExport(h, "ghost")
		if h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1) != http.StatusNoContent || h.repo.exports[doc.ID].Status != ExportFailed {
			t.Errorf("vanished user: status %s", h.repo.exports[doc.ID].Status)
		}
		h2 := newHarness(t)
		h2.seedActive("u1", "Alice")
		doc2 := newPendingExport(h2, "u1")
		h2.clock.Advance(8 * 24 * time.Hour)
		if h2.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc2.ID}, 1) != http.StatusNoContent || h2.repo.exports[doc2.ID].Status != ExportFailed {
			t.Errorf("expired: status %s", h2.repo.exports[doc2.ID].Status)
		}
	})

	t.Run("a section failure retries, leaves no object and stays PENDING", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		_ = h.l.RegisterExportSection(fakeSection{name: "graph", err: errors.New("firestore down")})
		doc := newPendingExport(h, "u1")
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", code)
		}
		if _, ok := h.objs.get(doc.ObjectPath); ok || h.repo.exports[doc.ID].Status != ExportPending || h.repo.writes != 1 {
			t.Error("a failed export left an object, changed state or wrote more than the lease claim")
		}
	})

	t.Run("a retry overwrites the same object", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		doc := newPendingExport(h, "u1")
		h.objs.objects[doc.ObjectPath] = []byte("stale partial from a crashed run")
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 2); code != http.StatusNoContent {
			t.Fatalf("status = %d", code)
		}
		parseExport(t, h.objs.objects[doc.ObjectPath])
		if len(h.objs.objects) != 1 {
			t.Errorf("%d objects, want exactly one", len(h.objs.objects))
		}
	})

	t.Run("redelivery after READY or FAILED costs 1 read and 0 writes", func(t *testing.T) {
		for _, st := range []ExportStatus{ExportReady, ExportFailed} {
			h := newHarness(t)
			h.seedActive("u1", "Alice")
			doc := newPendingExport(h, "u1")
			h.repo.exports[doc.ID].Status = st
			if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusNoContent {
				t.Fatalf("status = %d", code)
			}
			if h.repo.reads != 1 || h.repo.writes != 0 || h.log.count("obj.") != 0 {
				t.Errorf("%s: reads %d writes %d", st, h.repo.reads, h.repo.writes)
			}
		}
	})

	t.Run("a lost status race acks and keeps the object; an erased doc removes it", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		doc := newPendingExport(h, "u1")
		h.repo.failOnce["SetExportStatus"] = ErrJobConflict
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusNoContent {
			t.Fatalf("conflict: status = %d", code)
		}
		if _, ok := h.objs.get(doc.ObjectPath); !ok {
			t.Error("the winner's object was deleted by the loser")
		}
		h2 := newHarness(t)
		h2.seedActive("u1", "Alice")
		doc2 := newPendingExport(h2, "u1")
		_ = h2.l.RegisterExportSection(fakeSection{name: "posts", json: "{}", hook: func() {
			h2.repo.mu.Lock()
			delete(h2.repo.exports, doc2.ID) // the account deletion erased the export while it was composing
			h2.repo.mu.Unlock()
		}})
		if code := h2.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc2.ID}, 1); code != http.StatusNoContent {
			t.Fatalf("erased: status = %d", code)
		}
		if _, ok := h2.objs.get(doc2.ObjectPath); ok {
			t.Error("the object of an erased export doc was left behind")
		}
	})

	t.Run("unknown export, no bucket, repo errors", func(t *testing.T) {
		h := newHarness(t)
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: strings.Repeat("c", 64)}, 1); code != http.StatusNoContent {
			t.Errorf("unknown export status = %d", code)
		}
		h.seedActive("u1", "Alice")
		doc := newPendingExport(h, "u1")
		h.repo.failOnce["GetExport"] = errors.New("boom")
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusInternalServerError {
			t.Errorf("read error status = %d", code)
		}
		h.repo.failOnce["GetProfile"] = errors.New("boom")
		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusInternalServerError {
			t.Errorf("profile error status = %d", code)
		}
		h3 := newHarness(t, func(d *LifecycleDeps) { d.Objects = nil })
		h3.seedActive("u1", "Alice")
		doc3 := newPendingExport(h3, "u1")
		if code := h3.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc3.ID}, 1); code != http.StatusInternalServerError {
			t.Errorf("no bucket status = %d", code)
		}
	})
}
