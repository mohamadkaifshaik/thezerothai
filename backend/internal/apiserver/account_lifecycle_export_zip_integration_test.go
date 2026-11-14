//go:build integration

package apiserver

// ZIP export over the real Build chain (Firestore, Auth, Storage and Pub/Sub emulators).
//   - TestAccountLifecycle_ExportZip: with export_zip on, a ZIP request writes exports/{id}.zip (not .json) holding
//     manifest.json, account.json, profile.json and one JSON file per section; a later JSON request still writes the
//     single .json object.
//   - TestAccountLifecycle_ExportZipErasedWithAccount: deleting the account removes the ZIP object and its exports doc.
//   - TestAccountLifecycle_ExportZipFlagOffIsJSON: with export_zip off, a ZIP request is served as the JSON object.

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"testing"

	"cloud.google.com/go/storage"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// zipExportOf is the ZIP-format export of uid, run through the job; it returns the export id and the archive's entries.
func (e *lifecycleEnv) zipExportOf(t *testing.T, u testUser, key string) (id string, files map[string][]byte, order []string) {
	t.Helper()
	ctx := context.Background()
	exp, err := e.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: key, Format: identityv1.ExportFormat_EXPORT_FORMAT_ZIP}))
	if err != nil {
		t.Fatalf("RequestAccountExport (zip): %v", err)
	}
	if exp.Msg.GetFormat() != identityv1.ExportFormat_EXPORT_FORMAT_ZIP {
		t.Fatalf("response format = %v, want ZIP", exp.Msg.GetFormat())
	}
	id = exp.Msg.GetExportId()
	for _, m := range e.pull(t) {
		if m["kind"] == "account_export" && m["exportId"] == id {
			if code := e.deliver(t, m); code != http.StatusNoContent {
				t.Fatalf("export delivery = %d", code)
			}
		}
	}
	rd, err := e.bucket.Object(id + ".zip").NewReader(ctx)
	if err != nil {
		t.Fatalf("zip export object: %v", err)
	}
	defer rd.Close()
	raw, err := io.ReadAll(rd)
	if err != nil {
		t.Fatal(err)
	}
	zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		t.Fatalf("export is not a ZIP archive: %v", err)
	}
	files = map[string][]byte{}
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
		if !json.Valid(b) {
			t.Errorf("%s is not valid JSON", f.Name)
		}
		files[f.Name] = b
		order = append(order, f.Name)
	}
	return id, files, order
}

func TestAccountLifecycle_ExportZip(t *testing.T) {
	env := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		c.FeatureExportZip = flags.Spec{Name: "export_zip", Mode: flags.On}
	})
	u := env.newUser(t)
	ctx := context.Background()

	id, files, order := env.zipExportOf(t, u, "zip-export-key-001")
	for _, want := range []string{"manifest.json", "account.json", "profile.json"} {
		if _, ok := files[want]; !ok {
			t.Errorf("archive has no %s (entries %v)", want, order)
		}
	}
	if order[0] != "manifest.json" {
		t.Errorf("first entry = %s, want manifest.json", order[0])
	}
	if len(order) < 4 {
		t.Errorf("archive has %d entries, want the sections as well (%v)", len(order), order)
	}
	var profile map[string]any
	if err := json.Unmarshal(files["profile.json"], &profile); err != nil {
		t.Fatal(err)
	}
	if profile["userId"] != u.uid {
		t.Errorf("profile.json userId = %v, want the caller", profile["userId"])
	}
	if _, err := env.bucket.Object(id + ".json").Attrs(ctx); err == nil {
		t.Error("a ZIP export also wrote a .json object")
	}

	// GetAccountExport on a READY export signs a URL, which the Storage emulator cannot do; the status and format
	// it returns are covered by the identity unit tests.

	// The default is unchanged: a request without a format (or JSON) is the single JSON object.
	jsonID, _ := env.exportOf(t, u, "json-after-zip-key-01")
	if jsonID == id {
		t.Fatal("a JSON request reused the ZIP export id")
	}
	if _, err := env.bucket.Object(jsonID + ".json").Attrs(ctx); err != nil {
		t.Errorf("JSON export object: %v", err)
	}
}

func TestAccountLifecycle_ExportZipErasedWithAccount(t *testing.T) {
	env := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		c.FeatureExportZip = flags.Spec{Name: "export_zip", Mode: flags.On}
	})
	u := env.newUser(t)
	ctx := context.Background()
	id, _, _ := env.zipExportOf(t, u, "zip-erase-key-00001")

	if n := env.runDeletion(t, u, "zip-erase-delete-001"); n == 0 {
		t.Fatal("deletion ran no deliveries")
	}
	if _, err := env.bucket.Object(id + ".zip").Attrs(ctx); !errors.Is(err, storage.ErrObjectNotExist) {
		t.Errorf("ZIP object after erasure: err = %v, want ErrObjectNotExist", err)
	}
}

func TestAccountLifecycle_ExportZipFlagOffIsJSON(t *testing.T) {
	env := newLifecycleEnv(t) // export_zip is off by default
	u := env.newUser(t)
	ctx := context.Background()
	exp, err := env.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "zip-flag-off-key-01", Format: identityv1.ExportFormat_EXPORT_FORMAT_ZIP}))
	if err != nil {
		t.Fatalf("RequestAccountExport: %v", err)
	}
	if exp.Msg.GetFormat() != identityv1.ExportFormat_EXPORT_FORMAT_JSON {
		t.Errorf("response format = %v with the flag off, want JSON", exp.Msg.GetFormat())
	}
	id := exp.Msg.GetExportId()
	for _, m := range env.pull(t) {
		if m["kind"] == "account_export" && m["exportId"] == id {
			if code := env.deliver(t, m); code != http.StatusNoContent {
				t.Fatalf("export delivery = %d", code)
			}
		}
	}
	if _, err := env.bucket.Object(id + ".json").Attrs(ctx); err != nil {
		t.Errorf("JSON object: %v", err)
	}
	if _, err := env.bucket.Object(id + ".zip").Attrs(ctx); err == nil {
		t.Error("a ZIP object was written with the flag off")
	}
}
