//go:build integration

package objstore

import (
	"bytes"
	"context"
	"crypto/md5"
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

// TestMediaOps_Integration covers the media pipeline's reads and the cross-bucket copy against the Storage
// emulator: attributes (size, content type, MD5), a ranged head read, a copy that sets the public Cache-Control,
// and the not-found paths.
func TestMediaOps_Integration(t *testing.T) {
	if os.Getenv("STORAGE_EMULATOR_HOST") == "" {
		t.Skip("STORAGE_EMULATOR_HOST not set; run via the emulator suite")
	}
	ctx := context.Background()
	suffix := rand.Int63()
	up, err := New(fmt.Sprintf("demo-upload-%d", suffix))
	if err != nil {
		t.Fatal(err)
	}
	pub, err := New(fmt.Sprintf("demo-public-%d", suffix))
	if err != nil {
		t.Fatal(err)
	}
	body := "\xff\xd8\xff\xe0" + string(make([]byte, 600))
	if err := up.Put(ctx, "u/x/1.jpg", "image/jpeg", func(w io.Writer) error { _, err := io.WriteString(w, body); return err }); err != nil {
		t.Fatal(err)
	}

	a, err := up.Attrs(ctx, "u/x/1.jpg")
	if err != nil {
		t.Fatalf("Attrs: %v", err)
	}
	sum := md5.Sum([]byte(body))
	if a.Size != int64(len(body)) || a.ContentType != "image/jpeg" || !bytes.Equal(a.MD5, sum[:]) {
		t.Fatalf("attrs = %+v", a)
	}
	if _, err := up.Attrs(ctx, "u/x/missing.jpg"); !errors.Is(err, ErrObjectNotFound) {
		t.Fatalf("Attrs of a missing object: %v", err)
	}

	head, err := up.ReadHead(ctx, "u/x/1.jpg", 512)
	if err != nil || len(head) != 512 || head[0] != 0xff || head[1] != 0xd8 {
		t.Fatalf("ReadHead = %d bytes, %v", len(head), err)
	}
	if _, err := up.ReadHead(ctx, "u/x/missing.jpg", 512); !errors.Is(err, ErrObjectNotFound) {
		t.Fatalf("ReadHead of a missing object: %v", err)
	}

	if err := up.CopyTo(ctx, "u/x/1.jpg", pub, "m/1.jpg", "image/jpeg", "public, max-age=31536000, immutable"); err != nil {
		t.Fatalf("CopyTo: %v", err)
	}
	pa, err := pub.Attrs(ctx, "m/1.jpg")
	if err != nil || pa.Size != int64(len(body)) || pa.ContentType != "image/jpeg" {
		t.Fatalf("published attrs = %+v, %v", pa, err)
	}
	if got, ok := readObject(t, pub, "m/1.jpg"); !ok || got != body {
		t.Fatal("published bytes differ from the upload")
	}
	// A repeated copy replaces the destination harmlessly; a missing source is ErrObjectNotFound.
	if err := up.CopyTo(ctx, "u/x/1.jpg", pub, "m/1.jpg", "image/jpeg", "public"); err != nil {
		t.Fatalf("second CopyTo: %v", err)
	}
	if err := up.CopyTo(ctx, "u/x/missing.jpg", pub, "m/2.jpg", "image/jpeg", "public"); !errors.Is(err, ErrObjectNotFound) {
		t.Fatalf("CopyTo of a missing source: %v", err)
	}
}
