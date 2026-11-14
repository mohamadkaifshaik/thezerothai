//go:build integration

package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// End-to-end emulator test of `opsctl recount-replies|recount-quotes`: the real flag handling and output over the real
// posts.FirestoreRepo. Every referencing doc counts, whatever its moderation state.
func TestRecountChildren_Integration_CLI(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	const target, missing = "0000000000000007001", "0000000000000007999"
	docs := map[string]map[string]any{
		target:                {"authorId": "u-a", "replyCount": int64(5), "quoteCount": int64(0)},
		"0000000000000007002": {"authorId": "u-b", "replyToId": target},
		"0000000000000007003": {"authorId": "u-c", "replyToId": target, "moderation": map[string]any{"state": "REMOVED"}},
		"0000000000000007004": {"authorId": "u-d", "quoteOfId": target},
	}
	for id, d := range docs {
		d["createdAt"] = time.Now().UTC()
		if _, err := client.Collection("posts").Doc(id).Set(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	runCLI := func(args ...string) (int, string, string) {
		open := func(context.Context, string) (*backends, error) {
			return &backends{childCounts: posts.NewFirestoreRepo(client), close: func() {}}, nil
		}
		var out, errOut bytes.Buffer
		code := run(ctx, append(args, "--project", project), strings.NewReader(""), &out, &errOut, open, time.Now)
		return code, out.String(), errOut.String()
	}
	field := func(name string) int64 {
		t.Helper()
		snap, err := client.Collection("posts").Doc(target).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		v, _ := snap.DataAt(name)
		n, _ := v.(int64)
		return n
	}
	steps := []struct {
		args         []string
		want         string
		replies, quo int64
	}{
		{[]string{"recount-replies", "--post", target}, "dry-run: would set reply_count to 2", 5, 0},
		{[]string{"recount-replies", "--post", target, "--write"}, "set reply_count to 2", 2, 0},
		{[]string{"recount-replies", "--post", target, "--write"}, "in step", 2, 0},
		{[]string{"recount-quotes", "--post", target, "--write"}, "set quote_count to 1", 2, 1},
	}
	for _, s := range steps {
		code, out, errOut := runCLI(s.args...)
		if code != 0 || !strings.Contains(out, s.want) {
			t.Fatalf("%v: code %d out %q err %q, want %q", s.args, code, out, errOut, s.want)
		}
		if r, q := field("replyCount"), field("quoteCount"); r != s.replies || q != s.quo {
			t.Fatalf("%v: counts %d, %d; want %d, %d", s.args, r, q, s.replies, s.quo)
		}
	}
	if code, _, errOut := runCLI("recount-quotes", "--post", missing, "--write"); code != 1 || !strings.Contains(errOut, "not found") {
		t.Fatalf("missing post: code %d err %q", code, errOut)
	}
	if snap, err := client.Collection("posts").Doc(missing).Get(ctx); err == nil && snap.Exists() {
		t.Fatal("the recount created the missing post")
	}
}
