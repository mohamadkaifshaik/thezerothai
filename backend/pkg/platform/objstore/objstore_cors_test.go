package objstore

import (
	"context"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/storage"
)

// The upload bucket's CORS response_header list (infra/terraform/modules/media-buckets/main.tf) must name every header
// the browser sends on the signed PUT. Cloud Storage does not expand a prefix such as "x-goog-*", so a missing exact
// name fails the CORS preflight and the web app shows "No connection" with no request reaching the API.
func TestSignedPutURL_HeadersAreInUploadBucketCORS(t *testing.T) {
	raw, err := os.ReadFile("../../../../infra/terraform/modules/media-buckets/main.tf")
	if err != nil {
		t.Fatalf("read media-buckets module: %v", err)
	}
	cors := regexp.MustCompile(`(?s)cors\s*\{[^}]*?response_header\s*=\s*\[([^\]]*)\]`).FindSubmatch(raw)
	if cors == nil {
		t.Fatal("no cors response_header list found in the media-buckets module")
	}
	allowed := map[string]bool{}
	for _, m := range regexp.MustCompile(`"([^"]+)"`).FindAllStringSubmatch(string(cors[1]), -1) {
		name := strings.ToLower(m[1])
		if strings.Contains(name, "*") {
			t.Errorf("response_header %q is a wildcard; Cloud Storage does not expand it", m[1])
		}
		allowed[name] = true
	}

	s := &Store{
		bucket: "demo-upload",
		sign: func(context.Context, string, string, *storage.SignedURLOptions) (string, error) {
			return "https://storage.googleapis.com/demo-upload/o", nil
		},
	}
	_, headers, err := s.SignedPutURL(context.Background(), "u/uid/1.webp", "image/webp", "1B2M2Y8AsgTpgAmY7PhCfg==", 2<<20, time.Minute, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(headers) == 0 {
		t.Fatal("SignedPutURL returned no headers")
	}
	for name := range headers {
		if !allowed[strings.ToLower(name)] {
			t.Errorf("signed PUT header %q is not in the upload bucket CORS response_header list %v", name, allowed)
		}
	}
}
