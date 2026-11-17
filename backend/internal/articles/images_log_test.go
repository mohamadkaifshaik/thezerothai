package articles

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"

	av "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
)

// A failed image resolution is logged with the resolver's error scrubbed: Firestore names the media documents under the
// author's uid, and the raw uid must not reach the WARN line. The article still reads without its images.
func TestWithImages_ScrubsResolverError(t *testing.T) {
	// Not parallel: it swaps the process-wide default logger (withImages logs through slog's default).
	const author = "AuthorUidAbCdEfGhIjKl123"
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })

	s := &Server{images: &fakeImages{err: errors.New("rpc error: documents/users/" + author + "/media/" + imgA + " unavailable")}}
	out := &av.Article{}
	s.withImages(context.Background(), out, &record{ID: "a1", AuthorID: author, Body: body(imageBlock(imgA, "", ""))}, "")

	got := buf.String()
	if !strings.Contains(got, "article_images_unresolved") {
		t.Fatalf("no WARN line: %s", got)
	}
	if strings.Contains(got, author) {
		t.Errorf("raw author uid in %s", got)
	}
	if !strings.Contains(got, "rpc error: <redacted>") {
		t.Errorf("cause lost: %s", got)
	}
	if len(out.Images) != 0 {
		t.Errorf("images = %v, want none on a failed resolution", out.Images)
	}
}
