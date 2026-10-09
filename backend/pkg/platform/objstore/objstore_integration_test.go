//go:build integration

package objstore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"testing"

	"cloud.google.com/go/storage"
)

func readObject(t *testing.T, s *Store, name string) (string, bool) {
	t.Helper()
	obj, err := s.handle(context.Background(), name)
	if err != nil {
		t.Fatal(err)
	}
	r, err := obj.NewReader(context.Background())
	if errors.Is(err, storage.ErrObjectNotExist) {
		return "", false
	}
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	defer r.Close()
	b, _ := io.ReadAll(r)
	return string(b), true
}

// TestPutDelete_Integration runs against the Storage emulator: a failed write leaves nothing (and keeps the
// previous object), a successful one replaces it, and deleting a missing object is success.
func TestPutDelete_Integration(t *testing.T) {
	if os.Getenv("STORAGE_EMULATOR_HOST") == "" {
		t.Skip("STORAGE_EMULATOR_HOST not set; run via the emulator suite")
	}
	ctx := context.Background()
	s, err := New(fmt.Sprintf("demo-objstore-%d", rand.Int63()))
	if err != nil {
		t.Fatal(err)
	}

	if err := s.Put(ctx, "a.json", "application/json", func(w io.Writer) error { _, err := io.WriteString(w, `{"v":1}`); return err }); err != nil {
		t.Fatalf("Put: %v", err)
	}
	if got, ok := readObject(t, s, "a.json"); !ok || got != `{"v":1}` {
		t.Fatalf("object = %q, %v", got, ok)
	}

	boom := errors.New("composer failed")
	err = s.Put(ctx, "a.json", "application/json", func(w io.Writer) error { _, _ = io.WriteString(w, `{"v":"partial`); return boom })
	if !errors.Is(err, boom) {
		t.Fatalf("Put err = %v, want the composer's error", err)
	}
	if got, _ := readObject(t, s, "a.json"); got != `{"v":1}` {
		t.Errorf("a failed overwrite changed the object to %q", got)
	}

	err = s.Put(ctx, "never.json", "application/json", func(w io.Writer) error { _, _ = io.WriteString(w, "partial"); return boom })
	if !errors.Is(err, boom) {
		t.Fatalf("Put err = %v", err)
	}
	if _, ok := readObject(t, s, "never.json"); ok {
		t.Error("a failed first write left an object behind")
	}

	if err := s.Put(ctx, "a.json", "application/json", func(w io.Writer) error { _, err := io.WriteString(w, `{"v":2}`); return err }); err != nil {
		t.Fatal(err)
	}
	if got, _ := readObject(t, s, "a.json"); got != `{"v":2}` {
		t.Errorf("overwrite = %q", got)
	}
	if err := s.Delete(ctx, "a.json"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if err := s.Delete(ctx, "a.json"); err != nil {
		t.Errorf("Delete of a missing object: %v", err)
	}
	if _, ok := readObject(t, s, "a.json"); ok {
		t.Error("object survived Delete")
	}
}
