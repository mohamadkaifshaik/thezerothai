//go:build integration

package main

import (
	"bytes"
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// End-to-end emulator test of `opsctl recount-children` over the real posts.FirestoreRepo: the --before cutoff, the dry
// run, a --max-posts stop and an exact --resume, and a --write that fixes only the stale counters.
func TestRecountChildrenBulk_Integration(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	seed := func(id string, d map[string]any) {
		t.Helper()
		at, err := snowflake.Time(id)
		if err != nil {
			t.Fatal(err)
		}
		d["createdAt"], d["authorId"] = at, "u-bulk"
		if _, err := client.Collection("posts").Doc(id).Set(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	// Before the cutoff: three stale parents, one in step, one REPOST with a bogus count; after it: one stale parent.
	stale := []string{bulkID(t, 5*time.Hour, 0), bulkID(t, 4*time.Hour, 0), bulkID(t, 3*time.Hour, 0)}
	inStep, repost, newer := bulkID(t, 2*time.Hour, 0), bulkID(t, time.Hour, 0), bulkID(t, -time.Hour, 0)
	seed(stale[0], map[string]any{"kind": "POST", "replyCount": int64(5), "quoteCount": int64(0)})
	seed(stale[1], map[string]any{"kind": "QUOTE", "replyCount": int64(0), "quoteCount": int64(2)})
	seed(stale[2], map[string]any{"kind": "POST", "replyCount": int64(3), "quoteCount": int64(3)})
	seed(inStep, map[string]any{"kind": "POST", "replyCount": int64(1), "quoteCount": int64(0)})
	seed(repost, map[string]any{"kind": "REPOST", "replyCount": int64(7), "quoteCount": int64(0)})
	seed(newer, map[string]any{"kind": "POST", "replyCount": int64(9), "quoteCount": int64(0)})
	// Children (created after the cutoff, so never scanned themselves): 1 reply to stale[0], 1 quote of stale[2], 1 reply
	// to inStep.
	seed(bulkID(t, -2*time.Hour, 1), map[string]any{"kind": "REPLY", "replyToId": stale[0], "isReply": true})
	seed(bulkID(t, -2*time.Hour, 2), map[string]any{"kind": "QUOTE", "quoteOfId": stale[2]})
	seed(bulkID(t, -2*time.Hour, 3), map[string]any{"kind": "REPLY", "replyToId": inStep, "isReply": true})

	cpPath := filepath.Join(t.TempDir(), "cp.json")
	clock := &fakeClock{t: bulkNow}
	runCLI := func(args ...string) (int, string, string) {
		t.Helper()
		open := func(context.Context, string) (*backends, error) {
			return &backends{childBulk: posts.NewFirestoreRepo(client), sleep: clock.sleep, close: func() {}}, nil
		}
		full := append([]string{"recount-children", "--project", project, "--before", bulkBefore.Format(time.RFC3339), "--checkpoint", cpPath}, args...)
		var out, errOut bytes.Buffer
		code := run(ctx, full, strings.NewReader(""), &out, &errOut, open, clock.now)
		return code, out.String(), errOut.String()
	}
	counters := func(id string) (int64, int64) {
		t.Helper()
		snap, err := client.Collection("posts").Doc(id).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		r, _ := snap.DataAt("replyCount")
		q, _ := snap.DataAt("quoteCount")
		rn, _ := r.(int64)
		qn, _ := q.(int64)
		return rn, qn
	}
	updated := func() map[string]time.Time {
		docs, err := client.Collection("posts").Limit(50).Documents(ctx).GetAll()
		if err != nil {
			t.Fatal(err)
		}
		m := map[string]time.Time{}
		for _, d := range docs {
			m[d.Ref.ID] = d.UpdateTime
		}
		return m
	}
	before := updated()

	// Dry run in two parts: --max-posts 2, then --resume. Every stale counter is reported exactly once; nothing is written.
	code, out1, errOut := runCLI("--max-posts", "2")
	if code != 0 || !strings.Contains(out1, "--max-posts reached") {
		t.Fatalf("first part: code %d out %q err %q", code, out1, errOut)
	}
	code, out2, errOut := runCLI("--resume")
	if code != 0 || !strings.Contains(out2, "complete") {
		t.Fatalf("resume: code %d out %q err %q", code, out2, errOut)
	}
	all := out1 + out2
	for _, w := range []string{
		"post=" + stale[0] + " field=reply_count stored=5 recounted=1 action=dry-run",
		"post=" + stale[1] + " field=quote_count stored=2 recounted=0 action=dry-run",
		"post=" + stale[2] + " field=reply_count stored=3 recounted=0 action=dry-run",
		"post=" + stale[2] + " field=quote_count stored=3 recounted=1 action=dry-run",
	} {
		if strings.Count(all, w) != 1 {
			t.Errorf("%q appears %d times, want once:\n%s", w, strings.Count(all, w), all)
		}
	}
	if strings.Contains(all, "post="+inStep) || strings.Contains(all, "post="+repost) || strings.Contains(all, newer) {
		t.Fatalf("an in-step post, the REPOST or a post after --before was reported:\n%s", all)
	}
	if !strings.Contains(out2, "totals with the resumed checkpoint: scanned=5 reposts_skipped=1 mismatched=4 written=0") {
		t.Fatalf("resumed totals:\n%s", out2)
	}
	for id, at := range updated() {
		if !at.Equal(before[id]) {
			t.Fatalf("the dry run wrote %s", id)
		}
	}

	// --write (a dry-run checkpoint cannot be resumed in write mode; --force starts over).
	if code, _, errOut := runCLI("--write", "--resume"); code != 2 || !strings.Contains(errOut, "dry-run run") {
		t.Fatalf("mode mismatch: code %d err %q", code, errOut)
	}
	code, out, errOut := runCLI("--write", "--force")
	if code != 0 || !strings.Contains(out, "mismatched=4 written=3") {
		t.Fatalf("write: code %d out %q err %q", code, out, errOut)
	}
	for id, want := range map[string][2]int64{stale[0]: {1, 0}, stale[1]: {0, 0}, stale[2]: {0, 1}, inStep: {1, 0}, repost: {7, 0}, newer: {9, 0}} {
		if r, q := counters(id); r != want[0] || q != want[1] {
			t.Errorf("%s counters = %d, %d; want %d, %d", id, r, q, want[0], want[1])
		}
	}
	after := updated()
	for _, id := range []string{inStep, repost, newer} {
		if !after[id].Equal(before[id]) {
			t.Errorf("%s was written but needed no repair", id)
		}
	}
	cp, err := loadBulkCheckpoint(cpPath)
	if err != nil || cp.State != "complete" || cp.Mode != "write" || cp.After != repost {
		t.Fatalf("checkpoint = %+v, %v", cp, err)
	}
}
