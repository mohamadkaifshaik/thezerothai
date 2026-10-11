package media

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"google.golang.org/api/option"
	vision "google.golang.org/api/vision/v1"
)

// visionFor builds a Vision whose service talks to a stub endpoint that returns body with status.
func visionFor(t *testing.T, status int, body string, seen *string) *Vision {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if seen != nil {
			var req vision.BatchAnnotateImagesRequest
			_ = json.NewDecoder(r.Body).Decode(&req)
			if len(req.Requests) == 1 {
				*seen = req.Requests[0].Image.Source.ImageUri + "|" + req.Requests[0].Features[0].Type
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	svc, err := vision.NewService(context.Background(), option.WithEndpoint(srv.URL), option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	return &Vision{bucket: "demo-upload", svc: svc}
}

func TestVision_SafeSearch(t *testing.T) {
	tests := []struct {
		name    string
		status  int
		body    string
		want    SafeSearch
		wantErr bool
	}{
		{"annotation is mapped", 200, `{"responses":[{"safeSearchAnnotation":{"adult":"VERY_UNLIKELY","violence":"POSSIBLE","racy":"VERY_LIKELY"}}]}`,
			SafeSearch{Adult: LikelihoodVeryUnlikely, Violence: LikelihoodPossible, Racy: LikelihoodVeryLikely}, false},
		{"unknown value maps to unknown", 200, `{"responses":[{"safeSearchAnnotation":{"adult":"UNKNOWN","violence":"LIKELY","racy":"UNLIKELY"}}]}`,
			SafeSearch{Adult: LikelihoodUnknown, Violence: LikelihoodLikely, Racy: LikelihoodUnlikely}, false},
		{"empty responses fail closed", 200, `{"responses":[]}`, SafeSearch{}, true},
		{"missing annotation fails closed", 200, `{"responses":[{}]}`, SafeSearch{}, true},
		{"per-image error fails closed", 200, `{"responses":[{"error":{"code":7,"message":"denied"}}]}`, SafeSearch{}, true},
		{"http error fails closed", 503, `{"error":{"code":503,"message":"unavailable"}}`, SafeSearch{}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var seen string
			v := visionFor(t, tt.status, tt.body, &seen)
			got, err := v.SafeSearch(context.Background(), "u/uid/1.jpg")
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if err == nil && got != tt.want {
				t.Fatalf("got %+v, want %+v", got, tt.want)
			}
			if seen != "gs://demo-upload/u/uid/1.jpg|SAFE_SEARCH_DETECTION" {
				t.Fatalf("request = %q: Vision must read the private object by gs:// URI", seen)
			}
		})
	}
}

func TestVision_ErrorsDoNotCarryTheObjectPath(t *testing.T) {
	v := visionFor(t, 200, `{"responses":[{"error":{"code":3,"message":"gs://demo-upload/u/uid-secret/1.jpg bad"}}]}`, nil)
	_, err := v.SafeSearch(context.Background(), "u/uid-secret/1.jpg")
	if err == nil || strings.Contains(err.Error(), "uid-secret") {
		t.Fatalf("err = %v: the error must not echo the object path (it embeds the uid)", err)
	}
}

func TestNewVision_RequiresBucketAndAllowAllIsClean(t *testing.T) {
	if _, err := NewVision(""); err == nil {
		t.Fatal("no bucket must be refused")
	}
	ss, err := AllowAll{}.SafeSearch(context.Background(), "x")
	if err != nil || blockedBySafeSearch(ss, PurposeAvatar) {
		t.Fatalf("AllowAll = %+v, %v", ss, err)
	}
}

func TestBuckets_RefuseSameBucket(t *testing.T) {
	if _, err := NewBuckets("same", "same"); err == nil {
		t.Fatal("unmoderated and public buckets must differ")
	}
	if _, err := NewBuckets("", "b"); err == nil {
		t.Fatal("empty bucket must be refused")
	}
	if b, err := NewBuckets("up", "pub"); err != nil || b == nil {
		t.Fatalf("NewBuckets = %v, %v", b, err)
	}
}
