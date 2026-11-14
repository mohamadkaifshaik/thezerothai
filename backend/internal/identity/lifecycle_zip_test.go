package identity

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	fbauth "firebase.google.com/go/v4/auth"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// zipEntries opens a ZIP archive and returns its entry names in archive order and their bytes.
func zipEntries(t *testing.T, raw []byte) ([]string, map[string][]byte) {
	t.Helper()
	zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		t.Fatalf("not a ZIP archive: %v", err)
	}
	var order []string
	out := map[string][]byte{}
	for _, f := range zr.File {
		rc, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		b, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			t.Fatal(err)
		}
		order = append(order, f.Name)
		out[f.Name] = b
	}
	return order, out
}

// zipExportID is the id a ZIP export of uid with key gets (its own operation name, see lifecycle.go).
func zipExportID(uid, key string) string { return idempotency.Key(uid, exportRPCZip, key) }

// zipPendingExport seeds a PENDING ZIP export doc the job delivery can compose.
func zipPendingExport(h *harness, uid string) ExportDoc {
	now := h.clock.Now()
	id := zipExportID(uid, expKey1)
	doc := ExportDoc{ID: id, UID: uid, Status: ExportPending, ObjectPath: id + ".zip", Format: ExportFormatZIP, CreatedAt: now, ExpireAt: now.Add(7 * 24 * time.Hour), UpdateTime: utOf(1)}
	h.repo.exports[id] = &doc
	return doc
}

func TestRequestAccountExportFormat(t *testing.T) {
	t.Run("JSON stays the default: same id, .json object, no format stored", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		v, err := h.l.RequestAccountExport(context.Background(), "u1", expKey1)
		if err != nil {
			t.Fatal(err)
		}
		if v.ID != expID("u1", expKey1) || v.Format != ExportFormatJSON {
			t.Errorf("view = %+v", v)
		}
		if doc := h.repo.exports[v.ID]; doc.ObjectPath != v.ID+".json" || doc.Format != ExportFormatJSON {
			t.Errorf("doc = %+v", doc)
		}
	})

	t.Run("ZIP: its own id, .zip object, format stored and returned", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		v, err := h.l.RequestAccountExportFormat(context.Background(), "u1", expKey1, ExportFormatZIP)
		if err != nil {
			t.Fatal(err)
		}
		if v.ID != zipExportID("u1", expKey1) || v.ID == expID("u1", expKey1) || v.Format != ExportFormatZIP || v.Status != ExportPending {
			t.Errorf("view = %+v", v)
		}
		if doc := h.repo.exports[v.ID]; doc.ObjectPath != v.ID+".zip" || doc.Format != ExportFormatZIP {
			t.Errorf("doc = %+v", doc)
		}
		if h.pub.count() != 1 {
			t.Errorf("published %d, want 1", h.pub.count())
		}
	})

	t.Run("a ZIP request while a JSON export is PENDING returns that JSON export", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		first, err := h.l.RequestAccountExport(context.Background(), "u1", expKey1)
		if err != nil {
			t.Fatal(err)
		}
		v, err := h.l.RequestAccountExportFormat(context.Background(), "u1", expKey2, ExportFormatZIP)
		if err != nil {
			t.Fatal(err)
		}
		if v.ID != first.ID || v.Format != ExportFormatJSON {
			t.Errorf("view = %+v, want the earlier JSON export %s", v, first.ID)
		}
	})
}

func TestExportJob_ZIP(t *testing.T) {
	t.Run("writes a ZIP with manifest, account, profile and each section, then READY", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedActive("u1", "Alice")
		p.Bio, p.AvatarURL = "hello", "https://cdn.example/avatar.jpg"
		h.repo.seed(p)
		h.auth.users["u1"] = &fbauth.UserRecord{UserInfo: &fbauth.UserInfo{UID: "u1", Email: "alice@example.com"}, EmailVerified: true}
		_ = h.l.RegisterExportSection(fakeSection{name: "graph", json: `{"following":[]}` + "\n"})
		_ = h.l.RegisterExportSection(fakeSection{name: "posts", json: `{"posts":[{"text":"hi & bye"}]}` + "\n"})
		doc := zipPendingExport(h, "u1")

		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code != http.StatusNoContent {
			t.Fatalf("status = %d", code)
		}
		raw, ok := h.objs.get(doc.ObjectPath)
		if !ok {
			t.Fatal("no archive written")
		}
		order, files := zipEntries(t, raw)
		want := []string{"manifest.json", "account.json", "profile.json", "graph.json", "posts.json"}
		if strings.Join(order, ",") != strings.Join(want, ",") {
			t.Fatalf("entries = %v, want %v", order, want)
		}
		var manifest struct {
			ExportVersion int      `json:"exportVersion"`
			Format        string   `json:"format"`
			Files         []string `json:"files"`
		}
		if err := json.Unmarshal(files["manifest.json"], &manifest); err != nil {
			t.Fatal(err)
		}
		if manifest.ExportVersion != exportVersion || manifest.Format != "zip" || len(manifest.Files) != 4 || manifest.Files[3] != "posts.json" {
			t.Errorf("manifest = %+v", manifest)
		}
		var profile map[string]any
		if err := json.Unmarshal(files["profile.json"], &profile); err != nil {
			t.Fatal(err)
		}
		if profile["handle"] != "Alice" || profile["bio"] != "hello" || profile["avatarUrl"] != "https://cdn.example/avatar.jpg" {
			t.Errorf("profile = %v", profile)
		}
		if !strings.Contains(string(files["account.json"]), "alice@example.com") {
			t.Errorf("account.json lacks the account record: %s", files["account.json"])
		}
		if !strings.Contains(string(files["posts.json"]), `"hi & bye"`) {
			t.Errorf("posts.json = %s", files["posts.json"])
		}
		if got := h.repo.exports[doc.ID].Status; got != ExportReady {
			t.Errorf("status = %s, want READY", got)
		}
	})

	t.Run("a failing section writes no archive and nacks for a retry", func(t *testing.T) {
		h := newHarness(t)
		h.seedActive("u1", "Alice")
		_ = h.l.RegisterExportSection(fakeSection{name: "graph", err: io.ErrUnexpectedEOF})
		doc := zipPendingExport(h, "u1")

		if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, 1); code == http.StatusNoContent {
			t.Fatalf("status = %d, want a nack", code)
		}
		if _, ok := h.objs.get(doc.ObjectPath); ok {
			t.Error("a failed compose left an archive behind")
		}
		if got := h.repo.exports[doc.ID].Status; got != ExportPending {
			t.Errorf("status = %s, want PENDING", got)
		}
	})
}

func TestGetAccountExport_ZIP(t *testing.T) {
	h := newHarness(t)
	h.seedActive("u1", "Alice")
	doc := zipPendingExport(h, "u1")
	doc.Status = ExportReady
	h.repo.exports[doc.ID] = &doc

	v, err := h.l.GetAccountExport(context.Background(), "u1", doc.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	if v.Format != ExportFormatZIP || v.Status != ExportReady {
		t.Errorf("view = %+v", v)
	}
	if len(h.objs.signed) != 1 || h.objs.signed[0] != doc.ID+".zip" {
		t.Errorf("signed = %v, want the .zip object", h.objs.signed)
	}
	if other, err := h.l.GetAccountExport(context.Background(), "u2", doc.ID, true); err == nil || other.DownloadURL != "" {
		t.Errorf("another user got a view: %+v %v", other, err)
	}
}

func TestExportFormat_ContentTypeAndFilename(t *testing.T) {
	if ExportFormatJSON.contentType() != "application/json" || ExportFormatJSON.filename() != exportFilename || ExportFormatJSON.objectSuffix() != ".json" {
		t.Errorf("json: %q %q %q", ExportFormatJSON.contentType(), ExportFormatJSON.filename(), ExportFormatJSON.objectSuffix())
	}
	if ExportFormatZIP.contentType() != "application/zip" || ExportFormatZIP.filename() != exportFilenameZip || ExportFormatZIP.objectSuffix() != ".zip" {
		t.Errorf("zip: %q %q %q", ExportFormatZIP.contentType(), ExportFormatZIP.filename(), ExportFormatZIP.objectSuffix())
	}
}
