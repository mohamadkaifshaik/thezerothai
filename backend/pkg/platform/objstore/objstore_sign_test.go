package objstore

// The default signing path of SignedGetURL (no test seam): a real V4 URL minted offline from a service-account key,
// and the failure paths of the lazily built client. On Cloud Run the client signs through IAM signBlob instead (no
// private key in the container); that variant cannot run here and is covered by the dev smoke (plan T23).

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// useServiceAccountKey points Application Default Credentials at a freshly generated service-account key file and
// takes the emulator out of the way (STORAGE_EMULATOR_HOST makes the client anonymous). Returns the key's email.
func useServiceAccountKey(t *testing.T) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	const email = "exports-test@demo-dzeroth.iam.gserviceaccount.com"
	raw, _ := json.Marshal(map[string]string{
		"type": "service_account", "project_id": "demo-dzeroth", "private_key_id": "kid",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
		"client_email": email, "client_id": "1", "token_uri": "https://oauth2.googleapis.com/token",
	})
	path := filepath.Join(t.TempDir(), "sa.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", path)
	t.Setenv("STORAGE_EMULATOR_HOST", "")
	return email
}

func TestSignedGetURL_RealV4Signature(t *testing.T) {
	email := useServiceAccountKey(t)
	s, err := New("demo-dzeroth-exports")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	raw, err := s.SignedGetURL(context.Background(), "ab12cd.json", "dzeroth-export.json", 15*time.Minute, now)
	if err != nil {
		t.Fatalf("SignedGetURL: %v", err)
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme != "https" || u.Host != "storage.googleapis.com" || u.Path != "/demo-dzeroth-exports/ab12cd.json" {
		t.Errorf("URL = %s, want https://storage.googleapis.com/demo-dzeroth-exports/ab12cd.json", raw)
	}
	q := u.Query()
	if q.Get("X-Goog-Algorithm") != "GOOG4-RSA-SHA256" {
		t.Errorf("algorithm = %q", q.Get("X-Goog-Algorithm"))
	}
	if !strings.HasPrefix(q.Get("X-Goog-Credential"), email+"/") || !strings.HasSuffix(q.Get("X-Goog-Credential"), "/auto/storage/goog4_request") {
		t.Errorf("credential = %q", q.Get("X-Goog-Credential"))
	}
	if q.Get("X-Goog-SignedHeaders") != "host" {
		t.Errorf("signed headers = %q: a GET link must not require request headers from the browser", q.Get("X-Goog-SignedHeaders"))
	}
	// The link lives for the TTL (15 min = 900 s), give or take the clock reading inside the library.
	if exp := q.Get("X-Goog-Expires"); exp != "900" && exp != "899" {
		t.Errorf("X-Goog-Expires = %q, want 900 (15 minutes)", exp)
	}
	if !regexp.MustCompile(`^\d{8}T\d{6}Z$`).MatchString(q.Get("X-Goog-Date")) {
		t.Errorf("date = %q", q.Get("X-Goog-Date"))
	}
	if !regexp.MustCompile(`^[0-9a-f]{512}$`).MatchString(q.Get("X-Goog-Signature")) {
		t.Errorf("signature = %q, want 512 hex chars (RSA-2048)", q.Get("X-Goog-Signature"))
	}
	if cd := q.Get("response-content-disposition"); cd != `attachment; filename="dzeroth-export.json"` {
		t.Errorf("content disposition = %q: the browser must save the file, not render it", cd)
	}
	if q.Get("response-content-type") != "application/json" {
		t.Errorf("content type = %q", q.Get("response-content-type"))
	}
}

// TestSignedGetURL_EachCallIsAFreshLink: two calls for the same object are two valid links with their own expiry
// (GetAccountExport mints one per call and never stores it); a longer TTL shows in X-Goog-Expires.
func TestSignedGetURL_TTLIsHonouredPerCall(t *testing.T) {
	useServiceAccountKey(t)
	s, _ := New("b")
	now := time.Now()
	short, err := s.SignedGetURL(context.Background(), "o.json", "f.json", time.Minute, now)
	if err != nil {
		t.Fatal(err)
	}
	long, err := s.SignedGetURL(context.Background(), "o.json", "f.json", time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}
	exp := func(raw string) string {
		u, _ := url.Parse(raw)
		return u.Query().Get("X-Goog-Expires")
	}
	if got := exp(short); got != "60" && got != "59" {
		t.Errorf("1 minute link expires = %s", got)
	}
	if got := exp(long); got != "3600" && got != "3599" {
		t.Errorf("1 hour link expires = %s", got)
	}
}

// TestSignedGetURL_RejectsATTLBeyondSevenDays: V4 URLs cannot outlive 7 days; the export TTL is 15 minutes, and a
// misconfigured EXPORT_URL_TTL surfaces as an error instead of a link that silently never works.
func TestSignedGetURL_RejectsATTLBeyondSevenDays(t *testing.T) {
	useServiceAccountKey(t)
	s, _ := New("b")
	if _, err := s.SignedGetURL(context.Background(), "o.json", "f.json", 8*24*time.Hour, time.Now()); err == nil {
		t.Fatal("an 8-day signed URL was minted")
	}
}

// TestStore_NoCredentials: with no credentials at all the lazily built client fails, and every operation reports
// it as an error (never a panic, never a half-built Store) and keeps failing the same way on the next call.
func TestStore_NoCredentials(t *testing.T) {
	t.Setenv("STORAGE_EMULATOR_HOST", "")
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", filepath.Join(t.TempDir(), "does-not-exist.json"))
	s, _ := New("b")
	ctx := context.Background()
	for i := 0; i < 2; i++ {
		if _, err := s.SignedGetURL(ctx, "o", "f", time.Minute, time.Now()); err == nil || !strings.Contains(err.Error(), "objstore") {
			t.Errorf("SignedGetURL err = %v", err)
		}
		if err := s.Delete(ctx, "o"); err == nil || !strings.Contains(err.Error(), "objstore") {
			t.Errorf("Delete err = %v", err)
		}
		called := false
		if err := s.Put(ctx, "o", "application/json", func(_ io.Writer) error { called = true; return nil }); err == nil || called {
			t.Errorf("Put err = %v, writer callback called = %v (nothing may be composed with no bucket to write to)", err, called)
		}
	}
}

// TestSignedPutURL_RealV4Signature: a PUT link is signed offline from a key, carries the content-type, MD5 and
// length-range as signed headers (so GCS rejects altered bytes) and expires with the TTL.
func TestSignedPutURL_RealV4Signature(t *testing.T) {
	useServiceAccountKey(t)
	s, err := New("demo-dzeroth-media-upload")
	if err != nil {
		t.Fatal(err)
	}
	raw, headers, err := s.SignedPutURL(context.Background(), "u/uid-1/123.webp", "image/webp", "1B2M2Y8AsgTpgAmY7PhCfg==", 2<<20, 10*time.Minute, time.Now())
	if err != nil {
		t.Fatalf("SignedPutURL: %v", err)
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if u.Host != "storage.googleapis.com" || u.Path != "/demo-dzeroth-media-upload/u/uid-1/123.webp" {
		t.Errorf("URL = %s", raw)
	}
	q := u.Query()
	signed := strings.Split(q.Get("X-Goog-SignedHeaders"), ";")
	for _, h := range []string{"content-md5", "content-type", "host", "x-goog-content-length-range"} {
		found := false
		for _, s := range signed {
			if s == h {
				found = true
			}
		}
		if !found {
			t.Errorf("signed headers %v lack %s", signed, h)
		}
	}
	if exp := q.Get("X-Goog-Expires"); exp != "600" && exp != "599" {
		t.Errorf("X-Goog-Expires = %q, want 600", exp)
	}
	if headers["x-goog-content-length-range"] != "0,2097152" {
		t.Errorf("headers = %v", headers)
	}
}
