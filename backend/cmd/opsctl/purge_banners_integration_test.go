//go:build integration

package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

// `opsctl purge-banners` on the Firestore and Storage emulators: legacy banner media documents in every state, their
// public and private objects, and the legacy fields on users documents; a dry run writes nothing, --apply erases exactly
// the banner data, and a rerun writes nothing.
func TestPurgeBanners_Integration_CLI(t *testing.T) {
	if os.Getenv("STORAGE_EMULATOR_HOST") == "" {
		t.Skip("STORAGE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, project := backfillTestClient(t)
	ctx := context.Background()
	buckets, err := media.NewBuckets(project+"-media-upload", project+"-media")
	if err != nil {
		t.Fatal(err)
	}
	put := func(s *objstore.Store, name string) {
		t.Helper()
		if err := s.Put(ctx, name, "image/webp", func(w io.Writer) error { _, err := io.WriteString(w, "bytes"); return err }); err != nil {
			t.Fatalf("put %s: %v", name, err)
		}
	}
	exists := func(s *objstore.Store, name string) bool {
		t.Helper()
		_, err := s.Attrs(ctx, name)
		switch {
		case err == nil:
			return true
		case errors.Is(err, objstore.ErrObjectNotFound):
			return false
		}
		t.Fatalf("attrs %s: %v", name, err)
		return false
	}

	// --- seed: users with and without the legacy fields ---
	base := "https://storage.googleapis.com/" + project + "-media/m/"
	updated := time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC)
	users := map[string]map[string]any{
		"uid-legacy-1": {"bannerUrl": base + "0000000000000000901.webp", "bannerThumbUrl": base + "0000000000000000901_t.webp",
			"avatarUrl": base + "0000000000000000910.webp", "avatarThumbUrl": base + "0000000000000000910_t.webp", "location": "Pune"},
		"uid-legacy-2": {"bannerUrl": "", "bannerThumbUrl": base + "0000000000000000902_t.webp"}, // a half-set banner counts
		"uid-clean":    {"location": "Delhi"},
	}
	for uid, extra := range users {
		doc := map[string]any{"handle": uid, "handleLower": uid, "displayName": "U", "status": "ACTIVE", "updatedAt": updated,
			"createdAt": time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)}
		for k, v := range extra {
			doc[k] = v
		}
		if _, err := client.Collection("users").Doc(uid).Set(ctx, doc); err != nil {
			t.Fatal(err)
		}
	}

	// --- seed: legacy banner media documents in every state, and an avatar that must survive ---
	retired := time.Now().UTC().Add(-time.Hour)
	docs := map[string]media.Doc{
		"0000000000000000901": {OwnerID: "uid-legacy-1", Purpose: media.LegacyBannerPurpose, Status: string(media.StatusReady),
			PublicPath: "m/0000000000000000901.webp", ThumbPath: "m/0000000000000000901_t.webp"},
		"0000000000000000902": {OwnerID: "uid-legacy-2", Purpose: media.LegacyBannerPurpose, Status: string(media.StatusReady),
			PublicPath: "m/0000000000000000902.webp", ThumbPath: "m/0000000000000000902_t.webp", RetiredAt: &retired},
		"0000000000000000903": {OwnerID: "uid-legacy-1", Purpose: media.LegacyBannerPurpose, Status: string(media.StatusPending),
			UploadPath: "u/uid-legacy-1/0000000000000000903.webp", ThumbUploadPath: "u/uid-legacy-1/0000000000000000903_t.webp"},
		"0000000000000000904": {OwnerID: "uid-gone", Purpose: media.LegacyBannerPurpose, Status: string(media.StatusRejected)},
		"0000000000000000910": {OwnerID: "uid-legacy-1", Purpose: string(media.PurposeAvatar), Status: string(media.StatusReady),
			PublicPath: "m/0000000000000000910.webp", ThumbPath: "m/0000000000000000910_t.webp"},
	}
	for id, d := range docs {
		d.ContentType, d.CreatedAt = "image/webp", time.Now().UTC().Add(-48*time.Hour)
		if _, err := client.Collection("media").Doc(id).Set(ctx, d); err != nil {
			t.Fatal(err)
		}
		for _, p := range []string{d.PublicPath, d.ThumbPath} {
			if p != "" {
				put(buckets.Public, p)
			}
		}
		for _, p := range []string{d.UploadPath, d.ThumbUploadPath} {
			if p != "" {
				put(buckets.Upload, p)
			}
		}
	}

	// A legacy profile still decodes (the API reads it without the banner).
	identityRepo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	if p, err := identityRepo.GetProfile(ctx, "uid-legacy-1"); err != nil || p.Location != "Pune" {
		t.Fatalf("GetProfile of a legacy profile = %+v, %v", p, err)
	}

	cli := func(args ...string) (int, string, string) {
		t.Helper()
		open := func(context.Context, string) (*backends, error) {
			return &backends{
				bannerMedia:    media.NewLegacyBannerPurger(media.NewFirestoreRepo(client, media.WriteDeps{}), buckets),
				bannerProfiles: identityRepo,
				close:          func() {},
			}, nil
		}
		var out, errOut bytes.Buffer
		code := run(ctx, append([]string{"purge-banners", "--project", project}, args...), strings.NewReader(""), &out, &errOut, open, time.Now)
		return code, out.String(), errOut.String()
	}
	userData := func(uid string) map[string]any {
		t.Helper()
		s, err := client.Collection("users").Doc(uid).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return s.Data()
	}
	mediaExists := func(id string) bool {
		t.Helper()
		s, err := client.Collection("media").Doc(id).Get(ctx)
		if err == nil {
			return s.Exists()
		}
		return false
	}

	// --- dry run (the default): counts, writes nothing ---
	code, out, errOut := cli()
	if code != 0 || !strings.Contains(out, "dry-run: media documents to erase=4, users documents to clear=2 of 3 scanned") {
		t.Fatalf("dry run: code=%d out=\n%s\nstderr=%q", code, out, errOut)
	}
	for id := range docs {
		if !mediaExists(id) {
			t.Fatalf("the dry run deleted media/%s", id)
		}
	}
	if !exists(buckets.Public, "m/0000000000000000901.webp") || !exists(buckets.Upload, "u/uid-legacy-1/0000000000000000903.webp") {
		t.Fatal("the dry run deleted an object")
	}
	if _, has := userData("uid-legacy-1")["bannerUrl"]; !has {
		t.Fatal("the dry run cleared a users document")
	}

	// --- apply ---
	code, out, errOut = cli("--apply")
	if code != 0 || !strings.Contains(out, "purge-banners: complete: media documents erased=4 (objects first), users documents cleared=2 of 3 scanned") {
		t.Fatalf("apply: code=%d out=\n%s\nstderr=%q", code, out, errOut)
	}
	for _, id := range []string{"0000000000000000901", "0000000000000000902", "0000000000000000903", "0000000000000000904"} {
		if mediaExists(id) {
			t.Errorf("media/%s survived", id)
		}
	}
	for _, name := range []string{"m/0000000000000000901.webp", "m/0000000000000000901_t.webp", "m/0000000000000000902.webp", "m/0000000000000000902_t.webp"} {
		if exists(buckets.Public, name) {
			t.Errorf("public object %s survived", name)
		}
	}
	for _, name := range []string{"u/uid-legacy-1/0000000000000000903.webp", "u/uid-legacy-1/0000000000000000903_t.webp"} {
		if exists(buckets.Upload, name) {
			t.Errorf("upload object %s survived", name)
		}
	}
	// The avatar is untouched.
	if !mediaExists("0000000000000000910") || !exists(buckets.Public, "m/0000000000000000910.webp") {
		t.Error("the avatar (document or object) was erased")
	}
	for _, uid := range []string{"uid-legacy-1", "uid-legacy-2"} {
		d := userData(uid)
		for _, f := range []string{"bannerUrl", "bannerThumbUrl"} {
			if _, has := d[f]; has {
				t.Errorf("users/%s.%s survived", uid, f)
			}
		}
		if got, _ := d["updatedAt"].(time.Time); !got.Equal(updated) {
			t.Errorf("users/%s.updatedAt moved to %v: the clear is a field-level delete only", uid, got)
		}
	}
	if d := userData("uid-legacy-1"); d["avatarUrl"] != base+"0000000000000000910.webp" || d["location"] != "Pune" {
		t.Errorf("another field of users/uid-legacy-1 changed: %v", d)
	}
	if d := userData("uid-clean"); d["location"] != "Delhi" {
		t.Errorf("users/uid-clean changed: %v", d)
	}
	if _, err := client.Collection("users").Doc("uid-gone").Get(ctx); err == nil {
		t.Error("the purge created a users document for an owner without one")
	}

	// --- rerun: nothing left, nothing written ---
	before := userData("uid-legacy-1")
	code, out, errOut = cli("--apply")
	if code != 0 || !strings.Contains(out, "media documents erased=0 (objects first), users documents cleared=0 of 3 scanned") {
		t.Fatalf("rerun: code=%d out=\n%s\nstderr=%q", code, out, errOut)
	}
	if after := userData("uid-legacy-1"); len(after) != len(before) {
		t.Errorf("the rerun changed users/uid-legacy-1: %v -> %v", before, after)
	}
}
