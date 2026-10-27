//go:build integration

package main

import (
	"bytes"
	"context"
	"fmt"
	"math/rand"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// End-to-end emulator test of `opsctl backfill-has-media`: the real run() flag handling and output over the real posts
// repo. The opener wires only the backfiller (openFirestore also needs the Auth Admin client, which this command does not).

func backfillTestClient(t *testing.T) (*firestore.Client, string) {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	project := fmt.Sprintf("demo-test-%d", rand.Int63())
	client, err := firestore.NewClient(context.Background(), project)
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client, project
}

func runBackfillCLI(t *testing.T, client *firestore.Client, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	open := func(context.Context, string) (*backends, error) {
		return &backends{backfiller: posts.NewFirestoreRepo(client), close: func() {}}, nil
	}
	var out, errOut bytes.Buffer
	code = run(context.Background(), args, strings.NewReader(""), &out, &errOut, open, time.Now)
	return code, out.String(), errOut.String()
}

func TestBackfillHasMedia_Integration_CLI(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	media := []any{map[string]any{"mediaId": "m1", "url": "https://x/i.webp"}}
	seed := map[string]map[string]any{
		"1000000000000000001": {"authorId": "u1", "kind": "POST", "text": "legacy image", "media": media},
		"1000000000000000002": {"authorId": "u1", "kind": "POST", "text": "legacy text"},
		"1000000000000000003": {"authorId": "u2", "kind": "REPOST", "repostOfId": "1000000000000000001", "embedded": map[string]any{"media": media}},
		"1000000000000000004": {"authorId": "u1", "kind": "POST", "text": "new image", "media": media, "hasMedia": true},
		"1000000000000000005": {"authorId": "u1", "kind": "POST", "text": "new text", "hasMedia": false},
	}
	for id, d := range seed {
		if _, err := client.Collection("posts").Doc(id).Set(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	stored := func(id string) (value, present bool) {
		s, err := client.Collection("posts").Doc(id).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		value, present = s.Data()["hasMedia"].(bool)
		return value, present
	}

	// Dry run first: counts, writes nothing.
	code, stdout, stderr := runBackfillCLI(t, client, "backfill-has-media", "--project", project, "--dry-run")
	if code != 0 {
		t.Fatalf("dry run exit code = %d, stderr=%q", code, stderr)
	}
	t.Logf("dry run output:\n%s", stdout)
	for _, want := range []string{
		"backfill-has-media: reads=5 writes=0 deletes=0",
		"dry-run: scanned=5 missing=3 would_update=3 runs_needed=1 (nothing written)",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("dry run stdout missing %q:\n%s", want, stdout)
		}
	}
	if _, present := stored("1000000000000000001"); present {
		t.Fatal("the dry run wrote hasMedia")
	}

	// The real run.
	code, stdout, stderr = runBackfillCLI(t, client, "backfill-has-media", "--project", project)
	if code != 0 {
		t.Fatalf("exit code = %d, stderr=%q", code, stderr)
	}
	t.Logf("real run output:\n%s", stdout)
	for _, want := range []string{
		"backfill-has-media: reads=5 writes=3 deletes=0",
		"backfill-has-media: complete: scanned=5 updated=3 checkpoint=1000000000000000005",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("run stdout missing %q:\n%s", want, stdout)
		}
	}
	for id, want := range map[string]bool{"1000000000000000001": true, "1000000000000000002": false, "1000000000000000003": false, "1000000000000000004": true, "1000000000000000005": false} {
		if got, present := stored(id); !present || got != want {
			t.Errorf("posts/%s.hasMedia = %v (present=%v), want %v", id, got, present, want)
		}
	}

	// The rerun is clean: it reads everything and writes nothing.
	code, stdout, stderr = runBackfillCLI(t, client, "backfill-has-media", "--project", project)
	if code != 0 {
		t.Fatalf("rerun exit code = %d, stderr=%q", code, stderr)
	}
	t.Logf("rerun output:\n%s", stdout)
	for _, want := range []string{
		"backfill-has-media: reads=5 writes=0 deletes=0",
		"backfill-has-media: complete: scanned=5 updated=0 checkpoint=1000000000000000005",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("rerun stdout missing %q:\n%s", want, stdout)
		}
	}

	// --after resumes: only the posts after the checkpoint are read.
	code, stdout, stderr = runBackfillCLI(t, client, "backfill-has-media", "--project", project, "--after", "1000000000000000003")
	if code != 0 || !strings.Contains(stdout, "backfill-has-media: reads=2 writes=0 deletes=0") ||
		!strings.Contains(stdout, "complete: scanned=2 updated=0") {
		t.Errorf("--after run: code=%d stdout=\n%s\nstderr=%q", code, stdout, stderr)
	}
}
