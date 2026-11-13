//go:build integration

package engagement

import (
	"bytes"
	"context"
	"encoding/json"
	"sync"
	"testing"
)

// CreateShare on the emulator: ten concurrent first shares by one account commit exactly one marker and move shareCount
// once; a later call is ShareExists; a post that is gone is SharePostGone with no marker left behind.
func TestRepo_CreateShareOncePerAccount(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const pid, gone, uid = "0000000000000000051", "0000000000000000052", "sharer1"
	e.seedPost(t, pid, "author", 0, 0)

	var wg sync.WaitGroup
	outcomes := make([]ShareOutcome, 10)
	errs := make([]error, 10)
	for i := range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			outcomes[i], errs[i] = e.repo.CreateShare(ctx, uid, pid)
		}()
	}
	wg.Wait()
	created := 0
	for i, o := range outcomes {
		if errs[i] != nil {
			t.Fatalf("call %d: %v", i, errs[i])
		}
		if o == ShareCreated {
			created++
		}
	}
	if created != 1 {
		t.Fatalf("created = %d of 10 concurrent calls, want exactly 1", created)
	}
	if got := e.intField(t, "posts/"+pid, "shareCount"); got != 1 {
		t.Fatalf("shareCount = %d, want 1", got)
	}
	if has, err := e.repo.HasShare(ctx, uid, pid); err != nil || !has {
		t.Fatalf("HasShare = %v, %v; want true", has, err)
	}
	if o, err := e.repo.CreateShare(ctx, uid, pid); err != nil || o != ShareExists {
		t.Fatalf("repeat = %v, %v; want ShareExists", o, err)
	}
	if o, err := e.repo.CreateShare(ctx, uid, gone); err != nil || o != SharePostGone {
		t.Fatalf("gone post = %v, %v; want SharePostGone", o, err)
	}
	if e.exists(t, "postShares/"+gone+"_"+uid) {
		t.Fatal("a share of a missing post left a marker")
	}
	// The marker holds the post, the uid and the time only: never a channel, conversation or recipient.
	s, err := e.client.Doc("postShares/" + pid + "_" + uid).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if got := len(s.Data()); got != 3 {
		t.Fatalf("marker fields = %v, want postId, uid and createdAt only", s.Data())
	}
}

// The erasure step deletes the account's markers with shareCount -1 (a post that is gone falls back to a delete-only
// batch), the export lists them, the post_delete job removes a deleted post's markers, and CountShares counts them.
func TestRepo_SharesLifecycle(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const live, dead, uid, other = "0000000000000000061", "0000000000000000062", "sharer2", "sharer3"
	e.seedPost(t, live, "author", 0, 0)
	e.seedPost(t, dead, "author", 0, 0)
	for _, p := range []string{live, dead} {
		if o, err := e.repo.CreateShare(ctx, uid, p); err != nil || o != ShareCreated {
			t.Fatalf("share %s: %v %v", p, o, err)
		}
	}
	if o, err := e.repo.CreateShare(ctx, other, live); err != nil || o != ShareCreated {
		t.Fatalf("other share: %v %v", o, err)
	}
	if n, err := e.repo.CountShares(ctx, live); err != nil || n != 2 {
		t.Fatalf("CountShares = %d, %v; want 2", n, err)
	}

	var buf bytes.Buffer
	if err := e.repo.ExportUser(ctx, uid, &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Shares []map[string]any `json:"shares"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil || len(out.Shares) != 2 {
		t.Fatalf("export = %s, err %v; want 2 shares", buf.String(), err)
	}
	if out.Shares[0]["postId"] == nil || out.Shares[0]["createdAt"] == nil || len(out.Shares[0]) != 2 {
		t.Fatalf("export share = %v, want postId and createdAt only", out.Shares[0])
	}

	if _, err := e.client.Doc("posts/" + dead).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	cp, done := Checkpoint{}, false
	for i := 0; !done; i++ {
		var err error
		if cp, done, err = e.repo.PurgeUser(ctx, uid, cp); err != nil {
			t.Fatal(err)
		}
		if i > 6 {
			t.Fatal("purge did not finish")
		}
	}
	if cp.Deleted != 2 {
		t.Errorf("deleted = %d, want 2 markers", cp.Deleted)
	}
	if got := e.intField(t, "posts/"+live, "shareCount"); got != 1 {
		t.Errorf("shareCount after erasure = %d, want 1 (the other account's share)", got)
	}
	for _, p := range []string{live, dead} {
		if e.exists(t, "postShares/"+p+"_"+uid) {
			t.Errorf("marker of %s survived the erasure", p)
		}
	}

	// A checkpoint stored by an older revision at step 2 (userLikes) still finishes: shares are numbered 3.
	if _, done, err := e.repo.PurgeUser(ctx, uid, Checkpoint{Step: purgeStepDoc}); err != nil || !done {
		t.Fatalf("old checkpoint: done=%v err=%v", done, err)
	}

	// post_delete: the remaining marker of the live post goes with it.
	if _, err := e.client.Doc("posts/" + live).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	j := NewJobs(e.repo, e.posts, stubGone{}, nil)
	msg, _ := json.Marshal(map[string]any{"kind": JobKindPostDelete, "uid": "author", "postId": live})
	if outcome, err := j.Handle(ctx, msg); err != nil || outcome != "done" {
		t.Fatalf("job: %q %v", outcome, err)
	}
	if e.exists(t, "postShares/"+live+"_"+other) {
		t.Error("post_delete left a share marker")
	}
}

// StoredShareCount and SetShareCount (opsctl recount-shares) on the emulator: absent reads 0, a set lands, a missing post
// is reported.
func TestRepo_ShareCountRepair(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const pid, missing = "0000000000000000071", "0000000000000000072"
	e.seedPost(t, pid, "author", 0, 0)
	if n, found, err := e.posts.StoredShareCount(ctx, pid); err != nil || !found || n != 0 {
		t.Fatalf("stored = %d %v %v, want 0 found", n, found, err)
	}
	if err := e.posts.SetShareCount(ctx, pid, 4); err != nil {
		t.Fatal(err)
	}
	if n, _, err := e.posts.StoredShareCount(ctx, pid); err != nil || n != 4 {
		t.Fatalf("after set = %d %v, want 4", n, err)
	}
	if _, found, err := e.posts.StoredShareCount(ctx, missing); err != nil || found {
		t.Fatalf("missing post: found=%v err=%v", found, err)
	}
	if err := e.posts.SetShareCount(ctx, missing, 1); err == nil {
		t.Fatal("SetShareCount on a missing post must fail")
	}
	// The post converter reads the counter back.
	got, err := e.posts.GetAll(ctx, []string{pid})
	if err != nil || got[pid] == nil || got[pid].ShareCount != 4 {
		t.Fatalf("post = %v, %v; want ShareCount 4", got[pid], err)
	}
}
