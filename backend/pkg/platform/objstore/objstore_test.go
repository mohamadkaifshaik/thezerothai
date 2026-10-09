package objstore

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/storage"
)

func TestNew_RequiresBucket(t *testing.T) {
	if _, err := New(""); err == nil {
		t.Fatal("empty bucket accepted")
	}
}

func TestSignedGetURL_BuildsAttachmentGetOptions(t *testing.T) {
	s, err := New("demo-exports")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	var gotBucket, gotObject string
	var gotOpts *storage.SignedURLOptions
	s.sign = func(_ context.Context, bucket, object string, opts *storage.SignedURLOptions) (string, error) {
		gotBucket, gotObject, gotOpts = bucket, object, opts
		return "https://signed.example/x", nil
	}
	u, err := s.SignedGetURL(context.Background(), "abc.json", "dzeroth-export.json", 15*time.Minute, now)
	if err != nil || u != "https://signed.example/x" {
		t.Fatalf("SignedGetURL = %q, %v", u, err)
	}
	if gotBucket != "demo-exports" || gotObject != "abc.json" {
		t.Errorf("signed %s/%s", gotBucket, gotObject)
	}
	if gotOpts.Method != "GET" || gotOpts.Scheme != storage.SigningSchemeV4 || !gotOpts.Expires.Equal(now.Add(15*time.Minute)) {
		t.Errorf("opts = %+v", gotOpts)
	}
	if cd := gotOpts.QueryParameters.Get("response-content-disposition"); !strings.HasPrefix(cd, "attachment;") {
		t.Errorf("content disposition = %q", cd)
	}
}

func TestSignedGetURL_PropagatesSignerError(t *testing.T) {
	s, _ := New("b")
	s.sign = func(context.Context, string, string, *storage.SignedURLOptions) (string, error) {
		return "", errors.New("no signer")
	}
	if _, err := s.SignedGetURL(context.Background(), "o", "f", time.Minute, time.Now()); err == nil {
		t.Fatal("want error")
	}
}
