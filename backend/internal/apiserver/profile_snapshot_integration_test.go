//go:build integration

package apiserver

// P2 profile-snapshot-refresh over the real Build chain (ADR-0003 "Author snapshot refresh"): a rename or a
// display-name edit publishes one job on the shared jobs topic, delivering it rewrites `author` on the author's
// newest 100 posts, a replay writes nothing, and the daily snapshot-edit quota rejects the sixth edit.

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"connectrpc.com/connect"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func newSnapshotEnv(t *testing.T) *lifecycleEnv {
	t.Helper()
	return newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		c.FeatureProfileSnapshot = flags.Spec{Name: "profile_snapshot", Mode: flags.On}
	})
}

// seedPosts writes n root posts for uid straight into Firestore (oldest first), all at snapshotVersion 0 with the
// given handle, so the test does not depend on the daily post quota.
func seedPosts(t *testing.T, e *lifecycleEnv, uid, handle string, n int) []string {
	t.Helper()
	ctx := context.Background()
	base := time.Now().Add(-time.Hour).UTC().Truncate(time.Millisecond)
	ids := make([]string, 0, n)
	bw := e.fs.BulkWriter(ctx)
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("%019d", 7_000_000_000_000_000_000+int64(time.Now().UnixNano()%1_000_000)*1_000+int64(i))
		ids = append(ids, id)
		_, err := bw.Create(e.fs.Collection("posts").Doc(id), map[string]any{
			"authorId": uid,
			"author":   map[string]any{"userId": uid, "handle": handle, "displayName": "Old Name", "avatarUrl": "", "verified": false},
			"kind":     "POST", "isReply": false, "text": fmt.Sprintf("post %d", i), "conversationId": id,
			"hashtags": []string{}, "mentions": []map[string]any{},
			"likeCount": 0, "repostCount": 0, "replyCount": 0, "quoteCount": 0,
			"visibility": "PUBLIC", "snapshotVersion": 0, "createdAt": base.Add(time.Duration(i) * time.Second),
		})
		if err != nil {
			t.Fatalf("seed post: %v", err)
		}
	}
	bw.End()
	return ids
}

func postAuthor(t *testing.T, e *lifecycleEnv, id string) (handle, name string, version int64) {
	t.Helper()
	snap, err := e.fs.Collection("posts").Doc(id).Get(context.Background())
	if err != nil {
		t.Fatalf("get post %s: %v", id, err)
	}
	h, _ := snap.DataAt("author.handle")
	n, _ := snap.DataAt("author.displayName")
	v, _ := snap.DataAt("snapshotVersion")
	return h.(string), n.(string), v.(int64)
}

// jobLine returns the last account_job line of the profile_snapshot job.
func (e *lifecycleEnv) snapshotJobLines() []map[string]any {
	var out []map[string]any
	for _, l := range e.jobLines() {
		if l["account_job"] == "profile_snapshot" {
			out = append(out, l)
		}
	}
	return out
}

func TestProfileSnapshot_RenameRewritesNewest100Posts(t *testing.T) {
	ctx := context.Background()
	e := newSnapshotEnv(t)
	u := e.newUser(t)
	const total = 105
	ids := seedPosts(t, e, u.uid, "oldhandle", total)

	newHandle := uniqueHandle("rn")
	if _, err := e.identity.ChangeHandle(ctx, authed(u.token, &identityv1.ChangeHandleRequest{IdempotencyKey: "rename-key-000000001", NewHandle: newHandle})); err != nil {
		t.Fatalf("ChangeHandle: %v", err)
	}
	// RPC cost: users + handles reads (+ the interceptor's profile read, cold), 2 writes + 1 delete; the job is
	// a publish, no Firestore.
	if lines := e.requestLinesFor("/dzeroth.identity.v1.IdentityService/ChangeHandle"); len(lines) != 1 || lines[0]["fs_reads"].(float64) > 3 || lines[0]["fs_writes"].(float64) > 3 {
		t.Errorf("ChangeHandle request line = %v", lines)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "profile_snapshot_refresh" || msgs[0]["uid"] != u.uid {
		t.Fatalf("job messages = %v", msgs)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery = %d", code)
	}

	// The newest 100 carry the new handle at version 1; the 5 oldest keep the old snapshot (ADR-0003).
	for i, id := range ids {
		h, _, v := postAuthor(t, e, id)
		wantNew := i >= total-100
		if wantNew && (h != newHandle || v != 1) {
			t.Fatalf("post %d: handle %q v%d, want %q v1", i, h, v, newHandle)
		}
		if !wantNew && (h != "oldhandle" || v != 0) {
			t.Fatalf("post %d: handle %q v%d, want the old snapshot", i, h, v)
		}
	}
	lines := e.snapshotJobLines()
	if len(lines) != 1 || lines[0]["outcome"] != "refreshed" || lines[0]["updated_posts"].(float64) != 100 {
		t.Fatalf("job lines = %v", lines)
	}
	// Budget: 1 users read + 100 post reads; 100 writes in one batch.
	if r, w := lines[0]["fs_reads"].(float64), lines[0]["fs_writes"].(float64); r > 101 || w != 100 {
		t.Errorf("job cost = %v reads / %v writes, want <= 101 / 100", r, w)
	}

	// Replay-safe: the same message again rewrites nothing.
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("replay delivery = %d", code)
	}
	lines = e.snapshotJobLines()
	if len(lines) != 2 || lines[1]["outcome"] != "duplicate" || lines[1]["fs_writes"].(float64) != 0 || lines[1]["fs_reads"].(float64) > 101 {
		t.Fatalf("replay line = %v", lines)
	}
}

func TestProfileSnapshot_DisplayNameEditAndDailyQuota(t *testing.T) {
	ctx := context.Background()
	e := newSnapshotEnv(t)
	u := e.newUser(t)
	ids := seedPosts(t, e, u.uid, "somehandle", 3)

	edit := func(name string) error {
		_, err := e.identity.UpdateProfile(ctx, authed(u.token, &identityv1.UpdateProfileRequest{
			IdempotencyKey: fmt.Sprintf("edit-key-%s-0001", name), DisplayName: &name,
		}))
		return err
	}
	if err := edit("Alpha"); err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	// 1 users read (+ interceptor cold read) and quotas: reads <= 3, writes 2 (users + quotas).
	if lines := e.requestLinesFor("/dzeroth.identity.v1.IdentityService/UpdateProfile"); len(lines) != 1 || lines[0]["fs_reads"].(float64) > 3 || lines[0]["fs_writes"].(float64) != 2 {
		t.Errorf("UpdateProfile request line = %v, want reads <= 3, writes 2", lines)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 {
		t.Fatalf("job messages = %v", msgs)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery = %d", code)
	}
	for _, id := range ids {
		if _, name, v := postAuthor(t, e, id); name != "Alpha" || v != 1 {
			t.Fatalf("post %s: name %q v%d, want Alpha v1", id, name, v)
		}
	}

	// Edits 2..5 are accepted, the 6th is RESOURCE_EXHAUSTED (5 snapshot edits a day).
	for i, n := range []string{"Beta", "Gamma", "Delta", "Epsilon"} {
		if err := edit(n); err != nil {
			t.Fatalf("edit %d: %v", i+2, err)
		}
	}
	wireError(t, edit("Zeta"), connect.CodeResourceExhausted)
	// A bio-only edit is not a snapshot edit.
	bio := "still allowed"
	if _, err := e.identity.UpdateProfile(ctx, authed(u.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "bio-key-0000000001", Bio: &bio})); err != nil {
		t.Fatalf("bio edit at the quota: %v", err)
	}
	snap, err := e.fs.Doc("quotas/" + u.uid).Get(ctx)
	if err != nil {
		t.Fatalf("quotas doc: %v", err)
	}
	if n, _ := snap.DataAt("snapshotEdits"); n != int64(5) {
		t.Fatalf("snapshotEdits = %v, want 5", n)
	}
}
