package objstore

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"

	"cloud.google.com/go/storage"
	"google.golang.org/api/option"
)

// wireServer is a stand-in Cloud Storage endpoint that records every request and answers with a fixed status, so the tests
// assert on what actually goes over the wire (the Storage emulator ignores generation preconditions on media reads and does
// not implement objects.rewrite, so it cannot prove them).
type wireServer struct {
	mu     sync.Mutex
	reqs   []*http.Request
	status int // answer for every request
}

func (w *wireServer) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	w.mu.Lock()
	w.reqs = append(w.reqs, r)
	status := w.status
	w.mu.Unlock()
	rw.Header().Set("Content-Type", "application/json")
	switch status {
	case http.StatusOK:
		if strings.Contains(r.URL.Path, "/rewriteTo/") {
			_, _ = rw.Write([]byte(`{"kind":"storage#rewriteResponse","done":true,"resource":{"name":"dst","bucket":"pub"}}`))
			return
		}
		rw.Header().Set("Content-Type", "image/jpeg")
		_, _ = rw.Write([]byte("0123456789"))
	default:
		rw.WriteHeader(status)
		_, _ = rw.Write([]byte(`{"error":{"code":` + strconv.Itoa(status) + `,"message":"stub"}}`))
	}
}

func (w *wireServer) last(t *testing.T) *http.Request {
	t.Helper()
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.reqs) == 0 {
		t.Fatal("no request reached the storage endpoint")
	}
	return w.reqs[len(w.reqs)-1]
}

func newWireStore(t *testing.T, status int) (*Store, *wireServer) {
	t.Helper()
	t.Setenv("STORAGE_EMULATOR_HOST", "") // the emulator-only fallbacks must not apply
	ws := &wireServer{status: status}
	srv := httptest.NewServer(ws)
	t.Cleanup(srv.Close)
	c, err := storage.NewClient(context.Background(), option.WithEndpoint(srv.URL+"/storage/v1/"), option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return &Store{bucket: "up", client: c}, ws
}

func TestReadHead_PinnedReadCarriesTheGenerationPrecondition(t *testing.T) {
	s, ws := newWireStore(t, http.StatusOK)
	b, err := s.ReadHead(context.Background(), "u/x/1.jpg", 4, 1234)
	if err != nil || string(b) != "0123" {
		t.Fatalf("ReadHead = %q, %v", b, err)
	}
	r := ws.last(t)
	if got := r.Header.Get("x-goog-if-generation-match"); got != "1234" {
		t.Fatalf("pinned read headers = %v, query = %v: want x-goog-if-generation-match: 1234", r.Header, r.URL.Query())
	}
	if r.URL.Query().Get("generation") != "" {
		t.Fatalf("a pinned read must use the precondition, not ?generation= (that turns a 404 into %q): %v", "changed", r.URL.Query())
	}

	// Unpinned (generation 0) carries no precondition.
	if _, err := s.ReadHead(context.Background(), "u/x/1.jpg", 4, 0); err != nil {
		t.Fatal(err)
	}
	if got := ws.last(t).Header.Get("x-goog-if-generation-match"); got != "" {
		t.Fatalf("unpinned read carried a precondition: %q", got)
	}
}

func TestReadHead_ErrorMapping(t *testing.T) {
	tests := []struct {
		name       string
		status     int
		generation int64
		want       error
	}{
		{"404 pinned is not found, not changed", http.StatusNotFound, 7, ErrObjectNotFound},
		{"404 unpinned is not found", http.StatusNotFound, 0, ErrObjectNotFound},
		{"412 pinned is generation changed", http.StatusPreconditionFailed, 7, ErrGenerationChanged},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, _ := newWireStore(t, tc.status)
			_, err := s.ReadHead(context.Background(), "u/x/1.jpg", 4, tc.generation)
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
			if errors.Is(err, ErrGenerationChanged) == errors.Is(err, ErrObjectNotFound) {
				t.Fatalf("err = %v maps to both or neither sentinel", err)
			}
		})
	}
}

func TestCopyTo_SendsIfSourceGenerationMatch(t *testing.T) {
	s, ws := newWireStore(t, http.StatusOK)
	pub := &Store{bucket: "pub", client: s.client}
	if err := s.CopyTo(context.Background(), "u/x/1.jpg", 4321, pub, "m/1.jpg", "image/jpeg", "public"); err != nil {
		t.Fatalf("CopyTo: %v", err)
	}
	r := ws.last(t)
	if !strings.Contains(r.URL.Path, "/rewriteTo/") {
		t.Fatalf("the copy went to %s, want objects.rewrite", r.URL.Path)
	}
	// This precondition is the only thing that protects production from a swapped source (the emulator cannot test it).
	if got := r.URL.Query().Get("ifSourceGenerationMatch"); got != "4321" {
		t.Fatalf("rewrite query = %v: want ifSourceGenerationMatch=4321", r.URL.Query())
	}

	// An unpinned copy (integration helpers only) sends none.
	if err := s.CopyTo(context.Background(), "u/x/1.jpg", 0, pub, "m/1.jpg", "image/jpeg", "public"); err != nil {
		t.Fatal(err)
	}
	if got := ws.last(t).URL.Query().Get("ifSourceGenerationMatch"); got != "" {
		t.Fatalf("unpinned copy sent ifSourceGenerationMatch=%q", got)
	}
}

func TestCopyTo_ErrorMapping(t *testing.T) {
	tests := []struct {
		name   string
		status int
		want   error
	}{
		{"412 is generation changed", http.StatusPreconditionFailed, ErrGenerationChanged},
		{"404 is not found", http.StatusNotFound, ErrObjectNotFound},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, _ := newWireStore(t, tc.status)
			pub := &Store{bucket: "pub", client: s.client}
			err := s.CopyTo(context.Background(), "u/x/1.jpg", 99, pub, "m/1.jpg", "image/jpeg", "public")
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
		})
	}
}
